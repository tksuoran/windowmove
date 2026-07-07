// WindowMove for macOS.
//
// Hold down the capslock key and move the mouse to drag the window under the
// cursor. This is a port of the Windows version in main.cpp.
//
// The port uses:
//  - IOHIDManager to observe physical capslock key press and release events.
//    macOS does not deliver a key up event for capslock through the regular
//    event APIs (it only reports lock state transitions), so the raw HID
//    events are the only reliable way to implement "hold capslock" behavior.
//    This requires the Input Monitoring permission.
//  - A CGEventTap to observe synthesized capslock events. Remote desktop
//    software (Parsec, ...) does not press keys through real hardware, it
//    injects events into the window server with CGEventPost, and those events
//    never reach IOHIDManager. Unlike physical capslock events, synthesized
//    events do carry usable press/release information.
//  - The Accessibility API (AXUIElement) to find the window under the cursor
//    and to move it. This requires the Accessibility permission.
//  - IOHIDSetModifierLockState() to undo the capslock state being toggled
//    when the key was used to drag a window. This is the equivalent of the
//    synthesized capslock key events in the Windows version.
//
// Unlike the Windows version there is no low level mouse hook; instead a
// timer polls the cursor position while a drag is active. This works for both
// physical and injected mouse movement, and the timer only runs during a
// drag.
//
// Development builds (make dev) write a log to ~/Library/Logs/WindowMove.log,
// including every key event seen, which is how keyboards and remote desktop
// software whose capslock arrives in unexpected ways get diagnosed. Normal
// builds must never have logging enabled, since the log would contain
// everything the user types.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDParameter.h>
#import <IOKit/hidsystem/IOHIDShared.h>

#if defined(WINDOWMOVE_ENABLE_LOGGING)
#import <cstdarg>
#import <cstdio>
#import <ctime>
#import <initializer_list>
#endif

// Same value as the Windows scancode, by coincidence
#define VIRTUAL_KEYCODE_CAPSLOCK 0x39

AXUIElementRef    system_wide_element = nullptr;
AXUIElementRef    drag_window         = nullptr; // Window being dragged, nullptr when no drag is active
CGPoint           drag_start_cursor   = {};
CGPoint           drag_start_window   = {};
CGPoint           last_position       = {};
bool              was_moved           = false;
bool              capslock_is_down    = false;
bool              undo_toggle         = false; // Undo capslock toggle at release; only for the physical key
CFRunLoopTimerRef drag_timer          = nullptr;
IOHIDManagerRef   hid_manager         = nullptr;
CFMachPortRef     event_tap           = nullptr;
io_connect_t      hid_system          = IO_OBJECT_NULL;

#if defined(WINDOWMOVE_ENABLE_LOGGING)

FILE* log_file = nullptr;

// Logs to both stdout (visible when run from a terminal) and the log file
// (visible when launched with open / as a login item).
void log_line(const char* format, ...)
{
    char timestamp[32];
    const time_t now = time(nullptr);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", localtime(&now));
    for (FILE* stream : { stdout, log_file }) {
        if (stream == nullptr) {
            continue;
        }
        fprintf(stream, "%s ", timestamp);
        va_list args;
        va_start(args, format);
        vfprintf(stream, format, args);
        va_end(args);
        fprintf(stream, "\n");
        fflush(stream);
    }
}

#else

// Logging is compiled out of normal builds
#define log_line(...) do { } while (0)

#endif

// Current cursor position in global display coordinates (origin at the top
// left of the primary display, y grows downwards). This is the same
// coordinate space the Accessibility API uses for window positions.
CGPoint cursor_position()
{
    CGEventRef event = CGEventCreate(nullptr);
    const CGPoint position = CGEventGetLocation(event);
    CFRelease(event);
    return position;
}

// Find the top level window under the given position. The element under the
// cursor is typically a child element (button, text area, toolbar, ...), so
// ask for the window containing it, and if the element does not report its
// window, walk up the parent chain looking for an element with the window
// role. This is the equivalent of the GetParent() walk in the Windows
// version. The caller owns the returned reference.
AXUIElementRef copy_window_at_position(CGPoint position)
{
    AXUIElementRef element = nullptr;
    AXError error = AXUIElementCopyElementAtPosition(
        system_wide_element,
        static_cast<float>(position.x),
        static_cast<float>(position.y),
        &element
    );
    if ((error != kAXErrorSuccess) || (element == nullptr)) {
        return nullptr;
    }

    AXUIElementRef window = nullptr;
    error = AXUIElementCopyAttributeValue(element, kAXWindowAttribute, reinterpret_cast<CFTypeRef*>(&window));
    if ((error == kAXErrorSuccess) && (window != nullptr)) {
        CFRelease(element);
        return window;
    }

    AXUIElementRef current = element;
    for (;;) {
        CFStringRef role = nullptr;
        error = AXUIElementCopyAttributeValue(current, kAXRoleAttribute, reinterpret_cast<CFTypeRef*>(&role));
        if ((error == kAXErrorSuccess) && (role != nullptr)) {
            const bool is_window = CFEqual(role, kAXWindowRole);
            CFRelease(role);
            if (is_window) {
                return current;
            }
        }
        AXUIElementRef parent = nullptr;
        error = AXUIElementCopyAttributeValue(current, kAXParentAttribute, reinterpret_cast<CFTypeRef*>(&parent));
        CFRelease(current);
        if ((error != kAXErrorSuccess) || (parent == nullptr)) {
            return nullptr;
        }
        current = parent;
    }
}

bool get_window_position(AXUIElementRef window, CGPoint* out_position)
{
    AXValueRef value = nullptr;
    const AXError error = AXUIElementCopyAttributeValue(window, kAXPositionAttribute, reinterpret_cast<CFTypeRef*>(&value));
    if ((error != kAXErrorSuccess) || (value == nullptr)) {
        return false;
    }
    const bool ok = AXValueGetValue(value, kAXValueTypeCGPoint, out_position);
    CFRelease(value);
    return ok;
}

void set_window_position(AXUIElementRef window, CGPoint position)
{
    AXValueRef value = AXValueCreate(kAXValueTypeCGPoint, &position);
    if (value != nullptr) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute, value);
        CFRelease(value);
    }
}

// Equivalent of SetForegroundWindow() in the Windows version.
// This is optional but I find it useful.
void raise_window(AXUIElementRef window)
{
    AXUIElementPerformAction(window, kAXRaiseAction);
    pid_t pid = 0;
    if (AXUIElementGetPid(window, &pid) == kAXErrorSuccess) {
        NSRunningApplication* application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
    }
}

// Pressing capslock toggles the capslock state. When capslock was used to
// drag a window, we want to undo that toggle so that dragging does not change
// the capslock state, same as the Windows version does with synthesized key
// events. On macOS the state can be set directly through IOHIDSystem.
void undo_capslock_toggle()
{
    if (hid_system == IO_OBJECT_NULL) {
        return;
    }
    bool state = false;
    if (IOHIDGetModifierLockState(hid_system, kIOHIDCapsLockState, &state) == KERN_SUCCESS) {
        IOHIDSetModifierLockState(hid_system, kIOHIDCapsLockState, !state);
    }
}

// Moves the window being dragged while drag is active and the mouse is being
// moved. Equivalent of the low level mouse hook in the Windows version.
void drag_timer_fired(CFRunLoopTimerRef timer, void* info)
{
    (void)timer;
    (void)info;
    if (drag_window == nullptr) {
        return;
    }
    const CGPoint cursor = cursor_position();
    if ((cursor.x == last_position.x) && (cursor.y == last_position.y)) {
        return;
    }
    last_position = cursor;
    was_moved = true;
    // Position the window relative to where it and the cursor were when the
    // drag started, instead of accumulating deltas, so rounding does not make
    // the window drift under the cursor.
    const CGPoint position = CGPointMake(
        drag_start_window.x + (cursor.x - drag_start_cursor.x),
        drag_start_window.y + (cursor.y - drag_start_cursor.y)
    );
    set_window_position(drag_window, position);
}

// Capslock was pressed: (try to) start a new drag on the window under the cursor.
void begin_drag()
{
    if (drag_window != nullptr) {
        return;
    }
    const CGPoint cursor = cursor_position();
    AXUIElementRef window = copy_window_at_position(cursor);
    if (window == nullptr) {
        log_line("begin drag: no window under cursor");
        return;
    }
    if (!get_window_position(window, &drag_start_window)) {
        log_line("begin drag: could not read window position");
        CFRelease(window);
        return;
    }
    drag_window       = window;
    drag_start_cursor = cursor;
    last_position     = cursor;
    was_moved         = false;
    raise_window(window);
    drag_timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent(),
        1.0 / 120.0,
        0,
        0,
        drag_timer_fired,
        nullptr
    );
    CFRunLoopAddTimer(CFRunLoopGetMain(), drag_timer, kCFRunLoopDefaultMode);
}

// Capslock was released: end the drag.
void end_drag()
{
    if (drag_timer != nullptr) {
        CFRunLoopTimerInvalidate(drag_timer);
        CFRelease(drag_timer);
        drag_timer = nullptr;
    }
    if (drag_window != nullptr) {
        CFRelease(drag_window);
        drag_window = nullptr;
    }
    if (was_moved) {
        // Capslock was pressed and released, and mouse was moved, so window
        // drag function was used. In this case, we want to undo capslock
        // state being toggled. Synthesized capslock events do not toggle the
        // IOHIDSystem capslock state, so there is nothing to undo for them.
        if (undo_toggle) {
            undo_capslock_toggle();
        }
        was_moved = false;
    }
}

// Shared press/release state machine for both event sources. When the same
// key transition is reported by both the HID callback and the event tap, the
// second report is ignored.
void handle_capslock(bool pressed, bool physical)
{
    if (pressed == capslock_is_down) {
        return;
    }
    capslock_is_down = pressed;
    if (pressed) {
        undo_toggle = physical;
        begin_drag();
    } else {
        end_drag();
    }
}

// Raw HID input callback which detects physical capslock key press and
// release events. Equivalent of the low level keyboard hook in the Windows
// version.
void hid_value_callback(void* context, IOReturn result, void* sender, IOHIDValueRef value)
{
    (void)context;
    (void)result;
    (void)sender;
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (element == nullptr) {
        return;
    }
    const uint32_t usage_page = IOHIDElementGetUsagePage(element);
    const uint32_t usage      = IOHIDElementGetUsage(element);
#if defined(WINDOWMOVE_ENABLE_LOGGING)
    // Log all key events, skipping pages which continuously spam values
    // (mouse deltas, buttons)
    if ((usage_page != kHIDPage_GenericDesktop) && (usage_page != kHIDPage_Button)) {
        log_line(
            "hid event: usage_page=0x%x usage=0x%x value=%ld",
            usage_page,
            usage,
            static_cast<long>(IOHIDValueGetIntegerValue(value))
        );
    }
#endif
    if (usage_page != kHIDPage_KeyboardOrKeypad) {
        return;
    }
    if (usage != kHIDUsage_KeyboardCapsLock) {
        return;
    }
    const bool pressed = IOHIDValueGetIntegerValue(value) != 0;
    log_line("hid capslock %s", pressed ? "press" : "release");
    handle_capslock(pressed, true);
}

// Event tap callback which detects synthesized capslock events, for example
// from remote desktop software. Physical key events also pass through the
// tap, but those are left to the HID callback: for the physical key the
// alphashift flag reflects the capslock lock state rather than whether the
// key is held down, so it cannot be used to detect press and release.
CGEventRef event_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* info)
{
    (void)proxy;
    (void)info;
    if ((type == kCGEventTapDisabledByTimeout) || (type == kCGEventTapDisabledByUserInput)) {
        log_line("event tap re-enabled after being disabled (%u)", type);
        CGEventTapEnable(event_tap, true);
        return event;
    }
    const int64_t keycode    = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const int64_t source_pid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    const CGEventFlags flags = CGEventGetFlags(event);
#if defined(WINDOWMOVE_ENABLE_LOGGING)
    // Log all key events
    log_line(
        "tap key event: type=%u keycode=%lld source_pid=%lld flags=0x%llx",
        type,
        static_cast<long long>(keycode),
        static_cast<long long>(source_pid),
        static_cast<unsigned long long>(flags)
    );
#endif
    if (source_pid == 0) {
        // Hardware event, handled by the HID callback
        return event;
    }
    if (type == kCGEventFlagsChanged) {
        // Synthesized modifier events do not necessarily carry a usable
        // keycode (Parsec sends keycode 0 for all modifiers), but the
        // alphashift flag tracks the sender's capslock state, so detect its
        // transitions. Note that remote desktop software forwards the remote
        // capslock lock state, not the physical key: one capslock press
        // starts the drag and the next capslock press ends it, instead of
        // holding the key down.
        const bool pressed = (flags & kCGEventFlagMaskAlphaShift) != 0;
        if (pressed != capslock_is_down) {
            log_line("tap capslock %s (source_pid=%lld)", pressed ? "on" : "off", static_cast<long long>(source_pid));
        }
        handle_capslock(pressed, false);
    } else if (keycode == VIRTUAL_KEYCODE_CAPSLOCK) {
        // Some software posts capslock as plain key down/up events
        const bool pressed = (type == kCGEventKeyDown);
        log_line("tap capslock key %s (source_pid=%lld)", pressed ? "press" : "release", static_cast<long long>(source_pid));
        handle_capslock(pressed, false);
    }
    return event;
}

// Connection to IOHIDSystem, used for reading and writing the capslock state.
void open_hid_system_connection()
{
    const io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching(kIOHIDSystemClass));
    if (service == IO_OBJECT_NULL) {
        return;
    }
    IOServiceOpen(service, mach_task_self(), kIOHIDParamConnectType, &hid_system);
    IOObjectRelease(service);
}

bool setup_hid_manager()
{
    hid_manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (hid_manager == nullptr) {
        return false;
    }
    // Match all devices instead of just keyboards; some software creates
    // virtual keyboard devices which do not declare the keyboard usage. The
    // value callback filters by element usage, so non-keyboard devices only
    // cost a discarded callback.
    IOHIDManagerSetDeviceMatching(hid_manager, nullptr);
    IOHIDManagerRegisterInputValueCallback(hid_manager, hid_value_callback, nullptr);
    IOHIDManagerScheduleWithRunLoop(hid_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    const IOReturn result = IOHIDManagerOpen(hid_manager, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        log_line("IOHIDManagerOpen failed (0x%x)", result);
        IOHIDManagerUnscheduleFromRunLoop(hid_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(hid_manager);
        hid_manager = nullptr;
        return false;
    }
    return true;
}

bool setup_event_tap()
{
    const CGEventMask mask =
        CGEventMaskBit(kCGEventFlagsChanged) |
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp);
    event_tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        mask,
        event_tap_callback,
        nullptr
    );
    if (event_tap == nullptr) {
        log_line("CGEventTapCreate failed, capslock will only work from a directly attached keyboard");
        return false;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, event_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopDefaultMode);
    CFRelease(source);
    return true;
}

bool activate()
{
    if (!setup_hid_manager()) {
        return false;
    }
    setup_event_tap(); // Best effort; failure is logged
    return true;
}

bool permissions_granted()
{
    return
        AXIsProcessTrusted() &&
        (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted);
}

// Permissions can be granted in System Settings while we are running; poll
// until they are and then start listening for capslock.
void permission_timer_fired(CFRunLoopTimerRef timer, void* info)
{
    (void)info;
    if (!permissions_granted()) {
        return;
    }
    if (!activate()) {
        return;
    }
    log_line("permissions granted, now active");
    CFRunLoopTimerInvalidate(timer);
}

int main(int argc, char** argv)
{
    (void)argc;
    (void)argv;
    @autoreleasepool {
#if defined(WINDOWMOVE_ENABLE_LOGGING)
        NSString* log_path = [@"~/Library/Logs/WindowMove.log" stringByExpandingTildeInPath];
        log_file = fopen(log_path.fileSystemRepresentation, "a");
#endif
        log_line("WindowMove started: hold capslock and move the mouse to drag the window under the cursor");

        system_wide_element = AXUIElementCreateSystemWide();
        open_hid_system_connection();
        if (hid_system == IO_OBJECT_NULL) {
            log_line("could not open IOHIDSystem, capslock state will not be restored after dragging");
        }

        // Ask for the required permissions. Both calls show the system
        // permission dialog when the permission has not been granted yet.
        const bool accessibility = AXIsProcessTrustedWithOptions(
            (__bridge CFDictionaryRef)@{(__bridge NSString*)kAXTrustedCheckOptionPrompt: @YES}
        );
        const bool input_monitoring = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);

        if (accessibility && input_monitoring && activate()) {
            log_line("active");
        } else {
            log_line("waiting for permissions, grant them in System Settings > Privacy & Security:");
            log_line("  - Accessibility (for moving windows): %s", accessibility ? "granted" : "not granted");
            log_line("  - Input Monitoring (for detecting the capslock key): %s", input_monitoring ? "granted" : "not granted");
            CFRunLoopTimerRef permission_timer = CFRunLoopTimerCreate(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 2.0,
                2.0,
                0,
                0,
                permission_timer_fired,
                nullptr
            );
            CFRunLoopAddTimer(CFRunLoopGetMain(), permission_timer, kCFRunLoopDefaultMode);
            CFRelease(permission_timer);
        }

        CFRunLoopRun();
    }
    return 0;
}
