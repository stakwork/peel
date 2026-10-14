# Peel Brain: remote strut and the home server

Last updated 2026-10-14. **A proposal for Tom's review; nothing is built.**
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
  publishes no image of its own yet (only `strut-browser`).
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
   existing `Dockerfile` (copy `publish-browser.yml`).
2. Swarm gains a `Strut` image and a `PEEL_BRAIN=true` preset: one node, a
   `/data` volume, `STRUT_WORKSPACE_BACKEND=fs`, `STRUT_API_KEY` and
   `STRUT_SECRET_KEY` made at stack creation.
3. Later, `neo4j` and `bifrost` nodes are added to the preset and linked.

With a `HOST` that has no `.`, Swarm runs without Traefik, so the Route53
and S3 wiring is not needed at home.

## Relation to the iPhone plan

[phases/07-iphone.md](phases/07-iphone.md) makes the phone a remote by
sending Sphinx messages to the agent's own identity. This plan is the other
half: memory and jobs over a direct strut connection. They fit together:
Sphinx messages carry chat with the agent and queue while the brain is
down; the strut connection carries memory, jobs, run results and the
graph. The agent's own Sphinx identity on the server needs Peel's engine
there, which is later (below).

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

1. **Peel: the Brain setting.** `MemoryServer` accepts remote https and
   Tailscale addresses; the bundled strut is not started in home-server
   mode; a connection and version check. Memory and jobs then work against
   a home server.
2. **strut: `memory/export` and `memory/import`** (memory-backup.md). Backup
   and "Move memory to home server" from the same steps.
3. **Peel and strut: automations by pull.** Waiting runs that Peel claims,
   instead of strut calling `AutomationServer`.
4. **iPhone: pairing** by QR code, remote only.
5. **Packaging** (beside 1–4): strut's image, then the Swarm preset.

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
