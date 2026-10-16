# Foundation before a stable Peel

Last updated 2026-10-16. **Five decisions for Tom, then the road to a stable
build.** Nothing here is built. It was written from a read of every doc in
`docs/`, both repos' history since 2026-10-08, and the Sphinx core.

Peel's features are mostly built: messaging, tribes, calls, money, the design
system, agent v1, memory in strut on Ladybug, the bundled strut, automations
v1 and a first iPhone client. What is not settled is a handful of choices
that are expensive to change once real keys and real memory exist. The docs
disagree on each of them today. This page puts them in one place, with a
recommendation, so they can be answered before more is built on top.

## The five decisions

Answer 1 first: 3, 4 and 5 assume B there.

| # | Decision | Recommended | Answer |
|---|---|---|---|
| 1 | Where the agent's loop runs | B: strut on the brain, with a headless-Peel bridge | open |
| 2 | The key derivation contract | A: one HKDF registry from the raw seed, with test vectors | open |
| 3 | Whose account lives on the brain | A: only the agent's derived account; D, a remote signer, as the long-term target | open |
| 4 | How devices reach the brain | B: Sphinx required, a direct strut connection optional | open |
| 5 | What is backed up, how, and where | B: one whole-brain snapshot in two places, the round trip proven first | open |

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

## The road to stable

Each step starts when the one before it is agreed or merged.

1. **Answer the five decisions** on this page.
2. **One architecture of record.** Rewrite PLAN.md's architecture,
   agent-architecture.md and VISION open question 7 around the answers;
   mark the older proposals (agent-brain.md, jobs-architecture.md, the
   memory-only parts of peel-brain.md and memory-backup.md) superseded where
   they disagree. Docs only.
3. **The two small gates in code.** Decision 2's derivation file with test
   vectors, and memory-backup phase 0. Both are small and everything else
   depends on them.
4. **Finish the structure.** `WalletStore` and `ComposerStore` out of
   `AppModel` (still about 4,300 lines over 14 files, counting its extensions in PeelApp), the iPhone list
   engine (list PR 6), and the brain-handover PRs if decision 1 is B.
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
