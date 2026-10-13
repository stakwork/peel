#!/bin/sh
# Builds Peel and wraps it as a signed app bundle, by default .build/Peel.app.
# Usage: scripts/bundle-app.sh [path/to/Peel.app]
#
# PEEL_BUNDLE_ID sets the bundle ID. By default it is dev.peel.mac, which
# sign-app.sh turns into dev.peel.mac.<team> for any team but Peel's own.
# PEEL_REQUIRE_STRUT=1 (run-app.sh) fails without a staged strut instead of warning.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRUT_STAGE="${PEEL_STRUT_STAGE:-$HOME/Library/Caches/dev.peel.build/strut}/strut"
case "$STRUT_STAGE" in /*) ;; *) STRUT_STAGE="$PWD/$STRUT_STAGE" ;; esac
APP="${1:-$ROOT/.build/Peel.app}"
BUNDLE_ID="${PEEL_BUNDLE_ID:-dev.peel.mac}"
case "$BUNDLE_ID" in
  ''|*[!A-Za-z0-9.-]*) echo "PEEL_BUNDLE_ID may hold only letters, digits, dots and hyphens" >&2; exit 1 ;;
esac
cd "$ROOT"
if ! output=$(swift build --product PeelApp 2>&1); then
  printf '%s\n' "$output" | grep -v "ld: warning"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/debug/PeelApp "$APP/Contents/MacOS/PeelApp"
# Every framework the app loads through its rpath (LiveKit's WebRTC), for this
# Mac's architecture only and without headers; sign-app.sh signs them with
# Peel's identity. LiveKit's resource bundle holds only its privacy manifest
# and is never read.
for framework in $(otool -L .build/debug/PeelApp | sed -n 's|^[[:space:]]*@rpath/\([^/]*\.framework\)/.*|\1|p'); do
  ditto --arch "$(uname -m)" ".build/debug/$framework" "$APP/Contents/Frameworks/$framework"
  rm -rf "$APP/Contents/Frameworks/$framework/Headers" "$APP/Contents/Frameworks/$framework/Modules" \
    "$APP/Contents/Frameworks/$framework"/Versions/*/Headers "$APP/Contents/Frameworks/$framework"/Versions/*/Modules
done
cp Assets/AppIcon.icns Assets/Assets.car "$APP/Contents/Resources/"
# The agent's strut, as scripts/stage-strut.sh left it (once per Mac, shared
# by every checkout). Not under Contents/Helpers, which codesign keeps for
# signed nested bundles.
if [ -d "$STRUT_STAGE" ]; then
  echo "bundle-app: $(head -1 "$STRUT_STAGE/STAGED_FROM" 2> /dev/null || echo 'strut, unknown source')" >&2
  ditto "$STRUT_STAGE" "$APP/Contents/Strut"
else
  echo "bundle-app: WARNING: no strut staged at $STRUT_STAGE (scripts/stage-strut.sh <strut checkout>); this Peel's agent has no memory or automations" >&2
  [ "${PEEL_REQUIRE_STRUT:-}" != 1 ] || exit 1
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Peel</string>
    <key>CFBundleDisplayName</key><string>Peel</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>PeelApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Peel uses the microphone so people on a call can hear you.</string>
    <key>NSCameraUsageDescription</key><string>Peel uses the camera when you turn on video in a call.</string>
</dict>
</plist>
PLIST
# A stable identity and a provisioning profile, so the Keychain item survives rebuilds.
"$ROOT/scripts/sign-app.sh" "$APP"
