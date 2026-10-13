#!/bin/bash
# Gives a development profile sats on a local test stack, the only allowed
# way to fund one (AGENTS.md, "Checking the app"): a real payment from the
# integration tests' bank (Tests/PeelIntegrationTests/Bank.swift), which adds
# the profile as a contact (named "bank") and pays it. Nothing writes a
# balance or a setting into any database.
#
#   scripts/fund-dev.sh <stack dir> <dev profile> <sats>
#
# <stack dir> is a running stack from `scripts/test-stack.sh start` (the
# PEEL_STACK_DIR it prints); the profile must already be registered on that
# stack's broker (`peel --profile <name> --server <PEEL_BROKER> init`).
# Refuses `default` and `throwaway`, and any server that is not this stack's
# loopback broker. Each run makes a new bank (about a minute) and restarts
# the stack's mixer twice, ending with real accounting. Pass SPHINX_BIN_DIR
# as for test-stack.sh.
set -euo pipefail

die() { echo "fund-dev: $*" >&2; exit 1; }

[ $# -eq 3 ] || { echo "usage: scripts/fund-dev.sh <stack dir> <dev profile> <sats>" >&2; exit 2; }
PROFILE=$2 SATS=$3
case "$(printf '%s' "$PROFILE" | tr '[:upper:]' '[:lower:]')" in
    default | throwaway) die "never \"$PROFILE\"; use a development profile" ;;
esac
[[ "$SATS" =~ ^[1-9][0-9]{0,5}$ ]] || die "sats must be 1 to 999999"

[ -f "$1/env" ] || die "no stack in $1"
STACK=$(cd "$1" && pwd)
# The stack's own settings, read, never sourced.
setting() { sed -n "s/^$1=//p" "$STACK/env" | head -n 1; }
BROKER=$(setting PEEL_BROKER)
TAP=$(setting PEEL_BROKER_TAP)
for address in "$BROKER" "$TAP"; do
    [[ "$address" =~ ^127\.0\.0\.1:([0-9]+)$ ]] || die "not a loopback stack: \"$address\""
    case "${BASH_REMATCH[1]}" in 1883 | 8000) die "never port ${BASH_REMATCH[1]}" ;; esac
done
lsof -nP -iTCP:"${BROKER#*:}" -sTCP:LISTEN >/dev/null 2>&1 || die "the stack's broker is not running"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
swift build --product peel >/dev/null
PEEL=(.build/debug/peel --profile "$PROFILE")

# The CLI only opens profiles under Peel/dev and refuses `default`.
WHO=$("${PEEL[@]}" whoami) || die "cannot read profile \"$PROFILE\""
field() { printf '%s\n' "$WHO" | sed -n "s/^$1: //p"; }
SERVER=$(field server)
[ "$SERVER" = "mqtt://$BROKER" ] || [ "$SERVER" = "mqtt://$TAP" ] \
    || die "\"$PROFILE\" is on $SERVER, not this stack ($BROKER)"
CONTACT=$(field "contact info")
[[ "$CONTACT" =~ ^0[23][0-9a-f]{64}_ ]] || die "\"$PROFILE\" is not registered yet; connect it once"
balance() { "${PEEL[@]}" whoami | sed -n 's/^balance: .*(\([0-9]*\) msat)$/\1/p'; }
BEFORE=$(balance)
BEFORE=${BEFORE:-0}

# The profile stays online to answer the bank's key exchange and take the payment.
"${PEEL[@]}" listen >"$STACK/fund-$PROFILE.log" 2>&1 &
LISTEN=$!
trap 'kill "$LISTEN" 2>/dev/null || true' EXIT

PEEL_STACK_DIR=$STACK PEEL_FUND_CONTACT=$CONTACT PEEL_FUND_SATS=$SATS \
    swift test --filter PeelIntegrationTests.FundDev >"$STACK/fund-test.log" 2>&1 \
    || { tail -n 20 "$STACK/fund-test.log" >&2; die "the bank's payment failed; see $STACK/fund-test.log"; }

WANT=$((BEFORE + SATS * 1000))
for _ in $(seq 1 60); do
    NOW=$(balance)
    if [ "${NOW:-0}" -ge "$WANT" ]; then
        echo "funded \"$PROFILE\": $((BEFORE / 1000)) -> $((NOW / 1000)) sats"
        exit 0
    fi
    sleep 1
done
die "\"$PROFILE\" holds $(( ${NOW:-0} / 1000 )) sats, expected at least $((WANT / 1000))"
