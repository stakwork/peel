# Peel Home

Where your agent lives, strut and its bridge, on an always-on box, so it
answers while your Mac sleeps. Peel moves it from the Mac to the box once,
by copying its stopped folders, and can move it back the same way. The plan
is [../docs/always-on.md](../docs/always-on.md).

The box needs only outbound internet. strut and the bridge listen on
127.0.0.1 inside their own network, and your devices reach the agent over
Sphinx as they do today. The one port on your home network is the setup
service's. It answers while the box is empty, waiting for a move, and
during a send-back; while Peel Home runs on the box, nothing listens on it.

This replaces the Tailscale bundle in [../brain/](../brain/), which goes
away once Peel moves to this one (A7).

## Boxes

| Box | Before `docker compose up` |
|---|---|
| Raspberry Pi 4 or 5, 4 GB+ | 64-bit Raspberry Pi OS and Docker. Keep this folder on an SSD, not the SD card |
| PC or NAS (amd64 or arm64) | Docker with Compose v2 |
| VPS | As a PC, with `HOME_SETUP_BIND=127.0.0.1` in `.env`, and the setup page reached through an SSH tunnel: otherwise anyone on the internet sees its code and can move in first |
| Old Mac | OrbStack or Docker Desktop. Turn on automatic login, prevent sleep, and start up after a power failure |

## Setup

1. Copy this folder to the box and run `docker compose up -d`.
2. On the Mac, open `http://<the box's address>:8090`. The page shows a
   pairing link and a QR code. Click the link; Peel moves its strut and
   bridge to the box, and your agent is offline for about a minute.

## Running it

| | |
|---|---|
| Logs | `docker compose logs -f` |
| Send Peel Home back to the Mac | `docker compose exec setup sh /setup.sh send-back <the box's address>[:<port>]` (or set `HOME_SETUP_HOST` and leave the address out). It prints the link; the QR code is in `docker compose logs setup` |
| Keep it here after all | `docker compose exec setup sh /setup.sh cancel` (once the link is out, `cancel --force`: if the Mac already fetched Peel Home, it would then run in both places) |
| Update | Copy the new release's folder over this one, then `docker compose pull && docker compose up -d --force-recreate`. Peel and the box must run the same strut ("Images") |
| Stop | `docker compose down` |

Settings go in `.env` beside this file:

| | |
|---|---|
| `HOME_SETUP_HOST` | This box's address as the Mac reaches it, with `:<port>` if `HOME_SETUP_PORT` isn't 8090. The send-back link names it. The receive page uses the address it was opened at |
| `HOME_SETUP_PORT` | The setup page's port, default 8090 |
| `HOME_SETUP_BIND` | The address the setup port listens on, default all of them |
| `STRUT_IMAGE`, `BRIDGE_IMAGE` | Other images to run |

The Compose project is always `peel-home`, so one Docker host runs one
Peel Home. A second copy on the same host (to test, say) needs its own
project name, given as `docker compose -p <name> …` or `COMPOSE_PROJECT_NAME`,
and its own `HOME_SETUP_PORT`. Without them, its `up` replaces the first
copy's containers.

To back it up, stop it first (`docker compose stop`) and copy `data/`: the
graph files are only consistent while nothing writes to them.

### When something is stuck

- **A send-back was cut short** (a reboot, or `docker compose down`, while
  the Mac was fetching): strut and the bridge stay stopped, because the Mac
  may have Peel Home already. Run `send-back` again, or `cancel --force` if
  the Mac doesn't have it.
- **A move in was cut short**: `docker compose logs setup` says so. Stop
  it, move `data/strut/workspace` aside, start it again, and send the move
  again from the Mac.

## How it fits together

| Service | What it does |
|---|---|
| `setup` | strut's own image, running `strut move serve` through `setup.sh`. On an empty box it takes one move from the Mac; when asked, it sends Peel Home back. It makes this box's own values. Needs no Docker socket |
| `strut` | strut, as Peel's bundled strut runs it: Ladybug workspace and memory under `/data/strut/workspace`, on 127.0.0.1:3000 |
| `bridge` | The bridge (sphinx `runner`), in strut's network, on 127.0.0.1:8000, its store in `/data/bridge/store` |

strut and the bridge run through `gate.sh`, which starts each program only
while Peel Home is on the box (its moved values and `host.env` in
`/data/env/<program>/`). Compose's `depends_on` couldn't do this:
`service_completed_successfully` would hold `docker compose up -d` until the
upload, and Docker ignores `depends_on` when it starts containers after a
reboot.

- **Values.** The gate runs the program with the keys it takes and no
  others, so a move can't set `PATH`, `NODE_OPTIONS` or `LD_PRELOAD`. The
  moved files come from whoever sent the move, so the gate reads them
  without running them: a line that isn't exactly `KEY='value'` refuses the
  whole file.
- **Stopping.** When setup asks for Peel Home back (`/data/gate/stop`), the
  gate stops the program and everything it started. It then removes its
  heartbeat (`/data/gate/<program>.running`), which it touches every 10 s
  while the program runs and while it waits for it to stop. Setup reads a
  missing heartbeat as stopped, and one older than 30 s as a container that
  is down.
- **The bridge waits for strut.** Its first turn needs strut, and it doesn't
  retry. So it starts only once strut answers `/health`, which strut's gate
  marks with a new value in `/data/gate/strut.ready` at each start. When
  that value changes, strut has started again: the bridge's container exits,
  and Docker starts it again inside strut's network.
- **Restarts.** The gate starts a program that ends by itself again inside
  its container, rather than letting the container restart, because the
  bridge shares strut's network.

Each program's container mounts only its own folders, so the bridge never
sees strut's secret key or workspace, and strut never sees the agent's seed.
Only `setup` mounts all of `data/`.

`setup.sh` is a loop around `strut move serve`. With no Peel Home here, it
clears strut's cache (nothing a previous occupant left is loaded), writes
each program's `host.env`, and serves a receive. With Peel Home here, it
holds no port and waits for `setup.sh send-back`. It then stops strut and
the bridge through the gate and runs `serve --send-back`. This lasts until
the Mac confirms (the box is empty again), `setup.sh cancel`, or a failure,
after which strut and the bridge start again.

The scripts are mounted from this folder: after changing one, recreate the
containers (`docker compose up -d --force-recreate`).

### `data/`

| Path | What |
|---|---|
| `strut/workspace/`, `strut/host-config.json` | strut's folder, moved from the Mac |
| `bridge/store/db.redb` | The bridge's store: the agent's seed and inbox, moved from the Mac. It is strut move's `bridge` sidecar, a level below the mount, because a move puts it in place by renaming, which a bind mount of the folder itself wouldn't see |
| `env/strut/home.env` | strut's moved values (`STRUT_SECRET_KEY`), written by `strut move` once the folders are in place. Its presence means "Peel Home is on this box" |
| `env/bridge/bridge.env` | The bridge's moved values: `BROKER_URL`, `BRIDGE_DEVICE`, `RUNNER_ALIAS`, `BRIDGE_WORKFLOW`, `BRIDGE_ACTOR` |
| `env/<program>/host.env` | This box's own, never moved, new for each move in. strut's: `STRUT_API_KEY`. The bridge's: `RUNNER_ADMIN_TOKEN`, `BRIDGE_TOKEN`, `BRIDGE_STRUT_KEY`. The fixed ports and URLs are in the compose file |
| `cache/` | strut's models and cache, rebuilt, and cleared before each move in |
| `.move/` | `strut move`'s state: the receive code, a packed send-back |
| `gate/` | The gate's stop request, each program's heartbeat, and strut's ready mark |
| `setup/` | `setup.sh`'s send-back request, and `events`, the JSON lines the current `strut move serve` printed (emptied at each start) |
| `sent/sent-<time>/` | What was sent back to the Mac, kept in case it is needed. Only `setup` can see it: it holds the agent's seed and strut's key |

## How Peel Home uses `strut move`

The move is strut's: the format, the crypto, the pairing code, the HTTP
routes, and the rewrite strut does on its first boot on a moved folder. They
are specified in strut's AGENTS.md, "Moving strut to another host" and
"Moving a data folder" (`src/move/`, `src/moved.ts`), with the test vector
in `src/move/move.test.ts`. Peel runs the same commands on its side
(`node desktop.js move …`). What Peel Home adds is which folders and values
each side names.

**On the box** (`setup.sh`):

```sh
STRUT_MOVE_LINK=peel://home-setup STRUT_MOVE_HOST=<the box's address> \
STRUT_MOVE_BRIDGE_TOKEN=<the bridge's BRIDGE_TOKEN> [STRUT_SECRET_KEY=<on a send-back>] \
node build/move/cli.js serve [--send-back] \
  --data /data/strut/workspace --host-config /data/strut/host-config.json \
  --sidecar bridge=/data/bridge/store --env /data/env/strut/home.env \
  --sidecar-env bridge=/data/env/bridge/bridge.env \
  --state /data/.move --name "Peel Home" \
  --bridge http://127.0.0.1:8000 \
  --set-secret 'PEEL_BRIDGE_PORT={bridge.port}' --set-secret 'PEEL_BRIDGE_TOKEN={bridge.token}'
```

On arrival, strut's `moved.json` points the Mac's bridge callbacks at this
box's bridge, moves upload paths onto `/data/strut/workspace`, and sets the
two secrets Peel's device steps read (`Orchestrator.useBridge`). strut
applies it at its next boot.

**Moving out, from the Mac (A4)**, with its strut and bridge stopped:

```sh
STRUT_MOVE_BRIDGE_TOKEN=<the stopped bridge's token> \
node desktop.js move send 'peel://home-setup?host=…&code=…' \
  --data ~/Library/Application\ Support/Peel/Strut/workspace \
  --host-config ~/Library/Application\ Support/Peel/Strut/host-config.json \
  --sidecar bridge=~/Library/Application\ Support/Peel/Bridge \
  --env <a file> --bridge http://127.0.0.1:<the stopped bridge's port>
```

The `--env` file holds `STRUT_SECRET_KEY=…` and the bridge's portable
values as `bridge.BROKER_URL=…`, `bridge.BRIDGE_DEVICE=…`,
`bridge.RUNNER_ALIAS=…`, `bridge.BRIDGE_WORKFLOW=…` and
`bridge.BRIDGE_ACTOR=…` (`BundledBridge.environment`). The box takes exactly
one sidecar, `bridge`, and refuses a move with other sidecars. A
development profile names its own `strut/` and `bridge/` folders instead.

**Moving back (A4b)**: `fetch` with the link `setup.sh send-back` printed,
naming the same Mac folders (`--env` for strut's values and
`--sidecar-env bridge=<file>` for the bridge's). Give it
`--bridge http://127.0.0.1:<port>` with `STRUT_MOVE_BRIDGE_TOKEN`, and the
same two `--set-secret`s, for the bridge Peel will start; or leave them out
and repoint once the bridge is up, as Peel does at every bridge start.
`fetch` puts Peel Home in place before it confirms: if the confirmation
fails, the Mac has it, and the box must not be cancelled back into running.

**Not carried**: Peel's `Strut/connections.json` (the MCP grants it writes
`host-config.json` from) is beside the workspace, not in it, so it isn't
part of the move. The box needs only `host-config.json`. On a move back,
Peel keeps its own copy in `Strut.moved-<date>`.

### Who can do what

Anyone who can reach the setup port while the box is empty can open its page
and send a move first; Peel would then get a 409. That person's strut
would run on the box, but sees nothing of an earlier Peel Home: the sent-back
copy is out of strut's reach and the cache is cleared. Sending Peel Home
back reveals it, so its code is never on the page. It is printed by
`setup.sh send-back`, which needs a shell on the box. Without the code, a
download is useless, and the box refuses the "received" confirmation.

## Images

The compose file pins strut (by tag and digest) and the runner (by tag only,
for now) to the commits Peel ships in `Vendor/strut.lock` and
`Vendor/runner.lock`; they change together. Both ends of a move must run the same strut
commit and Ladybug core (`strut move check`), so a Peel release that moves
its strut pin moves these with it.

`ghcr.io/stakwork/sphinx-runner` must be a public package for a box to pull
it without logging in to ghcr; its digest goes in beside the tag once it is.
