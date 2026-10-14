# Peel Brain

Your own strut and memory graph on an always-on box, so Peel on your Mac
and phone can use them while the Mac sleeps. The plan is in
[../docs/peel-brain.md](../docs/peel-brain.md).

It runs strut (jobs, schedules, memory as a Ladybug file) behind Tailscale:
reachable from your devices at home or away, with no port opened on your
router. It needs to be online: strut calls hosted models.

## Boxes

| Box | Before `setup.sh` |
|---|---|
| Old Mac (Intel or Apple Silicon) | Install OrbStack or Docker Desktop. Turn on automatic login, prevent sleep, and start up after a power failure |
| Raspberry Pi 4 or 5, 4 GB+ | 64-bit Raspberry Pi OS and Docker. Keep this folder on an SSD, not the SD card |
| PC or NAS | Docker with Compose v2 |

## Setup

1. In the Tailscale admin console, turn on MagicDNS and HTTPS certificates
   (DNS settings). Optionally make an auth key (Settings › Keys).
2. Copy this folder to the box and run `./setup.sh`. It asks for an
   Anthropic key and a Tailscale auth key (both optional), makes strut's
   keys, starts everything and prints a pairing link.
3. Open the link on the Mac, or scan it on the phone.

Until `ghcr.io/stakwork/strut` is published, build the image from a strut
checkout on the box and point the bundle at it:

```sh
docker build -t strut:local /path/to/strut
echo STRUT_IMAGE=strut:local >> .env
```

## Running it

| | |
|---|---|
| Pairing link again | `./setup.sh` |
| Update | `docker compose pull && docker compose up -d` |
| Logs | `docker compose logs -f strut` |
| Stop | `docker compose down` |
| strut's UI | `https://peel-brain.<tailnet>.ts.net`, with the key from `.env` |

Back up `data/` and `.env`. `.env` holds strut's keys: without
`STRUT_SECRET_KEY` the secrets in `data/` cannot be read.
