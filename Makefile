# Builds WindowMove.app for macOS. See README.md.

APP        := WindowMove.app
EXECUTABLE := $(APP)/Contents/MacOS/WindowMove
FRAMEWORKS := -framework AppKit -framework ApplicationServices -framework IOKit

all: $(EXECUTABLE)

$(EXECUTABLE): main_macos.mm Info.plist Makefile
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	clang++ -std=c++17 -fobjc-arc -Wall -Wextra -O2 -o $(EXECUTABLE) main_macos.mm $(FRAMEWORKS)
	codesign --force --sign - $(APP)

clean:
	rm -rf $(APP)

.PHONY: all clean
