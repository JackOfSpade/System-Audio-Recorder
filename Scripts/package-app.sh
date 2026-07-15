#!/bin/sh
# Assembles TapDeck.app from the swift build release product and ad-hoc
# signs both it and the tapdeck CLI for local use (Section 9: a paid
# Developer ID cert is only needed to notarize for OTHER people, or for the
# Mac App Store — neither applies to running this on your own Mac).
#
# Usage: swift build -c release && Scripts/package-app.sh

set -e
cd "$(dirname "$0")/.."

BUILD_DIR=$(swift build -c release --show-bin-path)
APP_BUNDLE="$BUILD_DIR/TapDeck.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/TapDeckApp" "$APP_BUNDLE/Contents/MacOS/TapDeckApp"
cp Sources/TapDeckApp/Info.plist "$APP_BUNDLE/Contents/Info.plist"

codesign --force --deep --sign - --entitlements Resources/TapDeck.entitlements "$APP_BUNDLE"
codesign --force --sign - --entitlements Resources/TapDeck.entitlements "$BUILD_DIR/tapdeck"

echo "Packaged: $APP_BUNDLE"
echo "CLI:      $BUILD_DIR/tapdeck"
