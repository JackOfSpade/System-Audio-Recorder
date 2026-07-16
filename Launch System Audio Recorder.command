#!/bin/sh
# Double-click entry point (Finder runs .command files in a Terminal window):
# rebuilds "System Audio Recorder.app" from whatever source is currently on
# disk, launches it, then closes this Terminal window. On a build failure the
# window stays open so the error is visible. Run Scripts/package-app.sh
# directly instead if you just want to build/sign without auto-launch/close.

cd "$(dirname "$0")"

if ! Scripts/package-app.sh; then
    echo
    echo "Build failed — leaving this window open so you can see the error above."
    exit 1
fi

open "./System Audio Recorder.app"

# Only Terminal.app is handled — other .command handlers (iTerm, etc.) just
# keep the window open, same as before.
if [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    osascript -e 'tell application "Terminal" to close (first window whose tty is "'"$(tty)"'")' >/dev/null 2>&1 &
fi
