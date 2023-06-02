#include <Windows.h>
#include <windowsx.h>

#define SCANCODE_CAPSLOCK 0x3A

WNDCLASS wc               = {};
HWND     app_hwnd         = nullptr;
POINT    last_position    = {};
HWND     drag_window_hwnd = nullptr;
HHOOK    keyboard_hook    = nullptr;
HHOOK    mouse_hook       = nullptr;
bool     was_moved        = false;

// Low-level keyboard hook which detects capslock key press and release events.
// Capslock key press will start dragging window under the mouse, and bring it
// to the front. Capslock key release will end window dragging.
LRESULT CALLBACK keyboardProc(int nCode, WPARAM wParam, LPARAM lParam)
{
    if (nCode == HC_ACTION) {
        KBDLLHOOKSTRUCT* keyboard_struct = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
        if (keyboard_struct != nullptr) {
            // Filter by capslock key and filter away synthesized messages
            if ((keyboard_struct->scanCode == SCANCODE_CAPSLOCK) && (keyboard_struct->dwExtraInfo == 0)) {
                if ((wParam == WM_KEYDOWN) || (wParam == WM_SYSKEYDOWN)) {
                    // Capslock was pressed
                    if (drag_window_hwnd == nullptr) {
                        // Window was not being dragged, (try to) start a new drag here
                        POINT cursor_pos;
                        GetCursorPos(&cursor_pos);
                        HWND hover_window = WindowFromPoint(cursor_pos);
                        // Hover window could be a child window. Walk up the hierarchy to find
                        // the top level window
                        for (;;) {
                            if (hover_window == nullptr) {
                                break;
                            }
                            LONG_PTR style = GetWindowLongPtr(hover_window, GWL_STYLE);
                            if ((style & WS_CHILDWINDOW) == WS_CHILDWINDOW) {
                                hover_window = GetParent(hover_window);
                                continue;
                            }
                            // Found ancestor window without WS_CHILDWINDOW, start drag
                            drag_window_hwnd = hover_window;
                            last_position = cursor_pos;
                            // This is optional but I find it useful
                            SetForegroundWindow(drag_window_hwnd);
                            break;
                        }
                    }
                } else if ((wParam == WM_KEYUP) || (wParam == WM_SYSKEYUP)) {
                    // Capslock was released
                    drag_window_hwnd = nullptr;
                    if (was_moved) {
                        // Capslock was pressed and released, and mouse was moved, so window
                        // drag function was used. In this case, we want to undo capslock
                        // state being toggled, so we synthesize additional capslock key
                        // press and release events. However, sending keyboard events from a
                        // low level keyboard hook a) is a bad idea, and b) does not work.
                        // Instead, here we notify wndProc and let it synthesize those evente.
                        PostMessage(app_hwnd, WM_USER, 0, 0);
                        was_moved = false;
                    }
                }
            }
        }
    }
    return CallNextHookEx(nullptr, nCode, wParam, lParam);
}

// Low-level mouse hook which moves the window being dragged when
// drag has been activated and mouse is being moved.
LRESULT CALLBACK mouseProc(int nCode, WPARAM wParam, LPARAM lParam)
{
    if (nCode == HC_ACTION) {
        MSLLHOOKSTRUCT* mouse_struct = reinterpret_cast<MSLLHOOKSTRUCT*>(lParam);
        if ((mouse_struct != nullptr) && (wParam == WM_MOUSEMOVE) && (drag_window_hwnd != nullptr)) {
            POINT cursor_pos;
            GetCursorPos(&cursor_pos);
            int delta_x = cursor_pos.x - last_position.x;
            int delta_y = cursor_pos.y - last_position.y;
            was_moved = true;
            last_position = cursor_pos;
            // IDK why, but this method can change the window size off by one
            //WINDOWPLACEMENT placement = {};
            //GetWindowPlacement(drag_window_hwnd, &placement);
            //placement.rcNormalPosition.left   += delta_x;
            //placement.rcNormalPosition.top    += delta_y;
            //placement.rcNormalPosition.right  += delta_x;
            //placement.rcNormalPosition.bottom += delta_y;
            //SetWindowPlacement(drag_window_hwnd, &placement);
            RECT window_rect = {};
            GetWindowRect(drag_window_hwnd, &window_rect);
            SetWindowPos(drag_window_hwnd, HWND_TOP, window_rect.left + delta_x, window_rect.top + delta_y, 0, 0, SWP_NOSIZE);
        }
    }
    return CallNextHookEx(NULL, nCode, wParam, lParam);
}

LRESULT wndProc(const HWND hwnd, const UINT uMsg, const WPARAM wParam, const LPARAM lParam)
{
    switch (uMsg) {
        case WM_DESTROY: {
            PostQuitMessage(0);
            return 0;
        }
        case WM_USER: {
            INPUT input[2] = { 0 };
            input[0].type           = INPUT_KEYBOARD;
            input[0].ki.wVk         = VK_CAPITAL;
            input[0].ki.wScan       = 0;
            input[0].ki.dwFlags     = 0;
            input[0].ki.dwExtraInfo = 1;
            input[1].type           = INPUT_KEYBOARD;
            input[1].ki.wVk         = VK_CAPITAL;
            input[1].ki.wScan       = 0;
            input[1].ki.dwFlags     = KEYEVENTF_KEYUP;
            input[1].ki.dwExtraInfo = 1;
            SendInput(1, &input[0], sizeof(INPUT));
            Sleep(1); // Without this sleep, toggling capslock will not work
            SendInput(1, &input[1], sizeof(INPUT));
            break;
        }
        default: break;
    }

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, LPSTR, int)
{
    const wchar_t CLASS_NAME[] = L"WINDOW_MOVE_WINDOW_CLASS";

    wc.style         = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    wc.lpfnWndProc   = (WNDPROC)wndProc;
    wc.hInstance     = hInstance;
    wc.hCursor       = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = CLASS_NAME;
    RegisterClass(&wc);
    app_hwnd = CreateWindowEx(
        0,
        wc.lpszClassName,
        L"WindowMove",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        270,
        32,
        nullptr,
        nullptr,
        hInstance,
        nullptr
    );

    ShowWindow(app_hwnd, SW_SHOW);
    keyboard_hook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, hInstance, 0);
    mouse_hook    = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, hInstance, 0);

    MSG msg = {};
    while (GetMessage(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    UnhookWindowsHookEx(mouse_hook);
    UnhookWindowsHookEx(keyboard_hook);
    DestroyWindow(app_hwnd);
    return 0;
}
