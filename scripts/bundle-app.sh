#!/bin/sh
# Builds Peel and wraps it as a signed app bundle, by default .build/Peel.app.
# Usage: scripts/bundle-app.sh [path/to/Peel.app]
#
# PEEL_BUNDLE_ID sets the bundle ID. By default it is dev.peel.mac, which
# sign-app.sh turns into dev.peel.mac.<team> for any team but Peel's own.
# PEEL_REQUIRE_STRUT=1 (run-app.sh) fails without a staged strut instead of warning
# (scripts/embed-strut.sh, a build phase of the app).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Peel.app}"
BUNDLE_ID="${PEEL_BUNDLE_ID:-dev.peel.mac}"
case "$BUNDLE_ID" in
  ''|*[!A-Za-z0-9.-]*) echo "PEEL_BUNDLE_ID may hold only letters, digits, dots and hyphens" >&2; exit 1 ;;
esac
cd "$ROOT"
# Xcode builds the app (Apps/Peel.xcodeproj) and its build phase embeds the
# strut; the signing below is this script's own, so Xcode's is off.
DERIVED="$ROOT/.build/xcode"
if ! output=$(xcodebuild -project Apps/Peel.xcodeproj -scheme "Peel macOS" -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" -quiet \
    CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build 2>&1); then
  printf '%s\n' "$output" | grep -v "ld: warning"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$DERIVED/Build/Products/Debug/Peel.app" "$APP"
# Every framework the app loads through its rpath (LiveKit's WebRTC), for this
# Mac's architecture only and without headers; sign-app.sh signs them with
# Peel's identity. LiveKit's resource bundle holds only its privacy manifest
# and is never read.
for framework in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$framework" ] || continue
  ditto --arch "$(uname -m)" "$framework" "$framework.thin"
  rm -rf "$framework"
  mv "$framework.thin" "$framework"
  rm -rf "$framework/Headers" "$framework/Modules" "$framework"/Versions/*/Headers "$framework"/Versions/*/Modules
done
# A stable identity and a provisioning profile, so the Keychain item survives rebuilds.
"$ROOT/scripts/sign-app.sh" "$APP"
