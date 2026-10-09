#!/bin/sh
# Checks the app offscreen: builds .build/PeelCheck.app, runs a drive file
# against a development profile with -offscreen YES, waits for it to quit and
# prints where the snapshots are. Nothing shows on the screens, takes focus or
# posts system events (see AGENTS.md, "Checking the app").
# Usage: scripts/check-app.sh <dev profile> <drive file> <out dir>
set -eu
[ $# -eq 3 ] || { echo "usage: scripts/check-app.sh <dev profile> <drive file> <out dir>" >&2; exit 2; }
PROFILE=$1
case "$(printf '%s' "$PROFILE" | tr '[:upper:]' '[:lower:]')" in
  default|throwaway) echo "check-app: never \"$PROFILE\"; use a development profile" >&2; exit 2 ;;
esac
DRIVE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
mkdir -p "$3"
OUT="$(cd "$3" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/PeelCheck.app"
# A little over OffscreenDriver.deadline, after which the app is stopped.
DEADLINE=330

taskpolicy -b "$ROOT/scripts/bundle-app.sh" "$APP" > /dev/null
# Its own bundle ID, so its preferences, window frames and saved state never
# mix with the Peel in daily use, and no Dock icon even while it launches. No
# Keychain (development profiles keep their words in a file), so no
# provisioning profile: signed again with the same identity, under which
# LiveKit's framework still loads.
plutil -replace CFBundleIdentifier -string dev.peel.mac.check "$APP/Contents/Info.plist"
plutil -replace LSUIElement -bool true "$APP/Contents/Info.plist"
rm -f "$APP/Contents/embedded.provisionprofile"
codesign --force --sign "$("$ROOT/scripts/signing-identity.sh")" --options runtime --timestamp=none "$APP"

# -g: not to the front; -j: hidden, should the build lack the mode; -W: until
# it quits. The two defaults keep Emoji & Symbols and Dictation out of its menus.
open -g -j -n -W --stdout "$OUT/stdout.log" --stderr "$OUT/drive.log" "$APP" \
  --args -profile "$PROFILE" -offscreen YES -drive "$DRIVE" -driveOut "$OUT" \
  -NSDisabledCharacterPaletteMenuItem YES -NSDisabledDictationMenuItem YES &
OPEN=$!
waited=0
while kill -0 "$OPEN" 2> /dev/null && [ "$waited" -lt "$DEADLINE" ]; do
  sleep 1
  waited=$((waited + 1))
done
if kill -0 "$OPEN" 2> /dev/null; then
  # Only this bundle's own process, by its PID.
  for pid in $(pgrep -f "^$APP/Contents/MacOS/PeelApp"); do kill "$pid"; done
  echo "check-app: stopped the app after ${DEADLINE}s" >&2
fi
wait "$OPEN" 2> /dev/null || true

grep '^drive: ' "$OUT/drive.log" | tail -n 1
if grep -q '^drive: done' "$OUT/drive.log"; then
  ls "$OUT"/*.png 2>/dev/null || echo "no snapshots"
else
  echo "check-app: the drive did not finish; see $OUT/drive.log" >&2
  exit 1
fi
