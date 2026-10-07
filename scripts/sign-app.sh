#!/bin/sh
# Signs an app bundle with the Apple Development identity in the login keychain,
# so the Keychain can tie the account's words to this app across rebuilds.
# Usage: scripts/sign-app.sh path/to/Peel.app
# Set PEEL_SIGN_IDENTITY to choose an identity; with none available, signs ad hoc.
set -eu
APP="${1:?usage: sign-app.sh path/to/Peel.app}"
IDENTITY="${PEEL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "no Apple Development identity found; signing ad hoc (Keychain items will not survive a rebuild)" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "signed $(basename "$APP") with: $IDENTITY"
