# Foundation before a stable Peel

Last updated 2026-10-16. **Five decisions, answered by Tom on 2026-10-16
(two parts left open for Evan), then the road to a stable build.** Nothing
here is built. It was written from a read of every doc in
`docs/`, both repos' history since 2026-10-08, and the Sphinx core.

Peel's features are mostly built: messaging, tribes, calls, money, the design
system, agent v1, memory in strut on Ladybug, the bundled strut, automations
v1 and a first iPhone client. What is not settled is a handful of choices
that are expensive to change once real keys and real memory exist. The docs
disagree on each of them today. This page puts them in one place, with a
recommendation, so they can be answered before more is built on top.

## The five decisions

| # | Decision | Recommended | Answer (Tom, 2026-10-16) |
|---|---|---|---|
| 1 | Where the agent's loop runs | B: strut on the brain, with a headless-Peel bridge | B, with a Rust bridge built from `sphinx/runner` |
| 2 | The key derivation contract | A: one HKDF registry from the raw seed, with test vectors | Input: the seed. The agent's seed: `agent_seed(seed, n)` in the Sphinx core (Evan). Peel's other keys: open |
| 3 | Whose account lives on the brain | A: only the agent's derived account; D, a remote signer, as the long-term target | A, with D as the long-term target |
| 4 | How devices reach the brain | B: Sphinx required, a direct strut connection optional | B: the agent gets its own derived account |
| 5 | What is backed up, how, and where | B: one whole-brain snapshot in two places, the round trip proven first | B, memory first. Where: open, for Evan; not a v1 blocker |

### 1. Where the agent's loop runs

Tom chose strut on 2026-10-14 (brain-handover.md, "Decided"). PLAN.md,
agent-architecture.md, phases/09-agents.md and jobs-architecture.md still
describe the loop in Peel. phases/07-iphone.md plans a "brain mode" Peel with
a second engine. The code is the Peel version: AgentKit and PeelAgent are
about 6,900 lines of Swift, and conversations live in each Mac's SQLite.

| Option | What it means | Long-term risk |
|---|---|---|
| A. Peel, in Swift | AgentKit stays the loop; a headless Peel runs it on an always-on box | The agent depends on Peel being up; conversations don't move in a handover |
| B. strut on the brain | The loop is a strut workflow; a thin Sphinx bridge holds the agent's account and exposes the Sphinx tools | One more long-running process to keep healthy |
| C. Both, by device | Swift on the Mac, strut on a home server | Two loops that drift apart |

**Recommended: B.** Only B moves the whole agent with the brain, and it runs
while the laptop sleeps without a second Peel runtime. The Swift Sphinx tools
and approval gate become the bridge if the bridge is Peel's engine run
headless (the lean), not a new sphinx-rs service. It moves agent
conversations from Peel's per-device SQLite into the brain, which is cheaper
before more history builds up.

**Answered: B, with a Rust bridge.** Peel's engine does not build on Linux
(it imports `Security`, `CommonCrypto`, `CryptoKit` and
`NIOTransportServices`; peel-brain.md), and the home server is a Docker
bundle for any box. So the bridge starts from `~/Documents/sphinx/runner`:
a headless Rust Sphinx client (about 1,300 lines) with a Dockerfile. It
holds an account's seed (set through an admin endpoint), connects to the
broker and receives messages, which today it forwards to Jarvis and a
Stakwork podcast workflow. Turning messages into strut runs, sending the
replies and the Sphinx tools (read, send, pay) are the new work. AgentKit stays
the Mac's loop until the bridge works, then shrinks to the client side.

**Where the bridge lives, Evan, 2026-10-16: runner itself** (sphinx#382).
Its old Jarvis and podcast job was unused and is removed, so runner is only
the bridge now.

### 2. The key derivation contract

Four derived keys are planned in three docs, from two different input
secrets:

| Key | Doc | Input | Info string |
|---|---|---|---|
| Agent words, agent n | 07-iphone.md, VISION.md | the seed | `peel agent <n>` |
| Memory backup key | memory-backup.md | the node secret | `peel/memory-backup/v1` |
| Memory backup name | memory-backup.md | the node secret | `peel/memory-backup/name/v1` |
| Brain id and brain key | brain-handover.md | as the backup key (so the node secret) | not chosen |

No code derives any of them yet (`Sources` has no HKDF). agent-native.md
rule 6 says to fix this before any child exists.

| Option | Trade-off |
|---|---|
| A. One registry: HKDF-SHA256 over one input, info `peel/<purpose>/v<n>`, every entry in one PeelCore file with test vectors | CryptoKit only, one place to audit; only Peel knows the scheme |
| B. BIP85 for agent words, HKDF for the rest | A standard, but needs BIP32 from the core in Swift, and two schemes |
| C. Per feature, as written | Already inconsistent |

**Recommended: A**, with the raw seed as the input for everything new (the
preferences key stays as it is), the agent words behind a numbered
`agent/<n>` entry so sub-identities can replace them later, and the brain
key's reach (anyone with the words) accepted.

**Answered: the input is the seed.** The scheme (A, B, or the same registry
implemented once in sphinx-rs and exposed to Swift) is open, for Evan.
Whatever it is must come out the same in Swift (Peel) and Rust (the
bridge), checked by shared test vectors.

**The agent's seed, Evan, 2026-10-16:** `agent_seed(seed, n)` =
HKDF-SHA256(seed, info `agent seed <n>`, no salt), in the Sphinx core
(`sphinx/src/signer/derive.rs`, fixed test vectors; sphinx#383), exposed by
sphinx-ffi as `agent_seed` from v0.8.39 (sphinx-rs#100). Peel derives it
and posts it to runner's `/seed`; runner never sees the words. Peel's own
derived keys (the brain id and key, the backup key) are not decided yet.

### 3. Whose account lives on the brain

Underneath "which identity sends" is whether your root key sits on an
always-on box. Sphinx broker login needs the root key, so a brain that reads
your chats while every device sleeps must hold it. VISION says the box at
home never holds the words. automations-and-jobs.md decided on 2026-10-15
that sends go out as you, claimed by an online device, but its table still
says the home server sends as the agent by default.

| Option | Needs a device online for | Key exposure |
|---|---|---|
| A. Only the agent's derived account on the brain | Catch-ups on your chats, sends as you | Derived keys only; matches VISION |
| B. Your account on the brain too | Nothing | Root key on a networked box; breaks VISION's "never the words" (builders' table, row 9) |
| C. The agent sends as itself | Reading your chats | The agent joins every tribe it posts to; rejected 2026-10-15 |
| D. Your account on the brain, keys on a remote signer (later) | Nothing, while the signer answers | The brain asks a signing device in an isolated key zone to sign and decrypt; the root key never touches it |

**Recommended: A now, D as the stated long-term target.** D is the remote
signer pattern Lightning uses (VLS), applied to the Sphinx identity, with
the same device able to sign for an optional Lightning node. What D needs,
read in `~/Documents/sphinx` on 2026-10-16:

- **Decrypt as well as sign.** Broker login and message signatures are
  recoverable ECDSA over the node secret (`sphinx/src/signer/sig.rs`), and
  opening onion messages needs ECDH with the identity key. The core needs a
  remote-key mode; today every call takes the seed.
- **FROST does not fit as is.** It makes Schnorr signatures; Sphinx identity
  expects ECDSA. A threshold group means threshold ECDSA (an MPC scheme such
  as DKLs) or a protocol change. A single remote signer needs neither.
- **It may answer the lost phone** (VISION open question 4): with 2-of-3
  (phone, signer, home box), losing one revokes nothing.

Rule for everything built under A: nothing may assume the brain holds the
root key.

**Answered: A, with D as the long-term target.** The bridge holds only the
agent's account. Runs that read your chats or send as you wait for a Mac or
phone. `sphinx-rs/sphinx-frost` exists, but it is an early Schnorr
experiment (a `main.rs` on `schnorr_fun`), so the ECDSA point above stands.

### 4. How devices reach the brain

07-iphone.md and jobs-architecture.md: the phone never talks to strut.
peel-brain.md: the phone pairs by QR straight to strut over Tailscale.
brain-handover.md: Sphinx for the agent, Tailscale for strut's UI and the
graph. VISION: pairing is one step, no URLs or keys typed.

| Option | Over Sphinx | Direct to strut | Setup per device |
|---|---|---|---|
| A. Sphinx only | Everything | Nothing | None |
| B. Sphinx required, direct optional | Everything a user needs | Graph view, live streaming, strut's UI | None, or Tailscale for power use |
| C. Direct for data | Agent chat | Memory, jobs, runs, graph | Tailscale on every device |

**Recommended: B, with one rule:** no feature may require the direct path.
"What do you know about me", correct and forget, run status and approvals
need a Sphinx message shape (agent-native rule 4). strut's routes need real
authentication before it is reachable beyond loopback; most are open today.
Also open: Tailscale or WireGuard (peel-brain.md open question 2).

**Answered: B.** This is also what gives the agent its own Sphinx account:
derived from your words (decision 2), held by the bridge, shown as a
contact. Decision 3 is only about your account.

### 5. What is backed up, how, and where

Ladybug everywhere is decided (2026-10-15). memory-backup.md (not agreed)
backs up the memory graph only, to the memes server only. brain-handover.md
plans a whole-brain snapshot and folds memory backup into it. VISION asks
for more than one place, with restore checked at setup. None of it is built:
losing the Mac's disk today loses the agent's memory.

| Option | In it | Where | Gap |
|---|---|---|---|
| A. Memory graph only | Episodes, entities, facts | Memes server | Automations, workflows and conversations lost; a second format later for handover |
| B. Whole-brain snapshot | Memory, workspace graph, automations, portable secrets, agent conversations | Memes server and a second copy | Needs strut's snapshot PRs (handover 1–5) first |
| C. A replayed change log | Every write | Memes server | That is live sync, which every plan defers |

**Recommended: B.** One format means one restore path to test, and handover
becomes snapshot here, restore there. Sealed with RNCryptor v3 under the key
from decision 2; the manifest carries `format`, the account pubkey hash and
the Ladybug version. Gate: memory-backup.md phase 0 (export, wipe, import,
compare every row and edge on Ladybug 0.21.2). New here: the restore
matrix (finding-bugs.md section 6, run by hand today) grows to a new Mac, a
lost phone and a lost home server, and runs in CI on the local stack. Also open: the
second place (iCloud Drive, a folder you choose, or the home server's disk).

**Answered: B, memory first.** One sealed whole-brain format, also used
for handover. Memory ships in it first, since nothing is backed up today;
the other parts join as strut's snapshot PRs land. Where the copies go
(the memes server, iCloud Drive, a chosen folder, a BitTorrent swarm) is
open, for Evan. It is not a v1 blocker, but it is needed. Backups moved to
Phase 2 (decision 12).

## Added later on 2026-10-16

Tom's answers on how Phase 1 ("the agent is a contact") is built, and when
backups come. The design and PR plan are in
[agent-on-strut.md](agent-on-strut.md); the phases and milestones are in
[end-state.md](end-state.md).

| # | Question | Answer (Tom, 2026-10-16) |
|---|---|---|
| 6 | When devices get a channel to the agent | In Phase 1, so catch-ups don't get worse when the loop moves to strut |
| 7 | How many conversations | One: the agent DM, the same thread on every device. No token streaming |
| 8 | Where the bridge runs | Bundled in Peel.app and launched by Peel, as strut is today |
| 9 | Which devices answer the agent's requests | Only the Mac, in Phase 1 |
| 10 | Brain mode | Off by default: the Mac is the brain while it is awake |
| 11 | Is the contact an agent? | No. The bridge is a pipe; every message goes to the orchestrator, a strut workflow on the `agent` step, which starts or continues strut's `job` for bigger work, as Jamie does in Hive |
| 12 | When backups come | Phase 2, after always-on and the phone: the handover builds the snapshot format, and backups reuse it. Not in Phase 1 |
| 13 | One contact, one continuous session | One agent DM is one strut session, compacted in place by the `agent` step, as Hermes Agent and OpenClaw do (both moved away from time-based resets). A session keeps its first system prompt; a new prompt reaches the DM through `/new` for now (refreshing at compaction is deferred, strut#198). Older turns stay in the session record; searching them comes later if needed. `/new` in the DM starts a fresh session. Jobs keep their own ids |

Evan answered both on 2026-10-16: the bridge is runner (sphinx#382), and
the agent's seed is `agent_seed(seed, n)` in the Sphinx core (decision 2).

## The road to stable

Each step starts when the one before it is agreed or merged.

1. **Answer the five decisions.** Done 2026-10-16, Evan's parts included
   (Peel's own derived keys and the backup location still open). Phase 1's design is [agent-on-strut.md](agent-on-strut.md).
2. **One architecture of record.** Rewrite PLAN.md's architecture,
   agent-architecture.md and VISION open question 7 around the answers;
   mark the older proposals (agent-brain.md, jobs-architecture.md, the
   memory-only parts of peel-brain.md and memory-backup.md) superseded where
   they disagree. Docs only.
3. **The small gates in code.** Memory-backup phase 0 (the Ladybug round
   trip), and a spike of the bridge on `sphinx/runner` against the local
   stack (done: sphinx#382). The agent's seed is `agent_seed` in the core.
4. **Finish the structure.** `WalletStore` and `ComposerStore` out of
   `AppModel` (still about 4,300 lines over 14 files, counting its extensions in PeelApp), the iPhone list
   engine (list PR 6), and the brain-handover PRs.
5. **Make it impossible to lose.** Encrypted whole-brain backups in two
   places, the restore matrix, kill-mid-send tests and nightly journeys on
   tribes with threads (finding-bugs.md, sections 4, 6 and 10).
6. **Freeze features and audit** (phases/08-audit.md), including strut's
   unauthenticated routes and its `secretsEnv` exposure.
7. **Cut stable.** The paid team for TestFlight and an end to the weekly
   re-sign.

## Loose ends found on 2026-10-16

- Unpushed strut work with no PR: `strut-wt-http-secret` (an undecryptable
  secret reads as unset) and `strut-wt-memory-ontology` (a plan, +422 lines).
- Uncommitted work in `~/Documents/strut` on `feat/workflow-overview`.
- Open PRs from 10-13 to 10-15: peel #253, #261, #267; strut #162, #191.
- About 30 merged or stale worktrees; the data volume is 90% full.
