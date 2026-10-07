#!/bin/sh
# Builds and signs Peel (scripts/bundle-app.sh), installs it in ~/Applications
# and opens it. Extra arguments go to the app, e.g. ./scripts/run-app.sh -profile throwaway
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Peel.app"
"$ROOT/scripts/bundle-app.sh" "$APP"
# Install a copy at a fixed place, so a Dock pin and Spotlight survive rebuilds.
INSTALLED="$HOME/Applications/Peel.app"
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open -n "$INSTALLED" --args "$@"
