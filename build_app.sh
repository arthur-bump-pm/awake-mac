#!/bin/bash
# Builds build/Awake.app (release, ad-hoc signed) for this Mac's architecture.
#   --install    also copies it to /Applications and launches it
#   --universal  builds for Apple silicon and Intel in one app (for releases)
set -euo pipefail
cd "$(dirname "$0")"

APP="Awake"
BUNDLE="build/$APP.app"

if [[ " $* " == *" --universal "* ]]; then
    swift build -c release --arch arm64 --arch x86_64
    PRODUCTS=".build/apple/Products/Release"
else
    swift build -c release
    PRODUCTS=".build/release"
fi
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$PRODUCTS/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp "$PRODUCTS/awakectl" "$BUNDLE/Contents/MacOS/awakectl"
cp "Sources/$APP/Info.plist" "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
mkdir -p "$BUNDLE/Contents/Resources/Fonts"
cp Resources/Fonts/* "$BUNDLE/Contents/Resources/Fonts/"
codesign --force --sign - "$BUNDLE/Contents/MacOS/awakectl"
codesign --force --sign - "$BUNDLE"
echo "Built $BUNDLE"

if [[ " $* " == *" --install "* ]]; then
    osascript -e "quit app \"$APP\"" 2>/dev/null || true
    while pgrep -x "$APP" >/dev/null; do sleep 0.2; done
    rm -rf "/Applications/$APP.app"
    ditto "$BUNDLE" "/Applications/$APP.app"
    # LaunchServices can briefly refuse to relaunch an app that just quit (error -600).
    for attempt in 1 2 3; do
        open "/Applications/$APP.app" 2>/dev/null && break
        sleep 1
    done
    echo "Installed and launched /Applications/$APP.app"
fi
