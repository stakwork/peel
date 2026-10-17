#!/bin/sh
# Build phase of the Mac app (Apps/Peel.xcodeproj, "Peel macOS"): puts the
# agent's strut, as scripts/stage-strut.sh left it (once per Mac, shared by
# every checkout), into Contents/Strut. Not under Contents/Helpers, which
# codesign keeps for signed nested bundles.
#
# PEEL_REQUIRE_STRUT=1 (scripts/run-app.sh) fails without a staged strut
# instead of warning. When Xcode signs the build (an archive, a run from
# Xcode), the strut's native code is signed here, first, with the build's
# identity, so hardened runtime's library validation accepts it; Node alone
# gets an entitlement, allow-jit, which V8 needs. A build that Xcode leaves
# unsigned (scripts/bundle-app.sh) is signed by scripts/sign-app.sh instead.
#
# A Debug build also gets the agent's bridge, as scripts/stage-bridge.sh left
# it, in Contents/Bridge (docs/agent-on-strut.md, PR 4), only if it was
# staged from the commit Vendor/runner.lock names: only dev builds offer its
# preview, so a Release build never carries it.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_STAGE="${PEEL_BRIDGE_STAGE:-$HOME/Library/Caches/dev.peel.build/bridge}"
case "$BRIDGE_STAGE" in /*) ;; *) BRIDGE_STAGE="$PWD/$BRIDGE_STAGE" ;; esac
BRIDGE_DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Bridge"
rm -rf "$BRIDGE_DEST"
WANT_RUNNER="$(awk '!/^#/ && NF { print $1; exit }' "$ROOT/Vendor/runner.lock")"
if [ "${CONFIGURATION:-}" = Debug ]; then
  if [ -x "$BRIDGE_STAGE/sphinx-runner" ] && [ "$(sed -n 's/^sphinx //p' "$BRIDGE_STAGE/STAGED_FROM" 2> /dev/null)" != "$WANT_RUNNER" ]; then
    echo "warning: the staged bridge is not sphinx $WANT_RUNNER (Vendor/runner.lock); stage it again (scripts/stage-bridge.sh <sphinx checkout>). Left out"
  elif [ -x "$BRIDGE_STAGE/sphinx-runner" ]; then
    echo "embed-strut: bridge $(head -1 "$BRIDGE_STAGE/STAGED_FROM" 2> /dev/null || echo 'from an unknown source')"
    mkdir -p "$BRIDGE_DEST"
    ditto "$BRIDGE_STAGE/sphinx-runner" "$BRIDGE_DEST/sphinx-runner"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "$BRIDGE_DEST/sphinx-runner"
    fi
  else
    echo "warning: no bridge staged at $BRIDGE_STAGE (scripts/stage-bridge.sh <sphinx checkout>); the agent's strut preview cannot start one"
  fi
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
echo "embed-strut: $(head -1 "$STRUT_STAGE/STAGED_FROM" 2> /dev/null || echo 'strut, unknown source')"
# Its workspace is on Ladybug, whose extensions a signed app cannot download: a stage without them is refused.
[ "$(plutil -extract ladybug raw -o - "$STRUT_STAGE/desktop.json" 2> /dev/null)" = true ] || {
  echo "error: the staged strut has no Ladybug; stage it again (scripts/stage-strut.sh <strut checkout>)"
  exit 1
}
ditto "$STRUT_STAGE" "$DEST"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -d "$DEST/native" ]; then
  sign() { codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "$@"; }
  for code in "$DEST"/native/*; do
    case "$(basename "$code"):$(file -b "$code")" in
      node:*) ;;
      *:Mach-O*) sign "$code" ;;
    esac
  done
  sign --entitlements "$ROOT/scripts/${PEEL_STRUT_ENTITLEMENTS:-strut-node.entitlements}" "$DEST/native/node"
fi
