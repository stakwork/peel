# Peel Brain

Your own strut and memory graph on an always-on box, so Peel on your Mac
and phone can use them while the Mac sleeps. The plan is in
[../docs/peel-brain.md](../docs/peel-brain.md).

It runs strut (jobs, schedules, memory as a Ladybug file) behind Tailscale:
reachable from your devices at home or away, with no port opened on your
router. It needs to be online: strut calls hosted models, and on its first
start fetches Ladybug's vector and fts extensions, without which it won't
start (kept in `data/ladybug/`).

Its workspace is on Ladybug, as Peel's bundled strut's is: workflows, steps
and automations in `data/workspace/graph/graph.lbug`, run records still as
files. A brain set up before that moves over by itself on its first start
after an update: strut imports the file workspace into the graph and moves
the files to `data/workspace/fs-workspace.imported-<time>/`.

## Boxes

| Box | Before `setup.sh` |
|---|---|
| Old Mac (Intel or Apple Silicon) | Install OrbStack or Docker Desktop. Turn on automatic login, prevent sleep, and start up after a power failure |
| Raspberry Pi 4 or 5, 4 GB+ | 64-bit Raspberry Pi OS and Docker. Keep this folder on an SSD, not the SD card |
| PC or NAS | Docker with Compose v2 |

## Setup

1. In the Tailscale admin console, turn on MagicDNS and HTTPS certificates
   (DNS settings), and make an auth key (Settings › Keys; not reusable, not
   ephemeral).
2. Copy this folder to the box and run `./setup.sh`. It asks for the
   Tailscale auth key and an Anthropic key (optional), makes strut's keys,
   starts everything and prints a pairing link.
3. Open the link on the Mac, or scan it on the phone.
4. In the admin console's Machines list, turn off key expiry for
   `peel-brain`, or it drops off the tailnet when its key expires.

The bundle runs `ghcr.io/stakwork/strut:latest`, built for amd64 and arm64
from strut's `main`. To pin a version, or to run a strut you built
yourself, set `STRUT_IMAGE` in `.env`:

```sh
# a pinned version
echo STRUT_IMAGE=ghcr.io/stakwork/strut:<short-sha> >> .env
# or your own build
docker build -t strut:local /path/to/strut
echo STRUT_IMAGE=strut:local >> .env
```

## Running it

| | |
|---|---|
| Pairing link again | `./setup.sh` |
| Update | `docker compose pull --ignore-pull-failures && ./setup.sh` |
| Logs | `docker compose logs -f strut` |
| Stop | `docker compose down` |
| strut's UI | `https://peel-brain.<tailnet>.ts.net`, with the key from `.env` |

Back up `data/` and `.env`, with strut stopped: the graph files are only
consistent while nothing writes to them. `.env` holds strut's keys: without
`STRUT_SECRET_KEY` the secrets in `data/` cannot be read.
