#!/bin/sh
# Prints the identity Peel's bundles are signed with: PEEL_SIGN_IDENTITY (a
# SHA-1 hash or a name), else the one Apple Development identity's hash. Fails
# with several (set PEEL_SIGN_IDENTITY) or none (an ad-hoc app could not load
# its embedded frameworks under library validation, nor use the Keychain).
set -eu
NONE="no Apple Development identity: the app's frameworks and Keychain need one; see AGENTS.md, Signing"
if [ -n "${PEEL_SIGN_IDENTITY:-}" ]; then
  # "-" is ad hoc, which cannot load the frameworks or use the Keychain.
  [ "$PEEL_SIGN_IDENTITY" != "-" ] || { echo "$NONE" >&2; exit 1; }
  printf '%s\n' "$PEEL_SIGN_IDENTITY"
  exit 0
fi
HASHES="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p')"
case "$(printf '%s\n' "$HASHES" | grep -c .)" in
  0) echo "$NONE" >&2
     exit 1 ;;
  1) printf '%s\n' "$HASHES" ;;
  *) echo "several Apple Development identities found; set PEEL_SIGN_IDENTITY to one of:" >&2
     security find-identity -v -p codesigning >&2
     exit 1 ;;
esac
