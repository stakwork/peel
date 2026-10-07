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
# The profile comes from Xcode (signed in to the Apple ID under Settings >
# Accounts). A free Personal Team's profile lasts 7 days and the app will not
# launch once it has expired, so when the newest installed profile has under
# two days left this builds scripts/provision once with automatic signing to
# fetch a fresh one. Re-signing with a new profile keeps the Keychain items.
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
# The team is the certificate's organisational unit.
if printf '%s' "$IDENTITY" | grep -qE '^[0-9A-Fa-f]{40}$'; then
  CERT="$(security find-certificate -a -Z -p | awk -v h="$IDENTITY" '
    /^SHA-1 hash:/ { take = (toupper($3) == toupper(h)) } take && /BEGIN/,take && /END/ { print }')"
else
  CERT="$(security find-certificate -c "$IDENTITY" -p)"
fi
CERT_SHA1="$(printf '%s\n' "$CERT" | openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
TEAM="$(printf '%s\n' "$CERT" | openssl x509 -noout -subject -nameopt multiline | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)"
[ -n "$TEAM" ] || { echo "cannot read the team ID from the signing certificate" >&2; exit 1; }
APP_ID="$TEAM.$BUNDLE_ID"

PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Whether the decoded profile in $WORK/profile.plist lists the signing certificate.
lists_certificate() {
  i=0
  while cert="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$WORK/profile.plist" 2>/dev/null)"; do
    [ "$(printf '%s' "$cert" | base64 -D | openssl x509 -inform der -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')" = "$CERT_SHA1" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# Prints "<expiry epoch> <path>" for the installed profile for APP_ID and this
# certificate that lasts longest, or nothing.
newest_profile() {
  for p in "$PROFILES"/*.provisionprofile; do
    [ -f "$p" ] || continue
    security cms -D -i "$p" > "$WORK/profile.plist" 2>/dev/null || continue
    [ "$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$WORK/profile.plist" 2>/dev/null)" = "$APP_ID" ] || continue
    lists_certificate || continue
    expiry="$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist")"
    echo "$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" +%s) $p"
  done | sort -n | tail -1
}

NOW="$(date +%s)"
BEST="$(newest_profile)"
if [ -z "$BEST" ] || [ "${BEST%% *}" -lt $((NOW + 2 * 86400)) ]; then
  echo "fetching a provisioning profile for $APP_ID from Xcode" >&2
  # Xcode keeps using a profile that has not expired yet, so set the old one
  # aside while it fetches, and put it back if that fails.
  mkdir "$WORK/aside"
  [ -z "$BEST" ] || mv "${BEST#* }" "$WORK/aside/"
  if ! xcodebuild -quiet -project "$ROOT/scripts/provision/Provision.xcodeproj" -target Provision \
      SYMROOT="$ROOT/.build/provision" OBJROOT="$ROOT/.build/provision" -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build >"$WORK/xcodebuild.log" 2>&1; then
    mv "$WORK/aside/"* "$PROFILES/" 2>/dev/null || true
    cat "$WORK/xcodebuild.log" >&2
    echo "Xcode could not provide a profile. Open Xcode > Settings > Accounts, sign in to the Apple ID for team $TEAM, then run this again." >&2
    exit 1
  fi
  BEST="$(newest_profile)"
  [ -n "$BEST" ] || { echo "Xcode built without leaving a profile for $APP_ID in $PROFILES" >&2; exit 1; }
fi
PROFILE="${BEST#* }"

cat > "$WORK/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key><string>$APP_ID</string>
    <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
    <key>keychain-access-groups</key><array><string>$APP_ID</string></array>
</dict>
</plist>
PLIST
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# No timestamp: the bundle is re-signed on every launch, never distributed as is.
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$WORK/entitlements.plist" "$APP"
codesign --verify --strict "$APP"
echo "signed $(basename "$APP") as $APP_ID; its profile expires $(date -r "${BEST%% *}" '+%a %e %b %H:%M'), rebuild before then"
