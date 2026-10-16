#!/bin/sh
# Builds and signs Peel (scripts/bundle-app.sh), installs it in ~/Applications
# and opens it. Extra arguments go to the app, e.g. ./scripts/run-app.sh -profile throwaway
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Peel.app"
# The Peel in daily use always ships its strut (the agent's memory and
# automations): bundle-app fails without one, unless PEEL_ALLOW_NO_STRUT=1.
[ "${PEEL_ALLOW_NO_STRUT:-}" = 1 ] || export PEEL_REQUIRE_STRUT=1
"$ROOT/scripts/bundle-app.sh" "$APP"
# Install a copy at a fixed place, so a Dock pin and Spotlight survive rebuilds.
INSTALLED="$HOME/Applications/Peel.app"
mkdir -p "$HOME/Applications"
# Quit any running installed copy first: its bundle is about to be replaced, and
# a second copy on the same profile fails on the profile lock. Quit with an Apple
# Event, not a signal, so the app's willTerminate cleanup runs (clipboard,
# delivered notifications).
BINARY="$INSTALLED/Contents/MacOS/Peel"
PATTERN="^$(printf '%s' "$BINARY" | sed 's/[][\.*^$+?(){}|]/\\&/g')( |\$)"
USER_ID="$(id -u)"
running() { pgrep -U "$USER_ID" -f "$PATTERN"; }
for pid in $(running || true); do
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null || true
done
waited=0
while running >/dev/null; do
  if [ "$waited" -ge 10 ]; then
    echo "Peel is still running after $waited s; quit it and run this again." >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open -n "$INSTALLED" --args "$@"
