#!/bin/bash
# A local Sphinx stack for the integration tests (Tests/PeelIntegrationTests):
# broker, tribes server, mixer (NO_LIGHTNING), a memes stub and a wire tap in
# front of the broker, each on a random free port. Never 1883 or 8000 (another
# stack lives there), never a production server, never real sats.
#
#   scripts/test-stack.sh start [--owner-pid <pid>]
#       Starts a stack in a new temporary directory and prints its settings,
#       one KEY=value per line (also written to <dir>/env). With --owner-pid,
#       a watcher stops the stack once that process has exited.
#   scripts/test-stack.sh mixer <dir> fund|real
#       Restarts the mixer, then the tribes server, keeping their databases.
#       `fund` runs it with TESTING_ONLY_ADD_TO_SENDER=1 (senders are never
#       debited, so accounts can be given sats); `real` without it.
#   scripts/test-stack.sh stop <dir>
#       Kills only the processes this script started for <dir>, then checks
#       that their ports are free.
#
# Binaries, from stakwork/sphinx (~/Documents/sphinx), built with a target
# directory outside the checkout:
#   CARGO_TARGET_DIR=<dir> cargo build --manifest-path broker/Cargo.toml
#   CARGO_TARGET_DIR=<dir> cargo build --bin sphinx-mixer --bin sphinx-tribes
# SPHINX_BIN_DIR names that <dir>/debug (default ~/Documents/sphinx/target/debug);
# SPHINX_BROKER, SPHINX_MIXER and SPHINX_TRIBES override single binaries.
# The core Peel links (Vendor/, Sources/Sphinxrs) comes from ~/Documents/sphinx-rs
# by scripts/build-ffi.sh. The memes stub needs python3 with `cryptography`.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BIN_DIR=${SPHINX_BIN_DIR:-$HOME/Documents/sphinx/target/debug}
BROKER=${SPHINX_BROKER:-$BIN_DIR/sphinx-broker}
MIXER=${SPHINX_MIXER:-$BIN_DIR/sphinx-mixer}
TRIBES=${SPHINX_TRIBES:-$BIN_DIR/sphinx-tribes}
HELPERS=$HERE/test-stack-helpers.py
# Test-only keys for a stack that lives on this machine for one run.
BROKER_SEED=1111111111111111111111111111111111111111111111111111111111111111
TRIBES_SEED=2222222222222222222222222222222222222222222222222222222222222222
RESERVED="1883 8000"

die() { echo "test-stack: $*" >&2; exit 1; }

# Distinct free loopback ports, none of them reserved.
free_ports() {
    python3 - "$1" "$RESERVED" <<'EOF'
import socket, sys
count, reserved = int(sys.argv[1]), {int(p) for p in sys.argv[2].split()}
ports, held = [], []
while len(ports) < count:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    held.append(s)
    port = s.getsockname()[1]
    if port not in reserved and port not in ports:
        ports.append(port)
for s in held:
    s.close()
print(" ".join(map(str, ports)))
EOF
}

listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

wait_for_port() {
    local port=$1 name=$2
    for _ in $(seq 1 100); do
        listening "$port" && return 0
        sleep 0.2
    done
    tail -20 "$DIR/$name.log" >&2 || true
    die "$name did not listen on $port"
}

# Runs a command in the background from <dir>/<name>, its output appended to
# <dir>/<name>.log and its PID in <dir>/<name>.pid.
launch() {
    local name=$1
    shift
    mkdir -p "$DIR/$name"
    (cd "$DIR/$name" || exit 1; nohup "$@" >>"$DIR/$name.log" 2>&1 & echo $! >"$DIR/$name.pid")
}

# Kills the process in <dir>/<name>.pid, only if it is still the one started
# here (its command line names `expect`).
kill_own() {
    local name=$1 expect=$2 file=$DIR/$1.pid pid
    [ -f "$file" ] || return 0
    pid=$(cat "$file")
    if ps -p "$pid" -o command= 2>/dev/null | grep -q -- "$expect"; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
}

load_env() {
    DIR=${1:?a stack directory is needed}
    [ -f "$DIR/env" ] || die "no stack in $DIR"
    # shellcheck disable=SC1091
    source "$DIR/env"
}

start_tribes() {
    launch tribes env SEED=$TRIBES_SEED BROKER_URL=127.0.0.1:$BROKER_PORT ROCKET_PORT=$TRIBES_PORT \
        HOST=127.0.0.1:$TRIBES_PORT DB_PATH="$DIR/tribes/db" "$TRIBES"
    wait_for_port "$TRIBES_PORT" tribes
}

# The mixer names the tribes server's key as the default tribe server.
start_mixer() {
    local mode=$1 testing=""
    if [ "$mode" = fund ]; then testing=TESTING_ONLY_ADD_TO_SENDER=1; fi
    launch mixer env SEED=$BROKER_SEED NO_LIGHTNING=true TESTING_ONLY_AUTO_MINE=1 $testing \
        BROKER_URL=127.0.0.1:$BROKER_PORT ROCKET_PORT=$MIXER_PORT DEFAULT_TRIBE_PUBKEY=$TRIBES_KEY \
        DB_PATH="$DIR/mixer/db" "$MIXER"
    wait_for_port "$MIXER_PORT" mixer
    sed -i '' "s/^PEEL_MIXER_MODE=.*/PEEL_MIXER_MODE=$mode/" "$DIR/env"
}

# How often the mixer has logged the tribes server registering.
tribes_registrations() {
    local count
    count=$(grep -c "register\] COMPLETE | pubkey=$TRIBES_KEY" "$DIR/mixer.log" 2>/dev/null || true)
    echo "${count:-0}"
}

# The mixer's HTTP port opens before it listens on MQTT: an account that
# registers in between never hears back. The tribes server registering
# (it retries until answered) says the mixer is listening.
wait_for_tribes_registration() {
    local before=$1
    for _ in $(seq 1 150); do
        [ "$(tribes_registrations)" -gt "$before" ] && return 0
        sleep 0.2
    done
    die "the tribes server never registered with the mixer"
}

cmd_start() {
    local owner=""
    if [ "${1:-}" = --owner-pid ]; then owner=${2:?--owner-pid needs a pid}; fi
    for bin in "$BROKER" "$MIXER" "$TRIBES"; do
        [ -x "$bin" ] || die "missing $bin (see the build notes at the top of this script)"
    done
    command -v python3 >/dev/null || die "python3 is needed for the memes stub and the wire tap"

    DIR=$(mktemp -d "${TMPDIR:-/tmp}/peel-stack.XXXXXX")
    read -r BROKER_PORT CONSOLE_PORT TAP_PORT TRIBES_PORT MIXER_PORT MEMES_PORT <<<"$(free_ports 6)"
    cat >"$DIR/env" <<EOF
PEEL_STACK_DIR=$DIR
PEEL_BROKER=127.0.0.1:$BROKER_PORT
PEEL_BROKER_TAP=127.0.0.1:$TAP_PORT
PEEL_TRIBES=127.0.0.1:$TRIBES_PORT
PEEL_MEMES=127.0.0.1:$MEMES_PORT
PEEL_MIXER_MODE=none
BROKER_PORT=$BROKER_PORT
CONSOLE_PORT=$CONSOLE_PORT
TAP_PORT=$TAP_PORT
TRIBES_PORT=$TRIBES_PORT
MIXER_PORT=$MIXER_PORT
MEMES_PORT=$MEMES_PORT
EOF
    # A failed start leaves nothing running.
    trap 'cmd_stop "$DIR" >&2 || true' EXIT

    launch broker env SEED=$BROKER_SEED BROKER_MQTT_PORT=$BROKER_PORT BROKER_CONSOLE_PORT=$CONSOLE_PORT "$BROKER"
    wait_for_port "$BROKER_PORT" broker
    launch tap python3 "$HELPERS" tap "$TAP_PORT" "$BROKER_PORT" "$DIR/wire.bin"
    wait_for_port "$TAP_PORT" tap
    launch memes python3 "$HELPERS" memes "$MEMES_PORT" "$DIR/memes"
    wait_for_port "$MEMES_PORT" memes
    start_tribes
    TRIBES_KEY=$(curl -sf "http://127.0.0.1:$TRIBES_PORT/info" | sed -n 's/.*"pubkey":"\([0-9a-f]*\)".*/\1/p')
    [ -n "$TRIBES_KEY" ] || die "the tribes server gave no pubkey"
    echo "TRIBES_KEY=$TRIBES_KEY" >>"$DIR/env"
    start_mixer fund
    wait_for_tribes_registration 0
    trap - EXIT

    if [ -n "$owner" ]; then
        nohup "$0" watch "$DIR" "$owner" >"$DIR/watch.log" 2>&1 &
        echo $! >"$DIR/watch.pid"
    fi
    cat "$DIR/env"
}

cmd_mixer() {
    load_env "${1:-}"
    local mode=${2:?mixer needs fund or real}
    [ "$mode" = fund ] || [ "$mode" = real ] || die "mixer mode is fund or real"
    kill_own mixer sphinx-mixer
    kill_own tribes sphinx-tribes
    for port in $MIXER_PORT $TRIBES_PORT; do
        for _ in $(seq 1 50); do listening "$port" || break; sleep 0.2; done
    done
    # The tribes server reads the block height once and the mixer's
    # auto-mining raises it, so it starts again after the mixer.
    local before
    before=$(tribes_registrations)
    start_mixer "$mode"
    start_tribes
    wait_for_tribes_registration "$before"
    echo "mixer: $mode"
}

cmd_stop() {
    load_env "${1:-}"
    if [ "${2:-}" != --from-watcher ]; then kill_own watch "test-stack.sh watch"; fi
    kill_own mixer sphinx-mixer
    kill_own tribes sphinx-tribes
    kill_own memes test-stack-helpers.py
    kill_own tap test-stack-helpers.py
    kill_own broker sphinx-broker
    local ports="$BROKER_PORT $CONSOLE_PORT $TAP_PORT $TRIBES_PORT $MIXER_PORT $MEMES_PORT" busy=""
    for port in $ports; do
        if listening "$port"; then busy="$busy $port"; fi
    done
    [ -z "$busy" ] || die "ports still in use:$busy"
    echo "stopped; ports free: $ports"
}

cmd_watch() {
    local owner=${2:?watch needs a pid}
    while kill -0 "$owner" 2>/dev/null; do sleep 2; done
    cmd_stop "$1" --from-watcher
    rm -f "$1/watch.pid"
}

case "${1:-}" in
    start) shift; cmd_start "$@" ;;
    mixer) shift; cmd_mixer "$@" ;;
    stop) shift; cmd_stop "$@" ;;
    watch) shift; cmd_watch "$@" ;;
    *) sed -n '2,26p' "$0"; exit 2 ;;
esac
