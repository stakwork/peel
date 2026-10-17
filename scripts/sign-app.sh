#!/bin/sh
# Signs an app bundle with the Apple Development identity in the login keychain
# and a provisioning profile for its bundle ID, so the app can keep the
# account's words in the data-protection Keychain (`keychain-access-groups`).
# Usage: scripts/sign-app.sh path/to/Peel.app
#
# The identity comes from scripts/signing-identity.sh: PEEL_SIGN_IDENTITY (a
# SHA-1 hash or a name), else the one Apple Development identity. Without one
# it refuses: an ad-hoc app could not load its embedded frameworks under
# library validation, nor use the Keychain.
#
# The profile and entitlements come from scripts/provision, an empty app that
# Xcode (signed in to the Apple ID under Settings > Accounts) builds with
# automatic signing for the same bundle ID. A free Personal Team's profile
# lasts 7 days and the app will not launch once it has expired, so the stub is
# rebuilt when its profile has under two days left, was made for another app ID
# or certificate, or lacks an entitlement Apps/Mac/Peel.entitlements
# now asks for. Re-signing with a new profile keeps the Keychain items.
#
# Frameworks in Contents/Frameworks (LiveKit's WebRTC), the strut in
# Contents/Strut (Node, its native addons and their libraries) and a Debug
# build's bridge in Contents/Bridge are signed first with the same identity,
# so hardened runtime's library validation accepts them. Node alone gets an
# entitlement: allow-jit, which V8 needs.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: sign-app.sh path/to/Peel.app}"
IDENTITY="$("$ROOT/scripts/signing-identity.sh")"
# Hardened runtime; no timestamp: the bundle is re-signed on every launch,
# never distributed as is.
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$@"; }

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
if printf '%s' "$IDENTITY" | grep -qE '^[0-9A-Fa-f]{40}$'; then
  CERT="$(security find-certificate -a -Z -p | awk -v h="$IDENTITY" '
    /^SHA-1 hash:/ { take = (toupper($3) == toupper(h)) } take && /BEGIN/,take && /END/ { print }')"
else
  CERT="$(security find-certificate -c "$IDENTITY" -p)"
fi
fingerprint() { openssl x509 -noout -fingerprint -sha1 "$@" | sed 's/.*=//; s/://g'; }
CERT_SHA1="$(printf '%s\n' "$CERT" | fingerprint)"
# The team is the certificate's organisational unit.
TEAM="$(printf '%s\n' "$CERT" | openssl x509 -noout -subject -nameopt multiline | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)"
[ -n "$TEAM" ] || { echo "cannot read the team ID from the signing certificate" >&2; exit 1; }
# A bundle ID belongs to one team, and dev.peel.mac to Peel's (T3M78XC3UV), so
# anyone signing with their own Apple ID gets dev.peel.mac.<team> unless
# PEEL_BUNDLE_ID chose one.
if [ -z "${PEEL_BUNDLE_ID:-}" ] && [ "$BUNDLE_ID" = dev.peel.mac ] && [ "$TEAM" != T3M78XC3UV ]; then
  BUNDLE_ID="dev.peel.mac.$(printf '%s' "$TEAM" | tr '[:upper:]' '[:lower:]')"
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
fi
APP_ID="$TEAM.$BUNDLE_ID"

STUB="$ROOT/.build/provision/Debug/Provision.app"
PROFILE="$STUB/Contents/embedded.provisionprofile"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

build_stub() {
  xcodebuild -quiet -project "$ROOT/scripts/provision/Provision.xcodeproj" -target Provision \
      SYMROOT="$ROOT/.build/provision" OBJROOT="$ROOT/.build/provision" -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build >"$WORK/xcodebuild.log" 2>&1 && return
  cat "$WORK/xcodebuild.log" >&2
  echo "Xcode could not provide a profile. Open Xcode > Settings > Accounts, sign in to the Apple ID for team $TEAM, then run this again." >&2
  echo "If the log says $BUNDLE_ID is not available, another team owns it: set PEEL_BUNDLE_ID to another." >&2
  return 1
}

# Whether the stub was signed for APP_ID with this certificate and a profile
# that has two days left. Leaves its entitlements and profile in $WORK.
profile_is_current() {
  [ -f "$PROFILE" ] || return 1
  security cms -D -i "$PROFILE" > "$WORK/profile.plist" 2>/dev/null || return 1
  codesign -d --entitlements - --xml "$STUB" > "$WORK/entitlements.plist" 2>/dev/null || return 1
  [ "$(plutil -extract 'com\.apple\.application-identifier' raw -o - "$WORK/entitlements.plist")" = "$APP_ID" ] || return 1
  codesign -d --extract-certificates="$WORK/cert" "$STUB" 2>/dev/null || return 1
  [ "$(fingerprint -inform der -in "$WORK/cert0")" = "$CERT_SHA1" ] || return 1
  EXPIRY="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist")" +%s)"
  [ "$EXPIRY" -ge $(($(date +%s) + 2 * 86400)) ]
}

# Whether the stub has every entitlement Peel.entitlements asks for
# (reads what profile_is_current left in $WORK).
stub_has_entitlements() {
  plutil -p "$ROOT/Apps/Mac/Peel.entitlements" | sed -n 's/^  "\([^"]*\)" => .*/\1/p' > "$WORK/wanted"
  while read -r key; do
    plutil -extract "$(printf '%s' "$key" | sed 's/\./\\./g')" xml1 -o /dev/null "$WORK/entitlements.plist" 2>/dev/null || return 1
  done < "$WORK/wanted"
}

if ! profile_is_current; then
  echo "fetching a provisioning profile for $APP_ID from Xcode" >&2
  # Xcode keeps using its copy of a profile until it has expired, so set that
  # copy aside while it fetches, and put it back if that fails.
  OLD=""
  if [ -s "$WORK/profile.plist" ]; then
    OLD="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$(plutil -extract UUID raw -o - "$WORK/profile.plist").provisionprofile"
    if [ -f "$OLD" ]; then mv "$OLD" "$WORK/old.provisionprofile"; else OLD=""; fi
  fi
  build_stub || { [ -z "$OLD" ] || mv "$WORK/old.provisionprofile" "$OLD"; exit 1; }
elif ! stub_has_entitlements; then
  # The profile is still good: the stub is signed again with it, with no
  # request to Apple.
  echo "signing the provisioning stub again for its new entitlements" >&2
  build_stub || exit 1
fi
if ! { profile_is_current && stub_has_entitlements; }; then
  echo "Xcode did not provide a profile for $APP_ID with this certificate, the stub's entitlements and two days left" >&2
  exit 1
fi

cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
for framework in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$framework" ] || continue
  sign "$framework"
done
if [ -d "$APP/Contents/Strut/native" ]; then
  for code in "$APP"/Contents/Strut/native/*; do
    case "$(basename "$code"):$(file -b "$code")" in
      node:*) ;;
      *:Mach-O*) sign "$code" ;;
    esac
  done
  sign --entitlements "$ROOT/scripts/strut-node.entitlements" "$APP/Contents/Strut/native/node"
fi
[ ! -f "$APP/Contents/Bridge/sphinx-runner" ] || sign "$APP/Contents/Bridge/sphinx-runner"
# The stub's entitlements are what the profile grants; the stub sets
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO, so there is no get-task-allow.
sign --entitlements "$WORK/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed $(basename "$APP") as $APP_ID; its profile expires $(date -r "$EXPIRY" '+%a %e %b %H:%M'), rebuild before then"
