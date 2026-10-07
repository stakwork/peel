#!/bin/sh
# Renders Assets/peel.svg into Assets/AppIcon.icns for the app bundle.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
qlmanage -t -s 1024 -o "$WORK" "$ROOT/Assets/peel.svg" >/dev/null 2>&1
MASTER="$WORK/peel.svg.png"
[ -f "$MASTER" ] || { echo "could not rasterise Assets/peel.svg" >&2; exit 1; }
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$MASTER" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$MASTER" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Assets/AppIcon.icns"
cp "$MASTER" "$ROOT/Assets/peel-1024.png"
rm -rf "$WORK"
echo "wrote Assets/AppIcon.icns"
