# Peel and the Sphinx agent: architecture

Last updated 2026-10-19. **The architecture of record for Peel's agent:**
what is built and decided. It rests on [foundation.md](foundation.md)
(decisions 1 to 13), the end state in [end-state.md](end-state.md) and
Phase 1's design and build log in [agent-on-strut.md](agent-on-strut.md),
which has the detail. Where an older doc disagrees with this page, this
page wins; those parts are marked superseded with a pointer here.

It replaces this file's plan of 2026-10-10 (the agent in Swift inside Peel
on every device, one graph per device synced as an encrypted change log)
and the 2026-10-13 proposal in [agent-brain.md](agent-brain.md) (Peel's
agent as the front agent, handing work to strut). Both are in git history.

## In one paragraph

The agent lives on the **brain**: your Mac by default, a home server from
Phase 2. It is a **Sphinx contact** with its own account, derived from your
words with `agent_seed(seed, n)`. A Rust **bridge**, `sphinx/runner`,
bundled in Peel.app and started by Peel, holds that account. Every message
you send the agent goes through the bridge to strut's generic
**`orchestrator`** workflow, an agent on strut's `agent` step. It answers
small things itself and starts or continues strut's **`job`** for bigger
work. Memory (Ladybug) and automations are strut's. **Your keys stay on
your devices**: when a run needs your chats or a send as you, strut asks
your Mac with a hidden control message in the agent's DM, and your Mac
does it, behind an approval card where it acts. One agent DM is **one
continuous session**, compacted in place; `/new` starts a fresh one.

## The decisions it rests on

| # | Decision | Where |
|---|---|---|
| 1 | The loop runs in strut on the brain; the bridge is a Rust Sphinx client from `sphinx/runner` | foundation.md 1; runner is the bridge (sphinx#382) |
| 2 | The agent's seed is `agent_seed(seed, n)`: HKDF-SHA256 over your seed, info `agent seed <n>`, no salt, in the Sphinx core | foundation.md 2; sphinx#383, sphinx-rs#100 (v0.8.39) |
| 3 | Only the agent's derived account is on the brain; a remote signer is the long-term target | foundation.md 3 |
| 4 | Devices reach the agent over Sphinx; a direct connection to strut is optional and no feature needs it | foundation.md 4 |
| 5, 12 | One sealed whole-brain snapshot format, memory first, in Phase 2, after always-on and the phone | foundation.md 5 and 12 |
| 6–10 | The device channel is in Phase 1; one conversation, the agent DM, no token streaming; the bridge is bundled in Peel.app; only the Mac answers in Phase 1; brain mode is off by default | foundation.md 6–10 |
| 11 | The contact is a pipe; the orchestrator is a strut workflow that starts strut's jobs, as Jamie does in Hive | foundation.md 11 |
| — | The orchestrator is strut's, not Peel's: one generic workflow; Peel is its first host | agent-on-strut.md, decision 12 |
| 13 | One contact, one continuous session; `/new` starts a fresh one | foundation.md 13 |

## The shape

```
 Your devices (your account, your keys)        Sphinx v2 servers
 ┌───────────────────────────────────┐         ┌────────────────────┐
 │ Peel on Mac                       │         │ broker + mixer     │
 │  the agent DM · approval cards    │◄───────►│ (onion, queued)    │
 │  device requests (peel.sqlite)    │         │ push hub · memes   │
 │  send grants (agent.sqlite)       │         └─────────┬──────────┘
 ├───────────────────────────────────┤                   │
 │ Peel on iPhone, official apps     │◄──────────────────┤
 │  the same DM; never answer        │                   │
 └───────────────────────────────────┘                   │
                                                         │
 The brain: your Mac in Phase 1 (inside Peel.app); a home server in Phase 2
 ┌───────────────────────────────────────────────────────▼──────────────┐
 │ bridge (sphinx/runner): the agent's account · inbox · request ledger │
 │    │ POST /workflows/orchestrator/run          ▲ run.end callback     │
 │    ▼                                           │                      │
 │ strut: orchestrator (agent step, one session per DM, compaction)     │
 │    tools: memory/* · job/start, job/continue, job/* · automation/*   │
 │           sphinx/* (Peel's device steps) ──► bridge ──► your Mac     │
 │    job (its own folder, session, bash and web) · automations         │
 │    Ladybug: memory graph and workspace graph (strut the only writer) │
 └──────────────────────────────────────────────────────────────────────┘
```

A message to the agent: you write in the DM; the broker queues it until
the brain is online; the bridge opens it with the agent's key, stores it,
and starts one `orchestrator` turn in the DM's session; the turn recalls
memory and calls a model and its tools; the reply goes back through the
bridge as an ordinary DM, and the push hub wakes your phone. If the brain
is asleep the message waits on the broker. Auth, encryption, queues and
push are Sphinx's.

## The parts

| Part | What it is | Decides? |
|---|---|---|
| Your devices | Peel on the Mac: reads your chats, sends as you, draws the cards, keeps send grants. Peel on the iPhone and the official apps: the same DM, talk only | No |
| The contact | The bridge (`sphinx/runner`): the agent's keys, the inbox (store, then ack, one turn at a time per session), replies back, the request ledger, `cancel` to strut, tool rows from the run's events, chunking both ways | **No.** Every message from you goes to strut |
| The orchestrator | strut's `orchestrator` workflow on its `agent` step, with no built-in tools (`toolFilter: ['none']`). strut's tools (`memory/*`, `job/start`, `job/continue`, the `job/*` reads) plus the host's: Peel's `sphinx/*` steps, strut's `automation/*` steps and Peel's prompt section, read from a host config file at boot | **Yes** |
| Jobs | strut's `job` workflow, unchanged: a folder per job, artifacts, `ask`, bash and the web. Started detached with the bridge as its callback; continued by id | Yes, within one task |
| Automations | strut's scheduler. Each fire runs `peel-automation-run`: the same `agent` step with no session and the unattended prompt (no sends but by grant, no schedules) | Within the run |
| Memory | Ladybug inside strut: the memory graph and the workspace graph (workflows, steps, automations). strut is the only process that opens them | — |

Why the bridge is not the agent: it would be a second loop in Rust beside
strut's, its history would sit outside what a backup or handover moves, and
text from other people's chats would reach a model in the process that
holds the agent's keys. Why every message is not a job: `job` always has
bash, and on your Mac that bash could reach Peel's database. The
orchestrator stays small; jobs do the heavy work.

## Keys and accounts

- **Your account and its words stay on your devices.** The brain never
  holds your root key (foundation.md, decision 3). Rule for everything
  built: nothing may assume the brain holds it.
- **The agent's account** is agent 1: `agent_seed(seed, 1)`, derived by
  Peel (`Engine.agentAccount()`, `Engine+AgentAccount.swift`) and posted
  to runner's `POST /seed`, which refuses to replace one. runner never
  sees your words. A restore from your words gets the same agent back.
  The iPhone works out the same agent's pubkey from the same words
  (`Engine.agentPubkey()`) and stores nothing.
- **Pairing costs one invite.** Turning the agent on makes a 10-sat invite
  from your account; the agent registers with it, and sats it did not need
  are asked back (stakwork/sphinx#385, peel#322).
- **Trust.** The bridge runs turns only for your account's pubkey. The Mac
  answers requests only from its own agent's pubkey, addressed to its own
  device id.
- **Still open, for Evan:** how Peel's own derived keys are made (the
  brain id and key, the backup key). The input is the seed.
- **Long term (Phase 3):** a remote signer in an isolated key zone, so
  your account can run on the brain without the key ever touching it.

## The device channel

strut cannot read your chats or send as you: those need your keys. So a
`sphinx/*` step asks your Mac, in the agent's DM, and waits.

- **Two kinds of message.** Talk (Markdown, as written) and control (one
  short readable line as the content, a versioned JSON envelope under
  `metadata.peel`). Peel never draws a control message as a bubble; the
  official apps show the line.
- **The envelope** (`ControlEnvelope.swift`, v1): `request`, `ack`,
  `result`, `cancel`, `status`. A device that sees a `v` it does not know
  answers `failed`.
- **Requests** (stored and trusted in `Engine+DeviceRequests.swift`,
  done in PeelAgent's `DeviceReads.swift` and `DeviceActions.swift`): `chats.list`,
  `chats.read`, `chats.threads`, `chats.unseen`, `chats.search` (reads),
  `send` (a send as you) and `approve` (a card only, for strut steps that
  act on the brain, such as making an automation). `calendar.*` is
  designed but dropped from Phase 1 for now (Tom, 2026-10-18).
- **Nothing is done twice.** Each request has an id: strut's resume asks
  the same id again, the bridge's ledger and the Mac's `deviceRequest`
  table answer a repeat with the stored result. A send cut short after it
  was stored answers `unknown`, never a second send.
- **Approval cards.** A send in conversation, or an `approve`, shows a
  card in the DM on the Mac: Allow once, Always allow (never for anything
  with a cost or a grant), Deny. A card past its expiry closes itself.
  What runs is what the card showed.
- **Send grants.** An automation that posts as you gets a grant from your
  click on its create card: its chats, a sats cap per message, and
  `[Agent] ` first, checked on the Mac before each send. Grants live in
  `agent.sqlite`, never on the brain. Storing and checking them is merged
  (PR 3); making one from an automation's create card is PR 7, in review
  (waiting on stakwork/strut#215).
- **Waiting.** No ack in 10 s, or no result in time: the step returns
  `pending` wrapped in `withStop()`, the turn ends, and the DM says
  "Waiting for your Mac". A result that comes later starts a new turn in
  the same session.
- **Who answers.** Only the Mac, in Phase 1. The iPhone shows each request
  as one quiet line, and "Waiting for your approval on your Mac" where the
  Mac's card waits. The phone answering, first device to accept doing it,
  is Phase 2.

## One conversation, one session

- **The DM is the conversation**, the same thread on the Mac, the iPhone
  and the official apps. No token streaming: a reply arrives whole. On the
  Mac the agent's row in Direct messages opens it; "writing…" shows until
  a reply names your message; Stop sends a `cancel`.
- **One DM is one strut session** (`peel/agent-1/dm`), never reset on a
  timer, compacted in place by the `agent` step: older turns become a
  summary for the model and stay word for word in the session record.
- **`/new`** in the DM starts a fresh session (`dm-2`, `-3`, …). The bridge
  handles it and confirms. A session keeps its first system prompt, so a
  revised prompt reaches the DM through `/new` for now (agent-on-strut.md,
  open question 10).
- **Jobs keep their own sessions**, by job id, so `job/continue` works
  whatever the DM's session is. A job's result arrives as an agent message
  naming the job (`metadata.peel.job`), with what it points to.
- **Old history.** The conversation Peel's own agent kept on a Mac before
  strut was the agent stays there under "Old assistant chats (this Mac only)", read only,
  until Clear. It is not migrated.

## Connectors

Sphinx is one connector among others. Each is a set of strut steps with
its token in strut's secret store, granted to the orchestrator or a job.

| Connector | How | State |
|---|---|---|
| Sphinx | Peel's `sphinx/*` device steps, answered by your Mac with your keys | Built (Phase 1) |
| Gmail, Linear | strut steps, tokens in strut, granted to jobs | Not built |
| Calendar | `calendar.*` device requests, EventKit on the Mac | Designed, dropped from Phase 1 for now |

A connector that acts needs strut's **J1**: an `effect` on each step and
an approval stop in the job agent, so a job's write comes back as an `ask`
for the card. It is not built yet ([jobs-architecture.md](jobs-architecture.md),
"Build order"). Tokens never travel in a Sphinx message.

## What stays in Swift

No agent loop lives in Peel. On the Mac, AgentKit and PeelAgent are the
client side: the approval gate and its rules, the cards, the
device-request handler, the Sphinx read and send code it reuses, the
connected model's key (handed to strut), `BundledStrut`, `BundledBridge`
and `Orchestrator`, and the earlier local chat, read only. PeelCore,
Peel's Sphinx messaging engine, stays Swift. Peel's own loop, its model
clients, `AutomationServer` and the `peel-automation` workflow it served
were removed in PR 11 (agent-on-strut.md, "Built: PR 11").

## Where the brain runs

| | Phase 1 (now) | Phase 2 |
|---|---|---|
| Where | Your Mac, inside Peel.app: Peel, strut and the bridge, all started by Peel | Your Mac or a home server, one at a time |
| When it answers | While the Mac is awake and Peel is open | Always, on the home server |
| Who answers device requests | The Mac | The Mac or the iPhone, the first to accept |
| Backups | None yet; Time Machine's copy of strut's folder is the fallback | Sealed snapshots, memory first, then the whole brain |

The home server is strut and the bridge in one Docker bundle, with no Peel
on the box. Moving the brain is a handover of the whole strut workspace
([brain-handover.md](brain-handover.md)). Phase 2's plan is to come as its
own doc.

## What is built

As of 2026-10-19. The detail and each PR's checks are in
[agent-on-strut.md](agent-on-strut.md), "Built: PR 4" to "Built: PR 11".

| Piece | State |
|---|---|
| The bridge: runner (inbox, turns, sessions with `/new`, device requests, cancel, chunking; a run it did not launch, such as an automation's, sent to the DM) | Merged (stakwork/sphinx#382, #385, #387) |
| `agent_seed` in the core and sphinx-ffi v0.8.39 | Merged; Peel pins v0.8.39 |
| strut: `withStop()`, automation callbacks, retain text; `job/start`, `job/continue`; the generic `orchestrator`; the automation steps | Merged (stakwork/strut#198, #195, #196, #213) |
| Peel PRs 1–7, 6b, 9: the envelope, device reads, sends and approvals, the bridge launched, Peel's half of the orchestrator, the Agent chat as the DM, jobs in the DM, automations on strut with send grants, the iPhone's DM | Merged |
| PR 10: strut is the agent, no switch; runner ships in Release builds too, inside the sandbox | Merged (peel#334) |
| PR 11: Peel's own loop removed | Built; merges once Tom has used PR 10 on his account for a day or two |

## Open

- **For Evan:** Peel's own derived keys (the brain id and key, the backup
  key), and where the second backup copy goes.
- **For Tom and Evan:** how a revised orchestrator prompt reaches a
  long-lived DM (agent-on-strut.md, open question 10).
- Control messages are still messages: the official apps show their lines
  and the server keeps them (agent-on-strut.md, open question 1).
- strut's routes need real auth before strut is reachable beyond loopback.
