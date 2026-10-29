# Memory backup

Last updated 2026-10-13. **A plan, not agreed.** Nothing here is built.
It expands item 3 of "Next for memory" in
[phases/09-agents.md](phases/09-agents.md), and follows
[agent-brain.md](agent-brain.md) (strut owns the graph) and
[phases/12-automations.md](phases/12-automations.md) ("Mac now / Home
server later").

> **Superseded in part (2026-10-19).** Backups are one sealed whole-brain
> snapshot format, memory first, built in Phase 2 on the handover's
> snapshot (foundation.md, decisions 5 and 12). The key's input is your
> seed, not the node secret; the scheme is open, for Evan (decision 2).
> Where the copies go is open too, for Evan: the memes server is one
> candidate, with a second place. Phase 0 is done: memory and workspace
> graphs round-trip losslessly through Ladybug's export and import, and the
> whole brain needs snapshot format 2 (stakwork/strut#193). Remote access is
> decided: Sphinx, with an optional VPN (decision 4). Still standing: the
> envelope, the cipher, the restore rules and the threat model. See
> [agent-architecture.md](agent-architecture.md).

## Goal

Get the agent's memory back on a new Mac, or after a lost or wiped disk,
from the account's words alone.

Not goals:

- **Live sync between devices.** Two devices writing one graph is a
  different problem: an event log both sides replay (Tom T's change log, in
  agent-architecture.md's git history; not planned now). A backup is a whole snapshot, restored once.
- **History or undo.** One recent copy is enough; old copies are a cost,
  not a feature.
- **Backing up chats.** Peel's `agent.sqlite` holds conversation state;
  what matters long term is in the graph (agent-brain.md, "Compaction").

## What exists today

- strut's workspace and the memory graph live in
  `~/Library/Application Support/Peel/Strut` (`BundledStrut.dataFolder`),
  owner-only (0700), and are erased with the account (`BundledStrut.erase`).
- The graph is one Ladybug file, `workspace/memory/graph.lbug`, plus its
  write-ahead log `graph.lbug.wal` (`_db.ts` in strut's `memory/*` steps:
  `<dataDir>/memory/graph.lbug`, or `STRUT_MEMORY_DB`). On this Mac today
  the main file is 4 KB and the WAL 32 KB: most data is still in the WAL,
  so copying the main file alone loses it.
- strut is the only process that opens the file. Peel cannot read it
  while strut runs (agent-brain.md).
- The memory steps are not transactional: `remember` and `merge` are many
  statements with no transaction (`_db.ts`, header comment).
- There is no `memory/export` or `memory/import` step yet.
- The preferences file already does what a backup needs: RNCryptor v3
  (`Sources/PeelCore/MediaCrypto.swift`) with the node secret as the
  password (`Engine.preferencesKey`), uploaded to the memes server
  (`MemesServer.uploadPreferences`). See phases/11-preferences-sync.md.

> **Out of date (2026-10-19):** strut's `memory/export` and `memory/import`
> exist (stakwork/strut#169, #176), and the agent's conversation now lives
> in strut's sessions, which the whole-brain snapshot carries.

## What is backed up

| Item | In the snapshot | Why |
|---|---|---|
| The memory graph (Episode, Entity, Fact, Ontology and their edges) | Yes | The point of the backup |
| Automation records (name, schedule, prompt, enabled) | Yes, from phase 2 | Small, and lost with the disk otherwise |
| The `peel-automation` workflow | No | Peel installs it itself (12-automations.md, step 1) |
| Peel's loopback token | **No** | It sits in plain text in the workflow's `params` (`workflows/peel-automation/*.yaml`). A restore makes a new one |
| strut's API key | No | Made per launch, kept in memory (`BundledStrut.launch`) |
| The account's words, node secret, any key | No | The backup is opened with them; it never holds them |
| strut's cache (`Peel/Strut/cache`), run history, logs | No | Rebuildable, or not worth keeping |
| `agent.sqlite` | No | Conversation state, not memory |

Automations are read through strut's automations API, not copied as
files, so no workflow `params` (and no token) get in by accident.

## Snapshot

Two new strut lib steps beside the memory steps:

- `memory/export` → writes a snapshot folder under strut's data folder
  and returns its path, a content hash and counts per table.
- `memory/import` → takes a snapshot folder; refuses unless the graph is
  empty (no Entity, Fact or Episode rows), then loads it.

A workspace-level `workspace/export` that also takes automations is the
same shape; start with memory only.

**How.** Ladybug 0.21.2 has `EXPORT DATABASE` and `IMPORT DATABASE`
(the strings are in `lbugjs.node`; inherited from Kuzu). Export writes
the schema, the copy statements and one data file per table (CSV or
Parquet). Untested here; phase 0 tests it. The fallback is `CHECKPOINT`
then a copy of `graph.lbug`: simpler, but tied to Ladybug's storage
format, so a restore needs the same Ladybug release.

**Consistency.** `memory/export` takes the same in-process lock as the
writing steps (`remember`, `forget`, `merge`), so it never sees half a
write; reads continue. It runs `CHECKPOINT` first. Ladybug allows one
open database per file, so the step uses strut's existing handle rather
than opening a second.

**Envelope.** One file: a gzipped tar of the export folder plus
`manifest.json`:

```
manifest.json   format 1 · created_at · strut and Ladybug versions
                last migration index · ontology version · counts · content hash
graph/          what EXPORT DATABASE wrote
automations.json   (phase 2) the records, no params
```

The plaintext is written inside strut's 0700 folder and deleted once
sealed. Peel reads it through strut's step output (a path in that folder),
never through `/tmp`.

**Size.** Text only today: a few hundred KB after a year of use is a fair
guess. Embeddings (MiniLM, 384 floats, about 1.5 KB a node) change that:
10,000 facts and entities are about 15 MB before compression. Measure in
phase 0.

> **Superseded in part (2026-10-19):** the key comes from your seed, not
> the node secret (foundation.md, decision 2); the info strings below are
> not decided.

## Encryption

- **Cipher.** `MediaCrypto.encrypt`: RNCryptor v3, AES-256-CBC and
  HMAC-SHA256 over header and ciphertext, so a changed byte fails to
  decrypt (`Failure.wrongKey`). Same code the preferences file and
  attachments use; nothing new to review.
- **Key.** HKDF-SHA256 from the node secret
  (`Sphinxrs.nodeKeys(net: "bitcoin", seed:).secret`, as
  `preferencesKey`), info `"peel/memory-backup/v1"`, 32 bytes, hex-encoded
  as the RNCryptor password. Domain-separated: knowing the preferences
  password does not give this one, and the reverse. Never stored, never
  logged.
- **Name.** A second HKDF output, info `"peel/memory-backup/name/v1"`,
  first 16 bytes as hex. Fixed for the account, opaque, and the same on
  every device, so a new Mac can find it without any state.
- **Rotation.** The words do not change, so the key does not either. A
  new scheme is a new `v2` info string; restore tries v2 then v1.
- **Account check.** `manifest.json` carries a hash of the account's
  pubkey; a restore refuses a snapshot for another account. (The key
  already prevents it; this gives a clear error.)

What the memes server sees: the account's pubkey (it signed in), the
fixed name, the size of each upload and when. Not the contents. It can
withhold or delete a snapshot, or serve an older one; it cannot forge
one.

> **Superseded in part (2026-10-19):** the memes server is one candidate.
> Where the two copies go (the memes server, iCloud Drive, a chosen folder,
> a BitTorrent swarm) is open, for Evan (foundation.md, decision 5).

## Storage: the memes server

From stakwork/sphinx-meme `router.go`, read 2026-10-13:

- `POST /file` (signed in, multipart, `name` field) stores an encrypted
  file and returns a `muid`. Default limit 32 MiB and 512 bytes per
  upload, the whole multipart body (`lsat/size.go`), answered with 413
  "File too big"; lower when the server sets `RESTRICT_UPLOAD_SIZE`
  and `MAX_FREE_UPLOAD_SIZE_MB`. The hosted server runs the default
  (see open question 5). Larger files go to `POST /largefile`,
  which needs a paid LSAT.
- `GET /mymedia` lists the owner's media; `GET /mymedia/{muid}` one item;
  `GET /file/{token}` downloads with a media token, as attachments do.
- No route deletes or overwrites a file. `POST /preferences` is the only
  named file per account, and it is for preferences.

So each backup is a new file, and old ones pile up. Options:

| Option | Cost |
|---|---|
| A. Accept it | Storage grows by one snapshot a day. Fine while snapshots are KB |
| B. Upload only when the content hash changed | Cuts most days. Cheap; do it anyway |
| C. Ask for `DELETE /mymedia/{muid}` or overwrite-by-name | A sphinx-meme change, owned by someone else |

Plan: B now, A for what remains, ask for C. Over the size limit: back up
the graph without embeddings (they can be recomputed) and say so.

Peel keeps `device.memory_backup_seen` (muid, hash, time) so it can tell
"no backup yet" from "the server lost it", as the preferences file does
with `preferences_file_seen`.

## When

- **Daily while Peel runs**, after strut is up and the Mac has been idle
  a minute, at background priority. Skipped when the hash is unchanged.
- **After big changes:** a `merge`, a `forget` of an entity, or 50
  writes since the last snapshot. Debounced to once an hour.
- **Not on quit.** Quitting never waits on the network. A failed or
  missed backup is retried on the next launch.
- No button until memory has a place on screen (Tom: no memory UI for
  now). A failure is logged and shown nowhere yet.

## Restore

1. On account restore or import, once strut is up: if the graph is
   empty, look up the newest file with the backup name in `GET /mymedia`.
2. None: start empty, quietly.
3. Found: download, decrypt, check the manifest (format, account,
   Ladybug release for the copy fallback), `memory/import`.
4. Graph not empty (memory was written before restore finished, or a
   second restore): **never replace without asking.** Offer: keep this
   memory, or replace it with the backup from <date>. Replacing first
   keeps the current graph as a local, unencrypted-at-rest snapshot in
   the 0700 folder until the next successful backup.
5. Memory tools wait until restore finishes, so the agent does not write
   into a graph about to be replaced.

No merge of two graphs in v1. That is the sync problem.

## Home server

> **Superseded in part (2026-10-19):** remote access is decided: devices
> reach the brain over Sphinx, a VPN is optional (foundation.md, decision 4).
> The home server holds the agent's derived account in the bridge, plus the
> backup key, never your words. See [agent-architecture.md](agent-architecture.md).

When strut moves to an always-on Mac mini (agent-brain.md phase 6;
12-automations.md "Home server later"; the setting and the move are in
[peel-brain.md](peel-brain.md)):

- The graph lives on the server's disk, in its strut data folder. Memory
  stays its own Ladybug file there (Evan, 2026-10-13); strut's own graph
  may be Neo4j beside stakgraph and Jarvis.
- **The server backs itself up**, with the same steps and the same
  envelope. Laptops stop backing up memory they no longer hold.
- It needs the backup key and name, not the account's words. Peel derives
  both and hands only those to the server when it is set up.
- One format both ways: a laptop's snapshot seeds a new home server
  (`memory/import` into an empty graph), and a server's snapshot restores
  onto a laptop if the server goes.
- Only one writer at a time. Moving memory is: last backup on the old
  host, stop its memory steps, import on the new one. Two hosts each
  backing up under one name is the conflict the sync work exists for.

**Remote access / remote control: to define with Tom.** Tom asked how the
remote control flow works: how the phone and laptop reach the home
server away from home. Not decided. Options:

| Option | For | Against |
|---|---|---|
| Tailscale or WireGuard VPN | Plain HTTP to strut as on the Mac; low latency | A VPN on every device; a separate trust root from Sphinx |
| Sphinx messages as the control channel | Already the plan (agent-native.md, agent-brain.md); works through the broker while devices sleep; no open port | Slow for sync calls such as `recall`; message size limits |
| A relay | No VPN on the client | A server someone runs, and sees traffic metadata |

## Threat model

| Who or what | Can | Mitigation |
|---|---|---|
| Memes server operator | See pubkey, name, size, timing; delete, withhold, serve an old snapshot | Encryption; `memory_backup_seen` flags a missing file; rollback is possible and shown only by the snapshot's date at restore |
| Someone with the account's words | Read every backup | None needed: the words already hold the funds and messages |
| Another process on the Mac | Read the plaintext snapshot while it exists | 0700 folder; deleted once sealed |
| Time Machine | Already copies `Peel/Strut` unencrypted unless the backup disk is encrypted | Out of scope; note it in the restore docs |
| A bad snapshot | Fail import part-way | Import only into an empty graph; on failure, delete and start empty |
| A newer snapshot format | Not open on an older Peel | `format` in the manifest; refuse with "update Peel" |

## Risks

- `EXPORT`/`IMPORT DATABASE` may not round-trip every type (lists such as
  `aliases`, INT64 times) in 0.21.2.
- The checkpoint-and-copy fallback ties backups to one Ladybug release.
- No delete on the memes server: storage grows without bound if
  snapshots change daily.
- A restore that runs after the agent has written leaves the "keep or
  replace" choice to someone with no memory UI to judge it.

## Open questions

1. Remote access / remote control for the home server: VPN, Sphinx
   messages, or a relay (to define with Tom).
2. Will sphinx-meme add delete or overwrite-by-name for one's own files?
3. Do automation records belong in the memory snapshot, or in a separate
   workspace snapshot?
4. Should a home server hold only the derived backup key, or the
   agent's own account (agent-native.md), with backups under that?
5. ~~Is the 32 MB default limit what the hosted memes server runs?~~
   Answered 2026-10-29: yes, by its deploy config. sphinx-meme's
   `prod.yaml` (memes.sphinx.chat) sets neither `RESTRICT_UPLOAD_SIZE`
   nor `MAX_FREE_UPLOAD_SIZE_MB`, and its Caddy proxy and the older
   nginx config (`client_max_body_size 0`) add no body limit. So a
   snapshot over about 32 MB needs `/largefile` (a paid LSAT) or
   splitting. Not confirmed by an upload to the hosted server; Peel
   sends at most 32 MB (`Engine.sendLimit`).

## Phases

> **Superseded in part (2026-10-19):** phase 0 is done (stakwork/strut#193).
> Phases 1 to 5 are rebuilt in Phase 2 on the whole-brain snapshot, memory
> first.

0. **Prove the snapshot** (half a day). In a strut test: fill a graph,
   `EXPORT DATABASE`, `IMPORT DATABASE` into an empty file, compare every
   row and edge. Measure size with and without embeddings. Done when the
   round trip matches, or the copy fallback is chosen with the reason.
1. **strut steps** (1–2 days). `memory/export` and `memory/import` with
   the write lock, the manifest and the empty-graph check. Done when a
   test exports, wipes, imports and recalls the same facts.
2. **Peel backs up** (2 days). HKDF key and name, seal, `POST /file`,
   daily and after big changes, skip when unchanged,
   `memory_backup_seen`. Done when a second launch the same day uploads
   nothing, and one after a `remember` uploads once.
3. **Peel restores** (2 days). Lookup in `GET /mymedia`, download,
   decrypt, import on account restore into an empty graph; ask when not
   empty. Done when restoring the account on a clean user account brings
   back "What's my name?".
4. **Automations in the snapshot** (1 day). Records only, no params.
   Done when a restore brings back the automations with a fresh token.
5. **Home server** (with agent-brain.md phase 6). The server backs
   itself up with the derived key; a laptop snapshot seeds it. Done when
   a Mac mini starts from a laptop's backup and answers the same recall.
