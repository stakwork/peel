# Phase 1: the agent is a contact

Last updated 2026-10-16. **Design and PR plan, for Tom's review. Nothing
here is built.** It turns [foundation.md](foundation.md)'s answers into
the first phase of Peel's end state: the agent's loop runs in strut, the
agent is a Sphinx contact with its own account, and your devices do what
only they can (read your chats, send as you, Calendar) when strut asks.

Read on 2026-10-16 from Peel's `main` (2b6edaaf), strut's `origin/main`
(57b1f04) and `~/Documents/sphinx/runner`. Two spikes run beside this and
feed the build, not the design: the Ladybug snapshot round trip in strut,
and `sphinx/runner` replying on the local stack.

## In one paragraph

You message your assistant as a contact, from the Mac, the iPhone or the
official apps: one DM, the same thread everywhere. A small Rust bridge,
bundled in Peel.app and started by Peel as strut is today, holds the
agent's own Sphinx account. Each message you send it becomes one turn of a
strut workflow, `orchestrator`, on strut's core `agent` step, which keeps
the conversation as a strut session and compacts it. That workflow is
the orchestrator: it answers small things itself and starts or continues
strut's `job` for bigger work, as Jamie does in Hive. Memory and
automations are strut steps already, so they run there. Your chats, sends
as you and Calendar are not: only your devices hold your keys and
EventKit. So a step asks your Mac, with a hidden control message in the
same DM, and waits for the answer. In Phase 1 only the Mac answers. When
it doesn't, the run says "Waiting for your Mac". Nothing you use today
stops working while this is built: the Swift loop stays the default until
the last switch.

## Decided (Tom, 2026-10-16)

From [foundation.md](foundation.md), and the group added later that day:

1. The agent's loop runs in strut, on the brain. The brain is your Mac by
   default; a home server is optional (Docker first, Tailscale for the
   VPN).
2. The agent is a Sphinx contact with its own account, derived from your
   seed.
3. Your own keys never sit on the brain. A remote signer is the long-term
   target (Phase 3).
4. Devices reach the agent over Sphinx. A direct VPN is optional, and no
   feature may need it.
5. Backups use one whole-brain snapshot format, memory first.
6. **The device channel is in Phase 1**, so catch-ups don't get worse
   when the loop moves.
7. **One conversation:** the agent DM. No token streaming.
8. **The bridge is bundled in Peel.app and launched by Peel.**
9. **Only the Mac answers device requests in Phase 1.**
10. **Brain mode is off by default.** The Mac is the brain while it is
    awake.
11. **The contact is a pipe; the orchestrator is a strut workflow**
    (Tom, later on 2026-10-16). The bridge decides nothing: every message
    goes to the orchestrator (the `orchestrator` workflow), an agent in strut. It answers
    small things itself and starts or continues a `job` for bigger work,
    as Jamie does in Hive. Reuse strut's jobs as they are.
12. **The orchestrator is strut's, not Peel's** (Tom, later on
    2026-10-16). strut ships it, `orchestrator`, as it ships `job`: one
    generic workflow that any host talks to, with the host adding its own
    tools and a prompt section. Peel is its first host; Hive's Jamie could
    move onto it later, once it holds up in Peel, but that is not part of
    this plan. It can run several jobs at once: each job takes one turn at
    a time, the orchestrator any number of jobs.
13. **One contact, one continuous session** (Tom, later on 2026-10-16).
    One agent DM is one session, compacted in place. A session keeps its
    first prompt; `/new` starts a fresh one (section 1, Sessions).

Evan's answers (2026-10-16, merged as sphinx#382, sphinx#383 and
sphinx-rs#100):

14. **The bridge is `sphinx/runner`.** runner's old job (Jarvis triplets,
    the Stakwork podcast workflow, transcripts) was unused and is gone, so
    runner is only the bridge now. `/mainnet_seed_phrase` is removed;
    `/seed` takes the derived agent seed.
15. **The agent's seed is `agent_seed(seed, n)`**: HKDF-SHA256 over your
    seed with info `agent seed <n>` and no salt, in the Sphinx core
    (`sphinx/src/signer/derive.rs`, with fixed test vectors). sphinx-ffi
    exposes it as `agent_seed` from v0.8.39 (sphinx-rs#100). Peel derives
    it and posts the result to runner's `/seed`; runner never sees your
    words. This settles decision 2 for the agent account. Peel's own
    derived keys (the brain id and key, the backup key) are not decided
    yet.

Nothing in Phase 1 waits on Evan now. PR 10 waits only on Peel's
sphinx-rs pin moving from v0.8.38 to v0.8.39.

## The shape

```
 You: Peel on Mac (your account)        Peel on iPhone / official apps
 ┌───────────────────────────────┐      ┌────────────────────────────┐
 │ Agent DM (the Agent chat)     │      │ Agent DM: talk only;       │
 │ DeviceRequests (agent.sqlite) │      │ requests hidden or a line  │
 │  reads · sends · Calendar     │      └─────────────┬──────────────┘
 │  approval cards, rules        │                    │
 └──────────────┬────────────────┘                    │
                │      Sphinx DM: talk + control       │
                ▼                                      ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │ The brain (this Mac in Phase 1, inside Peel.app)                 │
 │                                                                  │
 │  bridge (Rust): the agent's account · inbox · request ledger     │
 │     │ POST /workflows/orchestrator/run    ▲ run.end callback     │
 │     ▼                                     │                      │
 │  strut: orchestrator ── agent step (session, compaction)         │
 │     tools: memory/* · automation steps · sphinx/* · calendar/*   │
 │                                   │ loopback: /bridge/device/request│
 │                                   └──────────► bridge ──► Sphinx │
 └─────────────────────────────────────────────────────────────────┘
```

Three processes on the Mac, all started by Peel: Peel itself (your
account), strut (bundled today) and the bridge (new). Brain mode, where
strut and the bridge run on a box without Peel, is Phase 2; nothing here
assumes the brain is the Mac except who answers device requests.

## The layers

| Layer | What | Decides? | In Hive |
|---|---|---|---|
| 1. Your devices | Peel on the Mac (and the phone later): read your chats, send as you, Calendar, approval cards | No | The browser |
| 2. The contact | The bridge: the agent's keys, the inbox, replies and files back, requests to your Mac | **No.** Every message from you goes to strut | Hive's server |
| 3. The orchestrator | `orchestrator`: strut's generic workflow on its `agent` step, with Peel's prompt section and tools added. Answers from memory and your chats, makes automations, and starts or continues jobs | **Yes** | Jamie |
| 4. Jobs | strut's `job` workflow, unchanged: a folder per job, artifacts, `ask`, the job index | Yes, within one task | Hive's jobs |

Why the bridge is not the orchestrator: it would be a second agent loop
in Rust (model calls, history, compaction, prompts) beside strut's; its
conversation would sit outside the strut data a backup or handover moves;
and text from other people's chats would reach a model in the process that
holds the agent's keys.

Why every message is not a job turn: `job` always has bash, file editing
and the web (its built-ins are always on, and a host can only add tools).
On your Mac that bash could read Peel's database around the device
requests and their cards. And "when is Kate's birthday?" does not need a
job folder. The orchestrator stays small; jobs do the heavy work, as in
Hive.

## 1. The agent loop as a strut workflow

### What strut already gives

strut's core `agent` step (`src/steps/core/agent.ts`) is the loop. What
the front agent needs is there:

| Need | strut today |
|---|---|
| Tools that are steps | `agentTools`: registry step types as LLM tools, globs allowed (`memory/*`); each call emits a nested run event |
| No coding tools | `toolFilter: ['none']` turns off the built-ins (bash, edit, search); only `agentTools` remain |
| One long conversation | `session`: a thread per id in `sessions/<id>/` (`FileSessionStore`, `src/session-store.ts`), one turn at a time (`session_busy`), a failed turn appends nothing |
| Compaction | Built (strut `plans/compaction.md`): at `STRUT_COMPACT_AT` of the window the thread gets a summary boundary; the whole thread stays on disk |
| A structured reply | `schema`, as the `job` workflow uses for `text`, `artifacts` and `ask` |
| Knowing a run ended | `POST …/run` with a `callback` gets `run.end` (`createStrut.ts`), resumed runs included |
| The model key | Already in strut's secret store: Peel writes the model and its key there for system automations (`AutomationsClient.setModel`: `STRUT_DEFAULT_MODEL` and the provider's key, such as `ANTHROPIC_API_KEY`) |

Three gaps, each a small strut change, merged as strut#198 (PR S1
below). A session's system prompt stays fixed by its first turn
(`system.md`, "never rewritten"): refreshing it at compaction
(`systemAtCompaction`) was tried and deferred (Sessions below, open
question 10).

1. **A tool can't end the turn.** strut's elicitation stops the builder
   chat on a tool result that asked (`stepAsked`); the `agent` step has no
   such stop for `agentTools`. strut#198 adds one: a step that returns
   its output wrapped in `withStop()` (a marker in `core.ts`, beside
   `withMedia`) ends the turn after that tool round. A `stop: true` field
   in an output means nothing. Needed for "Waiting for your Mac"
   (section 2) and approvals, so it is enforced in code, not by the prompt.
2. **Automations fire with no callback.** A scheduled run has no
   `run.end` target, so the bridge would never hear the result. Let an
   automation carry the same `callback` a launch takes. strut#198 keeps
   the URL in its own encrypted file (`automation-callbacks.json`), never
   in the secret store that every step can read.
3. **The summary must keep message references.** Peel's own summariser
   is told to keep chat ids, uuids and View links word for word
   (`Compaction.instructions`). strut's summariser already keeps "names,
   ids, paths, versions, numbers and exact wording" (`compaction.ts`), but
   the `agent` step adds `AGENT_RETAIN`, which is about files and
   commands. Let the step take its own retain text, so Peel's says chats,
   message uuids and View links.

Also to check in S1: that the `agent` step starts with `toolFilter:
['none']` on a machine without `git` and `rg` (its description says it
needs both, for the built-ins). It takes a `cwd`; the workflow gives it an
empty folder of its own.

### The `orchestrator` workflow

strut ships it and seeds it at boot, as it seeds `job`
(`src/job-seed.ts`): one version per content hash, so strut's UI shows it
and its runs, and a changed template publishes the next version. It knows
nothing about Peel. Its own tools are strut's: `memory/*`, `job/start`,
`job/continue` and the `job/*` reads. A host adds the rest and a section
of the prompt, as `createStrut({ job: { tools, system } })` does for
`job` today (the lab adds `pod/*`). Peel adds the device steps
(`sphinx/*`, `calendar/*`), the automation steps and its prompt section.

Most turns are not jobs. Like the Swift agent in the Agent chat today, the
orchestrator calls its tools inside the turn: "when is Kate's birthday?"
is one `memory/recall`, "what did I miss?" one `sphinx/unseen` to the
Mac. It starts a job only for work that needs files, the web or many
steps, and can have several going at once.

How Peel adds its part is open. `job`'s host delta is a `createStrut`
option, which suits a host that embeds strut; Peel runs strut as a bundled
server and installs workflows over HTTP today. *Recommended:* the bundled
server reads the host delta from a config file Peel writes at launch, so
there is one workflow name and strut's updates to the template still
reach Peel. The other way, Peel installing its own version of the
workflow, freezes the template at Peel's copy. Decided in PR 5.

```yaml
name: orchestrator
input:
  prompt:     { type: string }                  # the person's message, or an automation's prompt
  session:    { type: string, required: false } # the conversation's thread; none for an automation
  context:    { type: json, required: false }   # the host's line: time, time zone, device, automation name + since
steps:
  - id: dir
    type: job/dir                                # no job: the run's own artifact folder
  - id: turn
    type: agent
    config:
      cwd: "{{ dir.path }}"
      session: "{{ input.session }}"
      system: "{{ params.system }}"             # strut's text + the host's section; fixed by the session's first turn
      prompt: "{{ input.context.line }}{{ input.prompt }}"  # "Thu 16 Oct 14:02, Europe/London. "
      toolFilter: [none]
      agentTools: "{{ params.tools }}"          # strut's + the host's
      model: "{{ params.model }}"
      cacheTtl: 1h
      schema: { text, artifacts, ask? }         # job's reply shape; tool rows come from the run's events
  - id: result
    type: pack                                   # text, artifacts, ask at the top, as job's output
```

- **The reply** has `job`'s shape (`src/workflows/job.yaml`): `text`, the
  `artifacts` it produced (a file, an image, a link, short inline
  content) and an optional `ask`. One shape for the orchestrator and its
  jobs, so the bridge and the Mac handle both the same way. Its files go
  in its run's own folder (`job/dir` with no job), so `run.end` resolves
  its artifacts as it does a job's (tested in S2); a job's go in the job's.
- **The system prompt** is today's, from `AgentSetup.systemPrompt` and
  the sections it adds (`AgentMessageLink.instruction`,
  `SphinxTools.systemPrompt`, `sendPrompt`, `MemoryTools.systemPrompt`,
  `AutomationTools.systemPrompt`), moved into Peel's section of the
  prompt. Its
  `unattended` variant, which leaves out sending and scheduling, becomes
  the automation workflow's prompt; PR 7 puts a send section back for
  automations with a send grant. Two wording changes: the chats are "on your Mac", read
  by asking it, not "on this device"; and "if your Mac doesn't answer,
  say you are waiting for it and stop".
- **Memory steps.** The memory tools already call strut steps
  (`MemoryTools` names the verbs; `MemoryServer` posts to `/steps/memory/<verb>/run`). In the workflow
  they are `agentTools` directly: `memory/remember`, `recall`, `get`,
  `ontology`, `forget`, `merge`. The tool names change from Peel's
  (`read_memory` is `memory/get`); the prompt names them.
- **Sessions.** One agent DM is one session, compacted in place. See
  Sessions below. Automations run without a session, as today's headless run
  has no history: a second workflow, `peel-automation-run`, the same step
  with no `session` and the unattended prompt. (A missing `session` is a
  cold agent; an empty string is refused, `idProblem`.) Whether it stays a
  second workflow or becomes the orchestrator with the unattended prompt
  as a launch-time param is PR 5's call. Their `since` still comes from
  `{{ last.finishedAt }}`.
- **Compaction** is strut's, in place in the DM's one session. Peel's `Compaction` and `ContextWindow` stop
  being used for the DM once the switch is made.
- **The time.** `current_time` goes. The bridge stamps each turn's prompt
  with the time and your time zone (the Mac sends it with your message).
  Dates in a turn are then exact without a tool call.

### Sessions

**One contact, one continuous session** (Tom, 2026-10-16). One agent DM
is one strut session, `peel/agent-1/dm`. It never resets on a timer.
When it grows past strut's compaction mark, the `agent` step compacts it
in place (strut `plans/compaction.md`): older turns become a summary for
the model, and the recent ones stay word for word.

- **The system prompt** is fixed by the session's first turn. A new
  prompt reaches the DM only through `/new` for now. Refreshing it at
  compaction was built and deferred (strut#198); open question 10.
- **Older turns are kept** in the session record (`messages.jsonl`):
  compaction changes what the model is sent, not what is stored.
  Searching them is a later step, if real use needs it, beside the
  Ladybug memory.
- **`/new`** in the DM starts a fresh session. The bridge handles it
  (sphinx#382): it moves to the next id (`peel/agent-1/dm-2`, `-3`, …)
  and confirms in a short reply; a redelivered `/new` never moves it
  twice. The DM itself goes on as one thread.
- **Jobs keep their own sessions** (a job's thread is its job id), so a
  job is continued with `job/continue` whatever the DM's session is.

This is what Hermes Agent and OpenClaw do. Both keep one continuous
session per chat and compact it, and both moved away from time-based
resets:
[Hermes, messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging),
[Hermes, context compression and caching](https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching),
[OpenClaw, sessions](https://docs.openclaw.ai/concepts/session).

### Where each Swift tool goes

| Today (Swift, `PeelAgent`) | Effect | Phase 1 |
|---|---|---|
| `current_time` | read | The turn's context line (above) |
| `get_contacts_and_tribes` | read | Device request `chats.list` (`sphinx/chats`) |
| `read_recent_messages` | read | Device request `chats.read` (`sphinx/read`) |
| `read_unseen_messages` | read | Device request `chats.unseen` (`sphinx/unseen`) |
| `read_threads` | read | Device request `chats.threads` (`sphinx/threads`) |
| `search_messages` | read | Device request `chats.search` (`sphinx/search`) |
| `send_sphinx_message` | send | Device request `send` (`sphinx/send`), the card on the Mac |
| `remember`, `forget_memory`, `merge_memory` | write | strut's `memory/*` steps |
| `recall`, `read_memory`, `memory_ontology` | read | strut's `memory/*` steps |
| `list_automations`, `preview_schedule` | read | strut steps over strut's automation store |
| `create_automation`, `update_automation`, `delete_automation`, `run_automation_now` | send (asks) | strut steps that first send an `approve` device request; they act only on "allow" |
| Calendar (none today; jobs-architecture P4 planned it) | read, send | Device requests `calendar.*` (`calendar/*`), new in Phase 1 |
| (new) `start_job`, `continue_job`, as in Hive | act | strut steps `job/start` and `job/continue`: launch `job` detached with the bridge as its `callback`, and return the job id at once. `job/list`, `job/get`, `job/read` exist already |

The step names `sphinx/send` and `sphinx/read` are the ones
[automations-and-jobs.md](automations-and-jobs.md) already uses, so `job`
gets the same steps later with no rename.

**Who publishes the device steps.** Peel, as it publishes
`peel/run-automation` today: each is about 20 lines that post to the
bridge on loopback with a token from strut's secret store. They mirror
Peel's device contract, so they ship with Peel. The automation steps are
generic and go upstream to strut, as
[automations-and-jobs.md](automations-and-jobs.md) decision 3 already
says for `meta/create-automation`.

### What stays in Swift

On the Mac, AgentKit shrinks to the client side: the approval gate and
its rules (`ApprovalGate`, `ApprovalRules`), the cards, the device-request
handler, and the Sphinx read and send code it reuses (`SphinxTools`,
`SendTool`'s plan). The loop (`AgentLoop`, `AgentSession`'s turns, the
providers, `Compaction`) is removed in the last PR, once nothing calls it.

## 2. The device channel

strut cannot read your chats, send as you, or use Calendar: those need
your keys and EventKit, which only your devices hold. So a step asks a
device, in the agent's DM, and waits.

### Two kinds of message in the DM

| Kind | From | Content (what the official apps show) | `metadata.peel` |
|---|---|---|---|
| **Talk** | You or the agent | Markdown, as written | Absent, or small extras (the reply's tool rows, an automation's name) |
| **Control** | Either | One short readable line | One versioned JSON envelope |

Every Sphinx message has a `metadata` string (`sphinx/src/msg/mod.rs`,
`pub metadata: Option<String>`). Peel already puts `{"tz": …}` there
when a chat's time zone switch is on (`TimeZones.swift`, an offset such
as `GMT+1`). Control messages add a `peel` key beside it. Today
`TimeZoneOffset.setting` writes or removes the whole metadata, so a
resend would drop `peel`: PR 1 makes it merge keys.

```json
{ "tz": "GMT+1",
  "peel": { "v": 1, "op": "request", "id": "r_7Hq…", "device": "mac-3f2a…",
            "kind": "chats.unseen", "args": { "since": "2026-10-16T08:00:00Z" },
            "not_after": 1760610000 } }
```

The content is the fallback the official apps show, for example
"Peel asked your Mac to read your unread messages". Peel never shows a
control message as a bubble: it draws a card or a quiet line, or nothing.

This replaces the `BotCmd` / `BotRes` types (24, 25) that
[phases/07-iphone.md](phases/07-iphone.md) planned. Type 0 with metadata
needs no spike: Peel already sends and reads metadata, and the official
apps already show the content.

### The envelope

| `op` | Direction | Fields | Meaning |
|---|---|---|---|
| `request` | agent → you | `id`, `device`, `kind`, `args`, `not_after` | Do this |
| `ack` | you → agent | `re` | Stored on the device; working on it |
| `result` | you → agent | `re`, `status`, `result?`, `error?` | Done. `status`: `done`, `denied`, `expired`, `failed`, `unknown` |
| `cancel` | either | `re` (a request) or `run` (a turn) | From the agent: the run no longer needs the request. From you: Stop this turn |
| `status` | agent → you | `run`, `state`, `text` | A line for a person: "Waiting for your Mac", "Waiting for your approval" |

`v` is 1. A device that sees a `v` it does not know answers `failed` with
`unsupported`, so an older Peel never guesses.

### Request types

| `kind` | Args | Effect | On the Mac |
|---|---|---|---|
| `chats.list` | — | read | `SphinxTools.contactsAndTribes` |
| `chats.read` | `chat`, `since?`, `limit?`, `thread?` | read | `read_recent_messages`, `read_threads` |
| `chats.unseen` | `chat?`, `since?` | read | `read_unseen_messages`. One request covers every chat, so "what did I miss" is one round trip |
| `chats.search` | `q`, `chat?`, `limit?` | read | `search_messages` |
| `send` | `chat`, `text`, `thread_uuid?`, `reply_to_uuid?`, `max_price_sats`, `automation?` | send | `SendTool`'s plan and `Engine.sendText`, behind the card or a grant (below) |
| `calendar.events` | `from`, `to`, `calendars?` | read | EventKit; the first use asks for macOS Calendar access |
| `calendar.create`, `calendar.update`, `calendar.delete` | the event, or its id | send | EventKit, behind the card |
| `approve` | `intent` (a `ToolIntent`) | — | The card only; the answer is the result. Used by strut steps that act on the brain (automations) |

Results are what the Swift tools return today (`ChatData` text, with the
markers that say other people wrote it), so the model reads the same
thing.

### Sends as you, with the 2026-10-15 safeguards

Two cases, one rule: **the device that holds your key decides.** The
brain never sends as you and never holds a grant to.

| Case | Who approves | What the Mac checks before sending |
|---|---|---|
| **In conversation** ("reply to Sam") | You, on the card in the DM on the Mac, as today | The exact text and chat on the card; the tribe price; "Always allow" rules in `ApprovalRules` as today |
| **From an automation** ("post to Hive at 13:03", "every Monday recap Hive") | You, once, on the automation's create card. The Mac writes a **send grant**: the automation's id, its chats, its sats cap per message | The request names the automation; the chat is in its grant; the price is under the cap; the text starts with `[Agent] ` (the Mac adds it); the grant isn't revoked or the automation deleted |

That is the three safeguards of
[automations-and-jobs.md](automations-and-jobs.md) decision 1 (the chat
list, the sats cap, the `[Agent]` prefix), enforced on the Mac. The
fourth, "each send is in the run's history", holds twice: in strut's run
and in the DM's result message.

Send grants live in `agent.sqlite` beside `ApprovalRules`, as records. A
grant is only made from your own click on the Mac. Account › Agent lists
them with Revoke.

### Approvals

- **Where:** a card in the DM on the Mac, drawn from the request. The
  `ToolIntent` is worked out on the Mac from the request (for a send) or
  carried in it (for `approve`). What runs is what the card showed.
- **Once, always, deny:** as today. "Always allow" is never offered for
  anything with a cost or a grant.
- **Expiry:** a card past `not_after` closes itself as `expired`, and a
  late click does nothing. A decided card answers once; a second click,
  or a replayed request, gets the stored answer.
- **The phone and the official apps** see "Waiting for your approval on
  your Mac" (the request's fallback). Deciding on the phone is Phase 2.

### Waiting, timeouts and "Waiting for your Mac"

A step posts the request to the bridge and waits on that HTTP call:

1. The bridge sends the request and waits for an `ack`.
2. **Ack within 10 s:** it waits for the result, up to the step's wait
   (30 s for reads, the card's expiry for anything that asks). The common
   case: the Mac answers in about two broker round trips, and the tool
   result goes back to the model inside the same turn.
3. **No ack in 10 s, or no result within the wait:** the step returns
   `pending`, wrapped in `withStop()` (S1). The turn ends; the agent's text says
   what it is waiting for. The bridge sends a `status` "Waiting for your
   Mac".
4. **The result comes later**, before `not_after`: the bridge starts a new
   turn in the same session whose prompt is the result, marked as from
   the Mac. The conversation goes on where it stopped.
5. **Past `not_after`:** the Mac answers `expired` and does nothing. The
   bridge tells the run, and the agent says so.

| Request | Step waits | `not_after` |
|---|---|---|
| Reads (`chats.*`, `calendar.events`) | 30 s | 12 hours, as Talk in 07-iphone |
| A send or Calendar write in conversation | Until the card's expiry | 1 hour |
| A send from an automation | 60 s | The fire time + 10 minutes: "post at 13:03" never posts at 18:00 |
| `approve` | Until the card's expiry | 1 hour |

In Phase 1 the bridge and the Mac are one machine, and the bridge stops
when the account closes or Peel quits. So "Waiting for your Mac" means
Peel's own connection is down (or a request outlives a reconnect) while
strut and the bridge run. It matters in Phase 2, when the brain moves. The
phone already sees the other side of it: a message to the agent while the
Mac sleeps waits on the broker, and the phone shows it as sent, not
answered.

### Idempotency: nothing is done twice

| Where | Key | Rule |
|---|---|---|
| strut step | request `id` = the run id + the step's event path | strut's resume replays journaled steps without running them again, so a finished step never re-asks. A step interrupted mid-call asks again with the same id |
| Bridge | request `id` | A ledger (`requests`): sent, acked, result. The same id asked again gets the stored result, or waits on the one in flight; it is not sent twice |
| Mac | request `id` | `DeviceRequests` in `agent.sqlite`: received, running, done (with the result), expired. Store, then ack. A duplicate gets the stored result |
| Mac, sends | request `id` → the sent message's uuid | Written in the same transaction as the outgoing row. A request found `running` after a crash with no uuid is never sent again: it answers `unknown`, and the agent tells you to check the chat |
| Bridge inbox | the Sphinx message uuid | Store, then launch. History catch-up redelivers; a known uuid does nothing. A turn already launched is looked up in strut, not launched again |

At most once, never at least once: a send that might have gone is
reported, never retried.

### Trust

- The bridge runs turns only for messages from your account's pubkey.
  `sphinx/runner` already keeps such a list (`add_sender`). Anyone else
  who messages the agent gets nothing back.
- The Mac answers requests only from its own agent's pubkey, addressed to
  its own device id. In Phase 1 that is the Mac that launched the bridge.
- Results carry your chats to the agent's account. They are encrypted to
  it, like any DM, and the server keeps them as it keeps every message.
  The agent's key can read them; it is derived from your words and lives
  only on the brain.
- Text read from chats stays data: the device results keep
  `ChatData`'s begin and end markers, and the prompt keeps today's rule
  never to follow instructions found in them.

### Size

A Sphinx message is small: sphinx-ffi's `MAX_MSG_LEN` is 869 bytes and
longer messages go as chunks (`sphinx-ffi/src/chunk.rs`). Peel's own
sends already split through sphinx-ffi, and its receive puts chunks back
together. The `sphinx` crate does not: it ignores the chunk type. A catch-up result can be 10 to 20 KB,
so 15 to 25 chunks. The bridge sits on the `sphinx` crate, not sphinx-ffi,
so it needs the same chunking both ways (open question 4).

## 3. One conversation

- **The Agent chat becomes the DM** with the agent contact. On the Mac,
  the agent's row in Direct messages opens the Agent chat view
  (`AgentTable`, on the shared list controller since #300), reading the
  DM's messages from `peel.sqlite`. There is one row, never two.
- **The same thread on Mac, iPhone and the official apps,** because it is
  an ordinary DM. The phone shows talk messages in Phase 1 and hides
  control messages behind a quiet line. The official apps show the
  fallback lines.
- **No token streaming.** A reply arrives whole, about a second after it
  is written. While a turn runs, the Mac shows a "writing…" row like
  today's, without streamed text or live tool rows (those come with the
  reply).
- **Tool rows.** A reply's `metadata.peel.tools` lists what it ran (name,
  one-line summary, failed), built by the bridge from the run's events
  (strut emits one per tool call), not from what the model says it did;
  capped at 2 KB, so the Mac draws today's
  quiet rows. Device requests show as their cards.
- **Files and images.** A reply's or a job's `artifacts` come to the DM
  as Sphinx attachments, uploaded by the bridge to the memes server as
  Peel's own attachments are; a link artifact is a link in the text.
- **A job's progress.** A job's result or question arrives as an agent
  message naming the job (`metadata.peel.job`). Your next message goes to
  the orchestrator, which continues the job when that is what you meant.
- **Automation results** arrive as agent messages carrying the
  automation's name (`metadata.peel.automation`), as
  `AgentSession.deliver` titles them today, with a notification.
- **Stop.** The Mac's Stop sends a `cancel` for the turn; the bridge
  cancels the strut run (`POST /workflows/orchestrator/runs/:runId/cancel`, run control).
- **Old history.** `agent.sqlite`'s conversation stays readable on the
  Mac under "Earlier, on this Mac", read only. It is not migrated into the
  DM or the strut session. `agent.sqlite` itself stays: it holds the
  approval rules, the send grants and `DeviceRequests`.

## 4. The bridge

A Rust process that holds the agent's Sphinx account, bundled in Peel.app
and started by Peel when the account opens, as `BundledStrut` starts
strut. It stops when the account closes or Peel quits (brain mode is
off by default).

### What it does

| Job | How |
|---|---|
| Holds the agent's account | The derived agent seed set once over runner's admin call (`POST /seed`, which refuses to replace a seed); kept in runner's redb store under Peel's data folder |
| Inbox | Every message from your pubkey: stored, then acked to Sphinx, then handled in order, one turn at a time per session |
| Turns | The workflow Peel names (`BRIDGE_WORKFLOW`; runner's default is `peel-agent`, Peel sets `orchestrator`): `POST /workflows/<it>/run` with `prompt`, `session`, `context` and a `callback` to itself; `run.end` (or a poll, if the callback is missed) → the reply as a talk message. An unsent reply is retried up to `MAX_TRIES` (5) |
| Device requests | `POST /bridge/device/request` on loopback (token from strut's secret store): sends the request, keeps the ledger, returns the result or `pending`. It checks only the shape: `kind` is a bounded token, and the Mac refuses kinds it doesn't know, so a new kind needs no Sphinx release |
| Results | A `result` from your pubkey resolves its request; a late one starts a new turn (section 2) |
| Cancel | Your `cancel` → strut's `POST /workflows/:name/runs/:runId/cancel`; with no run id, it stops the turn in flight |
| Health | `GET /bridge/health`: connected to the broker, last message, inbox depth |

Peel's side is about one file, `BundledBridge`, beside `BundledStrut`: find
the binary in the bundle, start it on loopback with a port and a token,
pass strut's URL and key, set the seed and your pubkey, stop it on quit.

### Evan's answers

**Where it lives: runner** (sphinx#382, merged). Peel stages runner's
binary beside strut (`scripts/stage-bridge.sh`) and starts it with the
settings runner's README lists (`BRIDGE_STRUT_URL`, `BRIDGE_TOKEN`,
`BRIDGE_DEVICE`, `BRIDGE_WORKFLOW`, `BRIDGE_SESSION`).

**The agent's seed: `agent_seed(seed, n)`** (sphinx#383), HKDF-SHA256
with info `agent seed <n>` and no salt, in the Sphinx core with fixed
test vectors. sphinx-ffi exposes it from v0.8.39 (sphinx-rs#100). The
bridge never derives anything: Peel calls `agent_seed` with your seed
and `n = 1`, and posts the result to runner's `/seed`. Your words never
reach runner.

- **Dev builds** use a throwaway account on the local stack until Peel's
  pin reaches v0.8.39; after that PR 4 can use the real derived account,
  behind the preview.
- **Funding is settled.** An agent with 0 sats can accept its owner's key
  exchange from what the exchange pays it: you spend 3 sats and the agent
  keeps 1 (the runner spike). Nothing needs funding first.

Changing the agent's account later loses only the DM's Sphinx history,
not the conversation: the conversation lives in strut (its sessions and memory). So a temporary
account is cheap to replace (open question 2).

## 5. Automations, jobs and connectors

With the loop in strut, most of [automations-and-jobs.md](automations-and-jobs.md)'s
build order gets smaller.

| Build step | Before | Now |
|---|---|---|
| — The fire path | strut fires `peel-automation`, whose step posts to Peel's `AutomationServer` on loopback; Peel runs a headless Swift loop | **Goes.** Automations fire `peel-automation-run` in strut directly, with no session. `AutomationServer`, its token and port in strut's secrets, `peel/run-automation` and the headless run are removed |
| 1. Sends from automations | `send_sphinx_message` in the headless Swift run, limited to approved chats | **Simpler.** The `send` device request with a send grant (section 2). Same card, same three safeguards, enforced on the Mac |
| 2. Jobs (C) | Peel's `start_job` / `continue_job`, `Job` records in Peel, callbacks to Peel, Needs you cards (jobs-architecture P1–P3) | **Smaller.** The orchestrator is in strut, so it starts `job` itself with `job/start` (PR S2). Not with `meta/run-workflow`, which waits for the child run and would hold the DM's session (`session_busy`) for the whole job: `job/start` launches it detached, with the bridge as its `callback`. Job records stay in strut's job index. A job's `ask` comes back by `run.end` to the bridge and lands in the DM; your reply goes to the orchestrator, which calls `job/continue`. Peel keeps no job records. strut's J1 (`effect` + the approval stop) is still needed for connectors that act |
| 3. `sphinx/read` for `job` | A new loopback path from strut to Peel | **Disappears.** Grant `job` the same `sphinx/*` device steps |
| 4. Authoring (D) | strut | Unchanged |
| 5. Home server | The Sphinx bridge, the agent's identity, claims for sends as you | **Mostly done by Phase 1.** The bridge and the identity are built; the device channel is the claim. What is left is running strut and the bridge without Peel: Phase 2 |

Also gone or replaced:

- **"Automations by pull"** ([peel-brain.md](peel-brain.md) build step 3,
  open question 4): replaced by device requests over Sphinx. strut needs
  no "waiting for a client" run state.
- **07-iphone's remote track** (B1–B4, `RemoteInbox`, a second PeelCore
  engine on the brain, `BotCmd` / `BotRes`): replaced by the bridge, its
  inbox and the envelope here. B5–B7 (jobs on the phone, the phone's
  cards, notification actions) build on this in Phase 2.
- **Connectors** stay strut steps, as jobs-architecture.md planned, with
  their tokens in strut. Calendar was the exception there (EventKit in
  Peel's loop); it is now a device request, so a `job` can be granted it
  too.

## 6. PR plan

One PR per step, in order. Each is usable on its own. **The rule while
building:** the Swift loop stays the Mac's agent until PR 10. Catch-ups,
automations and the Agent chat keep working on it. Everything new sits
behind one setting, Account › Agent › "Run in strut (preview)", off by
default, shown only in dev builds until PR 10.

Risk tiers are AGENTS.md's ("How a change ships"), as `scripts/risk.sh`
would rank the files each PR touches, raised where it sends or holds
keys. strut PRs follow strut's own review; the tier is what this table
would give the same change.

| # | Repo | What | Done when | Risk | Waits on |
|---|---|---|---|---|---|
| 0 | peel | This doc, foundation.md's answers, the PLAN.md row | Tom agrees | low | — |
| S1 | strut | The three `agent` step gaps: a tool output that stops the turn (`withStop()`), a `callback` on automations (in its own encrypted file), a retain text of its own for compaction; the no-built-ins check. `systemAtCompaction` was deferred | Tests for each; an `orchestrator`-shaped workflow runs two turns in one session against a stand-in model; Hive unaffected (all opt-in) | medium | — (merged: stakwork/strut#198, replacing #194) |
| B1 | bridge | The bridge: seed and sender, the one workflow it launches (named by Peel), one session per DM, kept until `/new` starts a fresh one (sphinx#382), store-then-ack inbox, a strut run per message with the callback, the reply as a talk message, the request ledger and `POST /bridge/device/request`, late results as new turns, `status` lines ("Waiting for your Mac"), `cancel` to strut, the turn's time stamp, tool rows from run events, chunking both ways, `GET /bridge/health` | On the local stack: a throwaway account messages the bridge's account and gets a model reply from strut; a request round-trips to a stub device; a redelivered message and a repeated request do nothing twice | high (keys, untrusted input) | — (done: stakwork/sphinx#382, runner) |
| 1 | peel | The control envelope in PeelCore: encode and decode `metadata.peel`, keep `tz`, hide control messages in the Mac's and the phone's message lists behind a quiet line, never as a bubble | Unit tests on the envelope; a control message from a test account shows as a line on Mac and phone and as text in the official app; nothing else in the list changes | high (message list, untrusted input) | — |
| 2 | peel | `DeviceRequests` on the Mac: the table, the handler for `chats.*` (reusing `SphinxTools`), `ack`/`result`/`expired`, dedupe, trust (agent pubkey, device id). Reads only | Journey on the local stack: a throwaway agent account sends `chats.unseen`; the Mac answers once, a repeat gets the stored result, a wrong sender gets nothing | high (untrusted input, storage) | 1 |
| 3 | peel | Sends and approvals by request: `send` and `approve` with the card in the DM, expiry, `unknown` after a crash, send grants and their list in Account › Agent (shown only with the preview on) | Journey: a send request shows a card; allow sends once; a repeat after allow sends nothing; an expired card does nothing; a kill between send and record answers `unknown` | high (sends, money) | 2 |
| 4 | peel | Launch the bridge: stage runner beside strut, `BundledBridge`, the agent account behind the preview setting (a throwaway on the local stack until the pin reaches v0.8.39, then `agent_seed`) | A dev build with the setting on starts strut and the bridge, and the agent contact appears in Direct messages; off, nothing starts | high (keys) | B1 |
| S2 | strut | `job/start` and `job/continue`: launch `job` detached with a `callback`, return the job id; the orchestrator's (non-job) run returns `artifacts` the same way `job` does in the callback | Tests; an agent step granted them starts a job, ends its turn, and the job's `run.end` reaches the callback with resolved artifacts | medium | — (stakwork/strut#195) |
| 5 | peel + strut | strut seeds the generic `orchestrator` (its own tools: `memory/*`, `job/start`, `job/continue`, the `job/*` reads) with a host delta the bundled server can read; Peel supplies its part (today's prompts as its section, the `sphinx/*` steps it publishes) and `peel-automation-run`; strut's automation steps upstream (`automation/list`, `preview`, `create`, `update`, `delete`, `run-now`), the acting ones behind `approve`; Peel's `sphinx/*` steps end a turn with `withStop()` when the Mac doesn't answer; strut#196 is being reworked to match strut#198 | Preview on: "what did I miss?" in the DM reads through the Mac and answers; "remember…" writes to memory; a new automation shows a card before it exists | medium | S1, 2, 3, 4 |
| 6 | peel | The Agent chat is the DM (preview on): `AgentTable` reads the DM, Stop sends `cancel`, tool rows from metadata, cards for requests, "Waiting for your Mac", "Earlier, on this Mac" for the old history | Preview on: one agent row; type, see the reply, approve a send, stop a turn, read the old history; preview off: today's Agent chat unchanged | high (message list) | 5 |
| 6b | peel + bridge | Jobs and files from the DM: grant the orchestrator `job/start`, `job/continue` and the `job/*` reads; the bridge sends job results, questions and artifacts into the DM, files as attachments | Preview on: "research flights to Lisbon" starts a job and the chat stays free; its result and a screenshot arrive in the DM; answering its question continues the same job | high (attachments, untrusted input) | S2, 6 |
| 7 | peel | Automations on `peel-automation-run`: new ones are made on it; turning the preview on moves existing ones (same schedule and prompt, workflow changed), turning it off moves them back; sends from automations with grants (automations-and-jobs step 1) | Preview on: the Hive test posts at the minute it said, `[Agent]` first, nobody at the Mac; the weekly report lands in the DM; preview off: the same automations run on `peel-automation` as before | high (sends) | 5, 3 |
| 8 | peel | Calendar by request: `calendar.events` and the three writes, the Calendar access prompt and usage string, writes behind the card | "What's on Thursday?" answers from Calendar; "move it to 3" shows a card and moves it once; denied access says so | high (writes, a new permission) | 5 |
| 9 | peel | iPhone: the agent DM shows talk and hides control (on PR 1's envelope), "Waiting for your approval on your Mac" | From the phone, with the Mac awake: message the agent and get the answer in the same thread as the Mac | medium | 1, 6 |
| 10 | peel | **Turn it on.** The agent's account from `agent_seed(seed, 1)` (sphinx-ffi v0.8.39), checked against the core's test vectors; first-run setup ("Give your assistant its own account", one invite, the key exchange: you spend 3 sats, the agent needs none); the preview becomes the default; the Swift loop stays one release as the fallback | Tom uses it on his real account for a week: catch-ups no slower than today, automations fire, nothing sent twice; turning it off returns to the Swift loop | high (keys) | The sphinx-rs pin at v0.8.39 |
| 11 | peel | Remove the Swift loop: `AgentLoop` and the providers out of the app, `AutomationServer`, `peel-automation` and `peel/run-automation`, `AgentSession`'s turns and compaction; AgentKit keeps the client side | Builds; the journeys from 2, 3, 5, 6, 7 pass; nothing calls the removed code | medium (over 400 lines) | 10, plus a week of use |

```
now       S1 ✓  B1 ✓  S2 ✓  1
then      2    4
then      3
then      5
then      6    7    8    9
then      6b
once the pin is v0.8.39: 10, then 11
```

S1, S2 and B1 are merged (strut#198, strut#195, sphinx#382).
PRs 2 and 3 follow PR 1 in turn, since each builds on the one before.
PR 1 is the only one that changes what ships before the preview: control
messages hidden in the lists, and the time zone setting merging keys. PR 4 stages runner as it is merged.

**Measuring "catch-ups don't get worse".** PR 5 adds a timing to the
Agent chat's journey: "what did I miss" on the same fixture account, on
the Swift loop and on strut. PR 10 does not ship if strut is more than 3
seconds slower (open question 3).

## 7. Open questions

1. **Hidden control messages are still messages.** The official apps show
   every request and result as a fallback line, and the server keeps
   them. *Recommended:* accept it for Phase 1, with one-line fallbacks
   ("Peel read your unread messages on your Mac"). If it is too noisy,
   send results with no content where the official apps allow it, or
   delete them for everyone after use (Peel already deletes for
   everyone).
2. **Dogfood before the real account?** Settled: once Peel's pin is
   v0.8.39, the preview uses the real derived account, recoverable from
   your words, so no temporary account is needed.
3. **A loopback shortcut on the same Mac.** In Phase 1 the bridge and the
   Mac are one machine, yet requests go through the broker: about two
   round trips each. *Recommended:* Sphinx only, one path, as
   peel-brain.md argues for automations. Batch reads (`chats.unseen`
   covers every chat). Add a loopback path only if PR 5's timing misses
   the 3-second budget.
4. **Big results.** A catch-up can be 15 to 25 chunks. *Recommended:*
   chunk both ways in the bridge, cap a result at 32 KB (the tools
   already cap lines), and keep an encrypted memes-server upload as the
   later answer if real use needs more.
5. **Where send grants live.** On the Mac (Phase 1), they don't reach the
   phone or a second Mac. *Recommended:* keep them on the device that
   sends. When the phone answers requests (Phase 2), a grant made on one
   device is copied to the others as a control message signed by your
   account, never stored on the brain.
6. **Which session a late result joins.** A result that arrives after
   the turn ended starts a new turn in the same session. If you have
   moved on, the agent answers an old question. *Recommended:* the new
   turn's prompt says when the request was made, and the agent asks
   before acting on anything older than an hour, as 07-iphone's "stale
   work asks first".
7. **The automation steps' home.** Upstream strut (generic) or published
   by Peel. *Recommended:* upstream, with the approval as a hook a host
   supplies, so Hive can gate its own way. Peel's hook is the `approve`
   request.
8. **Two Macs on one account.** Only the Mac that runs the bridge answers
   (requests carry its device id). The other Mac shows the DM like the
   phone. *Recommended:* fine for Phase 1; device claims are Phase 2.
9. **The bridge launches the orchestrator, not `job`.** Settled: the
   spike's sketch now posts each message to the orchestrator (named
   `peel-agent` there, `orchestrator` since decision 12) on the DM's
   session, and one `run.end` route takes the orchestrator's replies and
   the jobs' results (#307).
10. **A new prompt for a long-lived DM.** A session keeps its first
    prompt, so a revised orchestrator prompt reaches the DM only through
    `/new`. strut deferred `systemAtCompaction` (strut#198). Evan's
    suggested shape: a changed prompt forces a compaction at the start of
    the next turn, with the new prompt on that turn's line, so the commit
    stays atomic. *Recommended:* take Evan's shape when prompt changes
    become frequent; until then, `/new` after a Peel update that changes
    the prompt, said in the release notes.
