#!/usr/bin/env bash
# Verify the real local-use app package without launching audio capture or asking for permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/package-app.sh
APP='./System Audio Recorder.app'
PLIST="$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$PLIST"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = 'com.systemaudiorecorder.app'
test "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$PLIST")" = SystemAudioRecorderApp
test -n "$(/usr/bin/plutil -extract NSAudioCaptureUsageDescription raw -o - "$PLIST")"
test -x "$APP/Contents/MacOS/SystemAudioRecorderApp"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p build/ci-artifacts
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" build/ci-artifacts/System-Audio-Recorder-macOS.zip
BUILD_DIR=$(swift build -c release --show-bin-path)
test -x "$BUILD_DIR/systemaudiorecorder"
/usr/bin/codesign --verify --strict --verbose=2 "$BUILD_DIR/systemaudiorecorder"
/usr/bin/ditto -c -k --keepParent "$BUILD_DIR/systemaudiorecorder" build/ci-artifacts/systemaudiorecorder-cli.zip
