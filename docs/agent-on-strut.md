# Phase 1: the agent is a contact

Last updated 2026-10-19. **Design, PR plan and what was built** (the
"Built: PR n" notes in section 4). PRs 1 to 7 are merged (#311, #319,
#321, #322, #323, #325, #324) with PR 6's follow-ups (#326, #333), and
PR 8 (Calendar) is dropped from Phase 1 for now (Tom, 2026-10-18;
decision 16). PR 10 (#334, merged) makes strut the agent, with no
switch; PR 11 removes Peel's own Swift loop, merging once Tom has used
PR 10 on his account for a day or two. It turns [foundation.md](foundation.md)'s answers into
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
it doesn't, the run says "Waiting for your Mac". Since PR 10
(2026-10-18) this is the agent in every build, with no switch back; PR
11 removes Peel's own loop.

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

Later:

16. **Calendar is dropped from Phase 1 for now** (Tom, 2026-10-18). PR 8
    is not built in this phase; the `calendar.*` requests below stay the
    design for when it comes back. Nothing else in Phase 1 waits on it.

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
 │ DeviceRequests (peel.sqlite)  │      │ requests hidden or a line  │
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

On the Mac, AgentKit is the client side: the approval gate and its rules
(`ApprovalGate`, `ApprovalRules`), the cards, the device-request handler,
the Sphinx read and send code it reuses (`SphinxTools`, `SendTool`'s
plan), the connected model's key, and the earlier local chat, read only.
The loop, its model clients and its automation server went in PR 11
("Built: PR 11").

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
| `cancel` | either | `re` (a request), `run` (a turn), or neither | From the agent: the run no longer needs the request. From you: Stop this turn (with neither, the turn in flight) |
| `status` | agent → you | `run`, `state`, `text` | A line for a person: "Waiting for your Mac", "Waiting for your approval" |

`v` is 1. A device that sees a `v` it does not know answers `failed` with
`unsupported`, so an older Peel never guesses.

### Request types

| `kind` | Args | Effect | On the Mac |
|---|---|---|---|
| `chats.list` | — | read | `SphinxTools.contactsAndTribes` |
| `chats.read` | `chat`, `limit?`, `thread?` | read | `read_recent_messages`; with `thread`, `read_threads` on that thread |
| `chats.threads` | `chat`, `limit?` | read | `read_threads` |
| `chats.unseen` | `chat?` | read | `read_unseen_messages`. One request covers every chat, so "what did I miss" is one round trip |
| `chats.search` | `q`, `chat?`, `limit?` | read | `search_messages` |
| `diagnostics.latest` | — | read | Peel's newest crash record, redacted and trimmed (`DeviceReads`, docs/diagnostics.md); the chat's agent only, not an automation |
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
| Mac | request `id` | `deviceRequest` in `peel.sqlite` (PR 2): received, running, done (with the result; `expired` is a done status). Store, then ack. A duplicate gets the stored result |
| Mac, sends | request `id` → the sent message's uuid | Written, with the request marked `sending`, in the same transaction as the outgoing row; nothing is published before it. A request found `sending` after a crash is never sent again: it answers `unknown`, and the agent tells you to check the chat. One found `running` (its card was up) asks again (PR 3) |
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
- **A send grant trusts the request's `automation`.** The Mac cannot tell
  an automation's run from a conversational turn that names the same id,
  so a grant is in effect "the agent may post to these chats, under this
  cap, with `[Agent]` first". The strut steps must set `automation` from
  the run itself, never from the model's input (PR 5, PR 7), and the Mac
  refuses a grant send that expires more than 15 minutes out, as no
  automation's does (PR 3).

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
  as words and a handle, never the file: where Peel's own strut shows it
  (`path` for a file, `app` for an app, stakwork/sphinx#391), opened in
  the web pane beside the chat ("Built: a deliverable opens beside the
  chat", 2026-10-23); a link artifact is a link. Changed from the plan of
  Sphinx attachments through the memes server, which the bridge never
  built: the file stays on the strut that made it, an org's read through to it, a later turn's newer version is
  what opens, and nothing but the handle crosses Sphinx. A device with no
  strut of its own shows the words; fetching the file for it, on request,
  through the memes server, is for later.
- **A job's progress.** A job's result or question arrives as an agent
  message naming the job (`metadata.peel.job`). Your next message goes to
  the orchestrator, which continues the job when that is what you meant.
- **Automation results** arrive as agent messages carrying the
  automation's name (`metadata.peel.automation`), as
  `AgentSession.deliver` titles them today, with a notification.
- **Stop.** The Mac's Stop sends a `cancel` for the turn; the bridge
  cancels the strut run (`POST /workflows/orchestrator/runs/:runId/cancel`, run control).
- **Old history.** `agent.sqlite`'s conversation stays readable on the
  Mac under "Old assistant chats (this Mac only)" (PR 11; "Earlier, on this Mac" before), read only. It is not migrated into the
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

- **Dev builds** use the real derived account, behind the preview (PR 4).
- **Funding: one invite.** The agent's answer to your key exchange costs
  it 3 sats and a ping, and the mixer forwards your exchange before it
  credits the exchange's own 5 sats, so an agent with 0 sats cannot
  answer (the spike's success was timing; corrected 2026-10-17). Peel
  makes a 10-sat invite from your account and passes its code with the
  agent's seed; the agent's first register redeems it
  (stakwork/sphinx#385).

Changing the agent's account later loses only the DM's Sphinx history,
not the conversation: the conversation lives in strut (its sessions and memory). So a temporary
account is cheap to replace (open question 2).

### Built: PR 4, the bridge launched (2026-10-17)

- **Staged and pinned.** `scripts/stage-bridge.sh <sphinx checkout>` builds
  runner from the commit `Vendor/runner.lock` names (git archive of that
  commit only, `cargo --locked` against `Vendor/runner.Cargo.lock`, since
  sphinx keeps no lockfile) into `~/Library/Caches/dev.peel.build/bridge`.
  The pin is sphinx master at the merge of stakwork/sphinx#385.
  `embed-strut.sh` puts it in `Contents/Bridge` in Debug builds only, and
  `sign-app.sh` signs it; a Release build never carries it.
- **The agent's account.** `Engine.agentAccount()` (PeelCore) derives agent
  1 with `agent_seed` and gives the bridge only that seed, the agent's
  pubkey, the owner, the device id and the broker; it prints, dumps and
  reflects without the seed. A server runner would reach otherwise than
  Peel (runner takes TLS from port 8883) is refused.
- **`BundledBridge`** (PeelAgent): picks a loopback port and trusts it only
  once runner's own output says Rocket launched there, then sends the seed.
  The admin and strut-facing tokens are made per launch and kept in memory
  only (nothing to keep in the Keychain: runner checks them only for that
  launch). Its environment is runner's settings and `TMPDIR`, nothing else
  of Peel's. `/seed` (409, already set, is fine), `/add_sender` with the
  owner, then `GET /bridge/health` until the bridge answers. Its store is
  owner-only in Peel's folder (a development profile's in its own), erased
  with the account. Stopped with the account, with strut, and on quit,
  and meant to go by itself if Peel dies: its stdin is a pipe only Peel
  holds (`RUNNER_EXIT_ON_STDIN_EOF`, added in stakwork/sphinx#385). With
  the runner pinned now it does not after a crash: its stdout, the pipe
  Peel reads, dies with Peel too, and runner's "stdin closed" log line
  panics on the broken pipe before it exits (a SIGTERM's shutdown log
  the same), so it keeps the store open and the next runner exits as it
  starts (`DatabaseAlreadyOpen`). Each start therefore first stops an
  orphan runner (parent launchd) on the same store (`DB_PATH`,
  `stopLeftovers`). Strut has no such hole: it logs with
  `console.error`, which drops write errors, and exits after 1.5 s
  whatever its close does.
- **First run** (`BundledBridge.setUp`), only from the person's own
  switch (a start on its own never pays to pair): an invite from the
  account (10 sats, once the server holds it), one per bridge store with
  its code kept there, so a retry uses the code runner already holds. The
  agent registers with it; runner's `GET /contact_info` gives its contact
  info (only the agent's own pubkey is taken, on every start) and its
  balance. Then the invite's sats are asked back: they return if the
  agent did not need it (an account registered before from the same
  words), and a redeemed one gets no answer and is set aside
  (`forgetInvite`); nothing is marked used on a guess. The key exchange
  goes only when the agent can pay its answer (4 sats), and set-up ends
  when the agent has answered. The invite skips the confirmation
  threshold: turning the preview on was the yes (since PR 10, Set up,
  which shows the cost).
- **The preview** (removed in PR 10). Account › Peel agent › "Run in
  strut" (dev builds, `agentOnStrut` in the build's defaults; the driver's
  `agent-on-strut` and `agent-off-strut`).
  On, it starts Peel's strut (a development profile's too) and the bridge
  beside it, with the workflow `orchestrator`; off, nothing of it starts
  and today's agent chat is unchanged. A failure is said under the switch.
- **Learned.** The spike's "a 0-sat agent answers" was timing: the mixer
  forwards the ContactKey before it credits its sats (corrected in
  `docs/research/runner-bridge-spike.md`); hence the invite.
- **Checked.** `BundledBridgeTests` (with the staged runner: seed, owner,
  health, tokens, exit on stdin EOF), `AgentAccountTests`, the journey
  `Journeys/Bridge` (real accounting: the agent answers the one key
  exchange, a message reaches a stub strut as an `orchestrator` run, a
  second set-up adds nothing, a start on its own never pairs, and after a
  restore the new invite comes back and only the 3 sats are spent), and
  `check-app.sh` on a development profile (off: nothing starts; on: strut,
  the bridge, the agent in Direct messages, idle near 0% CPU; off again:
  both stop).
- **Left for later** (the reviews, 2026-10-17): runner keeps the agent's
  seed in its store (Peel excludes the folder from backups; it could hold
  it in memory and have Peel send it each launch); its tokens and strut's
  key go in its environment (stdin would hide them from same-user `ps`);
  the strut callback carries the bridge token in its query; runner answers
  CORS `*` on loopback; Peel picks the port and frees it before runner
  binds it (a ready line with runner's own port would close that window);
  runner takes TLS from port 8883 only.
- **Next.** PR 5 seeds `orchestrator` and gives strut the bridge's token;
  the Mac's device-request trust (`setDeviceAgent`, PR 2) is set to the
  agent's pubkey once both are in.

### Built: PR 5, Peel's half of the orchestrator (2026-10-18)

- **How Peel adds its part: a host config file** (the call left open in
  section 1). `BundledStrut` writes `host-config.json` in strut's data
  folder at each launch and names it in `STRUT_HOST_CONFIG`; strut's
  bundled server reads it at boot and seeds `orchestrator` with it, so
  strut's later changes to the template still reach Peel. It holds Peel's
  tools (the five reads, `sphinx/send`, the six `automation/*` steps),
  Peel's prompt section, `model: null` (no pinned model: the turn runs on
  the connected one, `STRUT_DEFAULT_MODEL`, which Peel already keeps
  current), and the automation steps' workflow and approval step.
- **The prompt section** is today's prompt with strut's tool names, one
  text for both loops: `SphinxTools.Names`, `MemoryTools.Names` and the
  send and automation prompts take the names, `.swift` for today's loop
  and `.strut` for this one. The chats are "on their Mac, by asking it";
  dates come from the time the message starts with; and a request the Mac
  has not answered means "say you are waiting for their Mac, and stop".
- **The `sphinx/*` steps** (`DeviceStep`): Peel publishes them over
  `POST /steps` before the bridge starts (`installOrchestrator`), then
  the bridge's port and token in strut's secret store once it runs
  (`useBridge`) (`PEEL_BRIDGE_PORT`,
  `PEEL_BRIDGE_TOKEN`, new each launch, taken out again when the preview
  turns off). Each posts one request to the bridge on 127.0.0.1 with id
  `<run>/<hash of its path, kind and args>`: a resumed call asks the same
  question and gets the stored answer, and a stored answer (an "allow"
  above all) never stands for other args. Reads wait 30 s and live 12
  hours, a send or an approval waits 300 s (the bridge's most) and lives
  an hour. `pending` comes back wrapped in `withStop()`. `sphinx/approve`
  is never a tool: only the automation steps call it. `sphinx/send`
  passes the Mac's own most (1,000,000 sats) as `max_price_sats` unless
  the person named one: in conversation the card is the decision, and it
  shows the price.
- **Sealed.** The `sphinx/*` steps, `peel-automation-run` and strut's
  `orchestrator` are sealed: the meta surface a job has
  (`meta/run-workflow`) never runs them or reads their runs, so a job
  (which has bash and the web) cannot reach the chats through them
  (the security review).
- **Pinned.** `Vendor/strut.lock` names the strut commit Peel ships,
  as `Vendor/runner.lock` does runner's: strut main with strut#196 (the
  orchestrator), strut#213 (the automation steps) and strut#214 (the
  desktop package again, which stopped staging at strut#201).
  `stage-strut.sh` builds that commit from a git archive, so the checkout
  it is given is only where the commit comes from.
- **The automation steps are strut's** (strut#213: `automation/list`, `preview`,
  `create`, `update`, `delete`, `run-now`; open question 7 settled as
  recommended). They act on one workflow the host names, never another's
  schedules, and the four that act first run the host's approval step
  (`{ intent }` → `{ approved }`, or its `withStop` output passed up, so
  the turn ends with nothing changed). With no approval step they refuse.
  An automation made from a turn takes that turn's callback, as `job/start`
  does. Each run is handed `{ name, prompt, since, now }`.
- **`peel-automation-run` stays a second workflow** (the other call left
  to PR 5): Peel's own, installed with the steps, the same `agent` step
  with no session, today's run instruction as its prompt and the
  unattended section (memory and the reads; no send, no schedules), its
  reply in the orchestrator's shape. A launch-time prompt on the
  orchestrator would have been a second way to set a session's prompt.
- **The Mac answers once the bridge is up.** PR 4 left `Setting.deviceAgent`
  unset; the bridge's start now sets it to the agent's pubkey, and turning
  the preview off clears it.
- **Checked.** `OrchestratorTests` runs the staged strut with Peel's delta
  against a stand-in bridge: the seeded orchestrator carries Peel's tools
  and section, a read returns the Mac's text or a stopped `pending`, and
  an automation is created only after `approve` comes back done. The
  journey `Journeys/Orchestrator` runs everything real but the model
  (broker, the staged runner and strut, Alice's Mac answering): "What did
  I miss?" in the DM is read on her Mac, once, and the reply comes back
  in the DM. In a dev build with the preview on, a real model and a
  fixture like Tom's (two contacts' unread DMs, a tribe with a thread of
  two replies and another post): "What did I miss?" listed every chat
  correctly, read through the Mac (its request, ack and answer lines in
  the DM); "Remember that my sister Kate's birthday is on 3 May" ran
  `memory/remember`; "Every Monday at 9:00, remind me to check the Hive
  tribe" showed the create card with strut's words for the schedule, and
  the automation did not exist while it waited.
- **Measuring catch-ups.** On the journey's fixture with a model that
  takes no time, the Swift loop answered in 0.22 s and strut in 0.62 to
  0.84 s: about 0.6 s of plumbing (two DMs and one device request over the
  broker), inside open question 3's 3 s. With the real model
  (claude-sonnet-5-5) on the dev fixture, at strut a62d9bc: four strut
  turns took 22.1, 19.5, 8.1 and 10.1 s (the run, Mac read included); the
  Swift loop (`peel agent`, same profile and model) 13.2 to 13.5 s. The
  spread is the model's, not the plumbing's: a session's first turn writes
  the prompt cache, and strut's reply is a structured `final_answer`, the
  whole text as tool input. PR 10's gate needs a steadier measure than
  four turns: worth timing the model calls in strut's run events.
- **Found on the way: a turn cut off by quitting never ends.** strut
  answers a run orphaned by its restart as `stale`, and runner's `settle`
  treats anything but success, error and cancelled as in flight, so after
  relaunch the bridge waits on it for good and the DM's later messages
  queue behind it. Runner should end a `stale` run (sphinx).
- **Left for later.** A card answered after the step gave up (300 s)
  comes back as a new turn, and the model asks again rather than acting
  on the late "allow": a second card. Runner ignores a `run.end` for a
  run it did not launch, so a job's result (6b) and an automation's (7)
  do not reach the DM yet. From the security
  review: a step trusts whatever answers on the stored port (the bridge
  could sign its answers with the token); an automation reports to the
  root run's callback, which is only ever the bridge's on Peel's strut;
  send grants (PR 7) should be bound to strut's automation id and its
  fires, not the name alone; and a turn run as the bridge starts, before
  its secrets are set, fails its reads. From the second review: an
  automation's callback is that launch's bridge URL, which the next launch
  replaces (PR 7 gives automations a callback that lasts); Stop does not
  take a card down (PR 6); a read an automation's run gave up on comes
  back as a late turn in the DM, and a late "allow" reads as done though
  nothing was made (runner's late turns, for PR 7); any workflow may name
  the bridge's secrets in `secretsEnv` (strut could refuse them).
- **Review findings not applied, and why.** The send step's cap stays the
  Mac's most: a tribe send always shows its price on a card and is never
  "always allowed". The steps' descriptions, the run instruction and the
  intro are written again rather than generated from the Swift tools and
  `AgentSetup`: those go with the Swift loop in PR 11, and changing them
  now would change today's prompts. The host delta is written with the
  preview off too (one file, and strut reads it only at boot). The steps'
  installs run one after another: a few loopback calls once per bridge
  start.

### Built: PR 6, the Agent chat is the DM (2026-10-18)

- **One row.** With the preview on and the agent's contact known
  (`Setting.deviceAgent`, read when the agent opens so the DM is the chat
  before the bridge is back up, and set again by each bridge start),
  `AppModel.agentContact` is set; once that contact is a chat here,
  `agentChat` is its DM. The sidebar leaves the DM out of its sections and
  the agent's row opens it (`agentDestination`), with the DM's unread count
  and "Waiting on you" for its cards; `.agent` (Ask Peel, a notification,
  the driver) opens it too. The Mac draws that chat with `AgentChatView(dm:)`.
  Off, `agentContact` is nil and today's chat is as it was.
- **The list** is the shared one on the DM's composer, so read marks,
  "New messages", older pages and the saved place are a chat's.
  `ChatRow.rows(agentDM:)` makes the DM's rows for it (so days, runs and
  "New messages" are worked out over what is shown): talk as a chat draws
  it (`ListRowContent`: Retry, menus, the hover bar; the agent's messages
  with Peel's logo, AGENT and its links to messages, `inAgentDM`), an agent's reply
  without the quote of the message it answers and with its tool rows above
  it (`metadata.peel.tools`, `Message.agentTools`, one quiet line each,
  but for the `sphinx/*` ones), each request to this Mac as one quiet row
  (`AgentRequest`: "Read your unread messages ✓", "on your Mac…" until its
  result, "Declined", "Too late, nothing done"), its card in its place
  while it waits (PR 3's), its status lines ("Waiting for your Mac"), and
  no line of its own for an ack, a result or a cancel (Tom, trying
  Milestone 1: three lines a request read like tool calls). PR 9's phone
  gets the same rows.
- **"writing…"** (`AppModel.agentUnanswered`, worked out with the rows)
  is shown under your newest message until a reply names
  it (`replyUUID`, which the bridge sets on every reply, "Stopped." and
  `/new`'s confirmation included: `AgentDM.unanswered`); meanwhile Send
  is Stop, as today.
- **Stop** (the button or Escape) sends a `cancel` with no run (the turn
  in flight, which the bridge cancels in strut), takes the cards that turn
  put up (requests since your message) down as Deny, and ends "writing…" here at once: strut ends a cancelled run
  only once the model call in flight returns (the journey's stand-in held
  25 s, B1 saw the same), so the "Stopped." reply can come later, and a
  bridge that never answers leaves nothing running on the Mac.
- **`/new`** is ordinary text to the bridge, which answers "Started a new
  conversation." (decision 13).
- **Earlier, on this Mac.** The local turns stay above the DM under that
  divider, read only (no Retry), with the intro over them, only once the
  DM's rows start at its first message: not while older pages are to
  come, nor over a jump's window, so the list's first row is the DM's and
  a jump to an older message waits for its page. The list is made once
  the DM's messages have loaded, as a chat's is. The composer is text only (`AppModel.takesFiles`: the agent
  opens no files until 6b). Turning the preview off with the DM open
  opens today's agent chat in its place.
- **Checked.** `ControlEnvelopeTests` (tool rows, a bare cancel, the turn
  answered); the journey `Orchestrator.theDMAnswersStopsAndStartsAgainAsTheAgentChatReadsIt`
  (real broker, runner and strut, a stand-in model): a reply names its
  message and lists `sphinx_unseen`, Stop gives "Stopped.", `/new` its
  confirmation. `check-app.sh` on a development profile with a real model
  (pr6-me, a DM with threads and a tribe with threads): preview off, the
  local chat as today; on, one agent row, the local turns under "Earlier,
  on this Mac", a catch-up read through the Mac ("Read your unread
  messages ✓"), the reply waiting under "New messages" after bouncing
  through the tribe and a DM, a send's card and Allow ("Send a message
  ✓"), Stop by Escape, `/new`; off again, today's chat back. Idle on the
  agent chat: 0.0% CPU. The list journeys: the agent, control, bounce,
  arrival, open and return ones pass (the agent ones with the preview off).
- **Left for later.** strut should pass the abort into the model call so
  Stop ends a turn at once. Control messages still count as unread and
  notify (PR 2's note), so the agent's row counts a request while the chat
  is closed, and the hidden lines count as unread with nothing new to see.
  "writing…" can stay over a message the bridge never took (sent while it
  was down, or a turn cut off by quitting Peel: sphinx#386); Stop clears
  it here, for this launch. Go › Next Unread Chat skips the agent's DM, as
  it skips today's agent chat. A `sphinx/*` tool that failed before asking
  the Mac shows nowhere (its tool row is left out for the request's row).

### Built: PR 6's follow-ups, from Tom's hands-on test (2026-10-18)

- **A request's row opens** (a click on it, its state kept beside the list
  as a tool row's is) to what this Mac read or did, from its own result
  (`AgentRequest.text`, `reason`): a read's chats (`ChatDataReading`, the
  answer read back by the owner of its format), each a link to the chat,
  with up to five of the messages read, each opening its message, and
  how many more; a send's text and "Sent to …" with View; an approval's
  ask; why not ("Why: You said no"). The answer is the result as sent,
  capped as section 2 says (`ChatData.maxCharacters`, 12,000 characters).
- **The same row in any DM**, the preview off too: `ChatRow.rows` folds
  this Mac's own ack, result and cancel into the request's one row in
  every direct message; status lines stay lines; PR 1's three lines a
  request are gone. Only this Mac's answers fold: a contact's own control
  lines stay, so nobody can hide a message by dressing it as an ack.
  Outside the agent chat the row is named for who asked ("Peel: Read your
  unread messages ✓"), and one this Mac never answered says "Not
  answered", with nothing of what it asked shown. The agent chat's own
  look (Peel's logo, a reply's tool rows, no quote) stays the agent chat's.
- **From the review.** A read's chats come only from the data's own lines,
  never the header (which can hold the agent's words); `ChatData` writes
  a "]" in a name as ")", so an alias cannot pose as another line's sender
  or uuid. `FactLine` is the one fact row of a tool's and a request's
  details. Left: a new copy of a request moves its row to the newest copy
  (closed again); the chat's list corrects an opened row's height from its
  cell, where the agent chat measures it again by version.

### Built: PR 6b, Peel's side: jobs in the DM (2026-10-18)

- **The grant.** strut's `orchestrator` already offers its own job steps
  (`job/start`, `job/continue`, `job/list`, `job/get`, `job/read`), and a
  host's delta is appended to them (`templateWithDelta` pushes), so Peel's
  delta names none: naming them again would list them twice.
  `OrchestratorTests` now checks the seeded orchestrator offers them
  beside Peel's.
- **Starting and continuing** show as the turn's tool rows: "Started a
  job", "Sent a job your answer", "Checked on a job", with the job's title
  when the bridge's one line of its input holds it (never its whole
  prompt, and never half a JSON object). Runner sorts the input's keys
  and cuts the line at 80 characters, so the title, after the prompt,
  rarely survives: runner item 4 below.
- **A job's message** (`metadata.peel.job = {id, title?, state?}`, state
  `working`, `asking`, `done` or `failed`) shows its job above its text,
  one quiet line ("Job · Lisbon plan · Asks you", orange while it waits
  on you; "Done"; "Didn't finish"), and what it points to under it
  (`metadata.peel.artifacts`, strut's reply shape `{id, title, kind?,
  label?, summary?, url?}`): each by its label and title, with Open for an
  https link (the web pane, as any link) and nothing for any other.
  Answering a question needs nothing new: your next message goes to the
  orchestrator, which continues the job (`job/continue`).
- **Files** already arrive: a Sphinx attachment in the DM draws as in any
  chat. None comes yet, since runner sends none.
- **Checked.** `ControlEnvelopeTests` (a job, its artifacts, https only,
  unknown states), `ControlRowTests` (the agent chat's rows carry them; a
  plain DM's do not), `OrchestratorTests` (the grant). In the app, on a
  development profile with a real model: "Start a job to write a
  three-line plan for a weekend in Lisbon" started one ("Started a job")
  and the reply said so; its result did not reach the DM, since runner
  drops a run it did not launch until sphinx#387.
- **What runner needs (stakwork/sphinx; not opened, for Tom to decide).**
  1. **Name the job on its result.** sphinx#387 (pending, for PR 7)
     already sends a run the bridge did not launch to the owner, once
     (`turns::unasked`), so a job's result reaches the DM as plain text
     once it merges. On top of it: `run.end` names no workflow, so ask
     strut for the run as a job's (`GET /workflows/job/runs/:id`; a 404
     means it is not one), take its `job` and `jobTitle` (the launch
     records them on the run, not in its input), and put `metadata.peel = {"job": {"id", "title", "state": "asking" if
     its reply has `ask`, "done", or "failed" for an error or a cancel},
     "artifacts": [...], "tools": [...]}` on that message; a question
     comes back as `reply_text` already words it, `ask` included. A
     failed job's text is #387's ("A scheduled run didn't finish: …")
     today; a job's should say "The job didn't finish: …".
  2. **Artifacts.** Pass the reply's `artifacts` through (the orchestrator's
     own replies too), keeping `url` only when it is https. For one with
     a `path` (a file the job wrote, served at `GET
     /jobs/<job>/files/<path>` with strut's key), fetch it and send it as a
     Sphinx attachment through the memes server, as Peel's own attachments
     go (size-capped; an image or a PDF first), its title as the caption,
     and leave it out of `artifacts`.
  3. **Progress (optional).** A `status` control line ("Lisbon plan:
     working") when a job starts, so the DM shows it before its result;
     Peel already shows status lines.
  4. **A job tool's title.** Put `title` first in a job step's one-line
     summary (`strut::one_line`), so "Started a job · Lisbon plan" shows.
  All three sit in `runner/src/bridge/turns.rs`, beside #387's change.

### Built: PR 9, the agent's DM on the iPhone (2026-10-18)

- **Which chat.** The phone has no agent of its own (no `AgentHost`), so
  as the account opens it sets `AppModel.agentContact` to the account's
  own agent: `Engine.agentPubkey()`, agent 1's key from the same words,
  with nothing stored and no bridge needed. Once that contact is a chat
  here, `agentChat` is its DM, as on the Mac: one row, first in Direct
  messages, with Peel's logo and AGENT, out of the other sections.
  `ConversationScreen` works out `isAgent` from it ("Ask Peel", no bolt,
  no call, text only).
- **The rows** are the Mac's (`ChatRow.rows(agentDM:)`, the shared list
  and its controller): talk as written; the agent's messages with Peel's
  logo and AGENT (`ChatRow.byAgent`); a reply's tool rows above it and no
  quote (so `/new`'s "Started a new conversation." stands alone); no line
  of its own for an ack, a result or a cancel; each request as one quiet
  line (`AgentRequestLine`). The phone never answers a request (decision
  9) and has no cards: where the Mac's card waits, the line says
  "Waiting for your approval on your Mac" (`AgentRequest.asks`: a send
  in conversation, `approve`, a Calendar write; an automation's send goes
  on its grant), then ✓, "Declined" or "Too late, nothing done" from the
  Mac's result, which reaches the phone as one of your own messages.
  `PeelLogo` and `AgentToolTitle` moved to `Apps/Shared` for both apps.
- **Checked.** `ControlRowTests` (the waiting line, a grant's send asks
  nothing, `byAgent`), `AgentAccountTests` (`agentPubkey` is the bridge's
  key). In the iOS simulator against the local stack, on a second device
  of a paired development profile, with the Mac's offscreen app running
  the real bridge, strut and a real model: from the phone, "what did I
  miss" came back in the same thread as the Mac's, with "Read your
  unread messages ✓"; a send showed "Waiting for your approval on your
  Mac" while the Mac's card was up, then ✓ and the reply once the Mac
  allowed it; a Stop on the Mac gave "Declined" and "Stopped." on the
  phone. Idle on the DM: 0.0% CPU. The iOS core was built from sphinx-rs
  v0.8.39 (`agent_seed` needs it).
- **Left for later.** No "writing…" or Stop on the phone. Agent links to
  messages stay plain links on the phone, and a job's message (PR 6b)
  shows as its text, without the Mac's job line. `AgentRequest.asks` repeats
  `DeviceActions`' card rule (PeelAgent is Mac only): move it to PeelCore
  when PR 7 lands.
- **Fixed after (2026-10-19).** A control message in a direct message is
  never unread or notified: `message.isControl` (v27, set when stored and
  for the rows before; in `message_unread` beside `noWords`) leaves it out
  of `countsAsUnreadSQL`, `Message.countsAsUnread` ("New messages" and the
  pill) and `NotificationPolicy`, on Mac and phone; in a tribe it stays a
  message. An unanswered request says "Too late, nothing done" once its
  `not_after` passes (`AgentRequest.outcome(at:)`), the row drawn again
  then and only then (`redrawing(at:)`), on both. The agent's row is found
  by its name as a chat is (`ChatSections.matches`, the Mac's rule too).
  The phone's list read its end a bar too far down (`containerSize` is
  already the room between the bars, and the bottom inset was added
  again; with the keyboard, about 500 points), so it never counted as at
  its bottom and what came stayed on the pill; and the keyboard's rise,
  taken as leaving the bottom on its first frame, stopped the pinning.
  Not seen live: a request expiring unanswered (the Mac answers at once,
  and the shortest expiry is an hour); `ControlRowTests` covers it.
  The expiry rule is the Mac's own (`ControlEnvelope.isPast`, to the
  second). Left as found by the reviews: a read the Mac began just before
  its expiry says too late until its result comes; `isControl` is set
  once, with no rescan like `markNoWords`'s (a tribe stored after its
  messages); the Mac's agent row searches the agent's name and the
  phone's the DM's; a resize that is not the keyboard is still judged by
  the caller, not `ListBottom`. `isBehind` still counts control lines, on
  purpose: the server's marker moves for the official apps.


### Built: PR 7, automations on strut (2026-10-18)

- **Where they run.** With the preview on, the person's automations run on
  `peel-automation-run` in strut, with nobody at the Mac; off, on
  `peel-automation` through `AutomationServer` as before. New ones are made
  on the one the preview names, by the orchestrator's `automation/create`
  and by today's Swift tools alike (`AppModel.automationsClient(for:)`).
- **Moving them** (`AutomationsClient.moveYours`). Turning the preview on
  moves every one of the person's automations once the bridge runs;
  turning it off moves them back before strut stops; a launch with the
  preview off brings back any left on strut's workflow. Each keeps its id
  (a workflow's own in strut, and what the Mac keeps its send grant under),
  name, schedule, input and whether it is on; it is made on the new
  workflow before it is deleted from the old, so a move cut short leaves a
  copy on both, which the next move finds (the same id) and only deletes. Moves run one at a time
  (`AgentBridge.moving`). A done one-off strut will not make again stays
  where it is. Its earlier runs stay with the old workflow.
- **Reports reach the DM.** An automation's run ends go to the bridge
  (its callback), which sends the report to the DM under the automation's
  name, once; a run with nothing to report says nothing (runner change:
  stakwork/sphinx, `turns::unasked`). The bridge's token and port are new
  each launch, so each bridge start points every automation's callback at it
  (`pointRunEnds`), and Swift-made ones carry it from the start.
- **Sends with a grant, approved once** (strut#220, which replaced #215).
  strut's `automation/create` and `update` take a `grant` when the host says
  `grants: true`. strut mints the new automation's id before the card and
  hands the grant to `sphinx/approve` with that id and the name; it keeps
  nothing about grants. The Mac words the grant on the create card (its
  chats; with no cap asked, what they cost now, the dearer tribe's) and
  keeps it under the id. A fire's run carries `ctx.automation` ({ id }),
  which strut's scheduler stamps and no request body sets: the run's
  `sphinx/post` names the automation from there, never from the input or
  the model, and asks the Mac to send; the Mac checks the grant under that
  id, the chat, the cap and the 15-minute window, and adds `[Agent] `. A
  run that is no automation's fire is refused before the Mac is asked; one
  whose automation has no grant, by the Mac. (#215 kept a grant key in the
  run's input: readable wherever runs and automations are, so a bearer
  secret. It is gone.)
- **Grants go with their automation.** Every change, run-now or delete
  card names its automation's id; the Mac answers from its own records: a
  grant on file is named on the card, and an allowed delete revokes it.
  Reading the list from Peel's own strut also revokes any grant whose
  automation it no longer lists, once two reads in a row miss it and unless
  it was kept in the last 10 minutes (its automation is made just after the
  card). Deleting one in Automations revokes its grant at once.
- **What binds a post.** `sphinx/post` refuses a run that fired over 10
  minutes ago (`input.now`) and expires within 15 minutes of the fire; the
  Mac takes at most 5 posts from one run. A change or a run-now of an
  automation that has a grant shows the grant on its card ("It already
  posts as you to Hive without asking; that stays.").
- **Dates.** From Tom's first try: a reminder "at 1pm today" was made for
  2025, then changed. The bridge's time line now names the year ("Sun 18
  Oct 2026 10:21, GMT+1."), and strut's `automation/create` and `update`
  refuse a schedule with no runs to come before any card.
- **A hole closed in strut** (the security pass): `meta/run-workflow`
  passed `params` through unchecked, so a job could relaunch `job` with
  `params.tools` naming the sealed `sphinx/*` steps or `meta/create-step`,
  and an authored step reads the bridge's token from the secret store.
  `params` may now narrow a workflow's grants, never widen them.
- **Checked.** `OrchestratorTests` against the staged strut: the grant on
  the create card under the automation's id, a post outside a fire refused
  before the Mac is asked, moves both ways with a cut-short copy made once. The
  journey `Journeys/Orchestrator/anAutomationPostsAtItsMinuteAndReportsToTheDM`
  runs everything real but the model: "In two minutes, post to my club…"
  shows one card; at that minute the run posts `[Agent] …` as Alice with
  nobody at the Mac and no card, Bob reads it in the tribe, the report
  lands in the DM; a weekly report run now lands in the DM; the preview
  off moves them to `peel-automation`, where a run reaches the Mac's
  `AutomationServer` as before, and on again moves them back with their
  schedules and grant. A post from another automation's fire (one with no
  grant) is refused by the Mac and nothing is sent. The local stack needs a current mixer: the Oct 11
  one in `~/sphinx-target` fails tribe payments ("Outgoing CLTV value is
  too soon").
- **Review findings not applied, and why.** A cut-short move (a delete
  that failed) leaves both copies firing until the next move: the other
  order could lose one. The run history shows the DM's name header. One
  cap covers every chat in a grant (the dearest at the card); per-chat caps
  can come with the grant list's editing. The bridge's run-end token is its
  whole token (a runner change: a token for run ends alone). A run's error
  report in the DM does not name the automation (the runner sees no name).
  A run that fires while the bridge restarts posts its end to the old one
  and is not reported. The Swift `update_automation` card does not name a
  grant (the Swift loop goes in PR 11). Jobs' authored steps can read any
  secret by name, the bridge's among them: closed for jobs by the `params`
  fix, since `job` is not granted `meta/create-step`; strut's own question
  for any workflow that is. From the cleanup pass: a bridge callback that
  lasts (a token kept across launches) would replace re-pointing every
  automation at each start; `AgentSetup` takes a client made for one bridge,
  so the tools are made again at each bridge change, where a provider asked
  at each call would need none. The Mac tells a delete card from a change
  by strut's wording ("Delete “name”"); a field on the card would be firmer. From the security pass on #220, both needing strut's API key (which can
  fire a granted automation without a card anyway): the Mac keys a grant by
  the automation's id, which is unique per workflow only, so a workflow
  published over HTTP with `sphinx/post` and an automation under a granted
  id could post (strut could stamp the workflow beside the id); and an
  automation deleted outside a card keeps its grant until two reads miss
  it, so one made again under the same id in that gap inherits it (the
  create card could always name its id, so the Mac drops a stale grant).

### Built: PR 10, strut is the agent (2026-10-18)

- **No switch.** `AgentBridge` keeps only what the bridge is doing: off
  (the agent not open, the brain elsewhere, or no strut running), not
  set up, starting, running, failed. The bridge
  starts whenever the agent is open, this Mac is its brain and Peel's own
  strut runs, in Debug and Release. A development profile's strut still
  needs `-strut YES`. The Agent chat no longer reaches the Swift loop
  (automations still fire it until PR 7's move); its code stays for PR
  11. With a home server as the brain there is no agent: only this Mac
  runs the bridge in Phase 1 (decision 9), and moving the brain away
  clears the Mac's answers to the agent (`setDeviceAgent(nil)`) until its
  bridge starts here again.
- **First run: "Give your assistant its own account".** Until the agent
  is a contact, the agent chat shows the local turns read only, under
  "Earlier, on this Mac" as over the DM, and in the composer's place a
  card (`AgentSetUpPanel`) that says what it is and what it costs before
  anything is paid: up to `BundledBridge.setUpMsat`, 16 sats (the 10-sat
  invite, then the 5-sat key exchange and its 1-sat ping; the agent pays
  3 back, so 13 in the check). Set up (`setUpAgent`) is the only start
  that pays: a start on its own throws `NotSetUp` before runner runs, and
  the row says "Set up". The key exchange goes with the cost already
  confirmed (`confirmedMsat`), since the card was the yes. A failure says
  why with Try again. Try again pairs only after a set-up that failed
  (reusing the store's invite while the server holds it); after any
  other failure it starts again without paying, which leads back to the
  offer if the agent is not a contact. Any stop forgets the intent to
  pair (`AgentBridge.stop`), so a set-up cut short by a lock, a brain move
  or strut restarting never pays later on its own; a start waits for the
  one before it (a key exchange cannot be cut short). Peel's strut
  failing to start, or stopping under the bridge, is a failure too, and
  Try again starts it again. The same state is a row in Account › Peel
  agent ("Own account", Set up or Try again), and a failure after set-up
  is said above the DM's composer with Try again.
- **One agent 1.** The agent is always `agent_seed(seed, 1)`. An account
  that already has it as a contact (set up on another Mac, or a profile on
  the same words) uses it again with no invite, whatever store runner
  has: runner registers a known account without redeeming anything. An
  account without the contact whose agent was registered before gets its
  invite back (PR 4). n is never moved on.
- **Runner in Release.** `embed-strut.sh` puts the staged runner in
  `Contents/Bridge` in every build (`run-app.sh` refuses without it, or
  with one `Vendor/runner.lock` does not name), signed with the build's
  identity and, in Release, `scripts/bridge.sandbox.entitlements`:
  `app-sandbox` and `inherit` only, so runner has Peel's sandbox: its
  network (the broker, and its server on loopback for strut) and its
  container (the store, `Application Support/Peel/Bridge` there). A
  Release build fails without the staged bridge, so an archive never
  ships without its agent.
- **Found on the way: optimized builds stopped at the first wait.**
  `Engine.nextChange` (every `poll`: an invite's confirmation, among
  others) aborted with "Incorrect actor executor assumption" in a Release
  build, and in the CLI built with `-c release`; never in Debug. The
  continuation's isolation is now named (`isolation: self`), not
  inferred. Before PR 10 no Release build had made an invite.
- **Pinned.** `Vendor/runner.lock` is sphinx master at the merge of
  sphinx#386 (a stale strut run ends the turn), after sphinx#387 (PR 7's
  automation results). Automations move to `peel-automation-run` when the
  bridge starts (PR 7's move) and never back: there is no off.
- **Checked.** The journeys `Bridge` (with a new case: a fresh store for
  an account that has the agent as a contact sets up with no invite and
  no sats), `Orchestrator` (with a new case in the DM journey: a turn cut
  off by quitting ends as interrupted when Peel opens again, and the next
  message is answered) and `DeviceRequests` on a local stack; the
  unit suite. `check-app.sh` on a development profile with a real model:
  the card and the sidebar's Set up, Set up (13 sats), the DM as the
  chat, "What did I miss?" read through the Mac. A Release build signed
  as an archive signs it (hardened runtime, the App Store entitlements
  less the Keychain group, which needs the App Store profile) and run
  offscreen in its own container on a development profile: set up, a
  catch-up read through the Mac, a send's card allowed and sent, with
  Peel, strut's Node and runner all inside the sandbox and runner's store
  in the container. The run before the fix above crashed on the invite's
  confirmation and left its 10-sat invite pending (cancellable; its code
  was not yet kept, so a retry made a second). The list journeys for the
  agent chat: `agent-open`, `agent-return`, `agent-expand-tool`, both
  `agent-memory-panel`s and both `agent-stream`s pass; `agent-reply-ends`
  and `agent-reply-ends-open` fail, since a local reply no longer streams
  in the chat (they drive the Swift loop, which nobody reaches now): PR
  11 removes them with it.
- **Review findings not applied, and why.** An agent registered before
  with no sats left fails with Try again offered each time, each try
  making an invite that is refunded (the rare case of PR 4's restore; it
  needs the agent funded another way). `DeviceCards` and `AgentSession`
  keep the continuation shape `Engine.nextChange` had: both are on the
  main actor, and a send's card ran in the Release check. strut keeps the
  bridge's port and token after a bridge that failed to start, until the
  next start's `installOrchestrator` (one that stops by itself has them
  taken out). The orchestrator's steps are installed even on a start that
  then finds the agent not set up (a few loopback calls per launch).

### Built: PR 11, Peel's own loop removed (2026-10-19)

Nothing reached the Swift loop after PR 10, so it goes, with what only it
used. Peel keeps the client side: the device requests and their cards,
the connected model's key (handed to strut), `BundledStrut`,
`BundledBridge`, `Orchestrator`, and the earlier local chat, read only.

- **AgentKit.** Gone: `AgentLoop`, `Compaction`, `ContextWindow`,
  `RetryPolicy`, the model clients (`ModelProvider`, `AnthropicProvider`,
  `OpenAICompatibleProvider`, `ModelHTTP`, the SSE parser, `ModelMessage`,
  `ModelError`), `ToolRegistry`, `ToolApprover` and the `write` effect.
  `Tool` and `Approval` stay, for the device requests. `AgentSession` is
  the agent on this Mac: the connected model, its name, the "Always
  allow" rules, and the earlier chat read from the records the loop wrote
  (`Conversation`, `Turn`, `ToolCall`), with Clear (which forgets the
  loop's `Summary` records too). No migration: nothing in `agent.sqlite`
  changes, so the old chat reads as before and Clear still forgets it.
- **Connect keeps the key without a test call.** The test call was the
  model clients' (one streamed request); a key the provider refuses now
  shows as strut's failure in the DM. A check through strut, or a
  non-streaming one, is a follow-up if Tom wants it back.
- **PeelAgent.** Gone: `AutomationServer`, `AgentSetup`, `MemoryTools`,
  `AutomationTools` and the headless run (`AutomationRun`,
  `AutomationRequest`). The prompt text strut's orchestrator is given
  moved into `Orchestrator` (`memoryPrompt`, `automationsPrompt`) and
  `SphinxTools.systemPrompt` with strut's tool names written in, word for
  word the same as before (checked against the old templates).
  `AutomationsClient` no longer installs `peel-automation`, its
  `peel/run-automation` step or their token and port; `setModel` takes
  those two secrets out of strut's store with any hand-over of the model.
  Automations still on `peel-automation` (an account whose bridge has not
  started since PR 7) are listed and move to `peel-automation-run` on the
  next bridge start, as before; until then each fire fails, and its run
  says "Didn't run: it runs once your assistant is set up" (found by the
  independent review: before, they ran through `AutomationServer`). The
  old workflow and step stay in strut, unused. Their old
  runs read as before (`AutomationReply`, `AutomationFailure`).
- **The app.** Gone: the streaming reply, Retry and the problem rows, the
  local approval card, the summary row, the automation notification, the
  local composer's draft carried to the DM, and `-agentBaseURL` and
  `automationPort`. The agent chat before its DM is the intro, "Earlier,
  on this Mac" and the set-up card. `AgentApprovalCard` is the DM's card
  only (it never takes the keys as it appears).
- **"Old assistant chats (this Mac only)"** (Tom, from using PR 10): the
  heading over the old turns in the agent chat and the Account › Peel
  agent row with Clear… say the same, where both said "Earlier, on this
  Mac"; the row shows only while there is old history.
- **The CLI.** `peel agent` goes: it was the Swift loop in a terminal.
  `listen` (which answers the device reads) and `device-agent` stay.
- **Tests and journeys.** The loop's unit tests, the providers' streams
  and `scripts/record-agent-fixtures.sh` go. `AgentSessionTests` reads an
  old chat written with the stored literals. `Journeys/Agent` calls the
  Sphinx tools as the device requests do (the reads, a send only once
  allowed, a tribe send never paying more than its card).
  `OrchestratorTests` moves automations off a stand-in `peel-automation`;
  the orchestrator journey's "preview off" round trip and its Swift-loop
  timing go. List journeys: `agent-reply-ends`, `agent-reply-ends-open`,
  `agent-stream-bottom` and `agent-stream-scroll-away` went with the
  streaming; the rest seed an earlier chat (`{"agent": "seed"}`).
- **Checked.** The unit suite. On a local stack, the journeys `Bridge`,
  `Orchestrator` (the DM, Stop, quitting mid-turn, the automation that
  posts at its minute and reports to the DM), `DeviceRequests` and
  `Agent`. Every list journey (the agent ones on a seeded earlier chat;
  nine that timed out under load passed when run again). `check-app.sh`
  on a development profile with `-strut YES`: the agent chat with no
  model, the Connect panel, a placeholder key kept (`{"agent":
  "connect"}`: the panel's key field is secure, which posted keys never
  reach), Set up (13 sats) and the DM as the chat, Account › Peel agent
  without old chats (no row) and with them (the row and Clear…), and the
  heading over the old turns. The iOS app compiled (arm64, v0.8.39). The
  prompts strut is given compared with the old templates: the same.
- **Review findings not applied, and why.** Connect has no key check (above).
  `Tool` keeps the definitions and JSON Schemas the loop sent the model,
  now read by nothing (strut's `DeviceStep`s carry their own), and
  `AgentSession` still holds both the settings and the old chat: each a
  reshape for its own PR. `moveYours`'s `yours` and `callback` stay
  stored on the client; the bridge start's loopback calls (the steps
  posted one by one, the list read more than once) are as before.

### Built: PR 12, no model connected (2026-10-20)

Removing the key after set-up left the agent looking alive: Remove said it
would stop (only the key went), the DM took messages that each came back
as runner's "Sorry, that didn't work: agent: no model connected
(STRUT_DEFAULT_MODEL is not set)", the sidebar offered Set up again, and
Account said Connected when handing the key to strut had failed. Tom's
decisions (2026-10-20):

- **The account and the bridge stay.** A model is needed first only to set
  the agent up (`agentSetUp`); once its account is a contact, removing the
  key leaves the contact, the DM and the bridge. "Own account" says it
  answers once a model is connected.
- **The Mac DM can't send into a dead end.** With no model its composer's
  place is "Connect a model" with Connect (`AgentModelPrompt`, the Connect
  panel beside it, `AgentConnectSource.dm`); the intro's card stays the
  local chat's only.
- **Remove says what happens:** "Remove the key?" with "Your assistant
  stays in Direct messages but can't answer until you connect a model."
  once it has its account.
- **The sidebar row** says Set up only before the agent's account exists;
  after, AGENT, with a quiet "Needs a model" while none is connected.
- **Connected means strut has it.** `ModelHandOver` (handing, handed,
  failed) comes from each hand-over (`handModelToStrut`): "Connecting…"
  while it runs, Connected once strut took it, and a failure as "Not
  connected to your assistant: <reason>" with Try again (a removal that
  strut did not take says "Your assistant may still have the old key").
  While Peel's strut is starting or stopped there is no Connected (Own
  account says how that is going). With no strut of Peel's own (a home
  server, or none in this build) there is nothing to hand and Connected
  means the key is kept, as before.
- **The phone** cannot know whether the Mac has a model: nothing reaches it
  but the DM. A message from it (or one already in flight) still reaches
  strut, and the reply is strut's own error, which runner passes through
  unchanged (`end_text`, `runner/src/bridge/turns.rs`). Since
  stakwork/strut#237 strut says it for a person, generic rather than
  Peel's: "Sorry, that didn't work: No model is connected yet. Connect one
  to use your assistant." (`STRUT_DEFAULT_MODEL` goes to strut's log); Peel
  has it with the next strut pin. Runner mapping strut's words to its own
  line (stakwork/sphinx#388) was closed as superseded (Tom, 2026-10-20).
  If a host ever needs to recognise the case, an error code from strut
  (e.g. `no_model`) would be sturdier than matching words.
- **Checked.** The unit suite; the journeys `Bridge`, `Orchestrator` and
  `Agent` on a local stack; `check-app.sh` on a development profile with
  the agent's account and `-strut YES`: connected (Connected once strut
  took it), Remove (the DM's Connect prompt, "Needs a model" in the
  sidebar, Own account's line), Connect from the DM, Account with no model,
  and connected again (the composer back). The iOS app compiled (arm64,
  v0.8.39). Not seen: the failure line, which needs a strut that refuses.
- **Found on the way.** A profile's strut graph copied to another checkout
  fails to open: ladybug keeps the absolute path of its extensions from
  where the graph was made (the check moved the copy's graph aside).
- **Review findings not applied.** Remove's explanation keys off the DM
  (`agentChat`) and Own account off the contact (`agentContact`), which
  differ only before conversations load. The intro's card and the DM's
  prompt are two looks for "connect a model", one per place.

### Built: connectors P1, the builder gated (2026-10-22)

From the connectors and authoring design (stakwork/peel#342, `docs/connectors-and-authoring.md`), section 7.

- **Pin.** `Vendor/strut.lock` moves from strut c180e8f (#220) to main at
  2296d29 (#285), which brings strut's `builder` job (#239), proposals
  (#222), `acp/prompt`, and #289 (launch params may only add to an
  `approve:` list). The orchestrator could already start the builder
  (`job/start { workflow: builder }`), which strut seeds with
  `approve: []` and `peer: true`, so the gate ships in the same change.
- **Gate.** Peel's delta gives the builder `approve: [meta/publish-workflow,
  meta/create-step, meta/edit-step, app/publish]` and `peer: false`. Each
  such call is a pending proposal (`GET /proposals`); nothing is published
  or written until a person decides. `app/publish` is beside the three the
  design names because it publishes an app with its grants.
  `meta/set-automation` (#285) is gated too.
  `app/publish` is also sealed from the meta surface (`STRUT_SEALED`), so
  the builder cannot run it through `meta/run-step` around its proposal
  (strut seals `meta/*` itself).
- **Bypass, closed by strut#289.** The builder's `meta/run-workflow` could
  run `builder` again with `params: { approve: [] }`, and the nested
  builder published with no proposal (reproduced at 69cf03f: the workflow
  published, no proposal). At this pin strut refuses it ("approve may only
  grow"): the same reproduction publishes nothing. A builder launched with
  a `peer` reaches that strut ungated (strut#294); it matters only once
  Peel has peers, which P8 brings, and P8 waits on it.
- **Still open (strut S1).** The builder's ungated tools still run code:
  `meta/run-step` runs any unsealed step (`exec` with `secretsEnv`), and
  `meta/run-workflow` the `job` workflow, as the orchestrator's own jobs
  (bash) already could. Secret scoping (`builder.reach`) would close it;
  Peel sets none since 2026-10-24 (Connections, "What the AI publishes").
  `peer: false` only closes this builder to other struts; a build *on* a
  peer (`input.peer`) runs under that strut's approvals, so P8 keeps
  peers out of the builder's reach.
- **Test fix.** strut now clears its environment at boot (strut f4606bd),
  which dropped the journeys' stand-in model URL, so strut called
  Anthropic for real with the stand-in key (refused). `BundledStrut` keeps
  a loopback `ANTHROPIC_BASE_URL` through it (`STRUT_ENV_KEEP`).
- **Runner.** `Vendor/runner.lock` moves to sphinx 12ccccc4 (#389, runner
  R1): the bridge relays each pending proposal as an `approve` card on the
  Mac (`proposal:<id>`) and calls `decide` once with the answer alone. The
  card is R1's wording until P2 gives proposals their own.
- **Checked.** `Journeys.Orchestrator.aWorkflowTheAgentBuildsWaitsForApproval` (since 2026-10-24
  `aWorkflowTheAgentBuildsIsTestedAndPublishedWithNoCard`: the builder is ungated):
  a DM asks for a workflow, the orchestrator starts the builder, its
  publish is one pending proposal and the workflow does not exist.

### Built: connectors P3, the Connections screen (2026-10-23)

From the connectors design (stakwork/peel#342, sections 1 and 2), on
strut's MCP registry (strut#286). Built on P1 (the builder gated).

- **Pins.** `Vendor/runner.lock` to sphinx master 6a3863d4 (#389 the
  proposal cards, #390 rooms and the wake); strut stays at P1's 2296d29,
  which has the registry.
- **Account › Connections.** Each MCP server: where it is, Connected with
  its tool count and how many ask first (strut's probe), or why it did not
  answer (anything shaped like a key in that answer hidden); the Assistant
  and Jobs switches; Test; Remove (confirmed, which deletes its key too).
  Add MCP server: a name (its tools are `<name>_<tool>`), an https address
  (plain http only to a development profile's test server on this Mac),
  and a key or token. strut registers it first; then the key goes into
  strut's encrypted store under `MCP_<the name in hex>_KEY`, a name no
  other server's can be (`linear`, `Linear`, `lin-ear` each their own).
  Peel keeps no copy. A name already connected is refused (Remove it
  first), and an address strut refuses leaves nothing behind.
- **Grants.** Which agents reach a server is Peel's: `connections.json`
  beside strut's data, read into the host delta at each start
  (`orchestrator.tools` and `job.tools` gain `mcp/<server>/*`). A switch
  restarts Peel's strut; one flipped while it was starting is applied by
  one more start once it is up. A server strut no longer has takes its
  grants with it. On a home server the switches are hidden: its own
  settings decide.
- **Asks first.** strut gates every tool the server does not mark
  read-only: the call is a proposal, the bridge brings its card to the Mac
  (R1), and on Allow strut calls the server once, with the key. A server
  that marks a write read-only runs it unasked, by strut's design; the
  screen says the rule as it is.
- **What the AI publishes.** No `builder.reach` (strut#284) and no
  publish cards, as on Hive's strut (2026-10-24): the builder is free to
  work. It writes step code and publishes workflows and apps
  (`meta/publish-workflow`, `meta/create-step`, `meta/edit-step`,
  `app/publish`) with no card, and what it publishes may run any step,
  name any secret in strut's store (the model's, a connection's, the
  bridge's) and call other struts. Peel sets no `builder.approve`, so its
  test runs (`meta/run-step`, `meta/run-workflow`) need no card either:
  `meta/run-step` runs any unsealed step (`exec` with any secret, an
  `agent` with its own grants), the same reach as a workflow it publishes
  and runs. `app/publish` is no longer sealed (`STRUT_SEALED` is unset):
  the seal only kept `meta/run-step` from running it around its card.
  `sphinx/*` stay sealed, `meta/set-automation` is still refused (strut
  runs it only as an accepted proposal), and a workflow step calling
  `strut/run-workflow` still waits on its card (strut's `peers.test.ts`).
  Known and accepted: an AI workflow run in a job keeps that job's MCP
  servers (strut drops them only under a reach); no journey yet
  publishes a workflow that uses a secret.
  `Journeys.Orchestrator.aWorkflowTheAgentBuildsIsTestedAndPublishedWithNoCard`:
  the shell test run runs, the publish goes through, nothing is pending.
- **This Mac only for tests.** A development profile's strut may register
  a server on this Mac (`STRUT_MCP_LOCAL=1`); the app account's may not.
- **Checked.** `ConnectionsTests` on a staged strut against `MCPStub`
  (each name its own key, a refused add leaving nothing, a re-add refused);
  `Journeys/Orchestrator.aConnectedServersWriteWaitsForTheCardAndRunsOnce`
  (a read runs at once; a write is a proposal whose card reaches the Mac
  through the bridge, and Allow makes exactly one call, with the key); all
  the agent journeys on the new pins; `check-app.sh` with a stand-in
  server: added, tested (2 tools, 1 asks first), Jobs off (the delta
  followed), removed. An independent adversarial review found the shared
  key names, a failed add's leftovers, a switch lost during a restart,
  grants rebuilt from an empty cache, plain http, the reach, keys echoed in
  errors and weak tests: all fixed.
- **Not yet.** A switch restarts strut, which cuts short a turn or job
  under way. A workspace's shared-workflow count needs strut's
  read-through for a peer's workflows (S6). An accepted proposal runs
  against the registration as it is then (strut#286's open point).

### Built: connectors P8, Connect Stadeum (2026-10-23)

The connectors design (stakwork/peel#342, "Peers") on strut's
`specs/DESKTOP.md` and Hive's pairing (stakwork/hive#5602). The
user-facing name is Stadeum; the code says Hive where it talks to Hive's
API. Builds on P1's strut pin (person tokens, `personalOrchestratorSystem`,
proposals), P3's Connections screen, and runner #389 (proposal cards) and
#390 (rooms and the wake).

- **Pairing.** Account › Connections › Stadeum workspaces: Connect
  Stadeum asks Hive for a code (`POST /api/strut-devices/pair`), shows it
  and a QR of Hive's own pairing page (one on another site is refused),
  and polls every `interval` until the person approves there. The
  `hivedev_` credential and the org records go in `Profile.hive` (the
  Keychain for the app account), never a database or a log. Each org goes
  on Peel's strut as `PUT /peers/<id>` when the bridge starts; Peel puts no
  other peers, so any other is taken off.
- **The list.** Each workspace by its label and `@id`, "Paired, renews
  daily", and whether a request to it asks first; an org Hive gave no
  record for, with Hive's reason; Unpair.
- **Renewal.** `GET /api/strut-devices/peers` once a day (or when the
  tokens are within a day of expiring), checked hourly while the account
  is open and once as it opens; it replaces the orgs. A 401 is "Stadeum
  no longer knows this Mac" with Pair again, and the orgs come off strut
  and runner at once (their tokens may still work for days). Unpair takes
  the orgs off strut and runner (once the bridge runs, if it is stopped),
  forgets the credential and revokes the workspaces' Always rules; the
  device stays in Hive's settings until revoked there. An Always also
  goes when a pairing names another account or the org leaves the list,
  since its slug may later be another org's.
- **Runner.** Paired, the bridge starts with `BRIDGE_ACTOR` (the actor),
  so its strut calls and `decide`s name the owner (sphinx#389). After
  pairing, each renewal and each bridge start, Peel hands runner the orgs'
  person tokens (`PUT /peers { actor, tokens }`, sphinx#390, which holds a
  room on each org's strut for the jobs that end there): strut never
  returns a token. Unpair sends no tokens before strut and the bridge
  start again.
- **The prompt.** Paired, strut is started again speaking for the person:
  strut's own `personalOrchestratorSystem(actor)`, rendered by the Node it
  ships, follows Peel's section. Since strut#290 its thread on an org is
  `<actor>/<conversation id>`, the conversation id being the DM session
  runner names in each turn. A conversation keeps its first turn's
  prompt, so the DM knows the orgs from its next `/new`.
- **Consent.** `orchestrator.approve` and `job.approve` list
  `strut/run-workflow` (strut grants it to both): every call to an org is a
  proposal. The bridge relays it as an `approve` request with
  id `proposal:<id>` (runner R1); the Mac reads that proposal from its own
  strut and words the card itself: "Send this to Acme?", the message, "To
  Acme's assistant (@acme) in Stadeum, as you", with "Always allow for
  Acme" kept as an `ApprovalRules` rule on `(strut/run-workflow,
  acme/orchestrator)`: that org's assistant only, never another workflow
  there (asked every time). The workspace's row then says "Sends without
  asking" with Ask first, which revokes it. The card fails closed: a
  proposal Peel cannot read from strut, no longer pending, for a peer
  strut has not got, or holding more than the card shows (input beyond
  the message and its thread, a `version`, `params` or `job` on the org,
  a message too long or not showable) is refused, never shown in the
  bridge's words. The card does not show the thread (`input.session`),
  `wait` or `room`: they steer delivery on the org under the person's own
  token, among the person's own threads there.
- **Tokens go only where they should.** A peer whose address is not https
  off this Mac is refused (that org's error), so a person token never
  travels in the clear; plain http on this Mac only from a test Hive on
  this Mac. The Keychain item is readable once the Mac has been unlocked,
  so a renewal while it is locked is kept.
- **No route around the card.** `Vendor/strut.lock` moves to 4742720
  (strut#294, with #297 and #298): a host-gated `strut/run-workflow` runs
  only as an accepted proposal, so a builder launched with `peer`
  (`job/start`, `meta/run-workflow`, over HTTP) is refused before it
  reaches the org. The journey checks it on Peel's delta. Left for strut:
  `requireApproval` accepts any accepted proposal, not only one of
  `strut/run-workflow` (nothing reaches that at this pin).
- **Not here.** A turn after a `decide` (runner, R2's row): the org's
  first answer reaches the agent on the person's next turn, and the job's
  result by the room's wake. Deliverables as Sphinx attachments (runner).
  Hive's rate limit on the pair start and the `dev` claim (H4). Strut's
  read-through for a workspace's workflows (S6).
- **Checked.** `HiveTests` against a stand-in answering as hive#5602
  documents (no local Hive exists: it needs Postgres and the swarms'
  mcps); `Journeys/Orchestrator.aHiveWorkspaceIsAskedOnlyOnACard` on two
  staged struts at the pin, one standing in for the org's central with a
  person token it minted: strut's section names `<actor>/<conversation>`,
  the orchestrator's call is a proposal, the card's words come from strut,
  Always keeps a rule for that org, strut's `decide` reaches the org's
  assistant as the person, and the next call needs no card;
  `check-app.sh` with a stand-in Hive: the code and QR, the workspace and
  one org's error, then revoked there: Pair again, and Unpair. Reviews:
  `/code-review`, `/simplify`, `/security-review` (nothing at 8 or
  above) and an independent adversarial review (re-pair keeping Always
  rules, Unpair leaving runner's tokens, a revoked Mac still calling the
  orgs, a late poll undoing a newer pairing, top-level `params`/`version`/`job`
  hidden from the card, one bad id stopping the sync: all fixed). Not
  yet against Hive itself (it needs Tom's approval on hive.sphinx.chat).

### Built: a workspace's apps (2026-10-23)

An app a Stadeum workspace pinned as a tab opens in Peel, alone in the
detail column, from a new Apps section at the foot of the sidebar
(since replaced by the Apps row and its browser, `docs/apps-browser.md`). The
app lives on the workspace's strut (its grants, runs and data); Peel's
own strut is the window onto it (strut's plans/apps.md §7.4, strut#307
and #308).

- **The strut it needs.** strut#307 and #308, which the pin at #301's
  merge (2d119a3) holds: the read-through serves a peer's apps and their
  files, relays `POST /peers/<id>/mcp`, and a person token gets the app's
  `step_run` alone on the org; `?app=@<id>/<name>&solo=1` shows the page
  and nothing of strut's around it.
- **The list.** `AutomationsClient.pinnedApps(of:)` reads `GET
  /peers/<id>/apps` on Peel's own strut for each live workspace and keeps
  those marked `pinned` (what strut says a host showing tabs takes), under
  names strut gives (and, since 2026-10-26, the person's own on Peel's
  strut, `docs/apps-browser.md`). `refreshApps` runs after each `syncHive`
  (the bridge starting, a pairing, a renewal or revoke; never waited for,
  so a slow workspace cannot hold up the bridge) and every five minutes
  while the sidebar shows, reading the workspaces at once, a newer read
  replacing one under way. A workspace that cannot be read keeps what it
  last listed, and the list stays while Peel's strut is away (starting
  again, a memory move). Nothing on a home server, which holds none of
  this Mac's workspaces. The workspace's `@id` shows beside each app only when
  the apps come from several.
- **The page.** `WorkspaceAppView`: the app's title and `@workspace`,
  Reload, and a `WKWebView` on `MemoryServer.page(of:)`, strut's UI with
  Peel's strut key as `?key=`, which strut's UI keeps for the tab and takes
  out of the address. The web view's store keeps nothing
  (`.nonPersistent()`), so the key goes with the view; it is limited as
  the web pane is (`WebPane.limit`: no window without a click, no sound
  until clicked, no WebRTC). It navigates only to Peel's own strut,
  `about:` (the page's `srcdoc` frame) and data/blob frames; a link to
  anywhere else, or a new window strut opens for one, opens in the web
  pane beside the app (`WebPane.follow`), and only within a second of the
  person's own click or key in the view (`AppWebView`): a script's
  `click()` counts as a link activation too. No download, camera or
  microphone. The person's token for the workspace never leaves strut's
  peers file. The page itself is the workspace's, in a sandboxed frame
  with an opaque origin: strut's build gives it `connect-src 'none'`, so
  its calls go through strut's relay, but a workspace that served another
  document could fetch what any web page can (never strut's API, which
  wants the key the frame does not have).
- **Strut's side, fixed there.** Shown alone, strut's UI at this pin
  still loads every workflow, step type and peer's app list before
  drawing the page, and polls the active runs every five seconds while it
  shows; strut#313 loads only the one listing, for the next pin.
- **Not here.** The page's `ui/message` (a message about the app to the
  agent's DM) and in-place `ui/open-link`, which strut leaves unwired when
  the page shows alone; a workspace's apps that are not pinned; the
  iPhone (no strut of its own).
- **Checked.** `HiveTests.aWorkspacesPinnedAppsAreListedAndOpenAloneOnPeelsOwnStrut`
  (the read-through's path and key, pinned only, names strut gives, the
  page's `key`, `app` and `solo` read back exactly, none on a home
  server). By hand, two struts from the stage at the new pin, one standing
  in for the org with its seeded `strut/views` pinned and a person token
  it minted: Peel's strut listed it pinned through the read-through, and a
  WebKit web view with this view's configuration and rules loaded
  `page(of:)`: the gallery drew, the address lost the key, only strut's
  page and the `srcdoc` frame were let through, and the page's MCP
  `initialize` reached the org's `/mcp` through `/peers/acme/mcp`. Not yet
  `check-app.sh` (signing), nor against a swarm (mcp pins #307's merge).
  Reviews: an independent adversarial review (a script's `click()`
  opening pages in the pane, the bridge start waiting on every
  workspace's apps, a second copy of the pane's web view policy, a web
  view rebuilt when a title changed, overlapping reads, the list cleared
  while strut restarts, a test that could not see a `+` in the key: all
  fixed; strut's solo loading, above, left for strut).

### Built: an automation can do anything you can (2026-10-23)

From Tom's user model (`docs/connectors-and-authoring.md`, section 7):
an automation is a prompt on a schedule, and a workflow is a tool.

- **Runs start jobs.** `peel-automation-run`'s agent gets `job/start`
  beside memory, the reads and `sphinx/post`. Work its tools cannot do
  (the web, a page, a workflow by name) is a job's; the run then says
  `NOTHING_TO_REPORT` and the job's result reaches the DM by itself: the
  bridge sends the end of a job no DM started (`turns.rs`, `unasked`).
  The run's prompt forbids a builder job. Only `job/start` is granted, not
  the other `job/*`: a run is one shot.
- **The orchestrator never declines a schedule for want of a tool.** Its
  automations paragraph says a run can do what a turn can, a built
  workflow is scheduled as an automation whose prompt runs it, and
  building is never an automation's.
- **The builder no longer schedules.** `meta/set-automation` leaves
  `builder.approve`, so strut refuses it (it runs only as an accepted
  proposal): every schedule is an automation, on one card and in one list.
- **Next PR (security review):** a run reads other people's messages
  and can now start a job with the web and a shell, so text injected in a
  tribe could reach a job with nobody watching. The same path exists in
  the person's own turns, so the fix sits between the agent and its jobs:
  once a turn or run has read other people's messages, starting a job
  needs the person's card (a Peel step in front of `job/start`, asking
  the Mac, which knows which runs it answered reads for), and a run's
  `job/start` is pinned to `workflow: job` in code, not only the prompt.
- **Not changed:** automations still run on `peel-automation-run`, not on
  strut's `orchestrator`. Firing the orchestrator directly would lose the
  run's name, `since` and the post grant, and need strut and runner work;
  the run already has the same model, memory and now jobs.
- **Checked.** `Journeys.Orchestrator.anAutomationStartsAJobWhoseResultReachesTheDM`:
  an automation's run starts a job, says nothing, and the job's result is
  the agent's one message in the DM. `anAutomationPostsAtItsMinuteAndReportsToTheDM`
  is flaky on main as well (2 of 4 runs there failed: once at Bob reading
  the tribe post, which the Mac reported sent, once pairing contacts).

### Built: a deliverable opens beside the chat (2026-10-23)

A file or an app an org's strut made for a job, listed under the job's
message in the agent's DM, opens in the web pane beside the chat. The
message carries only where it opens; Peel's own strut reads it from the
org and draws it.

- **What it needs.** strut#314 (the viewer reads an org's file through
  `/peers/<id>/…` and `?artifact=<path>&solo=1` shows it alone) and
  strut#313, at the new pin (`Vendor/strut.lock`, strut main at #303's
  merge, after #313, #314 and #312; #303 makes `strut/run-workflow` take its
  `input` as an object, so a model's JSON text no longer reaches an org, or
  a proposal's card, as a string); sphinx#391 (the bridge adds the handle)
  and #392 (a proposal card Peel answers as not shown is turned down on
  strut with Peel's reason, once, and said in the DM, instead of left
  pending; an approved hand-off to an org is told as that org's reply,
  with its question and its deliverables' handles), at the new
  `Vendor/runner.lock`, sphinx master at #392's merge (no dependency changed, so
  `Vendor/runner.Cargo.lock` stays: `cargo metadata --locked` passes on
  that commit with it). An org needs nothing new: its job files and apps
  are read with the person's token as #368's apps are. strut#312 moved
  dictation's fixer (node-llama-cpp) into a `fixer/` package of its own, so
  `stage-strut.sh` installs it too; and `embed-strut.sh` now leaves out a
  staged strut that is not the pin (a failed build under `run-app.sh` or in
  Release), as it does the bridge: an older strut's UI would show the whole
  of itself for a deliverable, the key in its tab.
- **The handle.** `AgentArtifact.handle` (`ControlEnvelope.swift`):
  `path` (`/jobs/<job>/files/…` or `/artifacts/<run>/…`, behind at most
  two `/peers/<id>`, each segment percent-encoded) or `app` (`<name>` or
  `@<id>/<name>`), kept only in exactly those shapes: no `.` or `..`
  segment however written, no escaped `/` or `\` in a file's segments, a
  path's characters only, at most 512 bytes. Its `peer`, the first hop, is
  the `@<id>` the row shows. strut's peer id and app name rules moved there
  (`Handle.isPeerID`, `isAppName`) and `Hive` and `WorkspaceApp` use them.
  Only the agent's DM reads artifacts at all (`ChatRow`, `agentDM`).
- **The row.** `AgentArtifactLine` shows Open for a handle as for an https
  link, and `@<id>` where a link shows its host, while Peel's own strut
  runs (a home server shows none of this Mac's orgs); the page's address is
  made again on the click, since strut may have started again on another
  port and key.
- **The pane.** `WebPane.open(_:)` with a `StrutPage`, a third mode beside a
  page of the web and an HTML attachment: `MemoryServer.page(showing:)`,
  strut's UI with Peel's strut key as `?key=` and the handle as `artifact`
  or `app`, in a web view of its own whose store keeps nothing. The address
  field shows the deliverable's title and `@<id>`, never the address (no
  Copy link, Open in default browser or Try again with it); a crash loads
  the address with the key again, and Peel's strut starting again (another
  port and key) or stopping ends it, said in its place
  (`WebPane.strutChanged(to:)`, from `AppModel.memoryServer`). A download
  comes only from strut's own page (the viewer's Download for an org's
  file), never a frame in it, and goes to Downloads as the pane's do; a
  file of Peel's own strut that the viewer cannot show (its "open in a new
  tab" link) is saved there on the person's click. A link out opens in the
  pane as a page of the web, ending the deliverable, and only on the
  person's own click. The web view is let go of before the mode is, so
  nothing it reports while it stops is read as the next page's address.
- **One set of rules.** `StrutPage.policy` (actions and responses) and
  `newWindow` are #368's app view rules, moved so the app view and the pane
  both use them: Peel's own strut, `about:` and data or blob frames, a link
  out only within a second of the person's own click or key
  (`InputWebView`, which the pane's `PaneWebView` now is too), and
  downloads only where the host keeps them (`downloads`: the pane; an app's
  view keeps none, as before). `StrutPage` is never described with its
  address. A handle wins over an https link on the same deliverable.
- **Not here.** The iPhone and the official apps (no strut of their own:
  the row stays words); a preview inside the row; a handle on the
  orchestrator's own replies, which carry no artifacts yet (sphinx#391,
  "Not in this PR").
- **Checked.** `ControlEnvelopeTests` (a message's handles read beside its
  words; the paths and apps kept, with their `@<id>`; every other shape
  dropped), `HiveTests.aDeliverableOpensAloneOnPeelsOwnStrut` (`artifact`
  and `app` read back exactly by strut's UI, an escape in the path kept an
  escape; none on a home server). `swift test`: 1,052 pass. The Mac app
  builds with Xcode. By hand, two struts from the new pin, one standing in
  for the org with a job (`team/j-2`) holding `Lisbon plan.md`, a PNG, a PDF
  and an HTML page with a script, and Peel's strut holding a peer record for
  it: a WebKit view with the pane's configuration and `StrutPage`'s rules
  loaded `page(showing:)` for each. The markdown drew with its image (from
  a blob), its link opened the PDF in place and WebKit drew it (a blob
  frame), the PNG and the folder showed, the HTML page drew with its
  script not run (a `srcdoc` frame, `sandbox=""`), a path strut does not
  serve said so, no `src` or `href` held the key and the address lost it;
  with the pane's download rule, the viewer's Download saved the file under
  its name. Not yet `check-app.sh` (it needs the agent's DM on the local
  stack and a paired org), nor against a swarm. Reviews: an independent
  adversarial review (the pin's strut failing to stage, so an older strut
  was embedded without a word; a local file the viewer cannot show left
  with a dead link; the download rule with two owners; a deliverable
  outliving a strut restart; `endPage` reading a stopping view; a run id
  with a `/`, a control character in a file name and version-like app
  names accepted; `StrutPage` printing its address; an https link winning
  over a handle: all fixed). Left: `Handle`'s cases can be made without
  the checks (strut checks the path again, and the page encodes the whole
  value); strut's own names rules sit on `Handle` though `Hive` uses them.

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
building:** the Swift loop stayed the Mac's agent until PR 10, everything
new behind Account › Agent › "Run in strut (preview)", off by default and
only in dev builds. PR 10 (2026-10-18) removed the switch: Tom is the only
user, so strut became the agent at once rather than after a week's
preview, with no fallback in the UI.

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
| 8 | peel | **Dropped from Phase 1 for now** (Tom, 2026-10-18). Calendar by request: `calendar.events` and the three writes, the Calendar access prompt and usage string, writes behind the card | "What's on Thursday?" answers from Calendar; "move it to 3" shows a card and moves it once; denied access says so | high (writes, a new permission) | 5 |
| 9 | peel | iPhone: the agent DM shows talk and hides control (on PR 1's envelope), "Waiting for your approval on your Mac" | From the phone, with the Mac awake: message the agent and get the answer in the same thread as the Mac | medium | 1, 6 |
| 10 | peel | **Turn it on.** The agent's account from `agent_seed(seed, 1)` (sphinx-ffi v0.8.39), checked against the core's test vectors; first-run setup ("Give your assistant its own account", one 10-sat invite the agent registers with, then the key exchange); no switch: strut and the bridge are the agent in Debug and Release (runner in the sandbox), the Agent chat the DM for everyone, the local history read only; the Swift loop's code stays for PR 11 (Tom, 2026-10-18: faster than a week's preview, as the only user) | A signed Release build sets up, reads and sends inside the sandbox; Tom sets it up on his real account and uses it a day or two: catch-ups no slower than today, automations fire, nothing sent twice | high (keys, the sandbox) | The sphinx-rs pin at v0.8.39; 7 and sphinx#386 merged |
| 11 | peel | Remove the Swift loop: `AgentLoop` and the providers out of the app, `AutomationServer`, `peel-automation` and `peel/run-automation`, `AgentSession`'s turns and compaction; AgentKit keeps the client side | Builds; the journeys from 2, 3, 5, 6, 7 pass; nothing calls the removed code | high (a large deletion across the agent) | 10, plus a day or two of Tom's use (built 2026-10-19) |

```
now       S1 ✓  B1 ✓  S2 ✓  1
then      2    4
then      3
then      5
then      6    7    9         (8, Calendar: dropped for now)
then      6b
once the pin is v0.8.39: 10, then 11
```

S1, S2 and B1 are merged (strut#198, strut#195, sphinx#382). PRs 1 to 6
are merged (#311, #319, #321, #322, #323, #325), and PR 7 (#324).
PRs 2 and 3 follow PR 1 in turn, since each builds on the one before.
PR 1 is the only one that changes what ships before the preview: control
messages hidden in the lists, and the time zone setting merging keys. PR 4 stages runner as it is merged.

**Measuring "catch-ups don't get worse".** PR 5 adds a timing to the
Agent chat's journey: "what did I miss" on the same fixture account, on
the Swift loop and on strut. PR 10 does not ship if strut is more than 3
seconds slower (open question 3). PR 11 took the Swift side out with the
loop; the journey prints strut's time alone.

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

## 8. Journal

**PR 1, the control envelope (2026-10-16).** Built: `ControlEnvelope`
(`metadata.peel`) in PeelCore, written by `Engine.sendControl` (and the
CLI's `send-control`, for tests) and read by `Message.control`; the time
zone switch now sets `tz` beside the other metadata keys, so a resend
keeps `peel`. Decided while building:

- A message is a control message when it is text and its metadata's
  `peel` is an object with an `op`. A `peel` without one is a talk
  message's extras. A version, `op` or field shape this Peel does not
  read is `unsupported`: still a line, never acted on.
- The line is who sent it and the message's own text (what the official
  apps show), "Sam: Peel asked your Mac…", on one line as a preview shows
  it, at most 200 characters, in the quiet style of a tribe's membership
  notes, on the Mac and the phone. A blank one draws nothing. The name is
  there because until PR 4 there is no agent to tell apart: any contact
  can send a control message, and an unnamed grey line would read as
  Peel's own words. PR 6 can drop it in the agent's DM.
- One of ours that failed stays a bubble, for Retry and Discard; a deleted
  one is a deleted message, as any is.
- Only in a direct message: in a tribe the same metadata leaves a
  member's message a message, so nobody can dress text up as Peel's line.
- A control message your own device sent is not your send: it never pulls
  the list down to the newest (`ChatRow.listRow`).
- Not changed in PR 1: a control message from someone else counts as
  unread, notifies, and shows as a chat's preview, as any text does. The
  agent's DM does not exist before PR 4; leaving them out of the counts
  needs the database to know a control message (a column, as `senderTZ`
  is), which PR 2 is the place for. The same column saves reading each
  message's metadata again whenever the list is drawn again, which PR 1
  does (bounded at 64 KB a message). A search or a notification jumps to
  the line.

Review findings not applied, and why: the rule that a device's control
message is not your send stays specific to control rows rather than all
notes (a note of yours, "You asked to join", still follows, as before);
`MessageMetadata` reads `metadata` with its own decoder, not `BodyFields`,
because a body whose `metadata` is not a string must keep its content;
`AppModel.isTribe` falls back to "not a tribe" for a chat it does not
list yet, so a tribe member's control message could draw as a line there,
which the sender's name on the line makes harmless; and before PR 2 acts
on envelopes it should refuse duplicate `peel` keys and non-integer
versions, which Foundation reads and the bridge's serde does not.


Checked on a local stack (profiles `pr1-me` and `pr1-peer`, seeded by
`scripts/journeys/seed.sh`: a ~320-message chat with threads, the
`journeys` tribe with threads, and the bank): the four `control-*`
journeys pass (scrolled up, at the bottom, arriving while the tribe is
open, a bounce back to the tribe), and so do the other list journeys but
`search-early`, which fails on `main` too. The integration journey sends a
control message through the real core and reads the envelope and `tz`
back on the other side. The phone draws the same rows (`ChatRow`); it was
compiled, not run. The official apps were not checked: the line they show
is the message's content, as for any text.

**PR 2, device requests on the Mac: reads (2026-10-17).** Built: the
ledger, `deviceRequest` (v25), and `Engine+DeviceRequests`: a request
from the agent contact (`Setting.deviceAgent`) naming this device
(`Setting.deviceID`, which PR 4 passes the bridge as `BRIDGE_DEVICE`) is
stored, acked, done once through the handler the host gives
(`answerDeviceRequests`), and answered with a `result` whose `result` is
`{"text": …}`, the tool's `ChatData` as today's agent reads it. The Mac's
handler is `DeviceReads` (PeelAgent), over `SphinxTools`; the CLI's
`listen` answers too, and `peel device-agent <pubkey>` sets the contact.
Unset, nothing is answered: that is the preview's gate until PR 4 sets it
when it launches the bridge. Decided while building:

- **The ledger is in `peel.sqlite`, not `agent.sqlite`.** PR 3 writes a
  send's request id and the sent message's uuid in one transaction with
  the outgoing row, which only one database can do; and the agent store
  is a log meant to move between devices, while the ledger is this
  device's own.
- **Only the agent contact, only this device.** A request in a tribe, from
  anyone else, or naming another device gets nothing back and is not
  stored. A request this Peel cannot read (a later `v`) that names this
  device is answered `failed` with `unsupported`, and stored, so it is
  answered once.
- **The same message once.** History brings stored messages back; the
  ledger keeps the uuids of the copies it answered, so only a new copy
  (the bridge asking again) gets the stored answer again.
- **Signed by the agent, keyed by it.** Besides the chat, the message's
  signer must be the agent. A request is its id within its agent, so a
  change of agent never sends one agent's chats to another.
- **Off the inbound queue.** Storing and the ack happen as the message is
  handled; the read and the result run in the background, so a slow
  search never holds up the messages behind it. A request is claimed in
  the database (`running`) and finished only from there, so a live copy
  and the pass after a reconnect never do it twice; one past `not_after`
  when it is claimed answers `expired` and does nothing.
- **An answer that did not go is sent again.** `deliver` stores a failed
  send rather than throwing, so the ledger marks an answer `sent` only
  when its message did not fail, and the pass after a reconnect sends the
  rest. The bridge never resends a request it has an ack for, so without
  this a lost result would leave the run waiting.
- **Answered after the commit that stored it**, as purchases are, and once
  online again for what a stop cut short: a request stored and not done
  is done then (reads are safe to do again; a send found running will
  answer `unknown` in PR 3), one past `not_after` answers `expired`, and
  an answer that did not go is sent. Requests are forgotten a week after
  they expire.
- **Kinds.** `chats.list`, `chats.read` (with `thread`, that thread),
  `chats.threads`, `chats.unseen`, `chats.search` (`q`). `since` is not
  read: today's tools take none; PR 5 adds it if the steps need it. Any
  other kind is `failed`, "unsupported: this Mac does not answer '…'
  requests". The bridge's own id and kind rules are checked again here.
- **Size.** A result whose envelope is over 32 KB is `failed` with the
  reason ("ask for less"), never cut: a cut would lose `ChatData`'s end
  marker. `ChatData` caps a result at 12,000 characters, so only text
  heavy in emoji gets near it.
- **The lines the official apps show:** "Peel on your Mac is on it" for
  the ack, and "Peel on your Mac answered" (or the status's words) for the
  result.

Review findings not applied, and why: keeping the agent in memory rather
than reading the setting once per incoming batch (one small read; one
source of truth until PR 4 owns the setting); a shared helper for the
two "answer an incoming message by itself" paths, purchases and requests
(they differ in gating and ledger; revisit if PR 3 adds a third); and
reading the envelope once instead of through `Message.control` (only the
agent's messages pay it). A failed ack or result of ours shows as a
failed bubble in the agent's DM, as PR 1 draws any failed control
message of ours; PR 6, which draws that DM, decides what it shows.

Checked on a local stack: `DeviceRequests.theMacAnswersItsAgentOnce`
passes (one answer through the real reads, a repeat from the ledger
with no second read, `expired`, an unknown kind refused, Carol's request
and one for another Mac answered with nothing and not stored, then a
read cut short by a stop finished after a relaunch, with nothing answered
twice on the catch-up). Across the other journeys, only
`Contacts.anUnpaidContactKeyPaysNothing` failed in one full run, and it
passed when run again on its own; nothing in it sets an agent.

Not done here, from PR 1's list: control messages still count as unread,
notify and preview. The agent's DM appears in PR 4, so that work moves
there, with the column it needs. PR 1's note on duplicate `peel` keys
and a non-integer `v`: only the agent's own messages are acted on, and
the bridge writes them with serde, which writes neither, so there is no
reader the two could disagree for.

**PR 3, sends and approvals by device request (2026-10-17).** Built: the
`send` and `approve` kinds on the Mac (`DeviceActions`, PeelAgent), their
cards in the agent's DM (`DeviceCards`, the Mac), send grants
(`SendGrants`, AgentKit, beside `ApprovalRules` in `agent.sqlite`) and
their list with Revoke in Account › Peel agent, shown only with the
preview on. Decided while building:

- **One card, one gate.** A `send` is planned by today's send tool
  (`SphinxTools.send`: the chat resolved, the thread and reply checked,
  the price on the card) and asked through `ApprovalGate` with the tool's
  own name, so today's "Always allow for Kate" covers it and a card's
  "Always allow" is today's rule. The card is `AgentApprovalCard`, drawn
  in place of the request's line (`ChatRow.approval`, from
  `AppModel.waitingCards`, so the list measures the row again when the
  card comes and goes). Unlike the agent chat's, it does not take the keys
  as it appears: the agent decides when it comes, so a Return meant for
  the composer never allows it. Once you move to it, Return allows only a
  send that costs nothing, and Escape denies. A card taken down unanswered
  (the account closed, Peel quit) answers nothing: `ApprovalGate`'s ask
  may now come back empty, which is `stopped`.
- **Answered as sent only when it went.** A send stored whose publish
  failed, or may have, answers `unknown`, not `done`: the row is in the
  chat, and a reconnect's resend may still send it
  (`Engine.SendUnconfirmed`).
- **At most once.** Nothing is published before a send's commit, so the
  send and its record are one write: the commit that stores the message
  also marks the request `sending` (v26) with the message's uuid, only
  while it is running and in time; otherwise the whole commit is
  abandoned, unpublished. A request found `sending` after a stop is never
  sent again: it answers `unknown`, naming the uuid (Peel's own resend may
  still deliver a contact's message that was stored and not published,
  which is why it is not `failed`). A send that ends in anything but
  `done` once its message was stored is `unknown` too. A card waiting
  when Peel stops is not an answer: the request stays `running` and its
  card comes back after the relaunch, until its time.
- **Expiry.** A card still up at the request's `not_after` comes down and
  answers `expired`; a click after it does nothing (the engine checks the
  time again as it marks the send).
- **Price.** `max_price_sats` (0 when left out) is the most a message may
  pay; a tribe over it is refused before any card. The send pays no more
  than the card showed, as today.
- **Grants.** Made only by an `approve` card that carries `grant`
  (`automation`, `name?`, `chats`, `max_price_sats`). The card adds the
  Mac's own words for it (the chats as this Mac names them, the cap as a
  cost, the `[Agent]` prefix), first, before the agent's lines, so a
  click is never on the agent's words alone; the automation's name must be
  one line; a grant card always has a cost line, so only a click makes
  one, never Return; and "Always allow" is never offered for `approve`.
  A grant keeps the request that made it: asked again after a stop, that
  request finds it and answers `done` rather than showing a second card. A `send` with
  `automation` needs that automation's grant, a chat in it and a price
  under its cap; it gets `[Agent] ` first and no card; anything outside
  the grant is `denied`. Deleting an automation in Peel's Automations
  view revokes its grant; one deleted by today's Swift agent's
  `delete_automation` or in strut (PR 5's steps) is PR 7's to revoke, with
  the automations that have grants.
- **The grants list** shows whenever there is a grant, rather than behind
  the preview switch: a grant is only made through the preview's
  requests, and one in force must always have its Revoke. Requests
  themselves stay gated by `Setting.deviceAgent`, as in PR 2.

Review findings not applied, and why: an agent `cancel` with `re` does
not take a card down yet (the bridge does not send one; when it does, the
card should close as `expired`); a grant kept again is revoked then
added, two writes, which fails safe (no grant); grants are read from the
agent store on each automation send rather than kept in memory (a few
records; revoking takes effect at once); the device's cards share the
agent chat's rules through `AgentSession.rules` and `reloadRules` rather
than a gate the session hands out (one caller); and the card-or-deadline
race is written again beside `Automation.run`'s (different results). The
security pass found nothing over its bar. The independent review's
findings were applied (an unconfirmed publish answered `done`, the
automation window, a grant outliving a later Deny, Return making a grant,
a delete not revoking when the handler was never made, a cancellation
read as expiry, two cards for one request), but for the Swift agent's
`delete_automation`, which leaves a grant to PR 7 as above.

Checked: `DeviceActionsTests` (the card, once, deny, expiry, the rules,
the cap, grants and their cap and window, a failed publish never `done`:
that test fails without the fix), `ControlRowTests` (one card per
request, on its newest copy), `ApprovalTests` (an unanswered ask is
`stopped`) and `MigrationTests.v26RecordsASendWithItsMessageAndOnlyOnce`;
on a local stack `DeviceRequests.theMacSendsAsYouOnceAndOnlyWhenAllowed`
(allow sends once and a repeat sends nothing, deny, expiry, and `unknown`
after a relaunch with the request left `sending`, as a kill there leaves
it: the window between the mark and the commit cannot be hit from outside
the engine, so the journey leaves the row as the kill would) passes with
PR 2's journey.
