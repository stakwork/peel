#!/bin/sh
# Compiles Assets/AppIcon.icon (an Icon Composer file) into Assets/Assets.car and
# Assets/AppIcon.icns. macOS 26 draws the icon from Assets.car under its own mask;
# macOS 15 uses the pre-masked .icns. An icon shipped only as a hand-shaped .icns
# gets put on a white plate by macOS 26.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
xcrun actool "$ROOT/Assets/AppIcon.icon" --compile "$WORK" \
  --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$WORK/partial.plist" \
  --output-format human-readable-text > "$WORK/actool.log" 2>&1 || true
if [ ! -f "$WORK/Assets.car" ] || [ ! -f "$WORK/AppIcon.icns" ]; then
  cat "$WORK/actool.log" >&2
  echo "could not compile Assets/AppIcon.icon" >&2
  exit 1
fi
cp "$WORK/Assets.car" "$WORK/AppIcon.icns" "$ROOT/Assets/"
rm -rf "$WORK"
echo "wrote Assets/Assets.car and Assets/AppIcon.icns"
