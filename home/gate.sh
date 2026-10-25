#!/bin/sh
# gate.sh NAME COMMAND…: runs COMMAND (strut or the bridge) only while this
# box holds Peel Home (README.md, "How it fits together"). Its values are in
# /data/env/NAME/: what the move carried and this box's own host.env. Only
# the keys NAME takes are read, and never run: a move can't set PATH,
# NODE_OPTIONS or LD_PRELOAD. The bridge starts only once strut answers
# /health, and starts again whenever strut does.
set -u

# Reads FILE's KEY='value' lines (strut move's format: ' escaped as '\'')
# without running them: a moved file is untrusted. Every line must have that
# shape, or the whole file is refused. Calls `each KEY VALUE` for each line.
read_env() {
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        key=${line%%=*} quoted=${line#*=}
        case $key in '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) echo "gate: $1: line $n is not KEY='value'; refused" >&2; return 1 ;; esac
        case $quoted in \'*\') ;; *) echo "gate: $1: line $n ($key) is not KEY='value'; refused" >&2; return 1 ;; esac
        inner=${quoted#\'} inner=${inner%\'}
        case $(printf '%s' "$inner" | sed "s/'\\\\''//g") in *\'*) echo "gate: $1: line $n ($key) is not KEY='value'; refused" >&2; return 1 ;; esac
        each "$key" "$(printf '%s' "$inner" | sed "s/'\\\\''/'/g")"
    done <"$1"
}

# gate.sh get FILE KEY: KEY's value, for setup.sh.
if [ "${1:-}" = get ]; then
    want=$3 found=
    each() { [ "$1" = "$want" ] && found=$2; return 0; }
    read_env "$2" || exit 1
    printf '%s' "$found"
    exit 0
fi

name=$1
shift
env=/data/env/$name
gate=/data/gate
case $name in
strut) moved=$env/home.env keys="STRUT_SECRET_KEY|STRUT_API_KEY" ;;
bridge) moved=$env/bridge.env keys="BROKER_URL|BRIDGE_DEVICE|RUNNER_ALIAS|BRIDGE_WORKFLOW|BRIDGE_ACTOR|RUNNER_ADMIN_TOKEN|BRIDGE_TOKEN|BRIDGE_STRUT_KEY" ;;
*) echo "gate: unknown program $name" >&2; exit 2 ;;
esac

# strut's gate writes a new value here each time strut answers /health after
# a start. The bridge starts on one, and when it changes (strut, or strut's
# container, started again) the bridge's container exits for Docker to
# restart it: it rejoins strut's network, and its first turn finds strut.
ready=$gate/strut.ready
[ "$name" = strut ] && rm -f "$ready"

child= health=
nap() { sleep "$1" & wait $!; }
beat() { touch "$gate/$name.running"; }
# Stops the program and everything it started (gate.sh is the container's
# first process), keeping the heartbeat fresh while it waits, then removes
# the heartbeat: setup.sh reads a missing or stale one as "stopped".
stop_child() {
    if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null
        t=0
        while kill -0 "$child" 2>/dev/null && [ "$t" -lt 50 ]; do beat; nap 1; t=$((t + 1)); done
        kill -KILL "$child" 2>/dev/null
        wait "$child" 2>/dev/null
        child=
    fi
    [ -n "$health" ] && kill "$health" 2>/dev/null
    health=
    kill -TERM -1 2>/dev/null; nap 1; kill -KILL -1 2>/dev/null
    rm -f "$gate/$name.running"
    [ "$name" = strut ] && rm -f "$ready"
    return 0
}
trap 'stop_child; exit 0' TERM INT

has_home() { [ -f "$moved" ] && [ -f "$env/host.env" ] && [ ! -f "$gate/stop" ]; }
missing() {
    [ -f "$gate/stop" ] && { echo "a send-back (see the setup service)"; return; }
    [ -f "$moved" ] || { echo "$moved"; return; }
    echo "$env/host.env"
}

# Exports the keys this program takes; this box's host.env, read last, wins.
export_keys() {
    each() { case "|$keys|" in *"|$1|"*) export "$1=$2" ;; esac; }
    read_env "$moved" && read_env "$env/host.env"
}

while :; do
    if ! has_home; then
        stop_child
        echo "gate: $name waits for Peel Home ($(missing))"
        while ! has_home; do nap 2; done
    fi
    started=
    if [ "$name" = bridge ]; then
        [ -s "$ready" ] || echo "gate: bridge waits for strut"
        while has_home && [ ! -s "$ready" ]; do nap 2; done
        started=$(cat "$ready" 2>/dev/null)
    fi
    # The heartbeat before the program, then the stop check again: setup.sh
    # writes the stop request before it looks at the heartbeat.
    beat
    has_home || continue
    (export_keys || exit 1; exec "$@") &
    child=$!
    if [ "$name" = strut ]; then
        rm -f "$ready"
        (until curl -fsS -o /dev/null "http://127.0.0.1:${STRUT_PORT:-3000}/health" 2>/dev/null; do sleep 1; done
            od -An -N8 -tx1 /dev/urandom | tr -d ' \n' >"$ready.tmp" && mv "$ready.tmp" "$ready") &
        health=$!
    fi
    # The heartbeat every 10 s (setup.sh allows 30), the checks every 2.
    i=0
    while kill -0 "$child" 2>/dev/null && has_home; do
        [ $((i % 5)) -eq 0 ] && beat
        i=$((i + 1))
        if [ "$name" = bridge ] && [ -s "$ready" ] && [ "$(cat "$ready")" != "$started" ]; then
            echo "gate: strut started again; restarting the bridge's container to rejoin its network"
            stop_child
            exit 1
        fi
        nap 2
    done
    if kill -0 "$child" 2>/dev/null; then
        echo "gate: stopping $name"
        stop_child
    else
        wait "$child"
        echo "gate: $name ended ($?); starting it again in 5 seconds"
        child=
        stop_child
        nap 5
    fi
done
