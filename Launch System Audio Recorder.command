#!/bin/sh
# Double-click entry point (Finder runs .command files in a Terminal window):
# rebuilds "System Audio Recorder.app" from whatever source is currently on
# disk, then launches it. Run Scripts/package-app.sh directly instead if you
# just want to build/sign without auto-launching (e.g. scripting).

cd "$(dirname "$0")"
Scripts/package-app.sh
open "./System Audio Recorder.app"
echo
echo "Launched. You can close this window."
