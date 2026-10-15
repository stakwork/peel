# Brain handover: one brain, moved whole

Last updated 2026-10-14. **A design for Tom's and Evan's review; nothing
here is built.** It replaces the memory-only move in
[peel-brain.md](peel-brain.md) ("Move, not sync", build steps 2–3) with
moving the whole brain. It builds on strut's `memory/export` and
`memory/import` (strut #169, #176) and the backup envelope in
[memory-backup.md](memory-backup.md). Read on 2026-10-14 from Peel's `main`
(ebcdc99), strut's `main` (5de0faf) and the bundled strut's workspace on
Tom's Mac; three read-only planning passes (snapshot, handover, Peel)
checked it against the code. Updated 2026-10-15 for the bundled strut's
workspace on Ladybug (peel#284, strut `main` ae64fde): workflows, steps
and automations are in a graph file now, not in files.

## Goal

The brain is a role, not a machine (agent-brain.md). An always-on Mac and a
home server are the same thing; Peel needs to know which one is the brain,
and moving between them moves everything the brain holds: memory,
automations, workflows, secrets, settings, conversations with strut. In both
directions, without patching one part at a time.

Not goals:

- **Live sync between two brains.** One brain is active at a time. Two
  writers is the problem this design avoids, not one it solves.
- **Peel's own data.** Agent conversations and Sphinx messages live in Peel
  on each device. Moving those is the later work of running Peel's engine
  on the brain (peel-brain.md, "Later").

## What the first version taught

The memory move (peel #270, #275) works, but it moves one part of the brain,
and Peel does strut's job in places: it renames `graph.lbug` to set this
Mac's copy aside (those `memory/backups/graph-*.lbug` files are on Tom's
Mac, unknown to strut). Built that way, every new part would be another
Peel-side special case. It also leaves real gaps:

- A home server that was switched away from keeps running its schedules,
  so automations can fire on two machines.
- Each device stores its own pointer to the brain. The Mac can switch back
  while the phone still writes to the home server.
- Each brain has its own `STRUT_API_KEY`, so a device can't follow the
  brain to another machine even if it learns the address.

## Identity: the brain belongs to the account

Two values are derived from the account's words, the way the backup key and
name are (memory-backup.md, "Encryption"), with their own HKDF info strings:

- **Brain id**: names this account's brain. Every device and every brain
  for the account computes the same id, so a Mac's strut and a home server
  are recognisably the same brain, and an upgrade can tell which of two
  "active" ones to park.
- **Brain key**: the key devices use to talk to the brain, wherever it
  runs. strut accepts it beside its own `STRUT_API_KEY` (which stays
  host-bound, for the box's owner and setup). Peel gives a brain its brain
  key when pairing or handing over; it is portable and travels in the
  snapshot.

So a device that follows a move already holds the key the new brain
accepts, and pairing only has to carry an address.

## The brain is one strut workspace

On disk a brain is strut's data folder (the bundled strut's on a Mac is
`~/Library/Application Support/Peel/Strut/workspace`). Every brain runs its
workspace on Ladybug (`STRUT_WORKSPACE_BACKEND=ladybug`: the bundled strut,
the `brain/` bundle, the desktop tarball), so it holds two graph files and
the rest as files. Every file in it is one of two kinds:

| Part | Kind | Paths |
|---|---|---|
| Workspace graph: workflows, every version and the active one, automations, custom steps and their versions, claims, checks and evidence | portable, as a workspace export only | `graph/graph.lbug` (or `STRUT_GRAPH_DB`) |
| Memory | portable, as `memory/export`'s output only | `memory/graph.lbug` |
| Secrets, actor secrets | portable, minus host-bound names | `secrets.json`, `actor-secrets.json` |
| Run history | portable, finished runs only, newest 20 per workflow | `workflows/<n>/runs/<id>/{run.json,events.jsonl}` |
| strut builder chats, agent sessions, job records | portable | `chats/**`, `sessions/**`, `jobs/<id>.json` |
| Dictation vocabulary | portable | `audio/hotwords/**` |
| The raw graph files, their backups and temp | host-bound | `graph/graph.lbug*`, `memory/graph.lbug*`, `memory/backups/`, `memory/snapshots/` |
| The file workspace from before Ladybug | host-bound, left where it is | `fs-workspace.imported-<time>/` |
| Secrets that address this machine | host-bound | Peel's `PEEL_AUTOMATION_PORT`, `PEEL_AUTOMATION_TOKEN`, named by the host (`hostBoundSecrets`), not hard-coded in strut |
| strut's own keys, brain state | host-bound | `STRUT_API_KEY`, `STRUT_SECRET_KEY` (environment), `brain.json` |
| Runs in progress, callback, git caches, temp | host-bound | runs without `run.json`, `callback.json`, `repos/`, `worktrees/`, `audio/tmp` |
| Custom steps written out for the module loader | host-bound, written again from the graph | `steps/_graph/**` |
| Models | host-bound, fetched again | `STRUT_MODEL_DIR`, outside the folder |

On Ladybug `workflows/<n>/` holds only `runs/`; a `workflows/<n>/v*.yaml`,
`_metadata.json` or `steps/custom/**` there is a file workspace strut
hasn't imported yet (it does at its next start), so a snapshot refuses it.

Open: artifacts, job working folders, dictation captures, cassettes,
`peers.json`, `mothership.json` (see "Open questions").

**The table is code.** strut gets one `parts.ts` listing every part, and one
`dataPath(dataDir, part, …)` that every store uses to build its paths
(run store, chats, sessions, secrets, jobs, cassettes, hotwords, git,
artifacts). A store can't get a path without naming its part, so a new
store that doesn't say whether it moves is a compile error. A test boots a
strut, exercises every store and checks every file under the folder
belongs to exactly one part. At run time a file that matches no part (a
shell step's working folder is the data folder) is listed in the
snapshot's `left_behind`, not an error.

## Brain snapshot

One gzipped tar, the memory envelope widened:

```
manifest.json      format 2 · kind "brain" · created_at · strut and Ladybug versions ·
                   workspace backend ("ladybug") · brain id · generation ·
                   parts {id: sha256, bytes, count} · left_behind · secrets_encoding
workspace.tar.gz   workspace/export's output: the workspace graph's nodes and edges
memory.tar.gz      memory/export's output, unchanged (format 1)
workflows/<n>/runs/** chats/** sessions/** jobs/*.json audio/hotwords/**
secrets.json       plaintext values (only inside a handover; see below)
actor-secrets.json
```

- **The workspace graph moves as an export, not as the file.** strut
  needs a `workspace/export` and `workspace/import`, the memory snapshot's
  format and checks applied to `graph/graph.lbug`'s handle: a dump of the
  `Node` table and every rel table, read in one transaction while strut
  runs, loaded into an empty graph and refused over a non-empty one. It
  keeps what a file workspace can't: claims and their evidence, version
  timestamps, soft-deleted nodes. Copying `graph/graph.lbug*` instead only
  works with strut stopped on both sides and the same Ladybug version, and
  a stopped bundled strut can't push, so it stays a manual backup, not a
  handover. Exporting the graph as a file workspace and restoring it
  through strut's fs import would lose claims and timestamps.
- **Both sides on Ladybug.** A snapshot names its workspace backend, and
  restore refuses another one. A brain still on fs (a home server set up
  before 2026-10-15) is updated first; strut imports its files at boot.

- **Routes, not steps.** `POST /brain/snapshot` and `POST /brain/restore`
  are owner-only routes. Steps can be an agent's tools, so a step that
  returns secrets would hand them to any workflow agent; and strut's peers
  may call any GET, so the snapshot is a POST that peers can't reach. Both
  need a key (the brain key or `STRUT_API_KEY`), never a file token.
- **Checks** are `_snapshot.ts`'s: hash per part, refuse a newer format or
  more migrations, refuse links and odd names (`[A-Za-z0-9_.%@-]+`, no `..`,
  no leading dot), per-part entry allow-lists, the strict Cypher check for
  the graph, size caps (1 GB memory, 2 GB unpacked). `tar()` gains ustar's
  prefix field for long run paths.
- `memory/export` and `memory/import` stay as they are.

### Secrets

Secrets leave decrypted, because the new brain has a different
`STRUT_SECRET_KEY`: values from the live store, every name not host-bound.
The plaintext exists only inside `<dataDir>/brain/` (owner-only) or in a
handover's request body over https, and is encrypted on arrival with the new
machine's key in one atomic save. A local backup copies the encrypted
entries as they are (`secrets_encoding: "local"`). A snapshot sent off the
machine (warm standby, the memes server) is sealed with the account's
backup key first. Secrets set only in the environment never move; the docs
say so.

## Restore

strut caches what it loaded: the secret store keeps the parsed file, the
scheduler its entries, the step registry its list. So restore goes through
the running process, never by swapping files under it:

1. **Validate everything** and stage the file parts under `brain/staging/`.
2. **Quiesce.** Refuse (`409 busy`) while a run or a chat turn is running;
   otherwise take a brain lock that refuses writes, launches and new chat
   turns; stop the scheduler.
3. **Back up** what is there as a format-2 snapshot (local secrets
   encoding), newest 3 kept.
4. **Replace part by part**: rename each folder aside and the staged one in;
   secrets through the live store; the workspace graph through
   `workspace/import`'s load with its handle open, then `steps/_graph`
   written again from it; memory last through the existing `load()` with
   its Ladybug handle open.
5. **On failure, roll back** in reverse from step 4's set-aside folders and
   step 3's backup.
6. **Reconcile** either way: rebuild the step registry, reseed system
   workflows, re-record claims, reload the scheduler from now (a new
   `automations.reload()`; resuming today fires every overdue entry at once,
   a bug to fix with it), release the lock.

## One active brain: state and generation

strut gains a brain mode (`STRUT_BRAIN=1`, set by Peel for the bundled strut
and by `brain/` for a home server; other hosts are unaffected). In it, each
brain keeps `brain.json` (host-bound, written atomically): brain id, state,
generation, forward address, and the handover in progress.

| State | Schedules, auto-resume | Writes | Answers |
|---|---|---|---|
| `empty` | off | only restore, or `init` | `409 empty` |
| `active` | on | accepted | normally |
| `handing-over` | off | refused | `409 handing_over` |
| `parked` | off | refused | `409 moved {address?, generation}` |

- **One gate.** A single middleware after auth refuses every non-GET
  request unless active (`/brain/*` and run cancel exempt). Step runs that
  only read (`memory/recall`, `memory/get`, `memory/export`) carry a
  `writes: false` flag in their metadata and pass. In-process launches
  (`launchDetached`, the scheduler's fire, chat wake-ups on GET) check the
  state too.
- **Generation.** Devices send `x-strut-brain: <brain id>/<generation>` on
  every request. A lower generation on a write is refused
  (`409 stale_generation`); a higher one for this brain id parks the brain
  there and then. No header, as from other hosts, is unchanged.
- **Boot.** The scheduler and auto-resume start only when active. An
  existing install with any portable data boots active, generation 1, with
  the account's brain id once Peel has given it; a fresh one boots empty.

## Handover

Peel asks one brain to run the handover and only watches its progress. The
driver is whichever side can reach the other:

- **Pull** (the new brain fetches from the old): any move whose old brain
  is reachable over the network: home server → this Mac, home server →
  another home server.
- **Push** (the old brain sends to the new): when the old brain is the
  bundled strut on a Mac, which listens on loopback only, a random port and
  a per-launch key, and can't be reached from a server. That stays a
  security property; it isn't opened up for this.

Pull, as the new brain sees it (push is the same steps from the other side):

| Step | | Failure |
|---|---|---|
| 1. begin | old: `handing-over`, stop schedules, set a 15-minute lease | retry; another handover in progress → `409` |
| 2. drain | wait until no runs are in progress (default 2 minutes); Peel can offer "stop them and move" | timeout → abort, list the runs |
| 3. snapshot | stream it from the old brain; check hash, brain id, generation | abort |
| 4. restore | as above; then write `brain.json` active, generation + 1. **That write is the commit point.** | before it: abort; old goes back to active |
| 5. complete | old: `parked`, forwarding, generation + 1 | after the commit, retried until it lands |

- **The rule against two active brains.** An old brain that has sent its
  snapshot and then hears nothing never goes back to active on its own: it
  stays `handing-over`, asks the new brain's `/health`, parks if that shows
  a higher generation, goes back to active only if the new brain says the
  handover was aborted or never landed, and otherwise waits (and shows it).
  The owner can force an abort.
- **Crash at any step**, either side, resumes from what `brain.json`
  recorded; the planning pass lists each case, and tests kill a handover at
  every step.
- **Runs in progress** wait to finish by default, or are stopped and marked
  cancelled if the person chooses. Carrying a half-finished run across is
  later.

## Devices follow the brain

Peel keeps a pointer per device: address, brain id, generation (the brain
key is derived, not stored). It moves into PeelCore so the iPhone shares
it. One place in PeelCore's strut requests sends the generation header and
reads `409 moved`: if the request was authenticated, the address passes
Peel's strut-address check and the generation is higher, Peel saves the new
pointer and retries once. `moved` with no address means "the brain is on a
Mac, not reachable from here", shown as "Your brain is on your Mac."

Peel's part shrinks to: pair, ask for a handover, show its progress, follow
`moved`. A parked bundled strut is stopped; Peel never touches strut's
files. Quitting Peel during a handover it is driving asks first.

Progress, from the driving brain's phase: "Pausing automations on
{old}…", "Copying Peel's brain to {new}…", "Checking your home server took
over…", then "Your home server is Peel's brain now." A failure before the
commit says "Nothing changed; {old} is still Peel's brain."

Automations: Peel's two host-bound secrets are put back on the bundled
strut whenever it becomes active, before its schedules start. On a home
server, the `peel-automation` workflow moves with the brain but can't reach
Peel; its runs fail with "runs once Peel's brain is this Mac" until Peel
runs on the brain (peel-brain.md, "Later").

## Warm standby (later)

The active brain sends a sealed snapshot to the parked one on a schedule,
for example every six hours. If the active brain dies, "use the standby" on
the parked one promotes it (generation + 1) and loses at most one interval.
The same sealed file is the off-machine backup memory-backup.md plans.

## What changes from what is built

| Built | Becomes |
|---|---|
| Brain setting, pairing link, "Connect a home server" form and copy | Stays; the link can drop the key once the brain key is derived |
| `memory/export`, `memory/import`, replace with backup | Stays; the memory part of a brain snapshot |
| Peel's MemoryMove, MemoryBackup, the slow snapshot sessions | Removed; "ask strut to hand over" |
| Peel renaming `graph.lbug` | Removed; strut restores its own folder |
| Automations pausing only because the Mac's strut stops | Every brain that isn't active has schedules off |

## Build order

| PR | Repo | What |
|---|---|---|
| 1 | strut | `parts.ts` and `dataPath`; every store moved onto it; the part test |
| 2 | strut | `tar` prefix; shared snapshot helpers; `FileSecretStore.replacePortable`, `hostBoundSecrets` |
| 3 | strut | `workspace/export` and `workspace/import` for the Ladybug workspace graph, on PR 2's helpers; restore reopens the handle and writes `steps/_graph` again |
| 4 | strut | `POST /brain/snapshot` (format 2) |
| 5 | strut | `POST /brain/restore`: lock, backup, part-by-part, rollback, `automations.reload()` |
| 6 | strut | Brain mode, `brain.json`, the brain key, `/brain`, `/health` with state, generation and version |
| 7 | strut | The write gate, `writes: false`, launch and chat guards |
| 8 | strut | Handover: begin, drain, snapshot stream, complete, abort, lease; pull and push; the kill-at-every-step tests |
| 9 | peel | Pointer and brain id/key in PeelCore; following `moved` |
| 10 | peel | Switch by handover; progress; MemoryMove and MemoryBackup removed |
| 11 | peel | Automations secrets on activation; upgrading two active brains; quit guard |
| 12 | both | Warm standby, sealed snapshots, shared with memory backup |

Each PR: tests, the live check it names, code review, simplify and security
review. strut PRs 1–8 can go in while Peel keeps the current memory move;
Peel switches over at 10.

## Decided

- **The brain belongs to the account** (Tom, 2026-10-14): its id and key
  come from the twelve words. It is the account's memory, wherever it runs:
  this Mac, or a home server.
- **The phone reaches the agent through Sphinx** (Tom, 2026-10-14): the
  agent is a contact, and the phone sends it messages, routed by meaning,
  as [phases/07-iphone.md](phases/07-iphone.md) plans. The phone is a
  client of the brain, not a host for it (strut doesn't run on iOS); a
  direct strut pairing on the phone is not the long-term path.

- **The agent runs in strut, and is a contact** (Tom, 2026-10-14). In v2
  the agent's loop is a strut workflow on the brain (agent-brain.md's
  "front agent … into strut", its open question 4, answered), so it moves
  with the brain in a handover like everything else. A thin Sphinx bridge
  on the brain (Peel's engine headless, or a small sphinx-rs service) holds
  the agent's Sphinx account, turns messages into strut runs and sends the
  replies, and exposes the Sphinx tools (read chats, send, pay) that live
  in Peel's Swift today. Remotes reach the agent by message, Tailscale stays
  for strut's UI and the graph.

## Open questions

1. **For Evan:** brain mode opt-in (`STRUT_BRAIN=1`) or the default?
2. **For Evan:** strut accepting a second, portable key (the brain key)
   beside `STRUT_API_KEY`.
3. **For Evan:** `peers.json`, `mothership.json`, artifacts, job working
   folders: portable or host-bound? Gate peer callers (hive) too?
4. Run history: newest 20 per workflow, or none?
5. Brain state and generation on keyless `/health`: acceptable?
6. **For Evan:** do the `graph/*` steps write into the workspace graph on
   Ladybug? If so, those nodes move with it in `workspace/export`.
7. The brain key derived from the words means anyone with the words can
   reach the brain; that is already true of everything else the words hold.
