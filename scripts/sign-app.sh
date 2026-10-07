#!/bin/sh
# Signs an app bundle with the Apple Development identity in the login keychain
# and a provisioning profile for its bundle ID, so the app can keep the
# account's words in the data-protection Keychain (`keychain-access-groups`).
# Usage: scripts/sign-app.sh path/to/Peel.app
#
# PEEL_SIGN_IDENTITY (a SHA-1 hash or a name) picks the identity; with exactly
# one Apple Development identity present it is chosen by its hash; with none,
# the bundle is signed ad hoc, without a profile, and cannot use the Keychain.
#
# The profile and entitlements come from scripts/provision, an empty app that
# Xcode (signed in to the Apple ID under Settings > Accounts) builds with
# automatic signing for the same bundle ID. A free Personal Team's profile
# lasts 7 days and the app will not launch once it has expired, so the stub is
# rebuilt when its profile has under two days left, or was made for another
# app ID or certificate. Re-signing with a new profile keeps the Keychain items.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: sign-app.sh path/to/Peel.app}"
IDENTITY="${PEEL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  HASHES="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p')"
  case "$(printf '%s\n' "$HASHES" | grep -c .)" in
    0) IDENTITY="-" ;;
    1) IDENTITY="$HASHES" ;;
    *) echo "several Apple Development identities found; set PEEL_SIGN_IDENTITY to one of:" >&2
       security find-identity -v -p codesigning >&2
       exit 1 ;;
  esac
fi
if [ "$IDENTITY" = "-" ]; then
  echo "signing ad hoc: the app cannot use the Keychain" >&2
  codesign --force --sign - --options runtime --timestamp=none "$APP"
  exit 0
fi

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
APP_ID="$TEAM.$BUNDLE_ID"

STUB="$ROOT/.build/provision/Debug/Provision.app"
PROFILE="$STUB/Contents/embedded.provisionprofile"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Whether the stub was signed for APP_ID with this certificate and a profile
# that has two days left. Leaves its entitlements and profile in $WORK.
stub_is_current() {
  [ -f "$PROFILE" ] || return 1
  security cms -D -i "$PROFILE" > "$WORK/profile.plist" 2>/dev/null || return 1
  codesign -d --entitlements - --xml "$STUB" > "$WORK/entitlements.plist" 2>/dev/null || return 1
  [ "$(plutil -extract 'com\.apple\.application-identifier' raw -o - "$WORK/entitlements.plist")" = "$APP_ID" ] || return 1
  codesign -d --extract-certificates="$WORK/cert" "$STUB" 2>/dev/null || return 1
  [ "$(fingerprint -inform der -in "$WORK/cert0")" = "$CERT_SHA1" ] || return 1
  EXPIRY="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist")" +%s)"
  [ "$EXPIRY" -ge $(($(date +%s) + 2 * 86400)) ]
}

if ! stub_is_current; then
  echo "fetching a provisioning profile for $APP_ID from Xcode" >&2
  # Xcode keeps using its copy of a profile until it has expired, so set that
  # copy aside while it fetches, and put it back if that fails.
  OLD=""
  if [ -s "$WORK/profile.plist" ]; then
    OLD="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$(plutil -extract UUID raw -o - "$WORK/profile.plist").provisionprofile"
    if [ -f "$OLD" ]; then mv "$OLD" "$WORK/old.provisionprofile"; else OLD=""; fi
  fi
  if ! xcodebuild -quiet -project "$ROOT/scripts/provision/Provision.xcodeproj" -target Provision \
      SYMROOT="$ROOT/.build/provision" OBJROOT="$ROOT/.build/provision" -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build >"$WORK/xcodebuild.log" 2>&1; then
    [ -z "$OLD" ] || mv "$WORK/old.provisionprofile" "$OLD"
    cat "$WORK/xcodebuild.log" >&2
    echo "Xcode could not provide a profile. Open Xcode > Settings > Accounts, sign in to the Apple ID for team $TEAM, then run this again." >&2
    exit 1
  fi
  stub_is_current || { echo "Xcode did not provide a profile for $APP_ID with this certificate and two days left" >&2; exit 1; }
fi

cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# The stub's entitlements are what the profile grants; the stub sets
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO, so there is no get-task-allow.
# No timestamp: the bundle is re-signed on every launch, never distributed as is.
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$WORK/entitlements.plist" "$APP"
codesign --verify --strict "$APP"
echo "signed $(basename "$APP") as $APP_ID; its profile expires $(date -r "$EXPIRY" '+%a %e %b %H:%M'), rebuild before then"
