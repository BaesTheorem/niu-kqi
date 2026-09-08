#!/usr/bin/env bash
# Render the app icon from the Material Symbols Sharp scooter glyph, so the icon
# is the same shape language as the icons inside the app. Flat and sharp: solid
# tonal ground, no gradient, no shadow, square corners (iOS applies its own mask).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=KQiRides/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$OUT"

GROUND="#00402C"
GLYPH="#85F8CA"
SVG=/tmp/scooter.svg

curl -fsSL -o "$SVG" \
  "https://raw.githubusercontent.com/google/material-design-icons/master/symbols/web/electric_scooter/materialsymbolssharp/electric_scooter_48px.svg"

# Recolour the glyph, render it large, then centre it on the ground.
sed -i '' "s|<svg |<svg fill=\"$GLYPH\" |" "$SVG" 2>/dev/null || true
rsvg-convert -w 660 -h 660 "$SVG" -o /tmp/scooter.png
magick -size 1024x1024 "xc:$GROUND" /tmp/scooter.png -gravity center -composite \
  -alpha remove -alpha off "$OUT/icon-1024.png"

cat > "$OUT/Contents.json" <<'JSON'
{
  "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
  "info": {"author": "xcode", "version": 1}
}
JSON
echo "icon written to $OUT"
