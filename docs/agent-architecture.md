# Peel and the personal agent: architecture

Last updated 2026-10-09. The single source of truth for the personal Sphinx
agent that Peel is the client for. Nothing here is built. It brings together
three sources:

- the team note "Sphinx Personal Agent: Protocols, Contacts and Threads"
  (8 October 2026, unfinished), which covers the official Sphinx app's agent;
- [agent-native.md](agent-native.md), the rules the engine already follows
  so an agent can run on it;
- PR #15 (`docs/phase9-acp`), the ACP research and phase 9 plan, now carried
  on this branch as [research/acp-harnesses.md](research/acp-harnesses.md),
  [design/agents.md](design/agents.md) and
  [phases/09-agents.md](phases/09-agents.md).

It also takes in Glimmer, Tom's personal concept tree, as the agent's
long-term memory of who Tom is and how he works.

The position in "Summary" was agreed with Tom on 2026-10-08. The numbered
list in "Open decisions for Tom" is what is still open. Where an answer
here is not agreed, it says so.

## Summary

- **One agent contact.** You talk to one contact, your agent. It owns your
  memory, your permissions and your budget. Claude Code, Codex and other
  coding agents are *workers* that run behind it over ACP. Workers are not
  contacts, and they are optional: the core is the agent plus Strut jobs.
- **Sphinx is the bridge.** The agent is its own Sphinx account on an
  always-on agent host (Tom's Mac now, a home server or the cloud later).
  Peel and the official apps reach it only by Sphinx messages; there is no
  private API. Strut runs next to the agent on the same host and hands it
  results locally; the agent sends them as Sphinx messages, and the mixer
  queues them while the phone sleeps. This is the answer to the team note's
  "a phone has no URL".
- **The agent loop runs on the host, in Swift,** on Peel's headless engine.
  Strut runs jobs, schedules and workflows for it.
- **One graph,** a LadybugDB file on the host. The agent host process is its
  only writer. Peel, the phone, Strut and workers ask by message or through
  the host's tools; none of them opens the file.
- **The host embeds LadybugDB directly** through its Swift bindings, with a
  small fixed schema: Job, Run, Artifact, Claim, Evidence, and Concept for
  Tom's tree. Porting Strut onto LadybugDB is Strut and company work; Peel
  does not wait for it.
- **Threads.** Peel shows threads in 1:1 chats, as it does in tribes;
  messages already carry a thread id. A plain thread is a conversation with
  the agent. A bound thread is tied to one worker session, mapped by the
  host from thread id to session. The official apps see flat messages.
- **The permission and budget gate** sits in the host, outside the model.
  It follows the AP2 model (signed, capped, revocable approvals) on top of
  the engine's existing `checkPayment`. Approve and reject cards are typed
  messages under the `peel` key of message metadata, with readable text for
  the official apps.
- **Deferred:** temporary contacts or tribes for long sessions, until a
  real team use comes up. Connections to calendar and other sources are a
  later phase ("Connections", below).
- **No app sandbox for the host.** Peel is not on the Mac App Store, so the
  host can start Strut and workers.

## The shape

```
 Tom (master seed, on his devices only)
 ┌──────────────────────┐   ┌──────────────────────┐   ┌───────────────────┐
 │ Peel on Mac          │   │ Peel on iPhone       │   │ official Sphinx   │
 │ DM threads · cards   │   │ (paused)             │   │ apps: plain text, │
 │ Account › Agent      │   │                      │   │ flat messages     │
 └──────────┬───────────┘   └──────────┬───────────┘   └─────────┬─────────┘
            │          Sphinx messages (onion-routed)            │
            └───────────────────────┬────────────────────────────┘
                                    ▼
                      broker + mixer: queues while offline
                                    │
 ┌──────────────────────────────────▼──────────────────────────────────────┐
 │ Agent host (Tom's Mac now; home server or cloud later; no app sandbox)  │
 │                                                                         │
 │  peel-agent (Swift, one process)                                        │
 │   ├─ PeelCore engine: the agent's own Sphinx account (child or invite)  │
 │   ├─ gate: owner check, mandates, caps, approvals (outside the model)   │
 │   ├─ agent loop: model + tools, one turn per message                    │
 │   ├─ thread router: plain thread → loop; bound thread → worker session  │
 │   ├─ ACP client ───────────────▶ workers: Claude Code, Codex, goose …   │
 │   ├─ MCP client ───────────────▶ tools: Sphinx ops, graph, later        │
 │   │                                     calendar and other connectors   │
 │   ├─ agent.sqlite: queue, thread→session map, pending asks, audit       │
 │   └─ LadybugDB file (only writer): Job · Run · Artifact · Claim ·       │
 │                                    Evidence · Concept                   │
 │        ▲ results (localhost)          │ start_job · continue_job ·      │
 │        │                              ▼ schedules                       │
 │  Strut (separate local process): jobs, workflows, schedules             │
 └─────────────────────────────────────────────────────────────────────────┘
```

## Components

### Peel app

A Sphinx client, nothing more. It never runs the agent. It talks to the
agent the way it talks to a person, by DM, and adds what the official apps
lack: threads in the DM, typed cards (ask, result, progress, mandate),
Markdown, and an Account › Agent page whose controls send typed messages to
the agent rather than calling the host. Because there is no private API,
the host can move from the Mac to a home server without the app changing.

### Agent host

`peel-agent`, a headless Swift executable on the always-on machine. On the
Mac it runs under `launchd` and has no UI. It holds:

- **The agent's account.** One PeelCore `Engine` for the agent's own Sphinx
  account. The engine is the same one the app uses; the multi-account rule
  in `agent-native.md` stays, so the host could carry more accounts later,
  but there is one agent now.
- **The gate.** Every inbound message is checked before anything sees it:
  the signature must recover Tom's pubkey (the core does this), it must not
  be the agent's own echo, and its uuid must not have run before. Every
  outbound effect (a payment, a worker permission, a write to the outside
  world) passes the gate too. The model cannot reach around it.
- **The agent loop.** One turn per message in a plain thread: thread
  history from the host's own message store, a graph read, a model call
  with a small tool list, a reply in the same thread. The tools are the
  engine's typed operations (send, pay, read a chat), the graph tools, the
  Strut job tools and MCP tools. The model provider is open (decision 1).
- **The thread router.** Thread id to destination: absent means the agent
  loop; present means a worker session.
- **The ACP client** from phase 9: spawns a worker in a granted folder,
  pins protocol version 1, answers `session/request_permission` through the
  gate. Findings in `research/acp-harnesses.md`.
- **Operational state** in `agent.sqlite` beside the account's
  `peel.sqlite`: the turn queue, thread bindings, pending asks, mandates and
  the audit log (decision 6).
- **The graph**, below.

### Strut

Stakwork's workflow engine, run as its own process on the same host. It
runs jobs (multi-turn work, each turn a Strut run of the job workflow),
workflows and schedules. The host starts jobs with `start_job` and
`continue_job`, as Jamie does in Hive. Strut reports back to a callback on
localhost that only the host listens on; the host records the result in the
graph and sends it as a Sphinx message. Strut never talks to the phone and
never opens the graph. Schedules fire only while Strut runs and missed runs
are skipped, which matters for anything proactive (decision 12).

### LadybugDB graph

An embedded graph database (MIT; Swift bindings for macOS 14+ and iOS 17+,
per the team note, not yet tried here). One file on the host, opened
read-write by `peel-agent` alone. Schema and write rules below.

### ACP workers

Claude Code (`claude-agent-acp`), Codex (`codex-acp`), goose and anything
else on the ACP registry. Each runs in a granted folder with a pinned
adapter, in its conservative mode, under the subscription login on the
host. A worker belongs to one bound thread. It is never a contact, has no
Sphinx account and never sends a message itself; the agent sends for it.

### MCP tools

MCP is how the agent and workers call tools. The host exposes its own
tools over MCP to workers it starts (read and send in this DM, graph reads,
`concept_open` and `concept_walk`), and calls outside MCP servers itself
(later: calendar, email and other connectors). Every MCP tool with an
outside effect passes the same gate.

## Message flows

### Plain thread

```
 Tom (Peel)            mixer          peel-agent                     Strut
    │ "plan my week"     │                │                              │
    │ (DM, thread T) ───▶│───────────────▶│ gate: owner, new uuid        │
    │                    │                │ loop: history + graph + model│
    │                    │                │  ├ answer inline, or         │
    │                    │                │  └ start_job ───────────────▶│
    │                    │                │   Job node, bound to T       │ runs
    │                    │                │◀──────────── callback (local)│
    │                    │                │ Run, Artifact, Claim nodes   │
    │◀───────────────────│◀───────────────│ reply in T (Markdown)        │
```

A new top-level DM starts a thread: the agent replies with `threadUuid` set
to Tom's message, so each topic stays in its own thread. Replies inside T
continue it. Long work does not block the loop: the job runs in Strut and
the result arrives later in T, also when Peel is closed, because the mixer
queues it.

### Bound thread and the permission loop

```
 Tom (Peel)                 peel-agent                       worker (ACP)
    │ "fix the login bug"      │                                  │
    │ Bind T to Claude Code ──▶│ gate · grant: folder, mode       │
    │                          │ session/new (pinned, conservative)▶
    │                          │ T → session id in agent.sqlite   │
    │ message in T ───────────▶│ gate, then straight through ────▶│ prompt
    │                          │◀──────────── session/update      │
    │◀── progress (collapsed) ─│  one message per step            │
    │                          │◀──── session/request_permission ─│
    │                          │ rules: allowed? answer itself    │
    │◀── ask card ─────────────│  otherwise ask Tom               │
    │ Allow once ─────────────▶│ signature = Tom · names the ask  │
    │                          │  · uuid not used ───────────────▶│ continue
    │◀── result card ──────────│◀──────────────────── end of turn │
    │                          │ Job, Run, Artifact (PR, files)   │
```

- In a bound thread Tom's messages go to the worker without a model call.
  The agent still watches: it checks every permission request against the
  grant and Tom's rules, and writes the result to the graph at the end.
- An ask card is a typed `ask` with the options the worker offered (for
  Claude Code: allow once, allow for the session, reject). The text
  fallback numbers them, so `1`, `2`, `3`, `yes` or `no` from the official
  app also counts. An answer counts only if its signature recovers Tom's
  pubkey and it names a pending ask; the message uuid is the idempotency
  key. "Allow for the session" never outlives the grant.
- Unbind, Stop and New session are typed messages too. Revoking a grant
  cancels the session and drops its queue.
- The rules in phase 9 (one prompt in flight per session with a queue
  behind it, idle and turn timeouts, respawn with `session/load`) come from
  Buzz's harness, adopted as rules, not code (`research/acp-harnesses.md`,
  section 8).

### Inbox items

Phase 9's Wave D (`phases/09b-inbox.md`). The agent keeps Tom's to-dos
and reminders as Item nodes. Peel's Inbox is a read-mostly view of them,
drawn from a local cache on each device.

```
 Tom ── "remind me about this tomorrow at 2" (T) ──▶ peel-agent
                                                   loop: inbox_add
                                                   Item ─ABOUT▶ Artifact
 Tom ◀── reply in T ─────────────────────────────────┤
 Peel (Mac, phone) ◀── item.state {id, rev, fields} ─┘ to Tom's account
 Peel ── item.put {id, base rev, doneAt | remindAt} ─▶ peel-agent  (tick, snooze)
 Peel ── item.sync {since rev} ─▶ … ◀── item.snapshot (paged)
```

- These are typed messages under the `peel` key, in the agent DM and
  outside threads, with short fallback text for the official apps.
- The `inbox_*` tools write the agent's own memory and have no outside
  effect, so the gate answers them without an ask card. Upkeep that
  changes the list is an ask card.
- Each device schedules reminders from its cache, so the host's sleep
  (decision 12) does not lose one. The lock rule applies.
- The message an item is about reaches the host as a pointer only.
- Quick capture (⌃⌥Space, later) sends a line to the agent as a message,
  or queues it while offline.

### Payments and mandates

Spending follows AP2's shape: a mandate is a signed, capped, revocable
approval. Here it is a typed `mandate` message from Tom to the agent:
scope (for example "pay invoices from this tribe"), a cap per payment and
per period, an expiry and an id. The core's signature check is the
signature. A typed `revoke` naming the id ends it.

Each spend goes through the engine's existing `checkPayment` and then the
gate's mandate check. With no mandate that covers it, the agent sends an ask
card with the amount, and Tom approves that one payment. The hard cap is
the agent account's balance at the mixer, which only Tom tops up
(`agent-native.md`, "Corrections"). The model never sees or sets a cap.

## The graph

### Schema sketch

LadybugDB needs a schema before any insert, one table per node type and
rel tables that list their endpoints. The set is small and fixed, which
suits it (team note E4).

```
NODE Job      (id PK, title, thread_uuid, status, strut_job_id,
               created_ms, updated_ms)
NODE Run      (id PK, kind: model | worker | workflow, worker,
               strut_run_id, status, started_ms, ended_ms, cost_msat)
NODE Artifact (id PK, kind: pr | file | message | url, ref, title,
               content_hash, created_ms)
NODE Claim    (id PK, text, status: proposed | checked | rejected,
               created_ms)
NODE Evidence (id PK, kind, ref, excerpt, created_ms)
NODE Concept  (key PK, name, description, seed_path, seed_sha)

REL TURN      (Job → Run)          REL SPAWNED   (Run → Run)
REL PRODUCED  (Run → Artifact)     REL MADE      (Run → Claim)
REL SUPPORTS  (Evidence → Claim)   REL CITES     (Evidence → Artifact)
REL PARENT_OF (Concept → Concept)  REL ABOUT     (Job | Claim → Concept)
```

Later, for Connections: Person (linked to a Sphinx contact) and Event.

**Inbox items** (phase 9 Wave D, `phases/09b-inbox.md`, decided
2026-10-09):

```
NODE Item     (id PK, text, created_ms, updated_ms, done_ms, remind_ms,
               deleted_ms, state: open | suggested, origin,
               thread_uuid, rev)

REL ABOUT     (Item → Artifact)    the message it is about: kind message,
                                   ref "<chat>/<uuid>", no text copied
REL HANDED_TO (Item → Job)         when the agent works the item
REL ABOUT     (Item → Concept)     later, for grouping
```

- `thread_uuid` is the agent thread the item came from. Peel's Inbox
  links to it.
- `ABOUT` gains the `Item` endpoint pairs. If multi-pair rel tables are
  awkward in the Swift bindings, the message edge is named `SAVED_FROM`.
- Assigning an item to a person waits for the Person node.

### Write rules

1. **One writer.** Only `peel-agent` opens the file read-write. Strut,
   workers, Peel and the phone ask through the host, by message or MCP tool.
2. **Records come from events, not from the model.** Job, Run and Artifact
   nodes are written by host code when a job starts, a callback arrives or
   a worker session ends. The model cannot invent a run.
3. **Claims need evidence.** The model may propose a Claim; it is stored
   only with at least one Evidence node pointing at an Artifact, and starts
   as `proposed`.
4. **Artifacts are pointers.** A PR URL, a message uuid, a file path with a
   content hash. The graph never copies content.
5. **Items are written by the host on an event:**
   - Tom's `item.put` (a tick or a snooze);
   - an `inbox_*` tool call in a turn Tom started;
   - Tom keeping a suggestion;
   - upkeep Tom approved with a card.

   An item the agent infers on its own is a suggestion until Tom keeps
   it. Upkeep (merging, dropping a stale item, ticking from a chat) is
   an ask card, in the spirit of rule 6.
6. **Concepts are read-only to the agent.** Glimmer's seed files are the
   source of truth and the Concept tables are a view rebuilt from them. An
   agent that wants to change Tom's tree sends a proposal card; approving
   it edits a seed file, and the rebuild picks it up. Nothing writes a
   Concept directly (decision 7).
7. **Reads are by tool.** `graph_query` for jobs, runs and claims;
   `concept_open` and `concept_walk` for the tree, the same names Glimmer
   uses in stakgraph, so Claude Code and the agent read the tree the same way.

## Protocols

| Protocol | Connects | Use | When |
|---|---|---|---|
| Sphinx messages | Tom ↔ agent | Every instruction, card, result and receipt | Now |
| ACP | host ↔ worker | Bound threads; the client from phase 9, protocol version 1 | Now, optional |
| MCP | agent ↔ tools | Host tools for workers; outside connectors | Now for host tools; connectors later |
| Strut jobs | host ↔ Strut | `start_job`, `continue_job`, schedules, over localhost | Now |
| AP2 (model only) | Tom → agent | The shape of mandates: signed, capped, revocable | Now as a model; the wire format later if merchants need it |
| A2A | agent ↔ other agents | Agents outside Sphinx | Later |
| UCP | agent ↔ merchant | Shopping and checkout | Later |
| PAP | agent ↔ business | Scoped sign-in to a business | Watch; spec not public |
| L402 | agent ↔ paid API | Pay per call over Lightning | When needed |

Jamie on Hive keeps its own API until an outside agent needs A2A.

## What Peel needs

In roadmap order (see `PLAN.md`):

1. **Markdown in messages** (phase 10 item 2, pulled forward): agent
   replies are Markdown.
2. **Threads in DMs.** The thread grouping and thread panel that tribes
   have, in 1:1 chats. Peel already stores `threadUuid` in DMs and the
   official Mac app sends it there; today Peel follows the Mac rule and
   shows DM replies inline.
3. **The typed message codec** in PeelCore: `ask`, `answer`, `progress`,
   `result`, `mandate`, `revoke`, `bind`, `unbind`, versioned, under the
   `peel` key of the `metadata` JSON object, keeping other keys such as
   `tz`, with readable `content` for the official apps. One codec, used by
   the app and the host.
4. **Cards:** ask, result and progress in the conversation; mandate and
   proposal cards. Colour is state as in `design/README.md`.
5. **The agent contact:** contact kind, the rounded-square avatar and the
   AGENT label from the design; a status line (idle, working, waiting on
   you) built from the agent's own messages.
6. **Bind a thread:** a thread action that sends `bind` with the worker and
   folder; the bound worker shown in the thread header.
7. **Account › Agent:** the agent's account, mandates, worker grants, the
   activity log and, later, Connections. Each control sends a typed
   message; the host answers with the new state.
8. **The host itself:** `peel-agent` on the engine, from phase 9.
9. **The Inbox** (phase 9 Wave D), after graph memory:
   - the `item.*` messages in the codec;
   - Peel's cache;
   - the read-mostly view;
   - per-device reminders.

   Quick capture comes later.

## What Strut and the company need

None of this blocks Peel's first version; each item says what Peel does
until it lands.

- **A Strut that runs outside the sandboxed Mac app.** Today Strut runs
  inside the official Mac app for dictation only, sandboxed. The host needs
  the same Strut as a standalone process. Until then: the job tools are off
  and the agent answers inline or through a worker.
- **A local callback.** Strut posts results to a URL; on the host that is
  localhost, which needs no change beyond configuration.
- **The job workflow on a desktop Strut.** Hive's jobs run on the swarm
  Strut with a GitHub token. Which tools the job workflow's agent has was
  not checked in the team note.
- **Strut on LadybugDB** (team note E4): a graph store interface in Strut
  with Neo4j and LadybugDB backends. Company work. Peel's schema above is
  the same small set, so a later Strut backend can share it.
- **The Glimmer MCP bridge** (`concept_open`, `concept_walk`) in stakgraph,
  if that split holds. Peel only needs the tool names to match.
- **The official apps:** threads in DMs and the `peel` metadata key are
  ignored safely today; showing cards would be their own work.

## Connections (later phase)

Ideation only, added 2026-10-08. Connecting a calendar first, then email,
contacts, files and notes, so the agent knows what Tom's day looks like.
It comes after graph memory.

### Where it lives

Account › Agent › Connections in Peel. One row per service: Connect, the
scope (which calendars, which mailboxes), the access level (read only, or
read and propose changes through approval cards), and Disconnect. Like the
rest of the page, each control is a typed message to the agent; the host
does the work and answers with the new state.

### Two ways to connect, side by side

1. **macOS EventKit, recommended first.** One system permission covers
   every calendar macOS already syncs: Google, iCloud, Exchange. No tokens.
   It works only while the host runs on the same Mac, and the permission
   prompt appears on that Mac. A command-line tool under `launchd` may need
   to be a small signed app bundle with a usage description before macOS
   will ask; not checked yet.
2. **Per-service OAuth through MCP connectors on the host.** Works when the
   host is on a home server or in the cloud. The host runs the connector,
   the OAuth flow and the token store.

### Uses

- On-demand questions: "am I free Thursday?"
- Scheduled briefs and reminders, run by Strut schedules and arriving as
  Sphinx messages: a morning brief, "you have a call with Kate in 10
  minutes".
- Meetings linked to people: an attendee who is a Sphinx contact becomes a
  Person node, and the meeting an Event node linked to it, so "what did I
  agree with Paul last week" can join meetings, messages and jobs.

### Rules

- **Read only by default.** Writes, such as creating or moving an event,
  are proposals sent as approval cards, through the same gate.
- **Tokens live on the host,** in its Keychain or token store, and never
  travel in a Sphinx message. A sign-in link may be sent; a token or code
  never is.
- **Pull versus graph.** Event details are read through on demand; only a
  thin Event node (time, title, attendees as links) goes into the graph
  (decision C2).

## Open decisions for Tom

Each has options and a recommendation. Decisions 1 to 12 are for phase 9;
C1 to C5 are for Connections.

1. **The agent loop's model.** (a) An API key on the host, called from
   Swift; (b) the agent's own brain as an ACP session (Claude Code on the
   subscription); (c) Strut's chat agent. **Recommend (a):** the loop stays
   small and in one process with the gate, and ACP stays for workers. (b)
   puts the agent's decisions inside a worker's permission model.
2. **Who runs ACP workers.** (a) The host, with phase 9's Swift ACP client;
   (b) Strut, as the team note proposes. **Recommend (a) now:** the research
   already shows it working, and the permission loop stays in the host.
   Strut may run workers inside its own jobs later.
3. **Who binds a thread.** (a) Tom, by a thread action; (b) the agent
   decides; (c) both. **Recommend (c):** Tom binds directly; the agent can
   propose a binding with a card ("Hand this to Claude Code in ~/hive?").
4. **The job tool list.** (a) `start_job` and `continue_job` only; (b) plus
   `run_workflow` and `set_schedule`. **Recommend `start_job`,
   `continue_job` and `set_schedule`,** since briefs and reminders need
   schedules without a job thread; add `run_workflow` when a quick action
   needs it.
5. **How the host runs Strut.** (a) The host starts and supervises Strut as
   a child process on localhost; (b) Strut is its own `launchd` service.
   **Recommend (a):** one thing to start and stop, and the callback port is
   never exposed.
6. **Where operational state lives.** (a) `agent.sqlite` (queue, bindings,
   pending asks, mandates, audit) beside a graph for memory; (b) all of it
   in the graph. **Recommend (a),** as phase 9 already has it: the queue
   and asks are transactional state, not memory.
7. **Glimmer in the agent.** Where the seed files live for the host (a git
   repo the host pulls, or a synced folder), and whether the host rebuilds
   the Concept tables itself or reads Strut's `graph/walk` on another graph.
   **Recommend** a git repo the host pulls, a rebuild into the host's
   LadybugDB, and approved proposals landing as commits.
8. **The agent's account.** (a) A fresh account from an invite now; (b) a
   child seed derived on Tom's device and handed to the host; (c) a separate
   agents root on the host. **Recommend (a) on a throwaway first, then (b)**
   after spike 1 in `agent-native.md` (a child of a registered root
   registers free, research section 9).
9. **The agent's words at rest.** The host cannot ask for a PIN at boot.
   (a) The agent's mnemonic in the host's Keychain without a PIN; (b) a PIN
   entered when the host starts. **Recommend (a):** it is not Tom's root,
   its balance is the hard cap, and an always-on host that needs a PIN after
   every reboot is not always on.
10. **Default rules for the gate.** **Recommend:** reads in a granted folder
    are answered by the agent; every write, every outside effect and every
    payment without a mandate asks Tom; no mandate exists until Tom sends
    one.
11. **How Peel shows the agent's status.** (a) From the agent's messages
    only; (b) a typed `status` message the host sends on change. **Recommend
    (b),** kept off the official apps' screen by a short text fallback.
12. **Where the host runs first.** (a) Tom's Mac, with sleep prevented
    while the host runs; (b) a home server from the start. **Recommend (a)
    for phase 9,** accepting that a sleeping Mac skips Strut schedules; move
    to (b) before proactive briefs matter.
- **C1. The first connector.** (a) EventKit; (b) Google Calendar over OAuth
  and MCP. **Recommend (a)** while the host is on the Mac; (b) when it
  moves.
- **C2. Pull versus import.** (a) Read through on every question; (b)
  import every event; (c) read through, plus a thin Event node only for
  meetings with known people. **Recommend (c).**
- **C3. Which MCP connectors.** (a) Existing open-source servers, pinned and
  read before use; (b) our own. **Recommend (a),** pinned by version like the
  ACP adapters, with tokens kept by the host, not the connector's own
  config.
- **C4. OAuth when the host is remote.** The redirect cannot reach a home
  server from the phone. (a) Device-code flow where the service has one;
  (b) a sign-in on the host's own browser over remote desktop. **Recommend
  (a),** and leave services without it until needed.
- **C5. Proactive defaults.** **Recommend** everything off until Tom turns
  it on: a morning brief at a time he picks, a meeting reminder ten minutes
  before, quiet hours honoured.

## Differs from the team note

The team note covers the official app; this is Peel's version.

- **The agent loop** runs on the always-on host, not in the app on the
  phone or Mac (team note section 1 and E1).
- **The graph lives on the host,** one file, and the host process is its
  only writer. The team note has Strut as the only writer (section 3) and
  weighs a phone graph against a second Strut graph (E5). Here there is one
  graph and Strut does not open it.
- **Strut does not own the graph or the workers.** It runs jobs, workflows
  and schedules. The host runs ACP workers itself (decision 2); the team
  note has Strut running them.
- **Results reach the phone through Sphinx,** from the agent account on the
  host. There is no HTTP callback to a phone (E6).
- **Strut on LadybugDB is not on Peel's path.** The host embeds LadybugDB
  directly with a fixed schema (E4 stays company work).
- **No sandbox.** The question of the Mac App Store (E6) does not arise:
  Peel and its host are not sold there.
- **Temporary contacts and tribes** (section 5) are deferred.
- **Threads in DMs** (an open question there) are decided here: Peel shows
  them; the official apps fall back to flat messages.
