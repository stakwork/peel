#!/bin/bash
# Runs the message list journeys (scripts/journeys/*.drive) offscreen
# against a development profile and prints PASS or FAIL for each, with
# what its probe measured (evaluate.py). Each journey runs in its own
# `scripts/check-app.sh`, under the shared build lock.
#
#   scripts/journeys/run.sh <dev profile> [--peer <profile>] [--chat <name>]
#       [--other <name>] [journey ...]
#
# --chat is the long chat the journeys read (default the peer's name), --other a
# second chat to leave it for (default "bank"); scripts/journeys/seed.sh
# makes both. With --peer, each journey starts with the chat read, and
# the journeys marked `// needs: peer` run too: that profile sends into
# the chat when a drive signals it, and its key marks the chat unread for
# `// before: unread <n>`. Without it they are skipped. Results go to .build/journeys/<journey>/. Exits 1 if any failed.
set -euo pipefail

usage() { echo "usage: scripts/journeys/run.sh <dev profile> [--peer <profile>] [--chat <name>] [--other <name>] [journey ...]" >&2; exit 2; }
[ $# -ge 1 ] || usage
ME=$1
shift
PEER="" CHAT="" OTHER=bank ONLY=()
while [ $# -gt 0 ]; do
    case $1 in
        --peer) PEER=$2; shift 2 ;;
        --chat) CHAT=$2; shift 2 ;;
        --other) OTHER=$2; shift 2 ;;
        -*) usage ;;
        *) ONLY+=("$1"); shift ;;
    esac
done
CHAT=${CHAT:-${PEER:-peer}}
for name in "$ME" "$PEER"; do
    case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
        default | throwaway) echo "journeys: never \"$name\"; use a development profile" >&2; exit 2 ;;
    esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"
LOCK=/private/tmp/claude-501/peel-build.lock
lockf "$LOCK" swift build --product peel >/dev/null
peel() { .build/debug/peel --profile "$@"; }
key() { peel "$1" whoami | sed -n 's/^contact info: //p' | cut -d_ -f1; }
ME_KEY=$(key "$ME")
PEER_KEY=""
[ -n "$PEER" ] && PEER_KEY=$(key "$PEER")

# The server index of the chat's <n>th newest message from the peer.
incoming() {
    peel "$ME" messages "$PEER_KEY" | awk '$2 ~ /^#[0-9]+$/ && $4 != "me" { sub("#", "", $2); print $2 }' \
        | tail -n "$1" | head -n 1
}

failed=0
for drive in "$HERE"/*.drive; do
    journey=$(basename "$drive" .drive)
    if [ ${#ONLY[@]} -gt 0 ] && [[ ! " ${ONLY[*]} " =~ " $journey " ]]; then continue; fi
    if grep -q '^// needs: peer' "$drive" && [ -z "$PEER" ]; then
        echo "SKIP $journey: needs --peer"
        continue
    fi
    OUT=.build/journeys/$journey
    rm -rf "$OUT"
    mkdir -p "$OUT"
    sed -e "s/{{chat}}/$CHAT/g" -e "s/{{other}}/$OTHER/g" "$drive" >"$OUT/journey.drive"

    # Each journey starts read to the newest: one before may have left
    # messages unread.
    if [ -n "$PEER_KEY" ]; then peel "$ME" read "$PEER_KEY" --wait 3 >/dev/null 2>&1; fi
    unread=$(sed -n 's|^// before: unread \([0-9]*\)$|\1|p' "$drive")
    if [ -n "$unread" ]; then
        index=$(incoming "$unread")
        peel "$ME" mark-unread "$PEER_KEY" "$index" --wait 3 >/dev/null 2>&1
    fi

    lockf "$LOCK" scripts/check-app.sh "$ME" "$OUT/journey.drive" "$OUT" >"$OUT/check.log" 2>&1 &
    CHECK=$!
    sent=0
    while kill -0 "$CHECK" 2>/dev/null; do
        if [ $sent -eq 0 ] && [ -f "$OUT/signal-peer-sends" ]; then
            peel "$PEER" send "$ME_KEY" "a message from the journey check" --wait 2 >/dev/null 2>&1 &
            sent=1
        fi
        sleep 0.2
    done
    wait "$CHECK" || true
    wait

    if ! result=$(python3 "$HERE/evaluate.py" "$OUT" "$drive" 2>&1); then failed=1; fi
    printf '%s\n' "$result" | sed -E "s/^(PASS|FAIL) /\1 $journey\//"
done
exit $failed
