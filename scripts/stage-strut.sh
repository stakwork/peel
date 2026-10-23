#!/bin/sh
# Stages the strut Peel ships, for bundle-app.sh to copy into
# Contents/Strut: strut's desktop package (scripts/package-desktop.mjs in a
# strut checkout, with dictation's speech engine, with Ladybug, its extensions, the
# memory/* steps, and the orchestrator with its automation/* steps) and
# the Node that runs it, a pinned release checked against its SHA-256 on every
# run. Apple silicon only. Built from the strut commit Vendor/strut.lock names
# (its first line that is not a # comment), taken from the checkout with git
# archive, so the checkout's own branch, changes and node_modules never reach
# the stage, and the checkout is left as it was.
# Usage: scripts/stage-strut.sh <strut checkout>  (needs yarn)
# Out: ~/Library/Caches/dev.peel.build/strut (or $PEEL_STRUT_STAGE), shared by every
# checkout's bundle-app.sh and replaced only once a new stage is complete;
# Node's download is cached beside it (<stage>.node). One run at a time.
set -eu
[ $# -eq 1 ] || { echo "usage: scripts/stage-strut.sh <strut checkout>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRUT_CHECKOUT="$(cd "$1" && pwd)"
OUT="${PEEL_STRUT_STAGE:-$HOME/Library/Caches/dev.peel.build/strut}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ "$(uname -m)" = arm64 ] || { echo "stage-strut: Apple silicon only" >&2; exit 1; }
command -v yarn > /dev/null || { echo "stage-strut: needs yarn" >&2; exit 1; }

COMMIT="$(awk '!/^#/ && NF { print $1; exit }' "$ROOT/Vendor/strut.lock")"
printf '%s' "$COMMIT" | grep -qE '^[0-9a-f]{40}$' || { echo "stage-strut: Vendor/strut.lock names no commit" >&2; exit 1; }
if ! git -C "$STRUT_CHECKOUT" cat-file -e "$COMMIT^{commit}" 2> /dev/null; then
  git -C "$STRUT_CHECKOUT" fetch --quiet origin "$COMMIT" || { echo "stage-strut: $STRUT_CHECKOUT cannot fetch $COMMIT" >&2; exit 1; }
fi

mkdir -p "$(dirname "$OUT")"
# One staging at a time: the stage is shared by every checkout.
mkdir "$OUT.lock" 2> /dev/null || { echo "stage-strut: another run is staging ($OUT.lock); remove it if none is" >&2; exit 1; }
WORK=; NODE_TMP=; STRUT_SRC=
trap 'rm -rf "$WORK" "$NODE_TMP" "$STRUT_SRC" "$OUT.lock"' EXIT
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
STRUT_SRC="$(mktemp -d)"
git -C "$STRUT_CHECKOUT" archive "$COMMIT" | tar -x -C "$STRUT_SRC"
# Node fresh from the checked download each run: the one that ships.
tar -xzf "$NODE_TAR" -C "$NODE_TMP"
NODE_DIR="$NODE_TMP/node-$NODE_VERSION-darwin-arm64"
# Under that Node, which strut requires (22 or newer): the checkout's
# dependencies from its lockfile, then the package (it builds strut).
(
  cd "$STRUT_SRC"
  export PATH="$NODE_DIR/bin:$PATH"
  yarn install --frozen-lockfile --silent
  node scripts/package-desktop.mjs --out "$WORK"
)
STAGE="$WORK/strut"
for needed in native/lbugjs.node build/steps/lib/memory/remember.js build/workflows/orchestrator.yaml \
    build/steps/lib/automation/create.js desktop.js desktop.json; do
  [ -e "$STAGE/$needed" ] || { echo "stage-strut: the package has no $needed; the strut commit in Vendor/strut.lock lacks the memory steps, the orchestrator and its automation steps, or the desktop Ladybug package" >&2; exit 1; }
done
# Dictation's speech engine (sherpa), which /audio/transcribe needs, in native/ to be signed.
[ "$(plutil -extract stt raw -o - "$STAGE/desktop.json")" = true ] && [ -e "$STAGE/native/sherpa-onnx.node" ] \
  || { echo "stage-strut: the package left the speech engine out (sherpa-onnx-node in the strut checkout's install?)" >&2; exit 1; }
# The package's own word that it carries Ladybug and its extensions, which the workspace needs.
[ "$(plutil -extract ladybug raw -o - "$STAGE/desktop.json")" = true ] || { echo "stage-strut: the package left Ladybug out (is openssl@3 installed? brew install openssl@3)" >&2; exit 1; }
cp "$NODE_DIR/bin/node" "$STAGE/native/node"
{
  echo "strut $COMMIT"
  echo "node $NODE_VERSION"
} > "$STAGE/STAGED_FROM"
rm -rf "$OUT.old"
[ ! -e "$OUT" ] || mv "$OUT" "$OUT.old"
mv "$WORK" "$OUT"
rm -rf "$OUT.old"
du -sh "$OUT/strut"
