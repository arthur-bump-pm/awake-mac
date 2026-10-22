#!/bin/bash
# Regenerates Resources/AppIcon.icns (and a glyph preview) from the shared OutpostMark geometry.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=".build/icon"
rm -rf "$WORK" && mkdir -p "$WORK/AppIcon.iconset"
swiftc -O Scripts/IconRenderer/main.swift Sources/Outpost/OutpostMark.swift -o "$WORK/render"
"$WORK/render" "$WORK"

for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns updated (preview: $WORK/glyph_preview.png)"
