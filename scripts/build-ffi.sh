#!/bin/sh
# Assembles the Sphinx core bindings for Swift:
#   Vendor/sphinxrsFFI.xcframework  - the Rust static library plus its C header
#   Sources/Sphinxrs/sphinxrs.swift - the generated Swift bindings
#
# Vendor/sphinxrs.lock pins them: the library's sha256 and the sphinx-rs
# release whose assets they are. sphinx-rs CI (build-all.yml) attaches the Mac
# library, the Swift bindings and the header to every release.
#
#   scripts/build-ffi.sh                downloads the pinned release's files
#                                       (cached in .build/sphinx-core) and
#                                       checks the library against the lock
#   scripts/build-ffi.sh --update <tag> downloads another release's files and
#                                       records it in the lock: for moving to
#                                       a new core
#
# Either way it then checks that the core the release pins (sphinx-ffi's
# Cargo.toml at the tag) has upstream's client security fixes, in the
# stakwork/sphinx checkout at $SPHINX (default ../sphinx). A missing fix only
# warns.
#
# For iOS, set both SPHINX_IOS_LIB (an ios-arm64 static library) and
# SPHINX_IOS_SIM_LIB (ios-arm64-simulator), built from the sphinx-rs release
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
# Release tags only: they go into URLs and file names.
valid_tag() { printf '%s\n' "$1" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; }

if [ "${1:-}" = "--update" ]; then
  TAG="${2:-}"
  valid_tag "$TAG" || die "usage: build-ffi.sh --update <sphinx-rs release tag, e.g. v0.8.36>"
  LIB_SHA=""
else
  [ -f "$LOCK" ] || die "missing $LOCK; run with --update <tag>"
  read -r LIB_SHA TAG < "$LOCK"
  printf '%s\n' "$LIB_SHA" | grep -qE '^[0-9a-f]{64}$' && valid_tag "$TAG" \
    || die "$LOCK should hold a sha256 and a sphinx-rs release tag"
fi
fetch() { # url destination
  [ -s "$2" ] && return
  echo "downloading $1" >&2
  get "$1" > "$2.part" || { rm -f "$2.part"; die "could not download $1"; }
  mv "$2.part" "$2"
}
RELEASE="https://github.com/stakwork/sphinx-rs/releases/download/$TAG"
LIB="$CACHE/$TAG-universal-sphinxrs-mac.a"
BINDINGS="$CACHE/$TAG-sphinxrs.swift"
HEADER="$CACHE/$TAG-sphinxrsFFI.h"
fetch "$RELEASE/universal-sphinxrs-mac.a" "$LIB"
fetch "$RELEASE/sphinxrs.swift" "$BINDINGS"
fetch "$RELEASE/sphinxrsFFI.h" "$HEADER"
fetch "https://raw.githubusercontent.com/stakwork/sphinx-rs/$TAG/sphinx-ffi/Cargo.toml" "$CACHE/$TAG-Cargo.toml"
if [ -z "$LIB_SHA" ]; then
  mkdir -p "$ROOT/Vendor"
  printf '%s %s\n' "$(sha256 "$LIB")" "$TAG" > "$LOCK"
else
  # Every signing and encryption step runs inside this library, so refuse a
  # copy that differs from the one recorded in the lock.
  if [ "$(sha256 "$LIB")" != "$LIB_SHA" ]; then
    rm -f "$LIB"
    die "the downloaded universal-sphinxrs-mac.a ($TAG) does not match Vendor/sphinxrs.lock"
  fi
fi
CARGO_TOML="$(cat "$CACHE/$TAG-Cargo.toml")"

# The core rev the release pins must carry upstream's client security fixes
# (merged 2026-09-25, in sphinx v0.6.29). Until a sphinx-rs release has them
# this warns for development builds; two stand in meanwhile:
# Engine.cappedToArrived for SR-016's amount check, Engine.isForeignContactRecord
# for SR-017 (docs/phases/08-audit.md, "N1, after", lists what goes then).
SPHINX="${SPHINX:-$ROOT/../sphinx}"
# As committed at the release tag the lock names.
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
  LEVEL=WARNING
  {
    echo "************************************************************"
    echo "$LEVEL: the core sphinx-rs $TAG pins (sphinx ${CORE_REV:-unknown})"
    [ -z "$MISSING" ] || echo "  lacks upstream's client security fixes:$MISSING"
    [ -z "$UNCHECKED" ] || echo "  could not be checked in $SPHINX for:$UNCHECKED"
    echo "  Fixed upstream in v0.6.29; pin a sphinx-rs release with them."
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

echo "bindings ready: sphinx-rs $TAG (core ${CORE_REV:-unknown})"
