#!/bin/bash
# Regenerates the committed app icon from assets/app-icon.svg. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."

set_dir="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" assets/app-icon.svg -o "$set_dir/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) assets/app-icon.svg -o "$set_dir/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set_dir" -o assets/AppIcon.icns
rsvg-convert -w 180 -h 180 website/static/img/icon.svg -o website/static/img/apple-touch-icon.png
echo "assets/AppIcon.icns"
