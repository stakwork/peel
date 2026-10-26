# Phase 2: always on, the phone, can't lose it

Last updated 2026-10-19. **A plan for Tom's review; nothing here is built.**
Phase 1 ([agent-on-strut.md](agent-on-strut.md)) made the agent a contact
whose loop runs in strut on your Mac. Phase 2 makes it dependable: it
answers with your laptop closed, your phone can do what your Mac does for
it, and losing a disk loses nothing. The architecture it builds on is
[agent-architecture.md](agent-architecture.md); the phases and milestones
are in [end-state.md](end-state.md) (milestones 5 to 8).

It starts from [brain-handover.md](brain-handover.md) (2026-10-14),
[peel-brain.md](peel-brain.md), [memory-backup.md](memory-backup.md),
the snapshot round trip (stakwork/strut#193) and foundation.md's decision
12. Handover's PRs 1 to 12 were designed before runner was the bridge and
before the orchestrator was in strut; "What changes from brain-handover.md"
below says what moves. Read on 2026-10-19 from Peel's `main` (940e50e0),
strut's `origin/main` (8a03e85) and sphinx's `origin/master` (runner).

## In one paragraph

First, a **home server**: one Docker bundle with strut and the bridge, and
no Peel on the box. You move the **whole brain** to it from your Mac, and
back: strut's workspace, memory, sessions and secrets, and the bridge's
own state, in one snapshot, with exactly one brain answering at a time.
The agent then answers with every device asleep, and still asks your Mac
when it needs your chats or a send as you. Second, **the iPhone answers
device requests too**: a request goes to any of your devices, the first
to accept does it, and you approve from the phone. Third, **sealed
backups** in the same snapshot format, memory first, then the whole
brain, restored on a fresh Mac from your twelve words. Fourth,
**hardening**: model budgets, real auth on strut's routes, and Tailscale
made optional, kept for the graph view and live job steps.

## Decided so far

From Tom and [foundation.md](foundation.md):

1. **Order:** always on, then the phone, then backups, then hardening
   (Tom, 2026-10-19; foundation.md, decision 12).
2. **The home server is one Docker bundle: strut plus the bridge.** No Peel
   on the box (Tom, 2026-10-19). Peel's Sphinx engine (PeelCore) does not build on Linux, and
   the bridge is runner, which does (foundation.md, decision 1).
3. **Handover moves the whole brain, Mac to home server and back.** One
   brain is active at a time (brain-handover.md, "Decided").
4. **Your keys stay on your devices.** The box holds the agent's derived
   account and the brain's own keys, never your words (decision 3). So a
   home server still asks your Mac or phone for your chats and sends as
   you.
5. **Devices reach the agent over Sphinx.** A direct path to the box is
   optional and no daily feature needs it (decision 4). Setting the box up,
   moving the brain and changing its settings (the model key, a Peel
   update) are not daily features; they use a direct path from the Mac
   (open question 1).
6. **The first device to accept a request does it** (Tom, 2026-10-19).
   The phone approves from the phone.
7. **Backups reuse the handover's snapshot**, memory first, then the whole
   brain, restored from the twelve words (decisions 5 and 12).
8. **The snapshot round trip is proven** (stakwork/strut#193): memory and
   the workspace graph round-trip losslessly through Ladybug 0.21.2's
   export and import. strut's snapshot reader refuses a workspace export
   (its index and extension lines), so a whole-brain snapshot is format 2.
9. **Automation grants bind to strut's automation id** (stakwork/strut#220,
   merged 2026-10-19). A fire's run carries `ctx.automation`, which only
   strut's scheduler sets; a host step that acts on a grant names the
   automation from there, never from the run's input, and no grant key
   rides in the input. The Mac keeps what it allowed under that id.

Decision 10 ("brain mode is off by default: the Mac is the brain while it
is awake") is about where the brain runs, and stands: the Mac stays the
brain until you move it. brain-handover.md's `STRUT_BRAIN` flag is a
different thing, strut's state machine for one active brain; this page
calls it **brain state**.

## The shape

```
 Your devices (your account, your keys)
 ┌──────────────────────────┐  ┌──────────────────────────┐
 │ Peel on Mac              │  │ Peel on iPhone           │
 │ answers requests, cards, │  │ answers requests, cards  │
 │ send grants              │  │ (step 2), send grants    │
 └────────────┬─────────────┘  └────────────┬─────────────┘
              │ agent DM: talk + control     │
              ▼                              ▼
          broker + mixer (onion-encrypted, queued while asleep)
              ▲
              │ the agent's account (one bridge connected at a time)
 ┌────────────┴──────────────────────────────────────────────────┐
 │ The brain: this Mac (Peel starts strut + bridge)               │
 │         or a home server (Docker: strut + bridge, no Peel)     │
 │                                                                │
 │  bridge (runner) ── its store: the agent's core state, owner,  │
 │     │                inbox cursor, session id, request ledger  │
 │     ▼  127.0.0.1, one network namespace                        │
 │  strut ── orchestrator, jobs, automations, memory, workspace   │
 │     brain.json: brain id, state, generation                    │
 └───────────────▲───────────────────────────────────────────────┘
                 │ setup, handover and settings only: Mac → box
                 │ (step 4: the graph view, live steps)
             Peel on Mac
```

The parked brain keeps its files and answers nothing. Sphinx carries
every message, so moving the brain changes nothing on your phone.

## What a brain is now

A brain is two stores and a few host files, and all of it moves:

| Store | What it holds | Moves how |
|---|---|---|
| strut's data folder | The workspace graph (workflows, steps, automations, Peel's `sphinx/*` steps and `peel-automation-run`), memory, the DM's sessions and jobs, run history, portable secrets (the model key) | brain-handover.md's parts table and format-2 snapshot |
| runner's store (redb) | The agent's Sphinx core state (its contact with you and the key exchange), the owner allowlist (senders), the inbox cursor, the current session id (`dm-2`, …), the request ledger, turns and runs | **New:** runner's export and import, carried in the snapshot. The export leaves out runner's params (the seed and the invite): Peel posts the seed again |
| Peel's host delta | Peel's tools and prompt section (`host-config.json`, which strut reads only at boot, `STRUT_HOST_CONFIG`) | **New:** a portable part; strut restarts after a restore to read it |
| Automation callbacks | Each automation's `run.end` URL (`automation-callbacks.json`): the bridge on this machine | **New:** host-bound; a restore rewrites them from the new brain's `PEEL_BRIDGE_PORT` and `PEEL_BRIDGE_TOKEN`. On the Mac, each bridge start already re-points them, since its port and token change each launch (Phase 1 PR 7, #324); the restore does the same on the new brain |

The bridge's store matters. A fresh runner on the same seed is the same
account but has lost its contact with you and its place in the inbox, so
it would redo the key exchange and could answer old messages again.

**Two bridges must never be connected at once.** Both would receive your
message and both would start a turn. So runner gets two modes beside
running: **hold**, during a handover's drain, takes messages in and
launches nothing (they travel in its export and run on the new brain);
**parked** holds its store and stays off the broker. A runner restored on
a new brain starts parked, and is activated only after the commit. The
old one holds, then parks before its store is exported.

## Step 1: always on

> **Replaced (2026-10-25)** by [always-on.md](always-on.md): a one-way move
> that copies the stopped strut and bridge folders, and a bundle with no
> Tailscale. The handover below (H1–H4, R1's export, hold, park and
> activate) is not built for always-on.

### The bundle

`brain/` today runs strut behind Tailscale (peel-brain.md, "Packaging").
It gains the bridge:

| Service | Image | Notes |
|---|---|---|
| tailscale | `tailscale/tailscale` | As today. The way in for setup, handover and settings in step 1; optional from step 4 (open question 1) |
| strut | `ghcr.io/stakwork/strut` (multi-arch) | As today, brain state on. It binds 127.0.0.1 in the shared network namespace |
| bridge | runner, from `runner/Dockerfile.runner` | In the same namespace (`network_mode: service:tailscale`), so the `sphinx/*` steps reach it on 127.0.0.1 as on the Mac. Bound to 127.0.0.1 (`ROCKET_ADDRESS`; the image's default is 0.0.0.0, which would put `/seed` and `/bridge/*` on the tailnet). Its admin routes reach the Mac only through a second `tailscale serve` path, behind runner's admin token. Needs a published multi-arch image (none exists yet). Its store on the data volume |

`setup.sh` makes strut's keys, runner's admin token and the bridge's
token and port, and writes the bridge's address into strut's secret store
(`PEEL_BRIDGE_PORT`, `PEEL_BRIDGE_TOKEN`, which Peel writes on the Mac
today) before brain state is on, since an `empty` brain refuses writes.
These names are host-bound, so a restore keeps them
(`replacePortable`). Then it starts the box empty (`brain.json` state
`empty`, runner parked with no seed) and prints a pairing link with the
box's address and runner's admin token. It stops asking for `ANTHROPIC_API_KEY`: the model key
comes with the brain, as a portable secret. Nothing on the box knows your
account until Peel hands the brain over.

### Pairing and handover

Peel on the Mac drives it, as brain-handover.md's "Handover" says, with
the bridge added. The Mac's strut is loopback only, so the Mac pushes.

1. **Pair.** Peel opens the link, checks the box (`/health`, version,
   state `empty`), and gives it the brain id and brain key (derived from
   your seed; open, for Evan).
2. **Begin.** The Mac's strut goes `handing-over`: schedules stop, and no
   new turn or run starts. The Mac's bridge goes to **hold**: a message
   you send now is stored and launches nothing; it runs on the new brain.
3. **Drain.** Runs finish (brain-handover.md's 2 minutes), and device
   requests are answered or cancelled: the Mac's bridge is still on the
   broker, so a result can still arrive, and its late turn is held too.
   An open card is taken down as expired after the drain; the agent asks
   again after the move.
4. **Park the Mac's bridge.** Off the broker; its store is quiet.
5. **Snapshot.** strut's format-2 snapshot, with runner's export and the
   host delta as parts, pushed to the box.
6. **Restore** on the box: strut's parts, then Peel posts the agent's seed
   to the box's runner (parked, its store empty apart from the seed) and
   runner imports its store. Peel sets the devices runner asks (the Mac's
   id; step 2 widens it to all your devices) through runner's admin API.
   Automation callbacks are rewritten for the box's bridge. strut restarts
   to read the host delta.
7. **Commit.** `brain.json` active, generation + 1, on the box.
8. **Activate.** The box's bridge connects and reads what waited on the
   broker. The Mac's strut is parked and stopped; its bridge stays parked.

A failure before the commit sets the box back to `empty` (runner store
wiped, still parked) and unparks the Mac's bridge and strut: "Nothing
changed; your Mac is still the brain." The Mac pushes, so it cannot always
tell whether the box wrote its commit: as brain-handover.md's rule says,
it goes back to active only once the box's `/health` shows no commit, and
otherwise waits and says so. After the commit, steps 7 and 8 are retried
until they land; the Mac's bridge never unparks on its own.
Tests kill a handover at every step, as brain-handover.md plans.

Back to the Mac is the same steps the other way, pulled by the Mac. The
Mac's parked strut folder is replaced through restore; its runner store is
set aside, wiped and imported, and Peel posts the seed again (runner's
`/seed` sets it once per store).

### What the Mac does once the brain has moved

- It no longer starts its own strut or bridge (Account › Brain says where
  the brain is).
- It still answers device requests from the agent, now over the internet
  instead of on one machine: "Waiting for your Mac" becomes real when it
  sleeps.
- Send grants stay on the Mac. An automation that posts as you fires on
  the box and asks the Mac; with the Mac asleep, it waits and expires at
  its fire time + 10 minutes, as in Phase 1. The Mac's grants are keyed
  by strut's automation id (`ctx.automation`, strut#220), so they still
  match after a move only if the workspace export keeps automation ids:
  H1 checks it.
- A changed model or model key, and a newer host delta or `sphinx/*`
  steps after a Peel update, reach the box over the same path as the
  handover, when the Mac can reach it (open question 3). Model keys never
  travel in a Sphinx message.

### Done when

With the brain on the home server and the Mac's lid closed: a message from
the phone gets an answer; "remember …" and "what do you remember about …"
work; a reminder automation, which needs nothing from your devices, fires
and lands in the DM; "what did I miss?" says "Waiting for your Mac" and is
answered once the Mac wakes. Moving back to the Mac continues the same
session and memory, and nothing is answered twice.

## Step 2: the phone answers too

### First to accept

A request today names one device (`device`, the Mac), and a device acts
only on its own id. In Phase 2 a request can go to any of your devices.
Your devices all sign as one account, so each says which device it is:

| `op` | Direction | Fields | Meaning |
|---|---|---|---|
| `request` | agent → you | `device: "any"`, or one id as today | Any of your devices that can do it |
| `ack` | you → agent | `re`, and the sender's `device` (new) | "I'll do it": sent at once for a read, on your click for a card |
| `assign` (new) | agent → you | `re`, `device` | The first ack wins; only that device does it. Every other device closes its card or drops the read |
| `result` | you → agent | `re`, `status`, and the sender's `device` (new) | From the assigned device; the bridge ignores any other |

Every device sees every message in the DM, because they are one account,
so an `assign` closes the card everywhere at once. A device does nothing
before `assign` comes back: a read costs one more broker round trip, and
a send can never go twice. A Phase 1 Peel does nothing with `"any"` (it
answers only its own id), and shows an `assign` as an unknown control
line; so the bridge sends `"any"` only once your devices say they know it
(open question 5).

### On the phone

- **The handler moves.** `DeviceReads` and `DeviceActions` are in
  PeelAgent, which is Mac only, and they lean on Mac-side code:
  `SphinxTools`, `ChatData`, AgentKit's send plan, `ApprovalGate` and
  `ApprovalRules`. The request ledger is already PeelCore's
  (`Engine+DeviceRequests.swift`). The reads, the send plan and the rules
  move to shared code so the phone runs the same code. This is the
  biggest PR of step 2.
- **Reads** come from the phone's own copy of your chats. It may hold less
  history than the Mac; the result says which device read it.
- **Cards** on the phone: Allow once and Deny for a send in conversation
  and for `approve`. "Always allow" rules stay per device. The lines that
  name the Mac today ("Waiting for your approval on your Mac") name the
  device that answers.
- **Send grants reach the phone.** A grant made on the Mac (keyed by
  strut's automation id, strut#220) is sent as a control message from
  your own account in the agent DM, which only your
  devices can sign. The phone stores it and checks it as the Mac does
  (agent-on-strut.md, open question 5). The brain never holds one.
- **In the background** the phone cannot answer: iOS does not run it. It
  answers while Peel is open, and approves from a notification action once
  push works (the hub accepting Peel's app: spike S4, for the Sphinx team).

### Done when

With the brain on the home server and the Mac asleep: from the phone,
"what did I miss?" is read on the phone; "reply to Sam" shows a card on
the phone, and Allow sends once. With both awake, one device does each
request and the other's card closes.

## Step 3: sealed backups

- **Memory first.** The brain seals `memory/export`'s output (format 1,
  which exists today) on a schedule and after big changes (memory-backup.md,
  "When"), and sends it to the backup place. Then the whole brain: the
  format-2 snapshot with runner's store and the host delta, secrets sealed.
- **The brain seals, not Peel.** With no Peel on the box, strut has to
  seal and open backups. Peel derives the backup key from your seed and
  gives it to the brain when pairing, as it gives the brain key. This
  moves the sealing from Peel's RNCryptor v3 (memory-backup.md, foundation
  decision 5) into strut; whether strut keeps RNCryptor v3 or uses
  AES-256-GCM is a question for Evan.
- **Under the agent's account.** The box holds only the agent's account,
  so on the memes server backups are the agent's files. strut seals them;
  runner, which holds the agent's key, signs in to the memes server and
  uploads them. A fresh Mac derives the same agent account from your words
  and lists its files. The manifest's account hash names your account, and
  a second hash the agent's. memory-backup.md's open question 4 is
  answered this way.
- **Restore from the twelve words.** A fresh Mac: enter your words, Peel
  derives the backup key and name, finds the newest backup, and restores
  it into an empty brain. Then it posts the agent's seed, and runner
  imports its store, so the agent is back with its contact and
  conversation. A memory-only backup restores memory; the agent re-pairs
  (one more invite).
- **Never two brains after a restore.** A restore is for a lost brain,
  but the old box may come back. The restored brain takes the backup's
  generation + 1, and Peel sends a `park` control message from your
  account in the agent DM, naming that generation, before the restored
  bridge activates. A bridge on a lower generation that reads it parks
  itself and parks its strut (schedules off, writes refused); runner
  treats `park` from you as a control message, not a turn. An old box that
  was online when the restored bridge started can overlap for a moment;
  that is accepted, since restore is for a brain you have lost. Restore
  asks first: "Is your old brain gone?"
- **Where** the copies go is open, for Evan: the memes server, iCloud
  Drive, a chosen folder, a BitTorrent swarm (foundation.md, decision 5).
  Until it is answered, the first copy goes to the memes server.
- **The restore matrix** (finding-bugs.md, section 6) grows to a new Mac,
  a lost phone and a lost home server, and runs in CI on the local stack.

### Done when

On a clean macOS user, restoring the account from its words brings back
"What's my name?" from memory (memory first); later, the agent answers in
the same session with its automations, from the whole-brain backup.

## Step 4: hardening

| Piece | What exists | What Phase 2 adds |
|---|---|---|
| Model budgets | strut's Mothership module (`src/mothership.ts`): delegations, `maxRunCostUsd` per workflow, put into the macaroon for the Mothership gateway to enforce; `STRUT_MOTHERSHIP_REQUIRED` (`auth.ts`). strut stops nothing locally, and Hive is the only issuer | A cap on the orchestrator, automations and jobs that a person sets in Peel, and the stop at the cap (write up, then end; VISION's errands row). Either a Mothership gateway for personal brains, or a local cap in strut (question for Evan) |
| Auth on strut | One deployment key (`STRUT_API_KEY`) opens every route; a peer key is scoped; unset, everything is open | A brain key for your devices beside the owner's key, scoped (no `PUT /secrets`, no snapshot), revocable per device; the generation header |
| The bridge's loose ends | PR 4's and PR 5's reviews: tokens in the environment, the bridge token in the callback's query, CORS `*`, `secretsEnv` naming the bridge's secrets | Tokens over stdin, a header for the callback, no CORS, strut refusing those names in `secretsEnv` |
| Tailscale | Required by `brain/`, and it owns the network namespace strut and the bridge share | Optional: the box answers the agent without it, and setup and handover go over the home network once scoped keys are in (open question 1); with it, Peel's graph view and a job's live steps (SSE) reach strut directly. Without it, the bridge joins strut's namespace instead |

### Done when

A turn that hits its cap stops with a note; a revoked device's key is
refused by the box; the bundle runs without Tailscale and the agent still
answers; with Tailscale on, the graph view opens from the Mac away from
home.

## What changes from brain-handover.md

| Handover PR | Then | Now |
|---|---|---|
| 1–3 (strut) | Parts, `dataPath`, tar helpers, `workspace/export` and `workspace/import` | **Stand.** The DM's sessions and jobs are in strut's data folder and portable in its parts table. Host-bound secrets become `PEEL_BRIDGE_PORT` and `PEEL_BRIDGE_TOKEN`; `PEEL_AUTOMATION_*` go when Phase 1's PR 11 removes `AutomationServer`. `automation-callbacks.json` is a new host-bound part |
| 4–5 (strut) | `POST /brain/snapshot` (format 2), `POST /brain/restore` | **Stand, plus** two host-supplied parts (runner's export, Peel's host delta), callbacks pointed at the new bridge, and a restart to read the host delta |
| 6–7 (strut) | Brain mode, `brain.json`, the brain key, the write gate | **Stand**, as "brain state". On for the bundled strut and for `brain/` |
| 8 (strut) | Handover: begin, drain, snapshot, complete, lease, pull and push | **Stands, plus** draining device requests, parking the old bridge before the export and activating the new one after the commit |
| — (sphinx) | — | **New:** runner's export, import, parked mode and activate; its published image |
| 9 (peel) | A pointer per device, following `409 moved` on every strut call | **Smaller.** Chat follows the brain through Sphinx with no pointer. Only the Mac driving a handover or a settings change, and the optional direct path, need the box's address |
| 10 (peel) | Switch by handover; remove MemoryMove and MemoryBackup | **Stands, plus** the Mac's bridge: parked while the brain is away, its store replaced when the brain comes back |
| 11 (peel) | Automation secrets put back on activation | **Goes.** Automations run in strut and need nothing from Peel; the bridge's address is set by Peel on the Mac and by `setup.sh` on the box |
| 12 (both) | Warm standby, sealed snapshots | **Step 3** (backups). Warm standby stays later |

peel-brain.md's built "Home server" mode (Account › Brain), which points
Peel's memory tools at a remote strut, is replaced by the handover: with
the orchestrator in strut, Peel no longer calls memory tools itself.

## PR plan

One PR per step, in order. Risk tiers are AGENTS.md's ("How a change
ships"), raised where a PR holds keys, sends or moves the brain. strut and
sphinx PRs follow their own repos' review; the tier is what this table
would give the same change. **Evan** marks a PR that needs his answer or
his review first (the questions are below).

Phase 2 starts when Phase 1 is in daily use: PR 10 (strut the default) and
PR 11 (the Swift loop removed) merged. runner ending a `stale` run, a
Phase 1 blocker, is merged (stakwork/sphinx#386).

| # | Repo | What | Done when | Risk | Waits on |
|---|---|---|---|---|---|
| 0 | peel | This doc | Tom agrees | low | — |
| H1 | strut | Handover PRs 1–3: `parts.ts`, `dataPath`, tar and secrets helpers, `workspace/export` and `workspace/import` | The part test: every file under a booted strut belongs to one part; the workspace graph round-trips (#193's checks), automation ids included | medium | Evan |
| R1 | sphinx | runner: `POST /bridge/export` (no params) and `/bridge/import` (into a store empty apart from the seed), hold mode (stores messages, launches nothing, exports them), parked mode (stays off the broker), activate, the devices it asks set through its admin API, a published multi-arch image | Export, wipe, post the seed, import, activate: the agent answers your next message with no new key exchange and answers no old one; a message held during the drain runs once on the new brain; a parked runner receives nothing | high (keys) | Evan |
| H2 | strut | Handover PRs 4–5: `POST /brain/snapshot` (format 2) and `/brain/restore`, with host-supplied parts (the bridge's export, the host delta), callbacks rewritten, restart after restore | Snapshot, wipe, restore: the same workflows, automations, memory, sessions and secrets; a failed restore rolls back | high (secrets) | H1, Evan |
| H3 | strut | Handover PRs 6–7: brain state, `brain.json`, generation, the brain key beside `STRUT_API_KEY`, the write gate | A parked or empty brain refuses writes and runs no schedules; a lower generation is refused | high (auth) | H2, Evan |
| H4 | strut | Handover PR 8: begin, drain (runs and device requests), stream, commit, activate, abort, lease, pull and push, with the bridge held, parked and activated through the host | Kill at every step: never two active brains, never two bridges connected; a failure before the commit leaves the Mac answering | high | H3, R1, Evan |
| 1 | peel | The brain id and brain key from your seed, in PeelCore, with shared test vectors | Same values as the vectors; never printed or reflected | high (keys) | Evan (the scheme) |
| 2 | peel | `brain/` gains the bridge: the service in Tailscale's namespace, bound to 127.0.0.1, its admin routes behind a second `tailscale serve` path, its store on the volume, `setup.sh` writing the bridge's secrets into strut before brain state is on and printing the pairing link, no model key asked | `setup.sh` on a Linux box gives an empty brain, a parked runner and a link; both survive a reboot | medium | R1, H3 |
| 3 | peel | Move the brain: pairing from the link, handover Mac → box (push) and back (pull), the Mac's strut and bridge parked, model key and host delta updates to the box, progress and errors in Account › Brain; MemoryMove and MemoryBackup removed | Step 1's done-when, on the local stack and a real box | high (keys, moves the brain) | 1, 2, H4 |
| R2 | sphinx | runner: `device: "any"`, `device` on acks and results, first ack wins, `assign`, results only from the assigned device | Two stand-in devices ack; one is assigned, one result is taken; the other's is ignored | high (untrusted input) | R1 |
| 4 | peel | Requests to any device in PeelCore: `"any"`, `assign`, `device` on acks and results; ack, then wait for `assign` | Journey: two devices of one account; each request is done once; a Phase 1 device does nothing with `"any"` | high (sends) | R2 |
| 5 | peel | The handler shared: the reads, the send plan and the rules move out of PeelAgent; the iPhone answers reads while open | From the phone with the Mac asleep, "what did I miss?" is read on the phone | high (untrusted input) | 4 |
| 6 | peel | Cards on the phone (send, `approve`), lines naming the device that answers, send grants shared as your own control messages | Step 2's done-when; a grant made on the Mac lets the phone post an automation's send | high (sends, money) | 5 |
| 7 | peel | Approve from a notification action | A send card's notification allows the send without opening Peel | high (sends) | 6, spike S4 |
| B1 | strut | Sealed memory snapshots: seal and open with a key the host gives, `format` and the account hash in the manifest, on a schedule | A sealed memory snapshot opens only with its key; unchanged memory uploads nothing | high (keys) | Evan (the cipher) |
| 8 | peel + sphinx | The backup key and name from your seed; runner uploads memory backups to the first place under the agent's sign-in; restore into an empty brain on a fresh Mac | Step 3's first done-when on a clean user account | high (keys, storage) | B1, 1, Evan (the key, the place) |
| 9 | peel + strut + sphinx | Whole-brain backups with the bridge's store; restore with `park` for an old brain (runner reads it as control and parks its strut too); the restore matrix in CI | Step 3's second done-when; an old box that comes back parks its bridge and strut; the matrix runs on the local stack | high | 8, H2, R1 |
| 10 | strut | Brain-key scopes and per-device revoke | A revoked key is refused; a device key cannot read secrets or take a snapshot | high (auth) | H3, Evan |
| 11 | peel + strut | Model budgets: a cap per orchestrator, automation and job, set in Peel, with the stop at the cap | A capped turn ends with a note; the next one waits for a higher cap | medium | Evan |
| 12 | sphinx + strut | The bridge's loose ends from Phase 1's reviews | Tokens absent from `ps`; strut refuses `secretsEnv` naming the bridge's secrets | medium | — |
| 13 | peel | Tailscale optional in `brain/`: the bridge in strut's namespace when Tailscale is off; setup and handover over the home network with the box's certificate pinned by the pairing link; the graph view and live job steps over Tailscale | Step 4's done-when | medium | 2, 10 |

```
first      H1  R1  1
then       H2
then       H3
then       H4  2
then       3                → milestone 5, always on
then       R2  4  5  6  7   → milestone 6, the phone helps too
then       B1  8  9         → milestone 7, can't lose it
then       10  11  12  13   → milestone 8, hardened
```

B1 needs only `memory/export`, which exists, so it can be built earlier if
a slot is free; it ships in step 3, as decision 12 orders.

## Questions for Evan

One line each, to paste:

1. **Brain state:** in strut, should brain state (`STRUT_BRAIN=1`, `brain.json`, the write gate) be opt-in per host or the default?
2. **The brain key:** will strut accept a second, portable key (the brain key) beside `STRUT_API_KEY`, scoped so it can't read secrets or take a snapshot?
3. **Peel's own keys:** how should Peel derive the brain id, the brain key and the backup key from the seed: the same `agent_seed`-style HKDF in the Sphinx core, or a Peel registry with shared vectors?
4. **Handover routes:** are `POST /brain/snapshot`, `/brain/restore` and the handover routes (begin, drain, commit, abort, pull, push) owner-only strut routes you're happy to take, with host-supplied parts for the bridge's export and Peel's host delta, and a restart to reread `STRUT_HOST_CONFIG`?
5. **Runner's state:** can runner get an export and import of its redb store (without the seed), a hold mode for the drain, a parked mode that stays off the broker, an activate, and a memes-server upload under the agent's sign-in for backups?
6. **Auth:** for real auth on strut's routes, per-device keys with scopes and revoke, or one brain key plus the generation header?
7. **Budgets:** `maxRunCostUsd` is enforced only by the Mothership gateway: should a personal brain run a gateway, or should strut get a local cap?
8. **Backups:** where should the second backup copy go (the memes server, iCloud Drive, a chosen folder, BitTorrent), and should strut seal with RNCryptor v3, as Peel planned, or AES-256-GCM?

## Open questions

1. **The path for setup, handover and settings.** The Mac must reach the
   box to hand the brain over (the Mac's strut is loopback only, so it
   pushes), and to send a changed model key. Foundation decision 4 says
   strut needs real auth before it is reachable beyond loopback.

   | Option | For | Against |
   |---|---|---|
   | A. The home network, the box's certificate pinned by the pairing link | No account anywhere | Needs scoped keys first (PR 10) and a TLS terminator in the bundle; moving back from away waits until home |
   | B. Tailscale, as `brain/` does today | Built; works from anywhere; only your tailnet reaches strut | An account and an app on the Mac |
   | C. Through Sphinx and the memes server: the Mac uploads the sealed snapshot, the box's bridge fetches it | No direct path at all | The box needs the agent's seed before it can hear anything; model keys may not travel by Sphinx; slow for a few hundred MB |

   *Recommended:* B in step 1, as built, and A added in step 4 once
   scoped keys are in, so Tailscale becomes optional.
2. **Two bridges on one account.** *Recommended:* runner's hold and
   parked modes, the hold, drain, park, export, import, commit, activate
   order above, and the
   generation in runner's store too, so a parked runner that restarts stays
   parked.
3. **Settings and Peel updates with no Peel on the box.** A new model key,
   or a Peel update that changes its prompt, tools or `sphinx/*` steps,
   must reach the box. *Recommended:* Peel sends them over the step 1 path
   when it can reach the box, and says in Account › Brain when the box is
   behind. Until then the box keeps what it has, and a changed prompt still
   needs `/new`.
4. **Reads on a phone with less history.** *Recommended:* the device that
   answers reads its own copy and says which device read it; first ack
   wins, with no preference for the Mac in the first version.
5. **Mixed versions.** *Recommended:* each device says in its acks which
   envelope features it knows; the bridge sends `"any"` only once every
   device that answered in the last week knows it, else it names the Mac.
6. **The phone in the background.** *Recommended:* answer only while open,
   and approvals from a notification action once push works. No background
   reads.
7. **The Mac's brain while it is away.** *Recommended:* strut parked and
   stopped, its folder kept; runner parked, its store kept until the brain
   comes back, then set aside and replaced by the import.
8. **Two Macs.** *Recommended:* both answer as devices; only one can be
   the brain at a time, and the handover says which.
9. **Warm standby.** Later, as brain-handover.md says: the active brain
   sends a sealed snapshot to the parked one on a schedule.

## Risks

- **Two active brains or two bridges.** The worst failure: double replies,
  or two diverging memories. The commit point, the lease, the kill tests
  and the `park` message after a restore exist for it.
- **The agent's core state lost in a move.** The agent then re-pairs and
  may answer old messages again. R1 comes first for this reason.
- **A send done twice when two devices race.** `assign` before acting,
  and the at-most-once rules of Phase 1 on each device.
- **A card lost in a move.** A card still open when the drain ends is
  taken down; the agent asks again after the move.
- **The box's secrets.** It holds the model key, the agent's seed and the
  brain key in its data folder. `STRUT_SECRET_KEY` encrypts strut's store;
  runner keeps the seed in its store (Phase 1's PR 4 review left this
  open).
