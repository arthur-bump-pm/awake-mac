#!/bin/bash
# Builds build/Awake.app (release, ad-hoc signed).
# --install also copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP="Awake"
BUNDLE="build/$APP.app"

swift build -c release
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp ".build/release/awakectl" "$BUNDLE/Contents/MacOS/awakectl"
cp "Sources/$APP/Info.plist" "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
mkdir -p "$BUNDLE/Contents/Resources/Fonts"
cp Resources/Fonts/* "$BUNDLE/Contents/Resources/Fonts/"
codesign --force --sign - "$BUNDLE/Contents/MacOS/awakectl"
codesign --force --sign - "$BUNDLE"
echo "Built $BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e "quit app \"$APP\"" 2>/dev/null || true
    while pgrep -x "$APP" >/dev/null; do sleep 0.2; done
    rm -rf "/Applications/$APP.app"
    ditto "$BUNDLE" "/Applications/$APP.app"
    open "/Applications/$APP.app"
    echo "Installed and launched /Applications/$APP.app"
fi
