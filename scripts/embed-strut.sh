#!/bin/sh
# Build phase of the Mac app (Apps/Peel.xcodeproj, "Peel macOS"): puts the
# agent's strut, as scripts/stage-strut.sh left it (once per Mac, shared by
# every checkout), into Contents/Strut, only if it was staged from the commit
# Vendor/strut.lock names. Not under Contents/Helpers, which codesign keeps
# for signed nested bundles.
#
# PEEL_REQUIRE_STRUT=1 (scripts/run-app.sh) fails without a staged strut and
# bridge instead of warning; a Release build always fails without the bridge. When Xcode signs the build (an archive, a run from
# Xcode), the strut's native code is signed here, first, with the build's
# identity, so hardened runtime's library validation accepts it; Node alone
# gets an entitlement, allow-jit, which V8 needs. A build that Xcode leaves
# unsigned (scripts/bundle-app.sh) is signed by scripts/sign-app.sh instead.
#
# Every build also gets the agent's bridge, as scripts/stage-bridge.sh left
# it, in Contents/Bridge (docs/agent-on-strut.md, PR 10), only if it was
# staged from the commit Vendor/runner.lock names. When Xcode signs, it is
# signed with the build's identity and, in Release, the entitlements that
# keep it in the app's sandbox (PEEL_BRIDGE_ENTITLEMENTS).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
sign() { codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "$@"; }
# A missing or stale bridge: a warning, or the build's end where it must ship one.
bridge_missing() {
  echo "warning: $1"
  [ "${PEEL_REQUIRE_STRUT:-}" != 1 ] && [ "${CONFIGURATION:-}" != Release ] || exit 1
}
BRIDGE_STAGE="${PEEL_BRIDGE_STAGE:-$HOME/Library/Caches/dev.peel.build/bridge}"
case "$BRIDGE_STAGE" in /*) ;; *) BRIDGE_STAGE="$PWD/$BRIDGE_STAGE" ;; esac
BRIDGE_DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Bridge"
rm -rf "$BRIDGE_DEST"
WANT_RUNNER="$(awk '!/^#/ && NF { print $1; exit }' "$ROOT/Vendor/runner.lock")"
if [ -x "$BRIDGE_STAGE/sphinx-runner" ] && [ "$(sed -n 's/^sphinx //p' "$BRIDGE_STAGE/STAGED_FROM" 2> /dev/null)" != "$WANT_RUNNER" ]; then
  bridge_missing "the staged bridge is not sphinx $WANT_RUNNER (Vendor/runner.lock); stage it again (scripts/stage-bridge.sh <sphinx checkout>). Left out"
elif [ -x "$BRIDGE_STAGE/sphinx-runner" ]; then
  echo "embed-strut: bridge $(head -1 "$BRIDGE_STAGE/STAGED_FROM" 2> /dev/null || echo 'from an unknown source')"
  mkdir -p "$BRIDGE_DEST"
  ditto "$BRIDGE_STAGE/sphinx-runner" "$BRIDGE_DEST/sphinx-runner"
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    sign ${PEEL_BRIDGE_ENTITLEMENTS:+--entitlements "$ROOT/scripts/$PEEL_BRIDGE_ENTITLEMENTS"} "$BRIDGE_DEST/sphinx-runner"
  fi
else
  bridge_missing "no bridge staged at $BRIDGE_STAGE (scripts/stage-bridge.sh <sphinx checkout>); this Peel's agent cannot start"
fi
STRUT_STAGE="${PEEL_STRUT_STAGE:-$HOME/Library/Caches/dev.peel.build/strut}/strut"
case "$STRUT_STAGE" in /*) ;; *) STRUT_STAGE="$PWD/$STRUT_STAGE" ;; esac
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Strut"
rm -rf "$DEST"
if [ ! -d "$STRUT_STAGE" ]; then
  echo "warning: no strut staged at $STRUT_STAGE (scripts/stage-strut.sh <strut checkout>); this Peel's agent has no memory or automations"
  [ "${PEEL_REQUIRE_STRUT:-}" != 1 ] || exit 1
  exit 0
fi
# Another strut than the pin, as for the bridge: left out, or the build's end where it must ship one.
# Its UI is what opens the agent's deliverables, so an older one would show the whole of itself instead.
WANT_STRUT="$(awk '!/^#/ && NF { print $1; exit }' "$ROOT/Vendor/strut.lock")"
if [ "$(sed -n 's/^strut //p' "$STRUT_STAGE/STAGED_FROM" 2> /dev/null)" != "$WANT_STRUT" ]; then
  echo "warning: the staged strut is not strut $WANT_STRUT (Vendor/strut.lock); stage it again (scripts/stage-strut.sh <strut checkout>). Left out: this Peel's agent has no memory or automations"
  [ "${PEEL_REQUIRE_STRUT:-}" != 1 ] && [ "${CONFIGURATION:-}" != Release ] || exit 1
  exit 0
fi
echo "embed-strut: $(head -1 "$STRUT_STAGE/STAGED_FROM" 2> /dev/null || echo 'strut, unknown source')"
# Its workspace is on Ladybug, whose extensions a signed app cannot download: a stage without them is refused.
[ "$(plutil -extract ladybug raw -o - "$STRUT_STAGE/desktop.json" 2> /dev/null)" = true ] || {
  echo "error: the staged strut has no Ladybug; stage it again (scripts/stage-strut.sh <strut checkout>)"
  exit 1
}
# Dictation turns speech into text on it: a stage without its speech engine is refused too.
[ "$(plutil -extract stt raw -o - "$STRUT_STAGE/desktop.json" 2> /dev/null)" = true ] || {
  echo "error: the staged strut has no speech engine; stage it again (scripts/stage-strut.sh <strut checkout>)"
  exit 1
}
# And its fixer, which cleans up dictation and learns from edits, as stage-strut.sh requires.
[ "$(plutil -extract fixer raw -o - "$STRUT_STAGE/desktop.json" 2> /dev/null)" = true ] \
  && [ -e "$STRUT_STAGE/native/llama/mac-arm64-metal/llama-addon.node" ] || {
  echo "error: the staged strut has no dictation fixer; stage it again (scripts/stage-strut.sh <strut checkout>)"
  exit 1
}
ditto "$STRUT_STAGE" "$DEST"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -d "$DEST/native" ]; then
  # native/ and its folders (the dictation fixer's in native/llama/<platform>).
  # node and esbuild are standalone executables; a sandboxed build's App
  # Store validation requires com.apple.security.app-sandbox on each one
  # directly, not just on the app that launches them. Everything else
  # under native/ is a dylib/bundle the parent process loads in-process,
  # which needs no entitlements of its own.
  find "$DEST/native" -type f | while IFS= read -r code; do
    case "$code:$(file -b "$code")" in
      "$DEST/native/node":*|"$DEST/native/esbuild":*) ;;
      *:Mach-O*) sign "$code" ;;
    esac
  done
  for code in "$DEST/native/node" "$DEST/native/esbuild"; do
    [ -e "$code" ] && sign --entitlements "$ROOT/scripts/${PEEL_STRUT_ENTITLEMENTS:-strut-node.entitlements}" "$code"
  done
fi
