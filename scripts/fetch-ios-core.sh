#!/bin/sh
# Fetches the iPhone's Sphinx core for scripts/build-ffi.sh, from the same
# sphinx-rs release Vendor/sphinxrs.lock names: its universal-sphinxrs.a,
# checked against the sha256 Vendor/sphinxrs-ios.lock pins for that release,
# and its iOS device slice (arm64) taken out. Its other slice is an x86_64
# simulator, which no Apple silicon simulator runs, so it is left: this is
# for archiving on a machine without a sphinx-rs-ios checkout
# (.github/workflows/testflight.yml).
#
#   scripts/fetch-ios-core.sh [<dir>]            downloads and checks it, prints
#                                                SPHINX_IOS_LIB=… for build-ffi.sh
#   scripts/fetch-ios-core.sh --update [<dir>]   records the sha256 of the release
#                                                Vendor/sphinxrs.lock names now: after
#                                                build-ffi.sh --update <tag>
#
# <dir> defaults to .build/sphinx-core-ios. Needs gh (GH_TOKEN on CI).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE=
[ "${1:-}" != --update ] || { UPDATE=1; shift; }
OUT="${1:-$ROOT/.build/sphinx-core-ios}"
die() { echo "fetch-ios-core: $*" >&2; exit 1; }

TAG="$(awk '!/^#/ && NF { print $NF; exit }' "$ROOT/Vendor/sphinxrs.lock")"
[ -n "$TAG" ] || die "Vendor/sphinxrs.lock names no release"
mkdir -p "$OUT"
LIB="$OUT/universal-sphinxrs-$TAG.a"
[ -f "$LIB" ] || gh release download "$TAG" --repo stakwork/sphinx-rs -p universal-sphinxrs.a -O "$LIB" \
  || die "cannot download universal-sphinxrs.a from sphinx-rs $TAG"
GOT="$(shasum -a 256 "$LIB" | awk '{ print $1 }')"

LOCK="$ROOT/Vendor/sphinxrs-ios.lock"
if [ -n "$UPDATE" ]; then
  {
    echo "# The sha256 of universal-sphinxrs.a from the sphinx-rs release named after it, the iPhone's"
    echo "# core (scripts/fetch-ios-core.sh). The release must be the one Vendor/sphinxrs.lock names."
    echo "$GOT $TAG"
  } > "$LOCK"
  echo "fetch-ios-core: pinned $TAG ($GOT)" >&2
else
  [ -f "$LOCK" ] || die "no Vendor/sphinxrs-ios.lock; run with --update"
  WANT="$(awk '!/^#/ && NF { print $1; exit }' "$LOCK")"
  WANT_TAG="$(awk '!/^#/ && NF { print $2; exit }' "$LOCK")"
  [ "$WANT_TAG" = "$TAG" ] || die "Vendor/sphinxrs-ios.lock pins $WANT_TAG but Vendor/sphinxrs.lock names $TAG; run with --update"
  [ "$GOT" = "$WANT" ] || { rm -f "$LIB"; die "universal-sphinxrs.a of $TAG is $GOT, not the $WANT Vendor/sphinxrs-ios.lock pins"; }
fi

DEST="$OUT/ios-arm64/libsphinxrs.a"
mkdir -p "$(dirname "$DEST")"
lipo -thin arm64 "$LIB" -o "$DEST" || die "universal-sphinxrs.a of $TAG has no arm64 slice"
# Platform 2 is iOS (LC_BUILD_VERSION), as named by the first object that
# names one: assembly objects carry none.
objects="$(mktemp -d)"
(cd "$objects" && ar x "$DEST")
found="$(find "$objects" -name '*.o' -exec otool -l {} + | awk '/cmd LC_BUILD_VERSION/ { getline; getline; print $2; exit }')"
rm -rf "$objects"
[ "$found" = 2 ] || die "the arm64 slice of $TAG is for platform $found, not iOS (2)"
echo "SPHINX_IOS_LIB=$DEST"
