#!/bin/bash
# Runs the message list journeys (scripts/journeys/*.drive) offscreen
# against a development profile and prints PASS or FAIL for each, with
# what its probe measured (evaluate.py). Each journey runs in its own
# `scripts/check-app.sh`, under the shared build lock.
#
#   scripts/journeys/run.sh <dev profile> [--peer <profile>] [--chat <name>]
#       [--other <name>] [--tribe <name>] [journey ...]
#
# --chat is the long chat the journeys read (default the peer's name),
# --other a second chat to leave it for (default "bank"), --tribe the long
# tribe (default "journeys"); scripts/journeys/seed.sh makes all three. A
# drive's `{"signal": "peer-sends"}` has the peer send in the chat,
# `"peer-posts-tribe"` post in the tribe, `"peer-replies-thread"` reply in
# the tribe's thread its message t210 started, `"peer-sends-control"` send
# a control message (a request, docs/agent-on-strut.md) in the chat. With --peer, each journey starts
# with the chat read, and the journeys marked `// needs: peer` run too:
# that profile sends into the chat when a drive signals it, and its key
# marks the chat unread for `// before: unread <n>`; `// before:
# thread-between` has <me> post a long message in the tribe, the peer reply
# in t210's thread (its row then below that message) and <me> post again,
# so the thread's row sits between two of <me>'s. Without it they are
# skipped. Results go to .build/journeys/<journey>/. Exits 1 if any
# failed. PEEL_BUILD_LOCK names the build lock (default
# $TMPDIR/peel-build.lock).
set -euo pipefail

usage() { echo "usage: scripts/journeys/run.sh <dev profile> [--peer <profile>] [--chat <name>] [--other <name>] [--tribe <name>] [journey ...]" >&2; exit 2; }
[ $# -ge 1 ] || usage
ME=$1
shift
PEER="" CHAT="" OTHER=bank TRIBE_NAME=journeys ONLY=()
while [ $# -gt 0 ]; do
    case $1 in
        --peer) PEER=$2; shift 2 ;;
        --chat) CHAT=$2; shift 2 ;;
        --other) OTHER=$2; shift 2 ;;
        --tribe) TRIBE_NAME=$2; shift 2 ;;
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
# The build lock other checkouts on this Mac share.
LOCK=${PEEL_BUILD_LOCK:-${TMPDIR:-/tmp}/peel-build.lock}
lockf "$LOCK" swift build --product peel >/dev/null
peel() { .build/debug/peel --profile "$@"; }
key() { peel "$1" whoami | sed -n 's/^contact info: //p' | cut -d_ -f1; }
ME_KEY=$(key "$ME")
PEER_KEY=""
[ -n "$PEER" ] && PEER_KEY=$(key "$PEER")
TRIBE=$(peel "$ME" tribes | awk -v name="#$TRIBE_NAME" '$2 == name { print $1 }' | head -n 1)

# The server index of the chat's <n>th newest message from the peer.
incoming() {
    peel "$ME" messages "$PEER_KEY" | awk '$2 ~ /^#[0-9]+$/ && $4 != "me" { sub("#", "", $2); print $2 }' \
        | tail -n "$1" | head -n 1
}

# The uuid of the tribe's thread its message t210 started.
t210() { peel "$PEER" threads | awk '/ t210 / { print prev } { prev = $2 }' | head -n 1; }

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
    # As JSON strings, so a name with quotes, slashes or "&" stays one.
    python3 -c 'import json, sys
text = open(sys.argv[1]).read()
for key, name in (("chat", sys.argv[2]), ("other", sys.argv[3]), ("tribe", sys.argv[4])):
    text = text.replace("\"{{%s}}\"" % key, json.dumps(name))
sys.stdout.write(text)' "$drive" "$CHAT" "$OTHER" "$TRIBE_NAME" >"$OUT/journey.drive"

    # Each journey starts read to the newest: one before may have left
    # messages unread.
    if [ -n "$PEER_KEY" ]; then peel "$ME" read "$PEER_KEY" --wait 3 >/dev/null 2>&1; fi
    if [ -n "$TRIBE" ]; then peel "$ME" read "$TRIBE" --wait 3 >/dev/null 2>&1; fi
    unread=$(sed -n 's|^// before: unread \([0-9]*\)$|\1|p' "$drive")
    if [ -n "$unread" ]; then
        index=$(incoming "$unread")
        peel "$ME" mark-unread "$PEER_KEY" "$index" --wait 3 >/dev/null 2>&1
    fi
    if grep -q '^// before: thread-between$' "$drive"; then
        peel "$ME" send "$TRIBE" "a long message from the journey check, over three lines at the usual width: \
heads up, out this afternoon, on the phone for the rest of the day, so replies will be slow" --wait 3 >/dev/null 2>&1
        peel "$PEER" send "$TRIBE" "a thread reply from the journey check" --thread "$(t210)" --wait 3 >/dev/null 2>&1
        peel "$ME" send "$TRIBE" "a second message from the journey check, two lines at the usual width, \
after the thread's row" --wait 3 >/dev/null 2>&1
        peel "$ME" read "$TRIBE" --wait 3 >/dev/null 2>&1
    fi

    lockf "$LOCK" scripts/check-app.sh "$ME" "$OUT/journey.drive" "$OUT" >"$OUT/check.log" 2>&1 &
    CHECK=$!
    handled=" "
    while kill -0 "$CHECK" 2>/dev/null; do
        for signal in "$OUT"/signal-*; do
            [ -f "$signal" ] || continue
            name=${signal##*/signal-}
            [[ "$handled" == *" $name "* ]] && continue
            handled+="$name "
            case $name in
                peer-sends) peel "$PEER" send "$ME_KEY" "a message from the journey check" --wait 2 >/dev/null 2>&1 & ;;
                peer-sends-control)
                    envelope='{"v":1,"op":"request","id":"r_journey","device":"mac-journey","kind":"chats.unseen","not_after":1760610000}'
                    peel "$PEER" send-control "$ME_KEY" "$envelope" "Peel asked your Mac to read your unread messages" --wait 2 >/dev/null 2>&1 & ;;
                peer-posts-tribe) peel "$PEER" send "$TRIBE" "a tribe message from the journey check" --wait 2 >/dev/null 2>&1 & ;;
                peer-replies-thread)
                    peel "$PEER" send "$TRIBE" "a thread reply from the journey check" --thread "$(t210)" --wait 2 >/dev/null 2>&1 & ;;
            esac
        done
        sleep 0.2
    done
    wait "$CHECK" || true
    wait

    if ! result=$(python3 "$HERE/evaluate.py" "$OUT" "$drive" 2>&1); then failed=1; fi
    printf '%s\n' "$result" | sed -E "s/^(PASS|FAIL) /\1 $journey\//"
done
exit $failed
