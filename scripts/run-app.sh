#!/bin/sh
# Builds Peel, wraps it as an app bundle and opens it. Extra arguments go to the
# app, e.g. ./scripts/run-app.sh --profile throwaway
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product Peel 2>&1 | grep -v "ld: warning" || true
[ -x .build/debug/Peel ] || { echo "build failed" >&2; exit 1; }

APP="$ROOT/.build/Peel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/Peel "$APP/Contents/MacOS/Peel"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Peel</string>
    <key>CFBundleDisplayName</key><string>Peel</string>
    <key>CFBundleIdentifier</key><string>dev.peel.mac</string>
    <key>CFBundleExecutable</key><string>Peel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
open -n "$APP" --args "$@"
