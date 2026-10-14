# Peel Brain: remote strut and the home server

Last updated 2026-10-14. **A proposal for Tom's review; build order step 1
is built.**
It follows [agent-brain.md](agent-brain.md) (strut owns the graph; phase 6
"move strut to a Mac mini or the cloud"), [memory-backup.md](memory-backup.md)
("Home server") and [phases/12-automations.md](phases/12-automations.md)
("Mac now / Home server later"). Research read on 2026-10-14 from Peel's
`main`, `~/Documents/strut` (`origin/main`), `~/Documents/sphinx-swarm`
(`master`, dd0f132d) and `~/Documents/stakgraph`.

## Goal

Without a home server, everything runs on the Mac, as today: Peel starts its
bundled strut and the graph lives there. The phone needs the Mac on.

With a home server, the Mac's bundled strut is not used. Peel on the Mac and
the phone call **your own strut** on an always-on box, and the graph lives
there. Connecting one should be a setting, not a migration project.

Not goals for v1:

- Running Peel's Sphinx engine on the server. Sphinx messaging stays on the
  devices; the server is the backend only (strut and the graph).
- Bifrost and Mothership. Model calls go direct with a key in strut's
  secret store. Both can be added to the brain later without the devices
  changing.
- Two graphs kept in sync. See "Move, not sync".

## The rule

**Peel talks to one strut, by URL and key. The brain is wherever that strut
runs, and an account has exactly one.**

```
 No home server                       Home server
 ┌──────────────┐  ┌────────┐         ┌──────────────┐  ┌────────┐
 │ Peel on Mac  │  │ iPhone │         │ Peel on Mac  │  │ iPhone │
 │ bundled strut│◄─┤        │         │ (no strut)   │  │        │
 │ graph.lbug   │  └────────┘         └──────┬───────┘  └───┬────┘
 └──────────────┘                            │ VPN, https    │
                                             ▼               ▼
                                     ┌─────────────────────────────┐
                                     │ Peel Brain (any box, Docker)│
                                     │ strut · graph.lbug          │
                                     │ (neo4j) (bifrost) later     │
                                     └─────────────────────────────┘
```

## What exists today

- **One seam already.** Every strut caller (`MemoryTools`, `AutomationsClient`,
  `AgentSetup`) takes a `MemoryServer`: a base URL and strut's key
  (`Sources/PeelAgent/MemoryServer.swift`). The only source of one is
  `BundledStrut.start()`, which launches strut on `127.0.0.1`, port 0, with
  a key made per launch (`BundledStrut.swift`, `environment`).
- **`MemoryServer.init` accepts only plain http to this Mac.** That is the one
  gate a remote strut has to pass.
- **strut calls Peel.** When an automation fires, strut's `peel-automation`
  workflow calls Peel's `AutomationServer` on loopback, using
  `PEEL_AUTOMATION_PORT` and `PEEL_AUTOMATION_TOKEN` from strut's secret store
  (`AutomationsClient.swift`). This only works on one machine.
- **strut runs on Linux.** strut's `Dockerfile` and `docker-compose.yml`
  exist; `@ladybugdb/core`, `onnxruntime-node` and `sherpa-onnx-node` have
  linux-x64 and linux-arm64 builds. Ladybug is a file
  (`<data>/memory/graph.lbug`, or `STRUT_MEMORY_DB`), not a service. strut
  publishes `ghcr.io/stakwork/strut` for amd64 and arm64 (strut#168).
- **Peel's engine does not run on Linux.** The `peel` CLI links
  `Vendor/sphinxrsFFI.xcframework` and imports `Security`, `CommonCrypto`,
  `CryptoKit` and `NIOTransportServices` in eight files. Not needed for v1:
  the engine stays on the devices.

## Design

### 1. The Brain setting

Account › Brain:

- **This Mac** (default). Peel starts the bundled strut, as today.
- **Home server.** A URL and key, kept per account like `Profile.strutKey`.
  Peel never starts the bundled strut and builds the `MemoryServer` from them.

`MemoryServer.init` also accepts https, and http to a Tailscale address
(`100.64.0.0/10`, `*.ts.net`). Nothing else in Peel knows which mode it is in.

On connect Peel reads strut's `/health` and checks the version, so a newer
Peel against an older brain says "update your brain" rather than failing
oddly.

### 2. Move, not sync

Ladybug allows one writer. Two graphs that both took writes is the merge
problem memory-backup.md leaves out. So:

- **Connecting a home server is a move.** Peel exports from the bundled
  strut (`memory/export`), imports into the server's empty graph
  (`memory/import`), and stops using the local one. These are the steps
  memory-backup.md already plans for backup; going back to "This Mac" is
  the same move the other way.
- **While a home server is in use, its memory is the truth.** This Mac's
  copy only goes stale, so bringing the memory back replaces it: Peel stops
  its strut, renames `graph.lbug` and its `graph.lbug.*` files into
  `memory/backups/graph-<time>.lbug…` (owner-only, never deleted there; the
  newest three sets are kept), starts strut on an empty graph and imports
  the home server's, checked as any move. Any failure puts this Mac's files
  back and stays on the home server; only success switches to "This Mac"
  (`MemoryMove.replacingThisMac`, `MemoryBackup`). A home server whose
  memory holds nothing is not exported over this Mac's: Peel just switches.
- **Reconnecting.** Memory follows you: whatever was in use last is the
  truth. Reconnecting after switching back, the home server holds an old
  copy and this Mac the newer one, so on connect this Mac's replaces the
  home server's: Peel sends it with `memory/import`'s `replace` (strut#176),
  and strut there writes its graph to `memory/backups/memory-<time>.tar.gz`
  first (the newest three kept), then loads this Mac's; a backup that
  fails (`backup_failed`) leaves its graph untouched. Account › Brain says
  "Its older copy is saved as a backup there." This Mac's memory empty,
  nothing is sent and the home server's is used as it is. A home server
  whose strut predates `replace` refuses with `not_empty`: still
  connected, and asked to update strut.
- **The bundled strut is never a fallback.** If the home server is
  unreachable, memory and jobs say the brain is offline; chat still works.
  A Mac writing its own graph while the server is down is the split this
  avoids.
- A read-only copy on the devices (Tom T's sync log) can come later. It
  reads the one graph and never writes.

### 3. Peel calls strut; strut never calls Peel

Reverse the automation callback so one path serves both modes:

- **Work without Sphinx** (research, summaries, janitors, reminders from the
  graph) runs entirely in strut's own workflows.
- **Work that reads Sphinx chats** becomes a run waiting for Peel. Whichever
  Peel is connected asks strut for waiting runs, does them and posts the
  result back.

On "This Mac" this behaves as today. With a home server it works whenever a
device is awake and never needs strut to reach a sleeping laptop behind NAT.
Keeping the loopback callback for local mode would mean two paths.

### 4. Keys live on the brain

- Model keys (Anthropic now; Bifrost or Mothership virtual keys later) are
  in the brain strut's secret store, never on the devices.
- Peel holds one strut key per account.
- The iPhone is always remote. It pairs by scanning a QR code on the Mac
  holding the URL and key.

### 5. Transport

Tailscale (or WireGuard on the router) gives https and device identity, for
example `tailscale serve` in front of strut; strut's `STRUT_API_KEY` is the
second lock. Nothing custom.

A server strut must set `STRUT_API_KEY` (unset, every route is open) and a
stable `STRUT_SECRET_KEY` (unset, the secret store falls back to a fixed dev
key). Only one strut may run per data folder: its scheduler is in-process.

## Where the brain runs

| Host | How | Notes |
|---|---|---|
| This Mac | Bundled strut, as today | The default |
| An old Mac or a Mac mini | strut's desktop tarball (`strut-darwin-arm64`) under a launchd agent, or Docker/OrbStack | Needs Node 22.18+. Apple Silicon is tested; the x64 tarball is only cross-staged. Auto-login, no sleep, restart after power failure |
| Any Linux box (old PC, NAS) | strut's `docker-compose.yml` with `STRUT_WORKSPACE_BACKEND=fs`, no Neo4j | Smoke-test that Ladybug loads in the image (it installs with `--ignore-scripts`) |
| Sphinx Swarm | A `PEEL_BRAIN` preset with one strut node (below) | Later; makes Neo4j and Bifrost a toggle |

### Sphinx Swarm

Swarm's second-brain stack (`src/secondbrain.rs`) already runs strut,
Neo4j, Bifrost (`ghcr.io/stakwork/stakgraph-gateway`, with budget and
macaroon enforcement) and Mothership billing (`STRUT_MOTHERSHIP_REQUIRED`).
But its strut is `repo2graph`, the `stakgraph-mcp` image: stakgraph's lab
with strut pinned inside (at #159, `feat/desktop-ladybug`, so Ladybug memory
is there). It refuses to start without Neo4j (`src/images/repo2graph.rs:72`),
is pulled as amd64 only (`src/dock.rs:116`), and brings Jarvis, Hermes and a
Playwright browser.

Stacks are presets chosen by env var (`src/defaults.rs`); after first boot
`config.yaml` is the source of truth. For Peel Brain:

1. strut publishes `ghcr.io/stakwork/strut` for amd64 and arm64 from its
   `Dockerfile` (strut#168).
2. Swarm gains a `Strut` image and a `PEEL_BRAIN=true` preset: one node, a
   `/data` volume, `STRUT_WORKSPACE_BACKEND=fs`, `STRUT_API_KEY` and
   `STRUT_SECRET_KEY` made at stack creation.
3. Later, `neo4j` and `bifrost` nodes are added to the preset and linked.

With a `HOST` that has no `.`, Swarm runs without Traefik, so the Route53
and S3 wiring is not needed at home.

## Packaging: the Peel Brain bundle

One Docker Compose bundle, the same on every box: an old Intel or Apple
Silicon Mac, a Raspberry Pi, an old PC or a NAS. It is always on and always
online: strut calls hosted models, and fetches MiniLM and Ladybug's search
extensions on first use.

```
brain/
├── docker-compose.yml   strut + a Tailscale container
├── serve.json           tailscale serve: https :443 → strut :3000
├── .env                 written by setup.sh
└── setup.sh             makes the keys, starts it, prints a pairing link
```

```yaml
services:
  tailscale:
    image: tailscale/tailscale
    hostname: peel-brain                # https://peel-brain.<tailnet>.ts.net
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_SERVE_CONFIG: /config/serve.json
      TS_STATE_DIR: /var/lib/tailscale
    volumes: [ts-state:/var/lib/tailscale, ./serve.json:/config/serve.json]

  strut:
    image: ghcr.io/stakwork/strut:latest   # multi-arch, from strut's CI
    network_mode: service:tailscale        # no port open on the home network
    restart: unless-stopped
    environment:
      STRUT_WORKSPACE_BACKEND: fs
      STRUT_API_KEY: ${STRUT_API_KEY}
      STRUT_SECRET_KEY: ${STRUT_SECRET_KEY}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
    volumes: [./data:/data]                # workspace, memory/graph.lbug, models

volumes: { ts-state: {} }
```

`setup.sh` generates `STRUT_API_KEY` and `STRUT_SECRET_KEY`, asks for the
model key and a Tailscale auth key, runs `docker compose up -d`, waits for
`/health`, and prints a link and QR code,
`peel://brain?url=https://peel-brain….ts.net&key=…`. Opening it on the Mac
or scanning it on the phone fills in the Brain setting. Everything worth
keeping is in `./data`. Updates are `docker compose pull && docker compose up -d`.

| Box | Install | Notes |
|---|---|---|
| Old Mac (Intel or Apple Silicon) | OrbStack or Docker Desktop, then `setup.sh` | Auto-login, no sleep, start after power failure |
| Raspberry Pi 4 or 5, 4 GB+ | 64-bit Raspberry Pi OS, Docker, then `setup.sh` | `./data` on an SSD, not the SD card: the graph writes constantly. No Neo4j on a Pi |
| Old PC or NAS | Docker, then `setup.sh` | |

The image is strut's existing `Dockerfile`, about 2 GB with ffmpeg, pandoc,
tesseract and a Python venv for workflows. A slimmer brain image can come
later. First check: that Ladybug and MiniLM load in the arm64 image, which
installs with `--ignore-scripts`.

### Ways to install

1. **`setup.sh` on any Docker host.** First, and what the rest build on.
2. **Umbrel.** An Umbrel app is a folder with an `umbrel-app.yml` manifest
   and a `docker-compose.yml` that uses Umbrel's `app_proxy` and
   `${APP_DATA_DIR}`. The strut service is the same; the Tailscale
   container goes, because Umbrel has its own Tailscale app, and the keys
   come from the app's settings instead of `setup.sh`. Start in a community
   app store (a GitHub repo); the official store wants multi-arch images
   pinned by digest. Check the details against Umbrel's app framework docs
   when this starts.
3. **A Raspberry Pi SD card image.** Raspberry Pi OS with Docker and the
   bundle preinstalled, and a first-boot step that runs `setup.sh` and shows
   the pairing link (on a screen, or a local web page). Last: it is the
   most to maintain.

### First install, 2026-10-14: what it took

The first real run, the brain on Tom's Mac in Docker, reached by Peel over
Tailscale, took these manual steps:

1. Create a Tailscale account; install Tailscale on the Mac and log in (a
   macOS VPN prompt, and a login that did not finish the first time).
2. In the admin console: MagicDNS (already on) and HTTPS certificates.
3. Build the strut image locally (no published image yet).
4. Run `setup.sh`; approve the box with a login link. **Bug:** Tailscale's
   container waits about a minute for that login, then restarts with a new
   link, so approving it rarely works.
5. Make an auth key in the admin console and paste it into `.env` with a
   shell command.
6. **Bug:** recreating only the Tailscale container left strut on the old
   one's network: `https://peel-brain…/health` answered 502 until strut was
   recreated too.

Both bugs are fixed in `brain/` (an auth key is required; `setup.sh`
recreates both containers). The rest is the work below.

### Where the install should get to

What telling someone (Gonza) to set it up should look like:

| Step | Today | Target |
|---|---|---|
| Network | Tailscale account and app on each device; turn on HTTPS; make an auth key | Same account and apps; the box's setup page logs in with a "Connect Tailscale" button, no key to copy |
| Install the brain | Install Docker, copy `brain/`, run `./setup.sh` | One command, `curl -fsSL <url>/install.sh \| sh`, or an Umbrel app, or a flashed SD card |
| Connect Peel | Open the printed `peel://brain` link, or type the address and key | Scan a QR code from the box's setup page; Peel shows Connected |
| Memory | Starts empty | "Move memory to home server" in Peel (build step 3) |

The pieces, in order:

1. **`install.sh`** hosted in this repo: checks for Docker, downloads
   `brain/`, runs `setup.sh`. Removes "copy the folder".
2. **A setup page on the box** instead of terminal prompts, served on the
   home network only during setup: a Tailscale login button (the box waits
   as long as needed, which avoids the auth-key step), an optional model
   key, then the pairing QR code. The same page serves Umbrel and the SD
   card image.
3. **Peel's Brain section explains setup**: what to install, the one
   command, and "scan the code" — so nobody needs this doc.
4. **Umbrel app**, then **SD card image**, both opening the setup page.

Tailscale itself stays a one-time step per person: an account, and the
app on the Mac and phone. In v2, with the agent as a contact, chat no longer
needs it.

## Relation to the iPhone plan

[phases/07-iphone.md](phases/07-iphone.md) makes the phone a remote by
sending Sphinx messages to the agent's own identity. This plan is the other
half: memory and jobs over a direct strut connection. They fit together:
Sphinx messages carry chat with the agent and queue while the brain is
down; the strut connection carries memory, jobs, run results and the
graph. The agent's own Sphinx identity on the server needs Peel's engine
there, which is later (below).

Tom, 2026-10-14: the agent as a contact "makes a lot of sense". So the
agent's chat goes over Sphinx to its own identity, and the direct strut
connection is for everything else.

## Later

- **Peel's engine on the server.** So the agent can be messaged and reply
  while every device is closed. On a Mac it runs today; on Linux it needs a
  port: `swift-crypto` for `CryptoKit` and `CommonCrypto`, a file secret
  store for the Keychain, `NIOPosix` for `Network` and
  `NIOTransportServices`, media helpers left out, and `sphinx-ffi` built as
  a Linux shared library. Swarm's `bot` image is a headless Sphinx client
  that may be worth reading first.
- **Bifrost and Mothership** in the brain, for per-agent keys and budgets.
- **Neo4j** beside the Ladybug memory, for stakgraph and Jarvis.
- **Remaining layers in Tom's draft diagram**: a local model, PII
  conversion before hosted models, a Lightning node holding no keys,
  BitTorrent backups, and a separate signing device.

## Build order

Moving memory alone (steps 2–3 below) is superseded by moving the whole
brain: [brain-handover.md](brain-handover.md).


1. **Peel: the Brain setting.** `MemoryServer` accepts remote https and
   Tailscale addresses; the bundled strut is not started in home-server
   mode; a connection and version check. Memory and jobs then work against
   a home server.
   *Built 2026-10-14 (Mac):* Account › Brain, This Mac or Home server
   (address and key in the Keychain, `Profile.brain`); `peel://brain`
   pairing links, confirmed in place; `MemoryServer` takes https anywhere
   and http to `100.64.0.0/10` or `*.ts.net`. With a home server the
   bundled strut is never started, the memory tools say "the brain is
   offline" or that the key was refused, and Peel neither listens for
   automations nor puts its token, port or model key in that strut (a
   disconnect would take the brain's own key out); the agent has no
   automation tools there and Automations says so. strut's `/health`
   answers `{ok: true}` to any key and names no version, so a refused key
   is read from the reply lacking `stepCount`, and the version check
   waits for strut to add one. Nothing is moved: the local graph stays.
2. **strut: `memory/export` and `memory/import`** (memory-backup.md). Backup
   and "Move memory to home server" from the same steps.
   *Peel's side built 2026-10-14 (Mac):* no switches; the memory follows
   the switch. Connecting a home server from This Mac copies this Mac's
   memory there unless it is empty: Peel's own strut is started for it and
   stopped after, the export read from its folder and deleted, the rows
   counted on both; memory already there is replaced, kept as a backup
   there ("Reconnecting"). Switching back to This
   Mac always brings the home server's memory back in place of this Mac's
   (inline export there, import here; this Mac's kept as a backup), or just
   switches when the home server's holds nothing. The form (2026-10-14, for
   people who never saw a terminal): "Connect a home server", one field
   for the pairing link (dots, its host shown under it once it parses), and
   "Enter address and key instead" for typing them. Neither side's memory is deleted; the memory tools wait
   while a move runs, and a move waits for a reply in progress.
3. **Peel and strut: automations by pull.** Waiting runs that Peel claims,
   instead of strut calling `AutomationServer`.
4. **iPhone: pairing** by QR code, remote only.
5. **Packaging** (beside 1–4): strut publishes a multi-arch image with an
   arm64 memory smoke test; Peel's `brain/` bundle and `setup.sh`; then
   `install.sh`, the setup page, Umbrel, the SD card image and the Swarm
   preset ("Where the install should get to").

## Open questions

1. Does the graph stay Ladybug on the server, or does strut's own graph go
   to Neo4j beside stakgraph and Jarvis (Evan, 2026-10-13)? Memory stays its
   own Ladybug file either way.
2. Tailscale, WireGuard on the router, or both? memory-backup.md left remote
   access "to define with Tom".
3. Should a device read memory while the brain is offline (a read-only
   copy), or is "brain offline" enough for v1?
4. Which strut endpoint does Peel poll for waiting runs, and does strut
   need a new run state for "waiting for a client"?
