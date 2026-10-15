#!/bin/sh
# Stages the strut Peel ships, for bundle-app.sh to copy into
# Contents/Strut: strut's desktop package (scripts/package-desktop.mjs in a
# strut checkout, without dictation, with Ladybug, its vector and fts
# extensions (the workspace's graph needs both) and the memory/* steps) and
# the Node that runs it, a pinned release checked against its SHA-256 on every
# run. Apple silicon only. It installs the checkout's dependencies and builds
# it, so the checkout's node_modules, build/ and web/dist change.
# Usage: scripts/stage-strut.sh <strut checkout>  (needs yarn)
# Out: ~/Library/Caches/dev.peel.build/strut (or $PEEL_STRUT_STAGE), shared by every
# checkout's bundle-app.sh and replaced only once a new stage is complete;
# Node's download is cached beside it (<stage>.node). One run at a time.
set -eu
[ $# -eq 1 ] || { echo "usage: scripts/stage-strut.sh <strut checkout>" >&2; exit 2; }
STRUT_SRC="$(cd "$1" && pwd)"
OUT="${PEEL_STRUT_STAGE:-$HOME/Library/Caches/dev.peel.build/strut}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ "$(uname -m)" = arm64 ] || { echo "stage-strut: Apple silicon only" >&2; exit 1; }
command -v yarn > /dev/null || { echo "stage-strut: needs yarn" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
# One staging at a time: the stage is shared by every checkout.
mkdir "$OUT.lock" 2> /dev/null || { echo "stage-strut: another run is staging ($OUT.lock); remove it if none is" >&2; exit 1; }
WORK=; NODE_TMP=
trap 'rm -rf "$WORK" "$NODE_TMP" "$OUT.lock"' EXIT
trap 'exit 1' INT TERM HUP

NODE_VERSION=v22.23.3
NODE_SHA256=23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53
NODE_TAR="$OUT.node/node-$NODE_VERSION-darwin-arm64.tar.gz"
mkdir -p "$(dirname "$NODE_TAR")"
if ! echo "$NODE_SHA256  $NODE_TAR" | shasum -a 256 -c - > /dev/null 2>&1; then
  curl -fsSL -o "$NODE_TAR" "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-arm64.tar.gz"
  echo "$NODE_SHA256  $NODE_TAR" | shasum -a 256 -c - > /dev/null || { rm -f "$NODE_TAR"; echo "stage-strut: Node's checksum does not match" >&2; exit 1; }
fi

WORK="$(mktemp -d "$OUT.new.XXXXXX")"
NODE_TMP="$(mktemp -d)"
# Node fresh from the checked download each run: the one that ships.
tar -xzf "$NODE_TAR" -C "$NODE_TMP"
NODE_DIR="$NODE_TMP/node-$NODE_VERSION-darwin-arm64"
# Under that Node, which strut requires (22 or newer): the checkout's
# dependencies from its lockfile, then the package (it builds strut).
(
  cd "$STRUT_SRC"
  export PATH="$NODE_DIR/bin:$PATH"
  yarn install --frozen-lockfile --silent
  node scripts/package-desktop.mjs --no-stt --out "$WORK"
)
STAGE="$WORK/strut"
for needed in native/lbugjs.node native/libvector.lbug_extension native/libfts.lbug_extension desktop.json build/steps/lib/memory/remember.js desktop.js; do
  [ -e "$STAGE/$needed" ] || { echo "stage-strut: the package has no $needed; this strut checkout lacks the memory steps or the desktop Ladybug package and its extensions (or openssl@3 is missing: brew install openssl@3)" >&2; exit 1; }
done
cp "$NODE_DIR/bin/node" "$STAGE/native/node"
{
  echo "strut $(git -C "$STRUT_SRC" rev-parse HEAD 2>/dev/null || echo unknown)$(git -C "$STRUT_SRC" diff --quiet HEAD || echo ' (with uncommitted changes)')"
  echo "node $NODE_VERSION"
} > "$STAGE/STAGED_FROM"
rm -rf "$OUT.old"
[ ! -e "$OUT" ] || mv "$OUT" "$OUT.old"
mv "$WORK" "$OUT"
rm -rf "$OUT.old"
du -sh "$OUT/strut"
