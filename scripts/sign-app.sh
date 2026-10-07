#!/bin/sh
# Signs an app bundle with the Apple Development identity in the login keychain,
# so the Keychain can tie the account's words to this app across rebuilds.
# Usage: scripts/sign-app.sh path/to/Peel.app
# PEEL_SIGN_IDENTITY (a SHA-1 hash or a name) picks the identity; with exactly
# one Apple Development identity present it is chosen by its hash; with none,
# the bundle is signed ad hoc.
set -eu
APP="${1:?usage: sign-app.sh path/to/Peel.app}"
IDENTITY="${PEEL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  HASHES="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p')"
  case "$(printf '%s\n' "$HASHES" | grep -c .)" in
    0) echo "no Apple Development identity found; signing ad hoc (Keychain items will not survive a rebuild)" >&2
       IDENTITY="-" ;;
    1) IDENTITY="$HASHES" ;;
    *) echo "several Apple Development identities found; set PEEL_SIGN_IDENTITY to one of:" >&2
       security find-identity -v -p codesigning >&2
       exit 1 ;;
  esac
fi
# No timestamp: the bundle is re-signed on every launch, never distributed as is.
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "signed $(basename "$APP") with: $(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)/\1/p' | head -1 || echo "$IDENTITY")"
