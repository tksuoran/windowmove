# windowmove

Utility for moving windows by moving mouse while holding capslock key. Runs on Windows and macOS.

## Windows

The Windows version is `main.cpp`.

### Building using Visual Studio 2022.

- You can download commity edition for free from https://visualstudio.microsoft.com/vs/community/

- Run Visual Studio, choose Open a project or Solution

- Browse to WindowMove.sln, open it

- Build menu / Build Solution

### Building using Clang

- Install Clang. You can download clang for windows from https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.1/LLVM-17.0.1-win64.exe

- When you try to run executables downloaded for internet, Windows may prompt you that it is not safe. Click on More info, run anyway

- Choose "Add LLVM to the system path for all users"

- Open command prompt, navigate to directory with WindowMove.sln and main.cpp in it

- Run `clang++ main.cpp -DUNICODE -luser32.lib -lgdi32 -WindowMove.exe`

### Building using G++

I have not tested this myself. Good luck.

- Install GCC

- Run `g++ main.cpp -DUNICODE -luser32.lib -lgdi32 -WindowMove.exe`

### Starting WindowMove.exe when you log in to Windows

- Open Windows file explorer

- Type location `%appdata%\Microsoft\Windows\Start Menu\Programs\Startup`

- Right-mouse-drag WindowMove.exe to Startup folder and choose Create shortcut here. Copying or moving the executable there might also work.

### Limitations

- When WindowMove is run as a normal user, it is not able to move windows that are run as Administrator. You can run WindowMove as Administrator to work around this issue.

## macOS

The macOS version is `main_macos.mm`.

### Building

- Install the Xcode command line tools if you do not have them: `xcode-select --install`

- Run `make`. This produces `WindowMove.app`.

- `make dev` produces a development build with logging enabled, see Troubleshooting. Normal builds have logging compiled out entirely.

### Running

- Run `open WindowMove.app`. The app has no window or Dock icon; it just sits in the background.

- On first launch macOS asks for two permissions, both under System Settings > Privacy & Security:

  - **Accessibility** — needed for finding and moving windows

  - **Input Monitoring** — needed for detecting capslock key press and release

- WindowMove notices when the permissions have been granted and activates automatically. If it does not seem to work after granting the permissions, quit it (`killall WindowMove`) and launch it again.

- To quit WindowMove, run `killall WindowMove` or use Activity Monitor.

### Starting WindowMove.app when you log in to macOS

- Open System Settings > General > Login Items, click "+" under "Open at Login" and select WindowMove.app.

### Using through remote desktop software (Parsec, ...)

Remote desktop software does not forward capslock key press and release, only capslock state changes, so the gesture is different when controlling the Mac remotely: tap capslock once to start dragging the window under the cursor, and tap capslock again to stop. The second tap also restores the capslock state on the remote machine.

Tested with Parsec. Other remote desktop software which forwards the capslock state the same way should also work.

### Troubleshooting

- Normal builds do not log anything. To diagnose problems (for example a keyboard or remote desktop software whose capslock does not get detected), build a development build with `make dev` and relaunch. It logs to `~/Library/Logs/WindowMove.log`, including every key event it sees — so everything you type ends up in the log file. Never use a development build for daily work; rebuild with `make` when done. Both rebuilds need the permissions granted again, see below.

- Because the app is ad-hoc signed, macOS treats each rebuild as a different app, and silently ignores previously granted permissions. After running `make` again, reset the stale permissions with `tccutil reset Accessibility com.tksuoran.windowmove` and `tccutil reset ListenEvent com.tksuoran.windowmove`, then relaunch WindowMove and grant the permissions again when it asks.

- The "Quit & Reopen" button in the System Settings permission prompt does not manage to quit WindowMove. Use `killall WindowMove` and `open WindowMove.app` instead; Input Monitoring only takes effect for a freshly started process.

### Limitations

- WindowMove cannot move windows of apps running as root, fullscreen windows, or some system UI.

- Built-in Apple keyboards delay capslock key activation slightly (to avoid accidental presses), so a very quick capslock tap and mouse move may not start a drag.
