# Automations

Last updated 2026-10-13. **v1 built** (PR #221); "Later" and the open questions are what is left. Builds on
[agent-brain.md](../agent-brain.md) (the Mac is the brain, strut owns the
graph) and strut's automations (`strut/plans/automations.md`, implemented
2026-09-20).

## What it is

A standing instruction the agent carries out on a schedule:

> "Read my messages and threads every Friday at 5 pm and give me a to-do
> list for Sunday night."

Two ways in, one record:

1. **Ask the agent.** In the agent chat, say it in your own words. The
   agent turns it into a schedule and a prompt and shows a card with the
   plain-English schedule and the next three runs. Create or Cancel.
2. **The Automations sidebar item.** It sits at the top of the sidebar,
   beside Threads and Mentions. Every automation is listed there. You can
   add one, pause it, run it now, edit it, delete it, and see what each run
   produced.

Each run reads what it needs (chats, threads, memory), writes what it
learned to the graph through strut, and delivers its result to you.

**A reminder is an automation that runs once.** "Text me the Cardiff score
tomorrow at 8am" is strut's `once` trigger. "Every Saturday after the
games finish" checks every 15 minutes on Saturdays between 16:45 and
19:00, and stays silent until there is something to say. It skips the
rest of the day through `{{ last.output }}`. Every run therefore ends in
one of three ways:

| Outcome | HTTP | strut's run | You see |
|---|---|---|---|
| `delivered` | 200 | success, with the text as output | A message in the agent chat and a notification |
| `nothing` | 200 | success, with no text | Nothing |
| `failed` | 500 | error. `since` doesn't move on, because `last` counts only successful runs | A failed run in the sidebar |

The sidebar groups automations by state, not by kind:

- **Upcoming:** one-off automations that haven't run yet.
- **Recurring.**
- **Done:** one-off automations that have run. strut never disables a
  `once`; whether it ran is worked out from its runs.

## Who owns what

| Part | Owner | Why |
|---|---|---|
| The schedule, the clock and run history | **strut** (exists) | strut already has a closed trigger grammar, `nextFire`, `describeTrigger`, a preview endpoint, Run now, overlap rules and `{{ last }}`. Peel reuses all of it and writes no scheduler. It moves to the home server with strut |
| The graph | **strut** (exists) | Memory writes go through the existing `MemoryTools` → `POST /steps/memory/<verb>/run` |
| The work: reading Sphinx chats | **Peel** | The messages live in Peel's `peel.sqlite`, and the Sphinx read tools are Swift in `PeelAgent`. strut cannot read them |
| Creating and managing automations | **Peel** | The agent tools and the sidebar are both clients of strut's automation endpoints |
| Delivery | **Peel** | Only Peel can post to the agent chat, notify, or send a Sphinx message |

Peel stores nothing new for the schedule. strut is the single source of
truth, so strut's own UI shows the same automations.

## The fire path

```
strut tick ── Fri 17:00 ──► run workflow `peel-automation`
                              input: { name, prompt,
                                       since: "{{ last.finishedAt }}" }
                              │
                              └─ step `http` POST 127.0.0.1:<port>/automations/run
                                   (bearer token, timeout 10 min)
                                       │
                 Peel AutomationServer ◄┘
                   └─ headless agent run: Sphinx read tools + memory tools, no approver
                        ├─ reads chats and threads since `since`
                        ├─ remember / recall ──► strut graph
                        └─ its reply ──► agent chat + notification (+ phone, later)
                   ◄── { status, text?, error? } ── becomes the strut run's output
```

- **One workflow, `peel-automation`, that Peel installs itself.** It holds
  one `http` step, with Peel's address and token in its params. Every Peel
  automation is an automation on this workflow: `GET
  /automations?workflow=peel-automation` lists them all. The `http` step's
  response becomes the run output, so strut's run history holds what each
  run said. strut needs no code change. On opening the agent chat, Peel
  reads the workflow's active version and publishes a new one only when
  its content changed: each version is labelled `p-` plus a hash of it
  (`AutomationsClient.install`).
- **`since` comes from `{{ last.finishedAt }}`.** "My messages" therefore
  means the messages since the last successful run, with a fallback of 7
  days on the first run.
- **Peel listens on loopback only.** `AutomationServer` is a swift-nio
  HTTP server bound to 127.0.0.1, port 4778 unless `defaults write
  dev.peel.mac automationPort` says otherwise. It needs a bearer token,
  made on first use and kept in the Keychain (`Profile.automationToken`),
  and rejects anything else. It runs while a strut is set in Account ›
  Peel agent, the same strut as the memory. This is the "channel from
  strut back into the app" that agent-brain.md says Option B lacked. The
  same endpoint later lets strut jobs reach Sphinx tools.

### The headless run

It is `AgentLoop.run` with no history and **no approver**, outside the
agent chat (`AutomationRun`). Its message says it is a scheduled run,
gives the `since` time, and says no one is watching. Its reply is what is
delivered: a turn in the agent chat named for the automation
(`AgentSession.deliver`), and a notification. The reply
`NOTHING_TO_REPORT` delivers nothing. Its tools:

| Tool | Effect | In a headless run |
|---|---|---|
| `current_time`, Sphinx read tools, `list_automations` | read | Yes |
| `remember`, `recall`, `read_memory`, … | memory | Yes |
| `send_sphinx_message`, and the tools that change automations | ask | **Not offered.** A loop with no approver is not told of tools that ask, and refuses any call to one. Nobody is there to approve a card, and a read message could steer it. An automation that would message someone says what it would send instead |

## Creating one from the agent chat

New tools in `PeelAgent/AutomationTools.swift`, beside `MemoryTools`. They
use the same strut base URL and the same `Web.isThisMac` check:

| Tool | Effect | Calls |
|---|---|---|
| `list_automations` | read | `GET /automations?workflow=peel-automation` |
| `preview_schedule(trigger)` | read | `POST /automations/preview` → `{ summary, next }` |
| `create_automation(name, prompt, trigger, deliver)` | act: approval card | `POST /workflows/peel-automation/automations` |
| `update_automation(id, …)`, `pause`, `resume` | act: approval card | `PATCH …/automations/:id` |
| `delete_automation(id)` | act: approval card | `DELETE …/automations/:id` |
| `run_automation_now(id)` | act | `POST …/automations/:id/fire` |

- **The model writes strut's trigger object directly.** It is a closed
  grammar (`interval`, `day`, `week`, `month`, `once`, each with an IANA
  `tz`), and its zod descriptions go into the tool schema. Peel does no
  date parsing of its own. strut validates the trigger, and the card shows
  strut's `summary` and next fires, so the person approves the schedule
  strut will actually run.
- **The card** reuses the send approval gate (`AgentKit/Loop/Approval.swift`)
  and shows the name, the schedule ("Fridays at 5:00 PM"), the next three
  runs, the prompt and the delivery. Create or Cancel. There is no "Always
  allow".
- **Two times in one sentence.** "Read Friday at 5, to-do list for Sunday
  night" has two times in it. The agent asks one question: run Sunday
  evening and cover everything since Friday at 5 (one automation), or
  capture on Friday and deliver on Sunday. v1 builds only the first. The
  second needs a `deliver_at`, which is listed under Later.

## The Automations sidebar

- **Item:** Automations, first in the sidebar, above Threads
  (`AutomationsLink` in `Sidebar.swift`, `Destination.automations`). Its
  quiet outline badge counts automations whose last run did not finish.
- **List view:** one row per automation, with its name, the schedule
  sentence, the next run, and the last run's status (ran, failed, running).
  Paused automations are dimmed. At the top is a "New automation" field.
  Typing there and pressing Return opens the agent chat with that text, so
  there is one creation path and one approval card.
- **Detail view:** a row opens in place: the prompt (editable), Pause or
  Resume, Run now, and Delete (in its menu, confirmed by a second click).
  Below them is run history from strut's runs for this automation, each
  delivered result rendered as the agent chat renders it. The schedule is
  changed by asking the agent, which shows strut's sentence on its card.
- Reads come from strut, every 30 seconds while the view is on screen.
  Nothing is cached in `peel.sqlite`.

## Delivery

| v1 | Later |
|---|---|
| A message in the agent chat (`agent.sqlite`), with the automation's name as its title | A Sphinx message to your own phone, once the agent has its own identity (agent-brain.md phase 6) |
| A local notification through `Notifier` that opens that message | Email, through a connector |
| The text is the strut run's output | A text message |

## Where it runs

| | Mac now | Home server later |
|---|---|---|
| strut and the schedule | strut on this Mac (its connection file) | strut moved to the Mac mini, with the same records |
| The work | Peel.app's `AutomationServer` | A headless `peel serve` (the CLI already has `listen`), with the same endpoint and the same tools |
| Asleep or closed | The run is skipped (strut skips missed fires) or fails because Peel is closed. The sidebar shows it, and Run now retries | Always on |

When strut gains Sphinx tools through the same loopback endpoint, the work
can move into strut's `job` workflow. This needs no change to the record or
the sidebar: the automation's workflow changes from `peel-automation` to
`job`.

## One workflow per target

strut is the hub: one clock for everything. A strut automation always
fires a workflow, so each thing strut can trigger gets its own small
workflow:

| Workflow | Calls |
|---|---|
| `peel-automation` | Peel's `POST /automations/run` (this plan) |
| `sphinx-automation` | The official Sphinx app's or a Sphinx service's own `/automations/run` (later) |
| Others | Any service through an `http` step, or pure strut work such as the janitors |

Every client implements the same contract:

```
POST /automations/run   Authorization: Bearer <token>
{ name, prompt, since }  →  { status: delivered | nothing | failed, text?, error? }
```

## Steps

0. **Spike (half a day).** Create `peel-automation` by hand in a local
   strut, with an `http` step to a stub, and an automation that runs every
   minute. Confirm that it fires, that the `http` response becomes the run
   output, and that `{{ last.finishedAt }}` resolves. Also find out how
   Peel hands strut its URL and token: through workflow params set without
   publishing a version, or as a fixed port and a token from a file.
   **Done 2026-10-13** against a local strut (`exp/ladybug-memory`), with
   a stub on 127.0.0.1:4777. Run now → `http` → the stub, authenticated.
   The stub's reply is stored as the run output, the run is stamped with
   `automation`, and `since` is `null` on the first run and the previous
   run's `finishedAt` after it. Findings:
   - `since` must be declared `{ type: json, required: false }`. A
     required string fails the first run, because `last.finishedAt` is
     `null`, not missing.
   - Peel's URL and token can live in the workflow's `params`. Changing
     them publishes a new version, which is fine for a value that rarely
     changes.
   - The clock is off when strut runs with `STRUT_SCHEDULER=0`, as the
     local dev `.env` sets it. `/health` doesn't say whether the scheduler
     is on. Peel infers it: an enabled automation whose `nextRunAt` is more
     than a minute in the past means the clock is off, and the
     Automations view says so.
1. **Peel installs `peel-automation` itself** (no strut change). The
   contract above goes into strut's docs when `sphinx-automation` follows
   it.
2. **Peel: `/automations/run`.** It includes the loopback listener and its
   token, a headless `AgentLoop.run` over the read tools and the memory
   tools (no approver, so anything that asks is refused), the scheduled-run
   preamble, and delivery to the agent chat with a notification. Done when
   a `curl` to the endpoint delivers a summary of today's unread messages.
3. **Peel: `AutomationsClient`,** the strut HTTP calls (list, preview,
   create, update, delete, fire) beside `MemoryServer`. The agent tools and
   the sidebar both use it.
4. **Peel: `AutomationTools`,** with the approval card for create, update
   and delete. Done when "every weekday at 9 summarise my unread tribes"
   creates the automation in strut, and Run now delivers.
5. **Peel: the Automations sidebar,** with the list, the detail view, run
   history and the failure badge.
6. **Later:** `deliver_at`, delivery to the phone, `sphinx-automation`,
   `peel serve` on the home server, and strut jobs for heavy work.

## Risks

- **Peel must be running.** On the Mac, an automation only works while
  Peel is open and the Mac is awake. A failed run shows in the sidebar,
  never silently. The home server fixes this.
- **Read text steering the agent.** A headless run has no tool that sends
  to anyone but you. Text in a read chat can at worst change what you are
  told.
- **Cost.** Every run is a model call over possibly many messages. The
  run's token cost is shown in its history. strut's `maxRunCostUsd` on
  `peel-automation` caps a run.
- **The loopback endpoint.** It is bound to 127.0.0.1, needs the token,
  and does nothing but run the automation prompt it was given.

## Open questions

1. Does v1 cover "capture Friday, deliver Sunday" (`deliver_at`), or only
   one time per automation?
2. Delivery in v1: the agent chat and a notification only, or also a
   Sphinx message to yourself so it reaches the phone now?
3. Should an automation ever act without you (for example, reply to
   someone)? v1 says no; it drafts instead.
