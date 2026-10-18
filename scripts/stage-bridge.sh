#!/bin/sh
# Stages the agent's bridge Peel ships, for embed-strut.sh to copy into
# Contents/Bridge: sphinx/runner (docs/agent-on-strut.md, section 4), built
# for Apple silicon from the sphinx commit Vendor/runner.lock names (its first
# line that is not a # comment), with the dependencies Vendor/runner.Cargo.lock
# pins (sphinx keeps no lockfile). The sources come from that commit alone
# (git archive), so the checkout's own branch and changes never reach the build.
# Usage: scripts/stage-bridge.sh <sphinx checkout> [--update-lock]  (needs cargo)
#   --update-lock resolves the dependencies afresh and writes the lockfile back
#   to Vendor/runner.Cargo.lock: once after moving the commit in Vendor/runner.lock.
# Out: ~/Library/Caches/dev.peel.build/bridge (or $PEEL_BRIDGE_STAGE), shared by
# every checkout and replaced only once a new stage is complete. The build goes
# to $CARGO_TARGET_DIR if set, else to a folder removed when it ends. One run at a time.
set -eu
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: scripts/stage-bridge.sh <sphinx checkout> [--update-lock]" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPHINX_SRC="$(cd "$1" && pwd)"
UPDATE_LOCK=
[ $# -eq 1 ] || [ "$2" = --update-lock ] || { echo "stage-bridge: unknown option $2" >&2; exit 2; }
[ $# -eq 1 ] || UPDATE_LOCK=1
OUT="${PEEL_BRIDGE_STAGE:-$HOME/Library/Caches/dev.peel.build/bridge}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ "$(uname -m)" = arm64 ] || { echo "stage-bridge: Apple silicon only" >&2; exit 1; }
command -v cargo > /dev/null || { echo "stage-bridge: needs cargo (rustup.rs)" >&2; exit 1; }

COMMIT="$(awk '!/^#/ && NF { print $1; exit }' "$ROOT/Vendor/runner.lock")"
printf '%s' "$COMMIT" | grep -qE '^[0-9a-f]{40}$' || { echo "stage-bridge: Vendor/runner.lock names no commit" >&2; exit 1; }
CARGO_LOCK="$ROOT/Vendor/runner.Cargo.lock"
[ -n "$UPDATE_LOCK" ] || [ -f "$CARGO_LOCK" ] || { echo "stage-bridge: no Vendor/runner.Cargo.lock; run with --update-lock" >&2; exit 1; }
if ! git -C "$SPHINX_SRC" cat-file -e "$COMMIT^{commit}" 2> /dev/null; then
  git -C "$SPHINX_SRC" fetch --quiet origin "$COMMIT" || { echo "stage-bridge: $SPHINX_SRC cannot fetch $COMMIT" >&2; exit 1; }
fi

mkdir -p "$(dirname "$OUT")"
# One staging at a time: the stage is shared by every checkout.
mkdir "$OUT.lock" 2> /dev/null || { echo "stage-bridge: another run is staging ($OUT.lock); remove it if none is" >&2; exit 1; }
WORK=; SRC=; TARGET=
trap 'rm -rf "$WORK" "$SRC" "$TARGET" "$OUT.lock"' EXIT
trap 'exit 1' INT TERM HUP

WORK="$(mktemp -d "$OUT.new.XXXXXX")"
SRC="$(mktemp -d)"
git -C "$SPHINX_SRC" archive "$COMMIT" | tar -x -C "$SRC"
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
  BUILT="$CARGO_TARGET_DIR"
else
  TARGET="$(mktemp -d)"
  BUILT="$TARGET"
fi
if [ -n "$UPDATE_LOCK" ]; then
  CARGO_TARGET_DIR="$BUILT" cargo build --quiet --release -p sphinx-runner --manifest-path "$SRC/Cargo.toml"
  cp "$SRC/Cargo.lock" "$CARGO_LOCK"
else
  cp "$CARGO_LOCK" "$SRC/Cargo.lock"
  CARGO_TARGET_DIR="$BUILT" cargo build --quiet --release --locked -p sphinx-runner --manifest-path "$SRC/Cargo.toml"
fi
cp "$BUILT/release/sphinx-runner" "$WORK/sphinx-runner"
[ "$(lipo -archs "$WORK/sphinx-runner")" = arm64 ] || { echo "stage-bridge: the build is not arm64" >&2; exit 1; }
{
  echo "sphinx $COMMIT"
  echo "Cargo.lock $(shasum -a 256 "$CARGO_LOCK" | awk '{ print $1 }')"
  rustc --version
} > "$WORK/STAGED_FROM"
rm -rf "$OUT.old"
[ ! -e "$OUT" ] || mv "$OUT" "$OUT.old"
mv "$WORK" "$OUT"
rm -rf "$OUT.old"
du -sh "$OUT"
