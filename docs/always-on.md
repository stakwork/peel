# Always on: Peel Home moves to a server by copying its folders

Last updated 2026-10-26. **A plan for Tom's review.** It replaces step 1
of [phase-2.md](phase-2.md) ("Always on": the bundle, pairing and
handover) with a simpler version. Steps 2 to 4 of phase-2.md (the phone,
backups, hardening) are unchanged and come after it.

## In one paragraph

**Peel Home** is where the agent lives: strut and the bridge (runner).
Today both run on your Mac, inside Peel. To make the agent answer with the
Mac asleep, Peel moves them to an always-on box. It stops its strut and
bridge, and its bundled strut packs their folders and keys and sends them
to the strut on the box. Moving back is the same thing the other way. The
box runs one Docker Compose file (strut and runner) with no ports open and
no Tailscale. It needs only outbound internet, so it runs on a Pi, an old
Mac, a NAS (Synology, Unraid, TrueNAS), Umbrel or CasaOS, or a VPS.
Devices reach the agent over Sphinx, as they do today.

## Naming (Tom, 2026-10-25)

What the docs and code call "the brain" is **Peel Home** in everything
new, always in full, never a bare "Home": Account › Peel Home, set to
This Mac or a home server. New work uses `home`: the `home/` bundle,
`peel://home-setup` links and `home.env`. Existing names (`Profile.brain`,
`peel://brain` links, Account › Brain, the old `brain/` folder, which
`home/` replaces) are renamed in a PR of their own (A7).

## Decided (Tom, 2026-10-25 and 26)

1. **A move by copying stopped folders, in both directions.** No live
   handover: no drain, hold, park, lease, generations, or strut snapshot
   routes. The agent is offline for about a minute while it moves, and the
   Sphinx broker keeps messages meanwhile.
2. **Strut owns the move.** Packing, sending, receiving and the rewrite on
   arrival are one strut feature with a client-agnostic contract, run by
   the same strut code on both ends (below). Peel only stops its own
   processes and calls it.
3. **No Tailscale in the bundle.** Since 2026-10-19 no daily feature needs
   a direct path to strut (foundation.md, decision 4). Tailscale comes back
   later as an add-on for the graph view and live job steps.
4. **One Compose file is the product.** Umbrel and CasaOS are thin wrappers
   around it. No SD card image.

What this gives up, for now: moving Peel Home while away from home,
moving with no downtime, and the Mac and box running different strut
versions.

## Architecture

```
 Clients        Peel on the Mac · later Hive, strut's web UI, a CLI
                stop their own processes, then call strut's move
 ─────────────────────────────────────────────────────────────────
 strut          strut move: pack, send, serve (receive, send back),
                fetch, and the rewrite on arrival (moved.json)
                the same code on the Mac (Peel's bundled strut) and the box
 ─────────────────────────────────────────────────────────────────
 Sidecars       the bridge (runner): a folder strut packs alongside
                and unpacks by name, without reading it
 ─────────────────────────────────────────────────────────────────
 Packaging      Peel Home = strut image + runner image + home/ compose
                → VPS, Pi, NAS, Umbrel, CasaOS
```

- **One implementation.** The move format, the pairing code and the
  encryption exist once, in strut (TypeScript). Peel's bundled strut runs
  it on the Mac, and the box's strut runs it on the box, so both directions
  share it. Peel has no tar or crypto of its own.
- **Client-agnostic.** The contract is documented in strut. Another strut
  client can move its workspace to a box the same way, with or without a
  sidecar.
- **Sidecars stay opaque.** A sidecar is a named folder (plus named env
  values) that strut packs and unpacks, stopped. Strut never reads the
  bridge's store. Whoever runs the sidecar (Peel on the Mac, the Compose
  file on the box) starts and stops it.
- **The box's setup service is strut**: strut's image started as
  `strut move serve`, not a separate program or image.
- **The generic box stays in peel for now.** `home/` lives in this repo as
  Peel Home. It moves to strut as a generic "strut home" when a second
  client needs it.

## Keys

| Key | What it guards | Where it lives |
|---|---|---|
| **Your Sphinx keys** (your 12 words) | You: your chats, your sats, sending as you | **Only on your devices**: the Mac's Keychain, the phone's Secure Enclave or keystore. Never in a move, never on the box |
| **The agent's key** (`agent_seed(seed, n)`, derived from yours) | The agent's own Sphinx account and its small balance | The bridge's store: on the Mac, or on the box after a move |
| **strut's secret key** (`STRUT_SECRET_KEY`) | strut's secret store: model keys, connector tokens | Peel's Keychain on the Mac; `home.env` on the box |
| **The pairing code** | One move | Shown on the box's page; used once |

- **Your keys stay on your clients.** When the agent needs your chats, or
  needs to send as you, it asks your Mac or phone (device requests over
  Sphinx), and you approve there. That is the "sign requests" path of the
  2026-10 draft diagram, with your own devices as the signer. So the
  agent waits when they are asleep ("Waiting for your Mac").
- **The agent's key moves with Peel Home.** The move carries it, encrypted
  end to end with the pairing code (HKDF-SHA256, AES-256-GCM). The box
  never sees the code over the network, and a move without the code is
  useless. Two bridges with the same key must never run at once: it would
  be one Sphinx identity live in two places. That is why the Mac keeps its
  own bridge stopped after a move.
- **At rest on the box**, the agent's key and strut's secret key are only
  as safe as the box's disk. Use full-disk encryption where the box offers
  it (most NAS systems and a Pi with LUKS do). A stolen box exposes the
  agent's account and the model keys, never you. Your words re-derive the
  agent's key, so a lost box never loses the agent's identity.
- **Later**: keep the agent's key off the box too, with the bridge signing
  through a remote signer (as Sphinx's own signer design does), or keep it
  in a TEE where the box has one. Evan, question 4.

## How a move works

**Out (Mac to box).** The box runs `strut move serve` (setup mode) and
shows a pairing link, `peel://home-setup?host=<box>&code=<code>`, and a
QR code. In Account › Peel Home › "Move to a home server", the user opens
the link on the Mac. Then:

1. Peel's bundled strut checks the code with the box (`move check`) and
   that the box's strut version matches its own.
2. Peel stops its strut and its bridge.
3. Peel runs its bundled strut's `move send <link>`, naming the strut
   folder, the bridge as a sidecar, and the portable keys. Strut packs,
   encrypts with the code, and uploads.
4. The box unpacks, writes `moved.json`, and starts strut and the bridge.
   strut applies `moved.json` at boot (A2b).
5. Peel pings the agent in the DM and waits for its answer from the box.
6. Peel marks Peel Home as moved and never starts its own strut or bridge
   again. It keeps its folders as `Strut.moved-<date>` and
   `Bridge.moved-<date>`.

If anything before step 5 fails, Peel restarts its own strut and bridge:
"Nothing changed; Peel Home is still on this Mac." If the box's bridge came
up but its answer was missed, two bridges could be on the broker. The
guard is that Peel keeps its own stopped until the user chooses, and says
so.

**Back (box to Mac).** From a "Send Peel Home back" button on the box's
page, which shows a fresh code, the user opens the send-back link in
Account › Peel Home › "Move back to this Mac". Then:

1. The box stops strut and the bridge, and packs.
2. Peel's bundled strut runs `move fetch <link>` and unpacks into Peel's
   folders, setting the `.moved-<date>` copies aside. It writes
   `moved.json` for the Mac's paths, bridge port and token.
3. Peel starts its strut and bridge, and pings the agent.
4. The box marks itself empty, so its strut and bridge stay off until a
   new setup.

**If the box dies** with no way to copy back, Peel offers "Use this Mac's
copy from <date>". This restores the folders it kept at the move, and
loses what happened on the box since. Sealed backups (phase-2.md step 3)
close that gap later.

After a move out, the Mac acts as phase-2.md's "What the Mac does once the
brain has moved" describes: it answers device requests over Sphinx, and
send grants stay on the Mac.

## Why a file copy works

[brain-handover.md](brain-handover.md) turned down copying `graph.lbug`
for two reasons. Neither holds here:

- *"A stopped strut can't push."* Peel stops strut, then runs strut's move
  command over the stopped folder.
- *"Needs the same Ladybug version on both sides."* The box's image is
  pinned to the strut and runner commits the Peel release ships
  (`scripts/stage-strut.sh`, `Vendor/runner.lock`). A newer Peel moves the
  box's pin with it, and `move check` refuses a mismatch.

**Checked, 2026-10-25.** A graph written by Peel's staged strut (Ladybug
0.21.2, macOS arm64) had a `FLOAT[384]` vector index, an FTS index and a
rel table. It opened as-is in strut's Linux image (linux arm64, with no
network). Node and rel counts, vector results and FTS results matched the
Mac's exactly. **Checked, 2026-10-26:** the same on linux amd64 (the NAS
and PC case), in an amd64 strut container under QEMU with no network.

## What moves

Everything the agent knows moves: the memory graph and the workspace
graph (live Ladybug files), the DM and sessions, runs, workflows,
automations and secrets. Only rebuilt or Mac-only leftovers stay behind
(below).

From the Mac (paths for the app account; a development profile keeps both
inside its own folder):

| What | Where on the Mac | On the box | Part of the move |
|---|---|---|---|
| strut's workspace: the workspace graph, memory graph, runs, sessions, the agent's DM, secrets (encrypted) | `~/Library/Application Support/Peel/Strut/workspace` | `/data/strut/workspace` | strut's own |
| strut's host config (the orchestrator's MCP grants and personal note) | `…/Peel/Strut/host-config.json` | `/data/strut/host-config.json` | strut's own |
| strut's secret key (decrypts the secrets above) | Keychain (`Profile.strutKey`) | `home.env` | strut's own |
| The bridge's store: the agent's seed (set once with `POST /seed`) and its inbox | `…/Peel/Bridge/db` | `/data/bridge/db` | sidecar `bridge` |
| The bridge's identity settings: `BROKER_URL`, `BRIDGE_DEVICE` (still the Mac's id, so device requests still reach the Mac), `RUNNER_ALIAS`, `BRIDGE_WORKFLOW`, `BRIDGE_ACTOR` | `BundledBridge.environment` | `home.env` | sidecar `bridge` env |

Left behind: `…/Peel/Strut/cache`, which can be rebuilt.

### What in strut's folder is tied to the Mac

From the paused H1 branch's survey of a real folder (strut
`handover-parts-workspace-export`, 3aaa725):

- **Encrypted with `STRUT_SECRET_KEY`**: `secrets.json`,
  `actor-secrets.json`, `peers.json`, `automation-callbacks.json` and
  `mothership.json`. The box gets the same key, so these files copy as they
  are.
- **Pointing at the Mac's bridge** (its port and token):
  `automation-callbacks.json`, the run folders' `callback.json`,
  `job-callback.json` and `mcp.json`, `jobs/.callbacks/*.json`, and the
  `PEEL_BRIDGE_PORT` and `PEEL_BRIDGE_TOKEN` secrets. Rewritten at first
  start by `moved.json` (A2b).
- **Absolute Mac paths in content**: chat uploads are rewritten by A2b.
  Job records' `repos` maps and the DM's and runs' history stay as they
  are: Mac checkouts can't run on the box anyway.
- **Ladybug**: copy only when stopped cleanly, `.wal` files included
  (an unclean close rebuilds the FTS index at boot).
- **Dropped, since they are rebuilt or local to the Mac**: `steps/_graph*/`,
  `graph|memory/snapshots/`, `memory/backups/`, `audio/tmp/`, `*.tmp`,
  `*.corrupt-*`, `fs-workspace.imported-*/`, `repos/`, `worktrees/`, job
  working folders, `privacy/vault/`, `acp/sessions/` and
  `audio/dictation.json`.

Made fresh on the box, because they belong to the host: `STRUT_API_KEY`,
`RUNNER_ADMIN_TOKEN`, `BRIDGE_TOKEN`, the ports, `BRIDGE_STRUT_URL` and
`BRIDGE_STRUT_KEY`. The new bridge port and token reach strut's secret
store through `moved.json`.

## The bundle

`home/docker-compose.yml`, a new folder beside the old `brain/`:

- **`setup`**: strut's image, run as `strut move serve`. It is the only
  service with a port on the home network, and only while a move is
  expected. On an empty box, it serves the pairing page and takes one
  upload. In send-back mode, it packs and serves the move once. On a box
  that already has Peel Home and no send-back request, it exits at once.
- **`strut`**: `ghcr.io/stakwork/strut@<pinned>`, bound to 127.0.0.1. It
  starts only once Peel Home is there: `home/gate.sh`, so that this
  survives reboots and works under Umbrel's compose.
- **`bridge`**: `ghcr.io/stakwork/sphinx-runner@<pinned>`, sharing strut's
  network (`network_mode: service:strut`), bound to 127.0.0.1, its store
  on `/data/bridge`. Held by the same gate.

Everything worth keeping is in `./data`. To update: `docker compose pull`,
then `up -d`.

## Done when

The same as phase-2.md step 1. With Peel Home on the box and the Mac's
lid closed:

- a message from the phone gets an answer;
- "remember …" and "what do you remember about …" work;
- a reminder automation fires and lands in the DM;
- "what did I miss?" says "Waiting for your Mac", and is answered once the
  Mac wakes.

Then, after "Move back to this Mac", the same session and memory carry on
on the Mac, and nothing is answered twice. This is checked on a Pi (arm64)
and on a linux amd64 box.

## PR plan

One PR per row, opened one at a time against the default branch (no
stacks).

| # | Repo | What | State |
|---|---|---|---|
| A1 | sphinx | runner as a multi-arch image, `ghcr.io/stakwork/sphinx-runner` | Merged: stakwork/sphinx#397. The ghcr package must be made public |
| A2 | strut | The image carries Ladybug's `vector` and `fts` extensions | Merged: stakwork/strut#334 |
| A2b | strut | `moved.json`: at boot, rewrite bridge callbacks, `PEEL_BRIDGE_*` and upload paths, and drop the Mac-only parts | Merged with A2c: stakwork/strut#335 |
| A2c | strut | `strut move`: the format (strut's parts, named sidecars, env), the pairing code and encryption, `check`, `send`, `serve` (receive and send back) and `fetch`, writing `moved.json` on arrival. Both directions tested between two strut folders | Merged: stakwork/strut#335 |
| A3 | peel | `home/`: setup as `strut move serve`, strut and bridge behind `gate.sh`; no Tailscale. Tested with a development profile's folders on Linux Docker, and the amd64 graph check | PR open: stakwork/peel#388 (strut pinned by digest; runner by tag until its package is public) |
| A4 | peel | Account › Peel Home: move out and back through the bundled strut's `move`; stop and start strut and the bridge; ping; mark moved | PR open: stakwork/peel#396, with A6 and the strut pin; live test on Tom's Umbrel passed |
| A5 | peel | Umbrel (and CasaOS) wrappers of `home/`; the Umbrel draft (`home-umbrel-app`, c6a291f1) reworked onto it | After A3 |
| A6 | peel | The old "Home server" mode removed (`MemoryServer` to a remote strut, `MemoryMove`, `MemoryBackup`) | In stakwork/peel#396 |
| A7 | peel | Rename "brain" to Peel Home in existing code and copy: `Profile.brain`, `peel://brain`, Account › Brain; remove the old `brain/` bundle (done in #396) | Later |
| A8 | strut | Ladybug reserves 64 GiB per graph instead of 1 TiB, so strut runs on a Raspberry Pi kernel | Merged: stakwork/strut#338 |

A3's Go setup is replaced, but its README's spec (pairing code, HKDF and
AES-GCM chunks, the routes, the test vector) is A2c's starting point.

The strut H1 branch (`handover-parts-workspace-export`) is paused. Its
export and import come back with sealed backups (phase-2.md step 3), which
still need a portable format.

## v1 scope (Tom, 2026-10-26)

v1 is the core only: install `home/` on Umbrel, a VPS or a Pi, open its
link on the Mac, and Peel Home moves there. The agent answers from the box,
with everything stored there. "Move back to this Mac" ships with it,
because it is the same code.

Everything else is an improvement on the same pieces, after v1:

- **v1.1**:
  - the box follows an update channel published with each Peel release;
  - Account › Peel Home shows when the box last answered ("offline");
  - pairing by scanning the box's QR code with the phone, which hands the
    link to the Mac over Sphinx;
  - a second Mac or a reinstalled Peel pings the agent before starting its
    own bridge.
- **v2**:
  - sealed backups, more urgent once the box holds the only live copy;
  - Tailscale for the graph view and live steps;
  - a remote signer, so the box holds no keys.

## Dictation with Peel Home moved (proposed, for team discussion)

**The gap in v1.** Dictation records on the Mac and sends the audio to
Peel's own strut on the Mac (`POST audio/transcribe`). That strut runs the
speech model and rewrites the text with your vocabulary. The vocabulary
lives in the memory graph (`memory/lexicon`: people's names, how they are
misheard, your terms), so when the agent learns a name, dictation spells
it right.

After a move, the Mac runs no strut at all, so dictation stops working.
The vocabulary has moved to the box with the rest of memory. v1 doesn't
handle this. It doesn't affect anyone who never moves, but Tom's real
move waits for it.

**The core (the same under every option): a dictation-only strut on the
Mac, a vocabulary cache, and the box as the only writer.**

- **Transcription stays on the Mac:** real time, offline, on the Mac's
  hardware. Your audio never leaves the Mac, as today.
- **After a move, the Mac starts a dictation-only strut:** no agent, no
  bridge, no scheduler (`STRUT_SCHEDULER=0`), and its own small data
  folder. It is not a second brain.
- **A vocabulary cache, full from the start.** The Mac keeps its vocabulary
  when Peel Home moves out, so the cache needs no network to fill. The
  speech model's cache stays on the Mac too.
- **One writer.** The box's memory graph is the only place the vocabulary is
  written. The Mac holds the cache and an outbox of the corrections
  dictation learned, never a second graph, so there is nothing to merge.
  Names the agent learns reach dictation, and corrections reach the agent.
- **It never waits on the network.** The rewrite uses the cache, and
  corrections apply locally at once. Syncing happens in the background.
- **Only changes travel after the move:** a correction or a new name is a
  few words.
- **On the box:** two workflows read and write the vocabulary,
  `dictation-lexicon` (the vocabulary since a version) and
  `dictation-learn` (writes queued corrections through `dictation/add`).

The options differ only in **how the Mac and the box exchange those
changes**.

### Option A: a direct peer call, on the home network

```
 Mac: dictation strut ──HTTP (home network, TLS)──► box strut
      cache + outbox     pull changes / push learned   dictation-lexicon, dictation-learn (peer: true)
```

- Uses strut's existing peers (`STRUT_PEERS`, `strut/run-workflow`,
  workflows marked `peer: true`; strut `plans/federation.md`), the same
  mechanism as Hive and Stadeum.
- Syncs at home. Away, dictation uses the cache and queues corrections
  until the Mac is home again. With the optional Tailscale add-on, it syncs
  from anywhere, but every device needs Tailscale.
- **Opens a port on the box.** Today the box's strut listens on 127.0.0.1
  only, and a peer key (`STRUT_PEER_KEY`) can read everything. So it needs:
  - a key scoped to the two dictation workflows;
  - TLS, its certificate pinned through the pairing link.
- **PRs:**
  - strut: a scoped peer key, created when a move lands and handed back in
    the move's result;
  - strut: the two vocabulary workflows;
  - strut: the dictation-only mode, with its cache, outbox and sync;
  - peel `home/`: the peer port on the home network, with TLS;
  - peel: start the dictation strut after a move, with the peer details from
    the move.

### Option B: light changes over Sphinx, bulk as an attachment

```
 Mac: dictation strut ⇄ Peel ──Sphinx──► bridge on the box ⇄ box strut
      cache + outbox     "vocab v42: Itoi → Paul Itoi" / "learned: Stadium → Stadeum"
                         a catch-up too big for a message: an encrypted snapshot
                         on the memes server, sent as a link, like any attachment
```

- **Sphinx carries light text only.** A change is a few words, sent when
  something changes, not on a timer. That follows Sphinx's rule that
  messages are light text.
- **Bulk goes the attachment route.** A big catch-up (say, 200 names
  learned while you were away, or a wiped cache) is uploaded to the memes
  server, encrypted, the way Sphinx already sends files. Only a link and
  its key go in a message.
- Syncs anywhere, with no port on the box and no Tailscale. The agent only
  takes these requests from your own devices, end-to-end encrypted, under
  Sphinx's existing rules.
- A sync takes a few seconds, which is fine: it never sits in the dictation
  path.
- **PRs:**
  - strut: the two vocabulary workflows;
  - strut: the dictation-only mode, with its cache, outbox and the changes
    format;
  - sphinx runner: a "vocabulary" request and reply on the agent's control
    channel, with snapshots above a size cap as a memes-server attachment
    under the agent's sign-in;
  - peel: start the dictation strut after a move, and carry its changes to
    and from Sphinx (transport only; the logic stays in strut).

### Comparing them

| | A: direct peer call | B: Sphinx changes + attachments |
|---|---|---|
| Away from home | Cache only; syncs when home (or anywhere with Tailscale) | Syncs anywhere |
| Port on the box | Yes, with TLS and a scoped key | None; the box stays outbound-only |
| What crosses Sphinx | Nothing | A few words per change; a link for anything big |
| New security surface | A key and a listening port | A request type on the bridge |
| Mostly built in | strut and `home/` | strut and runner (Evan's area) |
| Speed of a sync | Fast, on the home network | A few seconds |

**Recommendation:** B, because it syncs anywhere and keeps the box
outbound-only. Choose A for something simpler that syncs only at home.
(C, Tailscale on every device, is A plus a VPN; it is left as an add-on.)

**Rejected:**
- Streaming audio to the box for every dictation: a Pi is slower than Apple
  silicon, and the box can't be reached away from home. A box with a GPU
  could take audio for a bigger model, at home, as an opt-in later.
- Copying the vocabulary once at the move, with no sync: the Mac and the
  box drift apart.

**For the team:**
- A or B.
- Whether this lands before the first real move, or with it.
- B: the size cap between a message and an attachment (say 2 KB), and the
  memes-server upload under the agent's own account (Evan).
- A: the scoped key's shape, and TLS on the box.

## Later

- **Changes after the move.** A new model key, new MCP grants, or a Peel
  update that changes the host config or `sphinx/*` steps must reach the
  box. For now: "Update Peel Home" in Account › Peel Home when the Mac is on
  the same network (`strut move serve` in update mode). Later: over
  Sphinx, excluding model keys.
- **A generic "strut home"** in strut's repo, once a second client wants
  an always-on strut.
- **Optional Tailscale**, for the graph view and live job steps.
- phase-2.md steps 2 to 4: the phone answers device requests, sealed
  backups, hardening.

## Questions for Evan

1. **runner:** is copying a stopped runner's store (seed and inbox) to
   another host and starting it there safe? Is there anything on the
   broker side tied to the old host?
2. **strut:** `strut move` as a strut feature with a documented,
   client-agnostic contract, plus `moved.json` at boot (A2b): is that
   acceptable, and does anything else store a host name or path beyond the
   survey above?
3. **Versions:** is pinning the box's strut and runner to the commits the
   Peel release ships acceptable, with a Peel update moving the box's pin?
4. **The agent's key off the box:** can runner sign through a remote
   signer, as Sphinx's signer design does, so the box holds no keys at
   all? Not needed for the first version.
5. **Dictation sync, option B:** a light "vocabulary" request and reply on
   the agent's control channel, and snapshots over a size cap uploaded to
   the memes server under the agent's sign-in. Does that fit runner, and
   what cap?

## Open questions

1. **How a second Mac, or a reinstalled Peel, knows Peel Home has moved.**
   The mark in step 6 is local. Options: keep it in the agent's own state,
   so a starting bridge asks the broker or the DM first; or keep it in the
   account's synced preferences. Check whether `PreferencesFile` (shared
   with the official apps) can carry a Peel-only key.
2. **Finding the box.** The user clicks the box's link, which works
   everywhere. A Bonjour name from inside Docker is unreliable, so it is
   left out.
3. **How Peel's bundled strut runs `move`.** As a command beside the
   server (`desktop.js move …`), or a route on a strut started only for
   the move. A2c picks one, and A4 follows it.
