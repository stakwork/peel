# Automations

Last updated 2026-10-15. **v1 built** (PR #221); **system automations
built** (Peel's half, [../system-automations.md](../system-automations.md));
"Later" and the open questions are what is left. Builds on
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
  one step, `peel/run-automation`, a custom step Peel publishes with it:
  it reads the token and Peel's port from strut's encrypted secret store
  in code (`PEEL_AUTOMATION_TOKEN`, `PEEL_AUTOMATION_PORT`) and posts to
  127.0.0.1 at that port through `ctx.services.http`. Its config is only
  the run (name, prompt, since), so the workflow says nothing about Peel
  and its config can neither carry the token nor change where Peel's step
  sends it. (strut's own `exec` and `agent` steps can still read any stored
  secret by name with `secretsEnv`: strut's to tighten. The store's
  encryption protects copies and backups, not against a process running as
  the same user.) Every Peel
  automation is an automation on this workflow: `GET
  /automations?workflow=peel-automation` lists them all. The step's
  reply from Peel becomes the run output, so strut's run history holds what each
  run said. On opening the agent chat, Peel
  reads the workflow's active version and publishes a new one only when
  its content changed: each version is labelled `p-` plus a hash of it
  (`AutomationsClient.install`).
- **`since` comes from `{{ last.finishedAt }}`.** "My messages" therefore
  means the messages since the last successful run, with a fallback of 7
  days on the first run.
- **Peel listens on loopback only.** `AutomationServer` is a swift-nio
  HTTP server bound to 127.0.0.1, port 4778 unless `defaults write
  dev.peel.mac automationPort` says otherwise. It needs a bearer token,
  made when the agent chat opens and kept only in memory; Peel puts it and
  its port in strut's secret store before installing the workflow, so it is never in a workflow file. strut encrypts that store
  with `STRUT_SECRET_KEY`, a key the profile keeps (`Profile.strutKey`,
  `BundledStrut`). If Peel cannot store them, the Automations view
  says so, and fires fail with 401 until it can. It rejects anything else. It runs while Peel's strut is running (the
  one it ships, `BundledStrut`), the same strut as the memory. This is the "channel from
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
  sentence, the next run, and the last run's status (ran, failed, missed,
  running). Paused automations are dimmed. There is no field to add one:
  automations are made by asking the agent, so there is one way to make
  one and one approval card.
- **Empty states** (approved on the "Peel Automations empty states"
  canvas, A, 2026-10-13): no model connected → "Set up Peel's agent", with
  Set up opening the Connect panel; no strut → "Connect strut", with Open
  Account; nothing yet → "No automations", with Ask Peel opening the agent
  chat.
- **Missed:** a one-off whose time passed with no run (the Mac asleep,
  strut or Peel not running) shows "Missed" under Done, not as if it ran.
  strut never runs it late; Run now does.
- **Detail view:** a row opens in place: the prompt (editable), Pause or
  Resume, Run now, and Delete (in its menu, confirmed by a second click).
  Below them is run history from strut's runs for this automation, each
  delivered result rendered as the agent chat renders it. The schedule is
  changed by asking the agent, which shows strut's sentence on its card.
- Reads come from strut, every 30 seconds while the view is on screen.
  Nothing is cached in `peel.sqlite`.
- **System automations** ([../system-automations.md](../system-automations.md)):
  a "Yours" | "System" choice under the header (`SegmentedChoice`). Yours
  is the above, `peel-automation`'s only. System lists strut's
  `category: system` automations: name, the workflow's description, the
  last run and a switch; opened, the schedule, Run now and the runs (the
  agent's text and its cost). No prompt and no Delete. One muted line
  says which model they run on and which provider sees the memory. The
  badge counts both tabs' failures.

## Delivery

| v1 | Later |
|---|---|
| A message in the agent chat (`agent.sqlite`), with the automation's name as its title | A Sphinx message to your own phone, once the agent has its own identity (agent-brain.md phase 6) |
| A local notification through `Notifier` that opens that message | Email, through a connector |
| The text is the strut run's output | A text message |

## Where it runs

| | Mac now | Home server later |
|---|---|---|
| strut and the schedule | the strut Peel ships, on this Mac | strut moved to the Mac mini, with the same records |
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
7. **Peel: system automations** (2026-10-14,
   [../system-automations.md](../system-automations.md)).
   - Done: `AutomationsClient.list` reads every workflow's automations
     (`workflow`, `category`; a system one's description from its active
     version, `GET /workflows/<name>`, read once per strut); toggle, Run
     now and runs on each automation's own workflow; a system run's
     `{ text, cost }`. `setModel` puts `STRUT_DEFAULT_MODEL`
     (`<provider>/<model>`) and the provider's key in strut's secret
     store, and takes the other providers' keys out (all of them, and the
     model, with none connected); `AppModel.modelChanged` calls it apart
     from `install` and the automation server, one at a time, when strut
     starts and on each change of `AgentSession.connection`
     (`credentialChanged`; the same credential handed to the same strut
     again is skipped); a Keychain that cannot be read leaves the store
     alone. strut is started with no provider key of the shell's. Once
     strut has a model, each system automation Peel never turned on is
     turned on once (`Setting.systemAutomationsOn`, by workflow, per
     profile: strut makes a deleted one again under a new id), at agent
     open too; one the person switches is recorded once strut took it, so
     it stays as they left it, and a record that cannot be read or kept is
     said. The
     agent's tools see and change `peel-automation`'s only and refuse any
     other id. `PeelSwitch` came out of `FormSwitchStyle` for the row.
   - Checked: `AutomationsClientTests` against a loopback `HTTPStub`
     (moved to PeelTestSupport): workflow and category, a system run's
     text and cost, paths per workflow, the agent refusing a system id,
     the turn-on rule, the secrets per provider and on disconnect. The
     full suite. Offscreen on a development profile with strut's
     `feat/system-automations` (f2ac642) staged in a scratch
     `PEEL_STRUT_STAGE` and the Anthropic stub: Connect, the System tab,
     the opened row, Run now (strut ran the agent with the stored model
     and key; Anthropic refused the stub key, shown as "Didn't finish"),
     the switch. Idle on the System tab: 0% CPU.
   - Learned: a `.task` on a view that renders nothing never runs, so the
     runs are read from the opened row, not from the list inside it; and
     keyed on the whole last run, or a run that finishes after it was
     first seen never shows. strut's `pack` step may write the cost as
     text.
   - Not applied from review: deleting provider keys Peel did not write
     (the bundled strut's store is Peel's alone); one row view for both
     tabs (they share the status, but differ in menu, prompt and switch);
     the switch inside the row's button (as other rows' own buttons);
     running `setModel`'s few loopback calls side by side.
   - Next: Tidy memory's real run once strut ships it; undo
     (`memory/unmerge`) is out of v1.
8. **No run bookkeeping in memory** (2026-10-14): a run had saved its
   "last checked" time as a Fact on Self; the automation, memory and run
   prompts now say each run is told when the last one finished.

9. **Runs while the Mac is locked** (2026-10-15). Tom's "Missed messages
   check" fired at 09:00 on a locked Mac and failed with "Peel answered
   500: Could not read the connected model's key.": the agent's key was
   `WhenUnlockedThisDeviceOnly`.
   - Done: `KeychainItem.accessible`, chosen where `Profile` builds each
     item: the agent's key (`dev.peel.agent`) is
     `AfterFirstUnlockThisDeviceOnly`; everything else stays
     `WhenUnlockedThisDeviceOnly`, strut's key (`dev.peel.strut`) among
     it: strut starts with the account, behind the PIN (and after a crash
     only on the next chat send), and the system automations use the
     running strut's key in memory, so widening it would only add
     exposure. An item kept under another class moves on its next read
     (`SecItemUpdate` of `kSecAttrAccessible`, a failure logged once per
     item and launch, status only, and tried again next read) or write,
     so nobody reconnects; the agent reads its key when the account opens.
     Development profiles keep their files. A locked Keychain
     (`errSecInteractionNotAllowed`, the data-protection Keychain's only)
     is `KeychainLocked` (a `LocalizedError`, so the agent chat's notice
     reads plainly), never none kept; `handModelToStrut` still leaves
     strut's store alone on any read error. `ModelError.invalidKey`
     carries its status (401 by default) so a 403 is told apart without
     changing the chat. Run failures read as one sentence
     (`AutomationFailure`, `AutomationRunRecord.failure`, which masks
     anything shaped like a key first, `ModelError.maskingKeys`):
     - "Didn't run: your Mac was locked, so Peel couldn't use your
       model's key."
     - "Didn't run: Peel couldn't read your model's key."
     - "Didn't run: no model is connected. Connect one in Account."
       (Peel's runs and strut's)
     - "Didn't run: Peel's account wasn't open."
     - "Didn't run: Peel couldn't be reached (it may have been closed)."
       (strut's `fetch failed` on `peel-automation`, or a run naming no
       workflow)
     - "Didn't run: Anthropic rejected the key. Replace it in Account."
       (a 401: strut's agent step only, the provider named when its words
       say which; Peel's runs with the connected provider)
     - "Didn't run: OpenAI refused: <reason>" for a 403 in Peel's runs
     - anything else after "Didn't finish: ", with strut's "Peel answered
       500: " taken out. The view's colour stays `Theme.attention`.
   - Checked: `AuditSecretsTests` (each item's class; a locked status is
     not none kept), `AutomationsClientTests` (strut's and Peel's raw
     failures to the words shown, another step's 401, masked keys, a run
     with no workflow), `AutomationTests` (401, 403 and no provider in
     Peel's runs), `ModelErrorTests`; the full suite. Offscreen on a
     scratch development profile with `-strut YES`, the staged strut and
     a stub key: Run now on the system automation showed "Didn't run:
     Anthropic rejected the key. Replace it in Account." in the run list.
     Not driven: a locked screen (cannot be offscreen) and the class move
     itself (`swift test` and the offscreen check bundle have no Keychain
     entitlement, so a driver step for it would not reach the
     data-protection Keychain); a Peel run through the automation server
     (its token lives in memory only).
   - Not applied from review: a reason code in the reply instead of
     sentences recognised by "Didn't " (a change to what strut stores);
     the step throwing without "Peel answered NNN: " (old runs keep the
     prefix, so the strip stays); one wording for a refused key across the
     agent chat, `ModelError` and here (Tom chose these words); the
     provider from the connected credential rather than a refusal's words
     (a run read later may predate a change; OpenRouter's refusal names
     nobody and reads "the model's provider"); "Didn't run" for a key
     refused after some steps (the key is the same on every call); the
     agent chat still treating a 403 as a dead key (`isKeyRefused`,
     Replace key: a chat change, raised apart); `exists`, and so
     `hasMnemonic`, taking a locked Keychain for no account (unchanged
     here, raised apart); moving the agent's key apart from its first
     read (it is read when the account opens, behind the PIN).
     `/security-review`: no findings. `scripts/risk.sh` says medium: its
     key pattern misses `SecretStore.swift`, where `KeychainItem` lives;
     ranked high by hand (keys).
   - Next, raised apart: strut's keys over stdin rather than the
     environment; strut started again after a crash without waiting for a
     chat send.

## Risks

- **Peel must be running.** On the Mac, an automation only works while
  Peel is open and the Mac is awake. A failed run shows in the sidebar,
  never silently. The home server fixes this.
- **Read text steering the agent.** A headless run has no tool that sends
  to anyone but you. Text in a read chat can at worst change what you are
  told.
- **Cost.** Every run is a model call over possibly many messages. v1
  shows no cost per run and sets no cap; strut's `maxRunCostUsd` on
  `peel-automation` could cap a run later.
- **The loopback endpoint.** It is bound to 127.0.0.1, needs the token,
  and does nothing but run the automation prompt it was given.

## Open questions

1. Does v1 cover "capture Friday, deliver Sunday" (`deliver_at`), or only
   one time per automation?
2. Delivery in v1: the agent chat and a notification only, or also a
   Sphinx message to yourself so it reaches the phone now?
3. Should an automation ever act without you (for example, reply to
   someone)? v1 says no; it drafts instead.
