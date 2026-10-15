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
# On a fresh pair there is none yet: grep finds nothing, which is no failure.
last=$(peer messages "$ME_KEY" | { grep -o ' m[0-9]\{3\} ' || true; } | tr -d ' m' | sort -n | tail -n 1)
last=$((10#${last:-0}))
for n in $(seq 1 320); do
    if [ "$n" -gt "$last" ]; then
        if [ $((n % 7)) -eq 0 ] && [ $((n % 25)) -ne 0 ]; then
            me send "$PEER_KEY" "$(line "$n")" --wait 1 >/dev/null
        else
            peer send "$ME_KEY" "$(line "$n")" --wait 1 >/dev/null
        fi
    fi
    # Its thread made already (the original then shows only in threads).
    if [ $((n % 25)) -eq 0 ] && ! peer threads | grep " m$(printf '%03d' "$n") " >/dev/null; then
        # Two replies in the thread this message starts, from the peer,
        # which sent it: the other side may not have it yet.
        uuid=$(peer messages "$ME_KEY" | awk -v tag=" m$(printf '%03d' "$n") " '$0 ~ tag { print $3 }' | tail -n 1)
        [ -n "$uuid" ] || die "no uuid for message $n"
        peer send "$ME_KEY" "reply one to m$n" --thread "$uuid" --wait 1 >/dev/null
        peer send "$ME_KEY" "reply two to m$n" --thread "$uuid" --wait 1 >/dev/null
    fi
done
me read "$PEER_KEY" --wait 3 >/dev/null

# A tribe <me> owns, "journeys", with <peer> in it: ~300 messages from both,
# a thread every 30 (5 to 20 replies), long messages and images.
TRIBE=$(me tribes | awk '$2 == "#journeys" { print $1 }' | head -n 1)
if [ -z "$TRIBE" ]; then
    created=$(me tribe-create journeys --description "list journeys" --price-per-message 0 --wait 3)
    TRIBE=$(printf '%s\n' "$created" | sed -n 's/^created #journeys \([0-9a-f]*\)$/\1/p')
    [ -n "$TRIBE" ] || die "no tribe made: $created"
fi
LINK=$(me tribes | awk -v key="$TRIBE" 'found { print $1; exit } $1 == key { found = 1 }')
peer tribes | grep "$TRIBE" >/dev/null || peer tribe-join "$LINK" --yes --wait 5 >/dev/null
IMAGE=$ROOT/docs/design/layout-light.png
long() { local text=""; for i in $(seq 1 12); do text+="$(line "$1") "; done; printf '%s' "$text"; }
tlast=$(peer messages "$TRIBE" | { grep -o ' t[0-9]\{3\} ' || true; } | tr -d ' t' | sort -n | tail -n 1)
tlast=$((10#${tlast:-0}))
for n in $(seq 1 300); do
    if [ "$n" -gt "$tlast" ]; then
        text="t$(printf '%03d' "$n") $(line "$n")"
        [ $((n % 17)) -eq 0 ] && text="t$(printf '%03d' "$n") $(long "$n")"
        who=peer
        [ $((n % 5)) -eq 0 ] && [ $((n % 30)) -ne 0 ] && who=me
        if [ $((n % 41)) -eq 0 ]; then
            $who send-file "$TRIBE" "$IMAGE" --text "$text" --wait 2 >/dev/null
        else
            $who send "$TRIBE" "$text" --wait 1 >/dev/null
        fi
    fi
    if [ $((n % 30)) -eq 0 ] && ! peer threads | grep " t$(printf '%03d' "$n") " >/dev/null; then
        uuid=$(peer messages "$TRIBE" | awk -v tag=" t$(printf '%03d' "$n") " '$0 ~ tag { print $3 }' | tail -n 1)
        [ -n "$uuid" ] || die "no uuid for tribe message $n"
        # From the peer, which has the original (<me> may not yet).
        # Each again a few times while the original is not delivered yet.
        for r in $(seq 1 $((5 + (n / 30 % 4) * 5))); do
            for try in 1 2 3 4 5; do
                peer send "$TRIBE" "t$(printf '%03d' "$n") reply $r $(line $((n + r)))" --thread "$uuid" --wait 1 \
                    >/dev/null 2>&1 && break
                [ "$try" -lt 5 ] || die "no reply $r in the thread of tribe message $n"
                sleep 2
            done
        done
    fi
done
# <me> writes in one thread, so its Threads list has one.
if ! me threads | grep " t030 " >/dev/null; then
    uuid=$(peer threads | awk '/ t030 / { print prev } { prev = $2 }' | head -n 1)
    me send "$TRIBE" "t030 reply from me" --thread "$uuid" --wait 2 >/dev/null
fi
me read "$TRIBE" --wait 3 >/dev/null
echo "seeded \"$ME\" and \"$PEER\"; peer key $PEER_KEY; tribe journeys $TRIBE"
