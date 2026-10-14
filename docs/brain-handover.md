# Brain handover: one brain, moved whole

Last updated 2026-10-14. **A design for Tom's and Evan's review; nothing
here is built.** It replaces the memory-only move in
[peel-brain.md](peel-brain.md) ("Move, not sync", build steps 2–3) with
moving the whole brain. It builds on strut's `memory/export` and
`memory/import` (strut #169, #176) and the backup envelope in
[memory-backup.md](memory-backup.md). Read on 2026-10-14 from Peel's `main`
(ebcdc99), strut's `main` (5de0faf) and the bundled strut's workspace on
Tom's Mac.

## Goal

The brain is a role, not a machine (agent-brain.md). An always-on Mac and a
home server are the same thing; Peel needs to know which one is the brain,
and moving between them moves everything the brain holds: memory,
automations, workflows, secrets, settings. In both directions, without
patching one part at a time.

Not goals:

- **Live sync between two brains.** One brain is active at a time. Two
  writers is the problem this design avoids, not one it solves.
- **Peel's own data.** Agent conversations and Sphinx messages live in Peel
  on each device. Moving those is the later work of running Peel's engine
  on the brain (peel-brain.md, "Later").

## What the first version taught

The memory move (peel #270, #275) works, but it moves one part of the brain,
and Peel does strut's job in places: it renames `graph.lbug` to set this
Mac's copy aside. Built that way, every new part (automations, secrets)
would be another Peel-side special case. It also leaves two real gaps:

- A home server that was switched away from keeps running its schedules,
  so automations can fire on two machines.
- Each device stores its own pointer to the brain. The Mac can switch back
  while the phone still writes to the home server.

## The brain is one strut workspace

On disk a brain is strut's data folder (the bundled strut's on a Mac is
`~/Library/Application Support/Peel/Strut/workspace`):

```
memory/        graph.lbug (+ .wal, backups/)
workflows/     <name>/v*.yaml, _metadata.json (holds the automations), runs/
steps/         custom/ (custom steps), _history/
secrets.json   values encrypted with this machine's STRUT_SECRET_KEY
               (scrypt, per-file salt)
...            actor-secrets, peers, chats, jobs, artifacts, sessions,
               STT hotwords, mothership delegations, when used
```

Every part of it is one of two kinds, and nothing is in between:

| Portable: moves with the brain | Host-bound: stays with the machine |
|---|---|
| Memory, as Ladybug's portable export (`EXPORT DATABASE`), never the raw file | `STRUT_API_KEY`, `STRUT_SECRET_KEY` |
| Workflows, their automations, custom steps | Caches, downloaded models (fetched again) |
| Secrets (model keys, connector tokens), decrypted for the trip and encrypted again with the new machine's key | Secrets that address this machine: Peel's `PEEL_AUTOMATION_PORT` and `PEEL_AUTOMATION_TOKEN` |
| Settings, chats, jobs and artifacts (to confirm part by part) | Runs in progress, locks, temp folders |
| Run history, capped (the newest N per workflow) | |

The table is code, not convention: strut declares each part's kind in one
place, the snapshot is built from that list, and a part not listed is a
build-time error. A new store either says where it goes or doesn't ship.

## Brain snapshot

One file, the `memory/export` envelope widened:

```
manifest.json   format 2 · created_at · strut and Ladybug versions ·
                brain id · generation · parts and their hashes · counts
memory/         what EXPORT DATABASE wrote
workflows/      definitions, automations, custom steps, capped run history
secrets.json    plaintext values (see "Secrets in transit")
settings.json
```

- `brain/snapshot` writes it; `brain/restore` loads it. They reuse the
  memory steps' checks: hash, format, entry allow-list, size limits, the
  strict Cypher check for the graph files, never following links.
- Restore validates the whole snapshot before touching anything, backs up
  the brain that is there as a format-2 snapshot (newest 3 kept), then
  replaces part by part; a failure part-way restores the backup.
- `memory/export` and `memory/import` stay as they are: the memory part of
  the snapshot is exactly their output.

### Secrets in transit

Secrets leave the old brain decrypted, because the new brain has a
different `STRUT_SECRET_KEY`. So the snapshot is never written to disk in
plaintext outside strut's owner-only folder, travels only inside a
handover (https over Tailscale, strut's API key), and is encrypted again on
arrival. A snapshot kept as a backup or sent off the machine (warm standby,
the memes server) is sealed first with the account's backup key
(memory-backup.md, "Encryption").

## One active brain: handover

Each brain has a **state** and a **generation**:

| State | Schedules | Writes | Answers |
|---|---|---|---|
| `active` | run | accepted | normally |
| `handing-over` | paused | refused (`409 handing_over`) | reads only |
| `parked` | off | refused (`409 moved`, with the new brain's address and generation) | reads only |
| `empty` (new) | off | only `brain/restore` | — |

Switching is a protocol strut runs, started by Peel on any device:

```
old (active, gen 7)                          new (empty or parked)
1. → handing-over: pause schedules,
   finish or stop runs, refuse writes
2. brain/snapshot ─────────────────────────► 3. brain/restore: validate, back up
                                                what is here, load, gen = 8,
                                                → active, start schedules
4. → parked, forwarding to new, gen 8
```

- **One driver.** The new brain pulls from the old one (it has the address
  and key from Peel), so one process owns the sequence and its retries.
- **Failure rules.** Before step 3 completes, the old brain goes back to
  `active` and nothing changes. After step 3, the new brain is the brain
  even if step 4 fails; the old one is parked the next time anything
  reaches it (it learns the higher generation).
- **Generation** goes up by one on every handover. A brain that sees a
  higher generation for its brain id parks itself. A write carrying an old
  generation is refused, so nothing lands on a stale brain silently.
- **Parked is not deleted.** Its data is the latest backup of the brain,
  and it is where a handover back starts from.

The bundled strut on a Mac takes part like any other brain: "This Mac" is a
brain that happens to be local. Closing down a home server is a handover to
This Mac; getting one is a handover to it. Same code, both ways.

## Devices follow the brain

Peel on each device keeps a pointer (address, key, generation), as the
Brain setting does now. When a request gets `409 moved`, Peel updates its
pointer to the new brain and retries once. Switching from the Mac therefore
also moves the phone, the next time it asks. A device whose pointer is
gone stale for longer finds the brain the same way, as long as the parked
brain is still running.

Peel's part shrinks to: pair (the `peel://brain` link), ask for a handover,
show its progress, follow `moved`. Peel stops touching strut's files.

## Warm standby (later)

The active brain sends a sealed snapshot to the parked one on a schedule,
for example every six hours. The parked brain keeps it unopened as a
standby. If the active brain dies, "use the standby" on the parked one
promotes it (gen + 1) and loses at most one interval. The same sealed file
is the off-machine backup memory-backup.md plans.

## What changes from what is built

| Built | Becomes |
|---|---|
| Brain setting, pairing link, "Connect a home server" form | Stays |
| `memory/export`, `memory/import`, replace with backup | Stays; the memory part of a brain snapshot |
| Peel's memory move and bring-back (MemoryMove, MemoryBackup) | Replaced by "ask strut to hand over" |
| Peel renaming `graph.lbug` | Removed; strut restores its own folder |
| Automations pausing only because the Mac's strut stops | Every non-active brain has schedules off |

## Build order

1. **strut: the part list and brain snapshot.** Classify every store;
   `brain/snapshot` and `brain/restore` with backup and restore-on-failure;
   secrets re-encrypted on arrival. Tested by moving a full workspace
   between two struts and diffing the portable parts.
2. **strut: brain state, generation and handover.** The four states, the
   `409` answers, schedules following state, the pull-driven handover with
   its failure rules. Tested with a handover killed at each step.
3. **Peel: switch by handover.** The Brain setting asks for a handover and
   shows progress; follows `409 moved`; MemoryMove and MemoryBackup go.
   The bundled strut joins as a brain.
4. **Warm standby and sealed snapshots**, shared with memory backup.

## Open questions

1. Run history: carry the newest N per workflow, or none?
2. Chats, jobs and artifacts in strut's folder: portable, or host-bound?
   Artifacts can be large.
3. Does the brain id come from the account (derived like the backup name),
   or from the first brain at pairing?
4. Should `handing-over` wait for runs in progress to finish, or stop them
   and mark them interrupted (strut's `STRUT_AUTO_RESUME` resumes them on
   the new brain)?
5. Which secrets are host-bound beyond Peel's two: peers, Mothership
   delegations?
