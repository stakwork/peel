#!/bin/bash
# Makes the two development profiles the list journeys run against, on a
# local stack: <me> (the app's) and <peer>, contacts, with one long direct
# chat between them (~320 messages of mixed lengths, some from <me>, a
# thread every 25 (two replies), the word "needle" only in the 60th), read up to its
# newest. <me> also has the "bank" contact funding left (a second chat).
#
#   scripts/journeys/seed.sh <stack dir> <me> <peer>
#
# <stack dir> is a running stack (`scripts/test-stack.sh start`). Takes
# about fifteen minutes: funding, then a send a second or two each. Pass
# SPHINX_BIN_DIR as for fund-dev.sh, and PEEL_BUILD_LOCK as for run.sh. Never `default` or `throwaway`.
set -euo pipefail

die() { echo "seed: $*" >&2; exit 1; }
[ $# -eq 3 ] || { echo "usage: scripts/journeys/seed.sh <stack dir> <me> <peer>" >&2; exit 2; }
STACK=$(cd "$1" && pwd) ME=$2 PEER=$3
for name in "$ME" "$PEER"; do
    case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
        default | throwaway) die "never \"$name\"; use a development profile" ;;
    esac
done
setting() { sed -n "s/^$1=//p" "$STACK/env" | head -n 1; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
# The build lock other checkouts on this Mac share.
LOCK=${PEEL_BUILD_LOCK:-${TMPDIR:-/tmp}/peel-build.lock}
lockf "$LOCK" swift build --product peel >/dev/null
HOSTS=(--server "$(setting PEEL_BROKER)" --tribe-host "$(setting PEEL_TRIBES)" --memes-host "$(setting PEEL_MEMES)")
me() { .build/debug/peel --profile "$ME" "$@"; }
peer() { .build/debug/peel --profile "$PEER" "$@"; }
contact() { .build/debug/peel --profile "$1" whoami | sed -n 's/^contact info: //p'; }

balance() { .build/debug/peel --profile "$1" whoami | sed -n 's/^balance: .*(\([0-9]*\) msat)$/\1/p'; }
# Again after a failed run: a profile made and funded is kept.
for name in "$ME" "$PEER"; do
    .build/debug/peel --profile "$name" whoami >/dev/null 2>&1 \
        || .build/debug/peel --profile "$name" --alias "$name" "${HOSTS[@]}" init >/dev/null
    [ "$(balance "$name")" -ge 500000 ] 2>/dev/null \
        || lockf "$LOCK" scripts/fund-dev.sh "$STACK" "$name" 1000
done

PEER_KEY=$(contact "$PEER" | cut -d_ -f1)
ME_KEY=$(contact "$ME" | cut -d_ -f1)
# The peer stays online to answer the key exchange.
.build/debug/peel --profile "$PEER" listen >"$STACK/seed-$PEER.log" 2>&1 &
LISTEN=$!
trap 'kill "$LISTEN" 2>/dev/null || true' EXIT
me contacts | grep -q "$PEER_KEY" || me add "$(contact "$PEER")" --wait 10
sleep 5
# Each profile is open in one process at a time.
kill "$LISTEN" 2>/dev/null || true
wait "$LISTEN" 2>/dev/null || true
peer contacts | grep -q "$ME_KEY" || die "the key exchange did not finish"

# Lengths vary so rows have different heights, as a real chat's do.
words="the quick brown fox jumps over a lazy dog while it rains on the hills and nobody minds at all"
line() {
    local n=$1 count=$((1 + ($1 * 7) % 40)) text=""
    for i in $(seq 1 "$count"); do text+="$(echo "$words" | cut -d' ' -f$(( (n + i) % 19 + 1 ))) "; done
    [ "$n" -eq 60 ] && text+="needle "
    printf 'm%03d %s' "$n" "$text"
}
# Again after a failed run: on from the newest message sent.
last=$(peer messages "$ME_KEY" | grep -o ' m[0-9]\{3\} ' | tr -d ' m' | sort -n | tail -n 1)
last=$((10#${last:-0}))
for n in $(seq 1 320); do
    if [ "$n" -gt "$last" ]; then
        if [ $((n % 7)) -eq 0 ] && [ $((n % 25)) -ne 0 ]; then
            me send "$PEER_KEY" "$(line "$n")" --wait 1 >/dev/null
        else
            peer send "$ME_KEY" "$(line "$n")" --wait 1 >/dev/null
        fi
    fi
    if [ $((n % 25)) -eq 0 ] && ! peer messages "$ME_KEY" | grep -q "reply one to m$n "; then
        # Two replies in the thread this message starts, from the peer,
        # which sent it: the other side may not have it yet.
        uuid=$(peer messages "$ME_KEY" | awk -v tag=" m$(printf '%03d' "$n") " '$0 ~ tag { print $3 }' | tail -n 1)
        [ -n "$uuid" ] || die "no uuid for message $n"
        peer send "$ME_KEY" "reply one to m$n" --thread "$uuid" --wait 1 >/dev/null
        peer send "$ME_KEY" "reply two to m$n" --thread "$uuid" --wait 1 >/dev/null
    fi
done
me read "$PEER_KEY" --wait 3 >/dev/null
echo "seeded \"$ME\" and \"$PEER\"; peer key $PEER_KEY"
