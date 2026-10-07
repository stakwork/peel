#!/bin/sh
# Builds Peel, wraps it as an app bundle and opens it. Extra arguments go to the
# app, e.g. ./scripts/run-app.sh -profile throwaway
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! output=$(swift build --product PeelApp 2>&1); then
  printf '%s\n' "$output" | grep -v "ld: warning"
  exit 1
fi

APP="$ROOT/.build/Peel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/PeelApp "$APP/Contents/MacOS/PeelApp"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Assets/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Peel</string>
    <key>CFBundleDisplayName</key><string>Peel</string>
    <key>CFBundleIdentifier</key><string>dev.peel.mac</string>
    <key>CFBundleExecutable</key><string>PeelApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST
# A stable identity, so Keychain items survive rebuilds.
"$ROOT/scripts/sign-app.sh" "$APP"
open -n "$APP" --args "$@"
