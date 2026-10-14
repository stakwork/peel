#!/bin/sh
# Assembles the Sphinx core bindings for Swift:
#   Vendor/sphinxrsFFI.xcframework  - the Rust static library plus its C header
#   Sources/Sphinxrs/sphinxrs.swift - the generated Swift bindings
#
# Vendor/sphinxrs.lock pins them: the library's sha256, the sphinx-rs commit the
# bindings come from, and the sphinx-mac-v2 commit that ships that library, so
# Peel links exactly what the official Mac app ships.
#
#   scripts/build-ffi.sh            downloads the pinned files from GitHub
#                                   (cached in .build/sphinx-core) and checks
#                                   the library against the lock
#   scripts/build-ffi.sh --update   takes them from sibling checkouts instead
#                                   and records them in the lock: for moving to
#                                   a new core. Override the checkouts with
#                                   SPHINX_RS and SPHINX_MAC, and with SPHINX the
#                                   core's own, which the security check reads.
#
# For iOS, set both SPHINX_IOS_LIB (an ios-arm64 static library) and
# SPHINX_IOS_SIM_LIB (ios-arm64-simulator), built from the sphinx-rs commit
# the lock names; the xcframework (made by xcodebuild -create-xcframework)
# then gets those two slices beside the Mac one. The lock does not pin them
# yet, so the script prints their sha256 rather than checking it. Without
# them it writes the Mac slice alone, and a later run without them drops the iOS slices.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/Vendor/sphinxrs.lock"
CACHE="$ROOT/.build/sphinx-core"
mkdir -p "$CACHE"
die() { echo "build-ffi: $*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
get() { # url, to stdout; CI passes GITHUB_TOKEN for the API's rate limit
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
  else
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 "$1"
  fi
}
# GitHub serves a fork's commits under the upstream repo's URLs, so a commit
# is taken only once stakwork's own master has it.
on_master() { # repo commit
  [ -f "$CACHE/$2.on-master" ] && return
  compare="$(get "https://api.github.com/repos/stakwork/$1/compare/master...$2")" \
    || die "could not ask GitHub whether stakwork/$1 master has $2 (offline or rate-limited?)"
  status="$(printf '%s\n' "$compare" | grep -o '"status": *"[a-z]*"' | head -1 | sed 's/.*"\([a-z]*\)"$/\1/')"
  case "$status" in
    identical|behind) : > "$CACHE/$2.on-master" ;;
    *) die "$2 is not on stakwork/$1 master${status:+ ($status)}; push it there first" ;;
  esac
}

if [ "${1:-}" = "--update" ]; then
  SPHINX_RS="${SPHINX_RS:-$ROOT/../sphinx-rs}"
  SPHINX_MAC="${SPHINX_MAC:-$ROOT/../sphinx-mac-v2}"
  LIB="$SPHINX_MAC/universal-sphinxrs-mac.a"
  BINDINGS="$SPHINX_RS/sphinx-ffi/src/sphinxrs.swift"
  HEADER="$SPHINX_RS/sphinx-ffi/src/sphinxrsFFI.h"
  for f in "$LIB" "$BINDINGS" "$HEADER"; do
    [ -f "$f" ] || die "missing: $f"
  done
  # The Mac app keeps its own copy of the bindings; refuse to mix versions.
  MAC_BINDINGS="$SPHINX_MAC/com.stakwork.sphinx.desktop/Crypter/sphinxrs.swift"
  if [ -f "$MAC_BINDINGS" ] && ! cmp -s "$BINDINGS" "$MAC_BINDINGS"; then
    die "bindings in sphinx-rs and sphinx-mac-v2 differ; the static library may not match"
  fi
  # Others download by these commits, so both must be committed as they are here.
  git -C "$SPHINX_MAC" diff --quiet HEAD -- universal-sphinxrs-mac.a \
    || die "universal-sphinxrs-mac.a has uncommitted changes in $SPHINX_MAC"
  git -C "$SPHINX_RS" diff --quiet HEAD -- sphinx-ffi/src \
    || die "sphinx-ffi/src has uncommitted changes in $SPHINX_RS"
  RS_COMMIT="$(git -C "$SPHINX_RS" rev-parse HEAD)"
  MAC_COMMIT="$(git -C "$SPHINX_MAC" log -1 --format=%H -- universal-sphinxrs-mac.a)"
  on_master sphinx-rs "$RS_COMMIT"
  on_master sphinx-mac-v2 "$MAC_COMMIT"
  mkdir -p "$ROOT/Vendor"
  printf '%s %s %s\n' "$(sha256 "$LIB")" "$RS_COMMIT" "$MAC_COMMIT" > "$LOCK"
  CARGO_TOML="$(git -C "$SPHINX_RS" show HEAD:sphinx-ffi/Cargo.toml)"
else
  [ -f "$LOCK" ] || die "missing $LOCK; run with --update from sibling checkouts"
  read -r LIB_SHA RS_COMMIT MAC_COMMIT < "$LOCK"
  printf '%s %s %s\n' "$LIB_SHA" "$RS_COMMIT" "$MAC_COMMIT" | grep -qE '^[0-9a-f]{64} [0-9a-f]{40} [0-9a-f]{40}$' \
    || die "$LOCK should hold a sha256 and two commit hashes"
  on_master sphinx-rs "$RS_COMMIT"
  on_master sphinx-mac-v2 "$MAC_COMMIT"
  fetch() { # repo commit path destination
    [ -s "$4" ] && return
    echo "downloading $1/$3 at $(printf '%.7s' "$2")" >&2
    get "https://raw.githubusercontent.com/stakwork/$1/$2/$3" > "$4.part"
    mv "$4.part" "$4"
  }
  LIB="$CACHE/$LIB_SHA.a"
  BINDINGS="$CACHE/$RS_COMMIT-sphinxrs.swift"
  HEADER="$CACHE/$RS_COMMIT-sphinxrsFFI.h"
  fetch sphinx-mac-v2 "$MAC_COMMIT" universal-sphinxrs-mac.a "$LIB"
  fetch sphinx-rs "$RS_COMMIT" sphinx-ffi/src/sphinxrs.swift "$BINDINGS"
  fetch sphinx-rs "$RS_COMMIT" sphinx-ffi/src/sphinxrsFFI.h "$HEADER"
  fetch sphinx-rs "$RS_COMMIT" sphinx-ffi/Cargo.toml "$CACHE/$RS_COMMIT-Cargo.toml"
  # Every signing and encryption step runs inside this library, so refuse a
  # copy that differs from the one recorded in the lock.
  if [ "$(sha256 "$LIB")" != "$LIB_SHA" ]; then
    rm -f "$LIB"
    die "the downloaded universal-sphinxrs-mac.a does not match Vendor/sphinxrs.lock"
  fi
  CARGO_TOML="$(cat "$CACHE/$RS_COMMIT-Cargo.toml")"
fi

# The core rev sphinx-rs pins must carry upstream's client security fixes
# (merged 2026-09-25). The pinned bd9e140 has none of them, so for now this
# warns rather than stops. Two stand in meanwhile: Engine.cappedToArrived for
# SR-016's amount check, Engine.isForeignContactRecord for SR-017.
SPHINX="${SPHINX:-$ROOT/../sphinx}"
# As committed, the sphinx-rs commit the lock names.
CORE_REV="$(printf '%s\n' "$CARGO_TOML" | sed -n 's/^sphinx = .*rev = "\([0-9a-f]*\)".*/\1/p')"
CORE_KNOWN=no
git -C "$SPHINX" cat-file -e "${CORE_REV:-none}^{commit}" 2>/dev/null && CORE_KNOWN=yes
MISSING=""
UNCHECKED=""
while read -r commit name; do
  if [ "$CORE_KNOWN" = no ] || ! git -C "$SPHINX" cat-file -e "$commit^{commit}" 2>/dev/null; then
    UNCHECKED="$UNCHECKED $name"
  elif ! git -C "$SPHINX" merge-base --is-ancestor "$commit" "$CORE_REV"; then
    MISSING="$MISSING $name"
  fi
done <<'EOF'
c3ddbb7d02f26c70a96c50384dbd776d403fc229 SR-016(amount)
031427c3062722a1e70be5437f084cb610c8b6f4 SR-016(keyx)
9f784bc635e0d9b5a70e2f942216f697d04cd23a SR-017
a962ce1f3ca7d00cece2743e21ac27d38acc81ee SR-018
948f8cc1b0346000600858fbe51b522d09179cee SR-019
c1a46181f38e6085fdef51e84d9a28b09b102cf0 SR-020
480b3ae35fe511fb777b2f2ab3d72b0683ebb1e6 SR-022
EOF
if [ -n "$MISSING$UNCHECKED" ]; then
  {
    echo "************************************************************"
    echo "WARNING: the core this library pins (sphinx ${CORE_REV:-unknown})"
    [ -z "$MISSING" ] || echo "  lacks upstream's client security fixes:$MISSING"
    [ -z "$UNCHECKED" ] || echo "  could not be checked in $SPHINX for:$UNCHECKED"
    echo "  Fixed upstream in v0.6.29; sphinx-rs must move its pin."
    echo "************************************************************"
  } >&2
fi

XCF="$ROOT/Vendor/sphinxrsFFI.xcframework"
IOS_LIB="${SPHINX_IOS_LIB:-}"
IOS_SIM_LIB="${SPHINX_IOS_SIM_LIB:-}"
# One staging folder per slice, so each library keeps the same name and every
# slice shares the header and module map.
STAGE="$CACHE/xcframework-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Headers"
cp "$HEADER" "$STAGE/Headers/sphinxrsFFI.h"
cat > "$STAGE/Headers/module.modulemap" <<'EOF'
module sphinxrsFFI {
    header "sphinxrsFFI.h"
    export *
}
EOF
stage() { # slice library
  [ -f "$2" ] || die "missing: $2"
  mkdir -p "$STAGE/$1"
  cp "$2" "$STAGE/$1/libsphinxrs.a"
}
stage macos "$LIB"
set -- -library "$STAGE/macos/libsphinxrs.a" -headers "$STAGE/Headers"
IDS="macos-arm64_x86_64"
if [ -n "$IOS_LIB$IOS_SIM_LIB" ]; then
  [ -n "$IOS_LIB" ] && [ -n "$IOS_SIM_LIB" ] || die "set both SPHINX_IOS_LIB and SPHINX_IOS_SIM_LIB, or neither"
  stage ios "$IOS_LIB"
  stage ios-simulator "$IOS_SIM_LIB"
  echo "unpinned iOS library $(sha256 "$IOS_LIB") $IOS_LIB" >&2
  echo "unpinned iOS library $(sha256 "$IOS_SIM_LIB") $IOS_SIM_LIB" >&2
  set -- "$@" -library "$STAGE/ios/libsphinxrs.a" -headers "$STAGE/Headers" \
    -library "$STAGE/ios-simulator/libsphinxrs.a" -headers "$STAGE/Headers"
  IDS="$IDS ios-arm64 ios-arm64-simulator"
fi
# xcodebuild reads each library's platform from its load commands and writes
# the Info.plist from them. The new framework is built and checked beside the
# old one, which stays until the new one is good.
xcodebuild -create-xcframework "$@" -output "$STAGE/sphinxrsFFI.xcframework" >/dev/null
# A simulator library built for x86_64 only, say, lands under another
# identifier, so check each slice is where it belongs.
for id in $IDS; do
  [ -f "$STAGE/sphinxrsFFI.xcframework/$id/libsphinxrs.a" ] \
    || die "the xcframework has no $id slice; check the libraries' platforms and architectures"
done
rm -rf "$XCF"
mv "$STAGE/sphinxrsFFI.xcframework" "$XCF"
rm -rf "$STAGE"

mkdir -p "$ROOT/Sources/Sphinxrs"
cp "$BINDINGS" "$ROOT/Sources/Sphinxrs/sphinxrs.swift"

echo "bindings ready: sphinx-rs $(printf '%.7s' "$RS_COMMIT"), library from sphinx-mac-v2 $(printf '%.7s' "$MAC_COMMIT")"
