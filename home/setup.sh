#!/bin/sh
# setup.sh: Peel Home's setup service, a loop around strut's `strut move
# serve` on the strut image (README.md, "How it fits together").
#
#   setup.sh                          the service (the container's command)
#   setup.sh send-back [HOST[:PORT]]  sends Peel Home back to the Mac; prints the link.
#                                     HOST is this box's address (default HOME_SETUP_HOST)
#   setup.sh cancel [--force]         keeps Peel Home here; strut and the bridge start again
set -u
umask 077
state=/data/setup
gate=/data/gate
events=$state/events
request=$state/send-back
strut_env=/data/env/strut
bridge_env=/data/env/bridge

# Run in the background (`serve … &`): exec, so the pid a cancel kills is
# node's. The link prefix comes from STRUT_MOVE_LINK.
move() {
    exec node build/move/cli.js "$@" \
        --data /data/strut/workspace --host-config /data/strut/host-config.json \
        --sidecar bridge=/data/bridge/store --env "$strut_env/home.env" --sidecar-env "bridge=$bridge_env/bridge.env" \
        --state /data/.move --name "Peel Home" >>"$events"
}
nap() { sleep "$1" & wait $!; }
key() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
fail() { echo "setup: $*" >&2; exit 1; }
# Whether serve printed EVENT, and a string field of the last such line.
saw() { grep -q "^{\"event\":\"$1\"" "$events" 2>/dev/null; }
field() { grep "^{\"event\":\"$1\"" "$events" 2>/dev/null | tail -n 1 | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
# KEY from a KEY='value' file, read by gate.sh's parser, which runs nothing in it.
value() { sh /gate.sh get "$2" "$1"; }

# This box's own secrets, never moved, new for each move in; split by
# program, so the bridge never sees strut's keys.
write_host_env() {
    strut_key=$(key)
    mkdir -p "$strut_env" "$bridge_env"
    printf "STRUT_API_KEY='%s'\n" "$strut_key" >"$strut_env/host.env"
    printf "RUNNER_ADMIN_TOKEN='%s'\nBRIDGE_TOKEN='%s'\nBRIDGE_STRUT_KEY='%s'\n" "$(key)" "$(key)" "$strut_key" >"$bridge_env/host.env"
}

# strut's arrival rewrite points the moved callbacks at this box's bridge,
# and sets the two secrets Peel's device steps read (Orchestrator.useBridge).
# A send-back may first apply a moved.json strut hasn't, which needs strut's key.
serve() {
    STRUT_MOVE_BRIDGE_TOKEN=$(value BRIDGE_TOKEN "$bridge_env/host.env")
    export STRUT_MOVE_BRIDGE_TOKEN
    if [ -f "$strut_env/home.env" ]; then
        STRUT_SECRET_KEY=$(value STRUT_SECRET_KEY "$strut_env/home.env") || return 1
        export STRUT_SECRET_KEY
    fi
    : >"$events"
    move serve "$@" --bridge "$BRIDGE_URL" \
        --set-secret 'PEEL_BRIDGE_PORT={bridge.port}' --set-secret 'PEEL_BRIDGE_TOKEN={bridge.token}'
}

# gate.sh's heartbeat is gone (it stopped its program) or stale (its container is down).
stopped() {
    beat=$(stat -c %Y "$gate/$1.running" 2>/dev/null || echo 0)
    [ $(($(date +%s) - beat)) -gt 30 ]
}

# What strut move set aside after a send-back, under strut's own folder, goes
# where only setup can see it: it holds the agent's seed and strut's key, and
# the next Peel Home's strut must not read them.
put_away_sent() {
    for sent in /data/strut/sent-*; do
        [ -e "$sent" ] || continue
        mkdir -p /data/sent
        mv "$sent" /data/sent/
    done
}

# Stops strut and the bridge, then serves the move until the Mac confirms;
# returns early on `setup.sh cancel`.
send_back() {
    touch "$gate/stop"
    until stopped strut && stopped bridge; do
        [ -f "$request" ] || return
        nap 1
    done
    # The address the link names, from `send-back HOST` or HOME_SETUP_HOST.
    STRUT_MOVE_HOST=$(cat "$request")
    export STRUT_MOVE_HOST
    serve --send-back & child=$!
    while kill -0 "$child" 2>/dev/null; do
        [ -f "$request" ] || { kill "$child" 2>/dev/null; break; }
        nap 1
    done
    wait "$child"
    if saw sent; then
        put_away_sent
    else
        echo "setup: the send-back did not finish; Peel Home stays here" >&2
    fi
}

run() {
    mkdir -p "$state" "$gate"
    trap 'kill "$child" 2>/dev/null; exit 0' TERM INT
    child=
    put_away_sent
    # A send-back that a restart cut short is not served again under a new code
    # the Mac doesn't have. strut and the bridge stay stopped: the Mac may have
    # Peel Home already.
    if [ -f "$request" ]; then
        rm -f "$request"
        echo "setup: a send-back was under way when setup stopped. strut and the bridge stay stopped. Run setup.sh send-back again, or setup.sh cancel --force if the Mac does not have Peel Home" >&2
    fi
    while :; do
        if [ ! -f "$strut_env/home.env" ]; then
            rm -f "$gate/stop"
            # Rebuilt by strut; nothing a previous occupant left is loaded.
            rm -rf /data/cache/strut /data/cache/models
            write_host_env
            serve & child=$!
            wait "$child"
            if saw received; then :
            elif saw already-here; then
                # Folders but no home.env: strut move writes the env files last, so a move cut short.
                echo "setup: /data/strut has a move that did not finish; move /data/strut/workspace aside to start again" >&2
                nap 60
            else
                nap 5
            fi
        elif [ -f "$request" ]; then
            send_back
            # Sent, cancelled or failed: strut and the bridge run again if Peel Home is still here.
            rm -f "$request" "$gate/stop"
        else
            nap 2
        fi
    done
}

case "${1:-}" in
"") run ;;
send-back)
    [ -f "$strut_env/home.env" ] || fail "Peel Home is not on this box"
    host=${2:-${STRUT_MOVE_HOST:-}}
    [ -n "$host" ] || fail "say this box's address as the Mac reaches it: setup.sh send-back <address>[:<port>] (or set HOME_SETUP_HOST)"
    # Emptied first, so the ready line is this send-back's.
    : >"$events"
    printf '%s' "$host" >"$request"
    echo "Stopping strut and the bridge, then packing Peel Home…"
    until saw ready; do
        [ -f "$request" ] || fail "the send-back stopped; see: docker compose logs setup"
        nap 1
    done
    printf '\nOn the Mac, in Peel'"'"'s Account › Peel Home, choose "Move back to this Mac" and open this link:\n\n  %s\n\n' "$(field ready link)"
    echo "(The QR code is in: docker compose logs setup)"
    echo "Waiting for the Mac… (setup.sh cancel stops this, and strut starts again)"
    while [ -f "$request" ]; do nap 1; done
    [ -f "$strut_env/home.env" ] && fail "the send-back stopped; Peel Home stays here"
    echo "Peel Home is back on the Mac. This box is empty."
    ;;
cancel)
    # Once the link is out, the Mac may have fetched Peel Home before its
    # confirmation was lost: starting it here too would run the agent twice.
    if { [ -f "$request" ] && saw ready; } || { [ ! -f "$request" ] && [ -f "$gate/stop" ]; }; then
        [ "${2:-}" = --force ] || fail "the Mac may already have Peel Home; if it doesn't, run: setup.sh cancel --force"
    fi
    rm -f "$request" "$gate/stop"
    ;;
*) fail "unknown command ${1}" ;;
esac
