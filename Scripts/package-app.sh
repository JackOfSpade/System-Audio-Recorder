#!/bin/sh
# Builds the release configuration, then assembles "System Audio Recorder.app"
# at the project root and ad-hoc signs both it and the systemaudiorecorder
# CLI for local use (Section 9: a paid Developer ID cert is only needed to
# notarize for OTHER people, or for the Mac App Store — neither applies to
# running this on your own Mac).
#
# Usage: Scripts/package-app.sh
# Always runs a real `swift build -c release` first (not just a path query),
# so the packaged .app reflects whatever source is currently on disk.

set -e
cd "$(dirname "$0")/.."

swift build -c release
BUILD_DIR=$(swift build -c release --show-bin-path)
APP_BUNDLE="./System Audio Recorder.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/SystemAudioRecorderApp" "$APP_BUNDLE/Contents/MacOS/SystemAudioRecorderApp"
cp Sources/SystemAudioRecorderApp/Info.plist "$APP_BUNDLE/Contents/Info.plist"

codesign --force --deep --sign - --entitlements Resources/SystemAudioRecorder.entitlements "$APP_BUNDLE"
codesign --force --sign - --entitlements Resources/SystemAudioRecorder.entitlements "$BUILD_DIR/systemaudiorecorder"

echo "Packaged: $APP_BUNDLE"
echo "CLI:      $BUILD_DIR/systemaudiorecorder"
