# Builds WindowMove.app for macOS. See README.md.
#
# make      - normal build, logging compiled out
# make dev  - development build which logs to ~/Library/Logs/WindowMove.log,
#             including every key event seen. Never use for daily work.
#
# Both targets build from clean so that a development build can never be
# mistaken for a normal build.

APP        := WindowMove.app
EXECUTABLE := $(APP)/Contents/MacOS/WindowMove
FRAMEWORKS := -framework AppKit -framework ApplicationServices -framework IOKit
CXXFLAGS   := -std=c++17 -fobjc-arc -Wall -Wextra -O2

all: clean $(EXECUTABLE)

dev: CXXFLAGS += -DWINDOWMOVE_ENABLE_LOGGING -g
dev: clean $(EXECUTABLE)

$(EXECUTABLE): main_macos.mm Info.plist Makefile
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	clang++ $(CXXFLAGS) -o $(EXECUTABLE) main_macos.mm $(FRAMEWORKS)
	codesign --force --sign - $(APP)

clean:
	rm -rf $(APP)

.PHONY: all dev clean
