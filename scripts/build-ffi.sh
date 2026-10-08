#!/bin/sh
# Assembles the Sphinx core bindings for Swift:
#   Vendor/sphinxrsFFI.xcframework  - the Rust static library plus its C header
#   Sources/Sphinxrs/sphinxrs.swift - the generated Swift bindings
#
# Both come from sibling checkouts so they stay in lockstep with what the
# official Mac app ships. Override the locations with SPHINX_RS and SPHINX_MAC.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPHINX_RS="${SPHINX_RS:-$ROOT/../sphinx-rs}"
SPHINX_MAC="${SPHINX_MAC:-$ROOT/../sphinx-mac-v2}"

LIB="$SPHINX_MAC/universal-sphinxrs-mac.a"
BINDINGS="$SPHINX_RS/sphinx-ffi/src/sphinxrs.swift"
HEADER="$SPHINX_RS/sphinx-ffi/src/sphinxrsFFI.h"

for f in "$LIB" "$BINDINGS" "$HEADER"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# The Mac app keeps its own copy of the bindings; refuse to mix versions.
MAC_BINDINGS="$SPHINX_MAC/com.stakwork.sphinx.desktop/Crypter/sphinxrs.swift"
if [ -f "$MAC_BINDINGS" ] && ! cmp -s "$BINDINGS" "$MAC_BINDINGS"; then
  echo "bindings in sphinx-rs and sphinx-mac-v2 differ; the static library may not match" >&2
  exit 1
fi

# Every signing and encryption step runs inside this library, so refuse a copy
# that differs from the one recorded in Vendor/sphinxrs.lock. Pass --update after
# deliberately taking a new build.
LOCK="$ROOT/Vendor/sphinxrs.lock"
ACTUAL="$(shasum -a 256 "$LIB" | cut -d' ' -f1) $(git -C "$SPHINX_RS" rev-parse HEAD)"
if [ "${1:-}" = "--update" ] || [ ! -f "$LOCK" ]; then
  mkdir -p "$ROOT/Vendor"
  printf '%s\n' "$ACTUAL" > "$LOCK"
elif [ "$(cat "$LOCK")" != "$ACTUAL" ]; then
  echo "universal-sphinxrs-mac.a or sphinx-rs differ from Vendor/sphinxrs.lock; re-run with --update if intended" >&2
  exit 1
fi

XCF="$ROOT/Vendor/sphinxrsFFI.xcframework"
SLICE="$XCF/macos-arm64_x86_64"
rm -rf "$XCF"
mkdir -p "$SLICE/Headers"

cp "$LIB" "$SLICE/libsphinxrs.a"
cp "$HEADER" "$SLICE/Headers/sphinxrsFFI.h"
cat > "$SLICE/Headers/module.modulemap" <<'EOF'
module sphinxrsFFI {
    header "sphinxrsFFI.h"
    export *
}
EOF

cat > "$XCF/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>macos-arm64_x86_64</string>
            <key>LibraryPath</key>
            <string>libsphinxrs.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
                <string>x86_64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF

mkdir -p "$ROOT/Sources/Sphinxrs"
cp "$BINDINGS" "$ROOT/Sources/Sphinxrs/sphinxrs.swift"

echo "bindings ready: $(git -C "$SPHINX_RS" log -1 --format='sphinx-rs %h (%ad)' --date=short)"
