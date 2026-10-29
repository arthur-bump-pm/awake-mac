#!/bin/bash
# Builds the universal app and zips it for a GitHub release: build/Awake-<version>.zip and its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/Awake/Info.plist)
ZIP="build/Awake-$VERSION.zip"

./build_app.sh --universal
for binary in build/Awake.app/Contents/MacOS/Awake build/Awake.app/Contents/MacOS/awakectl; do
    lipo "$binary" -verify_arch arm64 x86_64 || { echo "$binary isn't universal" >&2; exit 1; }
done
codesign --verify --deep --strict build/Awake.app
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent build/Awake.app "$ZIP"
(cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Packaged $ZIP"
cat "$ZIP.sha256"
