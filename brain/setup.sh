#!/bin/sh
# Starts Peel Brain and prints the link that pairs Peel with it
# (docs/peel-brain.md, "Packaging").
#
#   ./setup.sh     first run: asks for the optional keys, makes strut's keys and
#                  writes .env (owner-only); every run: starts the containers,
#                  waits for Tailscale and strut, and prints the pairing link.
#
# Run it again any time to see the link. Needs Docker with Compose v2.
set -eu
cd "$(dirname "$0")"

fail() { echo "setup.sh: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is needed (docker compose)"
docker info >/dev/null 2>&1 || fail "Docker is not running"

random_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

# Reads a line without echoing it, for keys.
ask_secret() {
    printf '%s' "$1" >&2
    trap 'stty echo 2>/dev/null; exit 130' INT TERM
    stty -echo 2>/dev/null || true
    IFS= read -r answer || answer=""
    stty echo 2>/dev/null || true
    trap - INT TERM
    echo >&2
    printf '%s' "$answer"
}

# First run is "no strut keys yet", not "no .env": the README's
# STRUT_IMAGE=strut:local line may already be in it.
if ! grep -q '^STRUT_API_KEY=' .env 2>/dev/null; then
    echo "First run: writing .env"
    anthropic=$(ask_secret "Anthropic API key (Enter to add it later in strut's Secrets): ")
    # Required: without one, Tailscale's container waits about a minute for a
    # browser login, then restarts with a new link, so the link rarely works.
    tsauth=$(ask_secret "Tailscale auth key (Settings › Keys in the admin console): ")
    [ -n "$tsauth" ] || fail "a Tailscale auth key is needed"
    touch .env
    chmod 600 .env
    cat >> .env <<EOF
STRUT_API_KEY=$(random_key)
STRUT_SECRET_KEY=$(random_key)
ANTHROPIC_API_KEY=$anthropic
TS_AUTHKEY=$tsauth
EOF
fi
mkdir -p data

# strut lives in the Tailscale container's network; recreate both together so
# strut never keeps the network of a Tailscale container that was replaced.
docker compose up -d --force-recreate

# A string field of this machine's `tailscale status --json` (no peers).
ts_field() {
    docker compose exec -T tailscale tailscale status --json --peers=false 2>/dev/null \
        | sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1
}

echo "Waiting for Tailscale…"
i=0
while [ "$(ts_field BackendState)" != "Running" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "Tailscale did not connect; see: docker compose logs tailscale"
    sleep 2
done

echo "Waiting for strut (the first start downloads its models)…"
i=0
until docker compose exec -T strut wget -qO- http://127.0.0.1:3000/health >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 150 ] || fail "strut did not start; see: docker compose logs strut"
    sleep 2
done

host=$(ts_field DNSName)
host=${host%.}
[ -n "$host" ] || fail "no Tailscale name for this box"
key=$(sed -n 's/^STRUT_API_KEY=//p' .env)
link="peel://brain?url=https%3A%2F%2F$host&key=$key"

cat <<EOF

Peel Brain is running at https://$host
(HTTPS needs MagicDNS and HTTPS certificates on in the tailnet's DNS settings.)

Pair Peel with this link, or enter the address and key in Peel's Brain setting:

  $link

EOF
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 "$link"
else
    echo "(Install qrencode to show this as a QR code for the phone.)"
fi
