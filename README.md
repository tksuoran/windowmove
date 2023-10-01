# windowmove

Windows application for moving windows by moving mouse while holding capslock key.

## Building using Visual Studio 2022.

- You can download commity edition for free from https://visualstudio.microsoft.com/vs/community/

- Run Visual Studio, choose Open a project or Solution

- Browse to WindowMove.sln, open it

- Build menu / Build Solution

## Building using Clang

- Install Clang. You can download clang for windows from https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.1/LLVM-17.0.1-win64.exe

- When you try to run executables downloaded for internet, Windows may prompt you that it is not safe. Click on More info, run anyway

- Choose "Add LLVM to the system path for all users"

- Open command prompt, navigate to directory with WindowMove.sln and main.cpp in it

- Run `clang++ main.cpp -DUNICODE -luser32.lib -lgdi32 -WindowMove.exe`

## Building using G++

I have not tested this myself. Good luck.

- Install GCC

- Run `g++ main.cpp -DUNICODE -luser32.lib -lgdi32 -WindowMove.exe`

## Starting WindowMove.exe when you log in to Windows

- Open Windows file explorer

- Type location `%appdata%\Microsoft\Windows\Start Menu\Programs\Startup`

- Right-mouse-drag WindowMove.exe to Startup folder and choose Create shortcut here. Copying or moving the executable there might also work.

## Limitations

- When WindowMove is run as a normal user, it is not able to move windows that are run as Administrator. You can run WindowMove as Administrator to work around this issue.
