#!/bin/bash
# Regenerate the macOS AppIcon image set from Scripts/appicon.svg.
#
# Scripts/appicon.svg is the master (the "Snap-to-Whole" mark, framed on Apple's
# macOS icon grid — the squircle is scaled to 824/1024 with the standard margin so it
# matches native Dock icons). This rasterizes it to the ten sizes the asset catalog
# references and writes Contents.json. The PNGs are committed, so CI never needs this.
#
# Requires rsvg-convert (brew install librsvg).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/Scripts/appicon.svg"
DST="$REPO/App/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null || {
  echo "make-appicon: need rsvg-convert (brew install librsvg)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "make-appicon: no $SRC" >&2; exit 1; }
mkdir -p "$DST"

render() { rsvg-convert -w "$1" -h "$1" "$SRC" -o "$DST/$2"; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

cat > "$DST/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "make-appicon: regenerated $DST"
