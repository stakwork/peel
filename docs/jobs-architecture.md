# Jobs: architecture

Last updated 2026-10-13. **A proposal for Tom's review; nothing is built.**
How Peel's agent hands work to Strut. A **job** is any job to be done:
research, a named workflow, a scheduled task, coding, bulk work, or work in
Slack, Drive, GitHub and other services. Connectors are one thing a job can
use. They are not what a job is. This follows Tom's direction of
2026-10-13, which replaced the first draft of this PR (a Swift sub-agent per
connector; see "Considered"). It builds on [agent-brain.md](agent-brain.md),
which is still a proposal: the Mac is the brain, Strut runs on it, and the
phone is a remote. The UX is on the design board (boards 6–10).

## In one paragraph

Peel's agent keeps the chat, the Sphinx tools, Calendar and the approval
card. Anything bigger, it hands to Strut with **`start_job`** and
**`continue_job`**, the pattern Hive already uses against the same Strut
contract. A job is a Strut workflow run under an id that Peel mints. The
general workflow is `job`: an agent in a job directory with a session, and
with the steps the person has enabled granted as tools (`slack/*`,
`gdrive/*`, `github/*` …). A named workflow does one specific thing. Each
turn ends with `{text, artifacts, ask}`. An `ask` becomes a **Needs you**
card in Peel, and an `ask` that carries an approval becomes the usual
**Allow once / Always allow / Deny** card. Connector steps and their tokens
live in Strut. Peel never holds them.

## The shape

```
 Peel (Mac; the phone is a remote over Sphinx, agent-brain.md)
 ┌────────────────────────────────────────────────────────────────────┐
 │ Agent chat · AgentLoop · approval card · Needs you card            │
 │ tools: Sphinx · memory · calendar (EventKit) · start_job ·         │
 │        continue_job                                                │
 │ Jobs: a Job record per job (id, title, status, last run, last ask) │
 │       follows each running turn; the Active jobs list in context   │
 │ JobsClient, beside AutomationsClient, over the same MemoryServer   │
 │ (strut found by its connection file; loopback; bearer key)         │
 │ AutomationServer (loopback) also takes the jobs' run.end callback  │
 └───────┬──────────────────────────────────────────────▲─────────────┘
         │ POST /workflows/<job|name>/run               │ run.end callback →
         │   { job, title, input:{prompt}, params,      │   POST 127.0.0.1/jobs/done
         │     callback }                               │   {text, artifacts, ask}
         │ POST /steps/:type/run (an approved write)    │ SSE …/runs/:id/stream
         │ PUT /secrets/:name (a pasted token)          │   (live steps, while shown)
 ┌───────▼──────────────────────────────────────────────┴─────────────┐
 │ Strut on the same Mac (Node 22)                                    │
 │   job workflow: job/dir → agent(session = job,                     │
 │                 agentTools = params.tools) → pack                  │
 │   named workflows (a daily digest, a PR review …)                  │
 │   steps: slack/* gdrive/* x/* github/* git/* graph/* memory/* …    │
 │   secrets.json (AES-GCM, STRUT_SECRET_KEY): connector tokens       │
 │   jobs/<id>/ directory · sessions · StrutJob nodes · GET /jobs     │
 └────────────────────────────────────────────────────────────────────┘
```

### What stays in Peel

| Piece | Why |
|---|---|
| The agent loop, chat and Sphinx tools | Already built; Sphinx sends need PeelCore |
| Calendar, as direct tools (EventKit) | Local to Apple and Swift-only; about five small tools; reads run at once, writes go behind the card |
| The approval card and `ApprovalRules` | One gate for everything that acts, Sphinx or job |
| Job records and the Active jobs list | Ids must survive compaction (agent-brain.md); Hive keeps them only in chat text |
| The Connections screen | Lists Strut's connector steps, enables them for jobs, and takes pasted tokens or starts sign-in |

### What moves to Strut

| Piece | Where |
|---|---|
| Connector steps | `src/steps/lib/<service>/*.ts`, one folder per service; adding a connector means adding steps |
| Tokens | Strut's secret store (`secrets.json`, or `actor-secrets` per person); once deposited, never in Peel or its Keychain |
| Job runs | The `job` workflow and named workflows, sessions, the job directory, artifacts |
| Step schemas | Only the job agent gets the granted steps' schemas; Peel's agent sees none |

## The main agent's view

Two tools and a short context block. The system prompt is otherwise
unchanged.

```
start_job
  Hand a job to Strut, which works on it in the background: research,
  multi-step work, anything in the user's connected services, or a named
  workflow. Pass the user's words as they said them. Returns at once; the
  result appears in this chat when the turn ends. Do not call again for
  the same work.
  Connected services jobs can use: Slack, Google Drive, GitHub.
  Workflows: daily-digest (Summarise yesterday's Slack and Linear), …
  input:  { title: string (≤120), prompt: string, workflow?: string = "job" }
  output: { status: "started", job_id, run_id, note }
        | { status: "error", error }

continue_job
  Send the next message to an existing job: an answer to its question, a
  follow-up, a correction. Use a job_id from Active jobs.
  input:  { job_id: string, prompt: string }
  output: { status: "continued", job_id, run_id, note }
        | { status: "busy", job_id, note } | { status: "error", error }

Active jobs (kept by code, outside compaction; at most 10, newest first)
  - 3f2a… "Friday Night Chef plan": needs you: "Which supermarket?" (2h)
  - 91bc… "Weekly Linear triage": running (4m)
```

- **The shape matches Hive** (`hive/src/lib/ai/strutTools.ts` `start_job`
  and `continue_job`), with two differences. Hive's `workspace` field is
  dropped, because Peel has one Strut. Ids are `job_id` in snake_case, as
  every Peel tool is.
- **`workflow`** chooses a named workflow. Every named workflow Peel lists
  takes `{prompt}` as its input, so the call stays the same.
- **The grants are not the model's choice.** Peel sets `params.tools` from
  the Connections screen: the connector steps the person enabled, plus a
  base set. The model sees the services as one line in the description.
- **Effect.** Both tools are `.write`: they run alone and in order, and
  never ask. Starting a job changes nothing outside until a write inside it
  asks.

### How a result comes back

1. `start_job` mints a UUID and writes a `Job` record (title, status
   `running`, run id). It posts `POST /workflows/job/run {job, title,
   input:{prompt}, params:{tools}, callback:{url}}`, gets `202 {runId}`,
   and returns at once. The callback URL is Peel's own `AutomationServer`
   on loopback (phase 12), with a new `/jobs/done` route and the same
   bearer token.
2. While the job's row is on screen, the session follows `GET
   /workflows/job/runs/:runId/stream`. Steps appear under the job's row in
   the thread panel, using the same `ToolActivity` rows as today. The
   stream is only for watching: nothing depends on it.
3. Strut's `run.end` callback (`{status, output: {text, artifacts, ask}}`)
   is appended as one job message in the chat, as Hive's `job-<runId>` row
   is, through `AgentSession.deliver` as automations are. Its artifacts are
   links served through Strut. The `Job` record's status becomes `done`,
   `needs you` or `failed`.
4. Strut retries a callback it could not deliver. At launch, `GET
   …/runs/:runId` brings any job still marked running up to date (Hive's
   reconcile cron, run once).

Whether a finished turn also starts a model turn of Peel's agent, as Hive
wakes its canvas agent, is an open question. Proposed: no. The job's
message stands on its own, and the person replies to it.

## Needs you, and writes inside a job

Strut never parks a run. A question ends the turn with `ask`, and the
answer is the next turn (`plans/jobs.md`, "Asking the user"). Run
pause and resume are operator controls, and elicitation exists only in
Strut's builder chat. So a job asks Peel the way Hive's jobs do: the turn
ends, and Peel's answer is the next `continue_job`.

| The turn ends with | Peel shows | The answer |
|---|---|---|
| `ask: {message}` | **Needs you** card with the question, and a reply field under it | `continue_job(job_id, <reply>)` |
| `ask: {message, approval: {step, input, intent}}` | The **approval card**: the intent's action, exact content and target, as for a send | below |

For an approval, the card shows `intent` (`{action, content, details,
target}`, Peel's `ToolIntent` fields). The step and input it covers are
exactly what Strut stopped on.

- **Allow once.** Peel runs that exact write itself with `POST
  /steps/:type/run {input}`. Then it calls `continue_job` with "Approved
  and done: <the step's output>". What runs is what was shown: the
  `Tool.Plan.action` rule, carried across the process boundary.
- **Always allow.** As Allow once. Peel also adds an `ApprovalRule` for
  the step (such as `slack/post-message`), for this target or for any
  target, and passes it on every later launch as `params.allow: [{step,
  target?}]`. Strut then runs that write inside the job without stopping.
- **Deny.** `continue_job` with "The user declined: <action>. Nothing was
  done."

A job can only stop like this if Strut knows which steps write. Today no
step says so. This needs three small changes in Strut (PR J1):

1. An optional `effect?: "read" | "write"` on `StepDef` (`src/core.ts`).
   A step with no `effect` counts as a write.
2. In the job agent's tool executor (`buildRegistryTools`,
   `src/steps/core/agent.ts`), a write that `params.allow` does not cover
   is not run. It returns "Paused for the user's approval" and ends the
   agent's loop with `ask.approval` filled in by the step's
   `describe(input) → intent`. A step with no `describe` gets one built
   from its type and input.
3. `GET /steps` reports each step's `effect`, so the Connections screen
   can show "reads" and "writes".

Built-in tools such as bash and file edits stay inside the job directory.
They are not gated: grant them only to jobs that need them, as Hive's do.

## Connectors

- **A connector is a folder of steps** (`slack/read-channel`,
  `slack/post-message`), with its token in Strut's secret store. Peel's
  Connections screen is built from `GET /steps` grouped by folder, with
  each step's `effect`. Enabling a service adds `<service>/*` to the
  grants Peel sends with each job.
- **Calendar is the exception.** It is direct EventKit tools in Peel's
  loop, because only an Apple app can reach EventKit. A job that needs the
  calendar gets it in the prompt Peel writes, or the person asks Peel
  directly.
- **Auth today:**
  - A pasted token (Slack bot token, GitHub token, X token) goes from
    Peel's Connections screen to `PUT /secrets/:name` over loopback. Strut
    also has `request_secret`, which links to its own secret page, but
    only from its builder chat.
  - Strut does no OAuth. The host is meant to run sign-in and deposit the
    tokens (Strut AGENTS.md, "Secrets").
- **OAuth for Google (Gmail, Calendar on the web, Drive):**
  - Peel signs in as a native-app client in `ASWebAuthenticationSession`,
    using PKCE with no client secret.
  - It deposits the refresh token and client id in Strut. Strut's Google
    steps read a fixed `GOOGLE_ACCESS_TOKEN` today, so `gdrive/_shared.ts`
    would need a small refresh helper that swaps the refresh token for an
    access token when one expires.
  - Gmail's read and send scopes are Google's "restricted" scopes. Within
    a 100-user test mode they work without verification. A public release
    needs Google's security assessment.
- **MCP servers (Linear, Notion)** fit the same way later, as one
  `mcp/call` step family in Strut with tokens in its store, or as native
  steps. Either is Strut work, not Peel's.

## iPhone and always-on

- **The phone reaches the Mac's Strut through the Mac's Peel,** by Sphinx
  message (agent-brain.md). Strut does not run on iOS: it needs Node 22,
  `child_process`, files on disk and native addons, and has no JS-engine
  build. The phone never calls Strut directly, so `MemoryServer` stays
  loopback-only.
- **Always-on** is the same Strut moved to a Mac mini or a server. The
  `start_job` contract does not change. The tokens are already in Strut's
  store, so only the store moves.
- **Scheduled jobs are automations** (phase 12, built in #221). Strut owns
  the schedule. Today an automation calls back into Peel for a headless
  run that reads Sphinx chats. An automation whose work is a job (for
  example, "every Monday, triage Linear") would instead launch `job` on
  that schedule. That is a variant of the same workflow, not a new
  system.

## Research

Read-only, 2026-10-13. Strut was read from `origin/main` (27fe1ee): the
local `~/Documents/strut` checkout is an old branch with no jobs code.

### Start Job / Continue Job, by system

| | Hive | Strut | Jamie |
|---|---|---|---|
| Tools | `start_job {workspace, title, prompt}`, `continue_job {workspace, jobId, prompt}` (`src/lib/ai/strutTools.ts:460-534`) | None of its own: jobs are a host operation (`plans/jobs.md`). The builder's `run_workflow` takes no job | Not in code. `jamie-strut-loop` holds plans and `jamie-prompt-v17` holds prompts. Its plan uses `dispatch_strut {workspace, title, prompt, chatId?}` against Strut's builder chat, with no job id |
| Returns | `{status: started\|continued, jobId, title, runId, note}`, `{status: busy, …}` or `{status: error}` | `202 {runId}` | n/a |
| Job id | Hive mints a UUID. It is kept on each turn's `StrutRun.jobId` row and in the chat as `**Job · <id> · <title>**`, where the model reads it back | Caller-minted flat string, passed as `job` on the launch. Steps see it as `ctx.job` and templates as `{{ $job }}` | A builder chat id, kept on Hive's `AgentRun` |
| Continue | The same launch with the same id. Hive refuses if a turn is pending, and maps Strut's `job_busy:` to busy | Relaunch with the same `job`. `job/dir` holds one top-level run per job, and a second fails `job_busy:` (`src/jobs.ts:269`) | `POST /chat {chatId}` |
| Progress and result | A `run.end` callback only (`/api/strut-runs/webhook`). Output `{text, artifacts, ask?, cost, session}`, plus a reconcile cron | Callback, SSE `…/runs/:id/stream`, `GET …/runs/:id`, `…/events`, `…/artifacts` | A `turn.end` callback |
| Asking mid-run | `output.ask.message`, shown as "Question for you"; the answer is the next `continue_job` | `ask` in the output; the run ends `success`; nothing waits | `ask_user` ends the chat turn |
| Listing | None for jobs | `GET /jobs?q=&workflow=&mine=1`, `GET /jobs/:id`, `/jobs/:id/files`, and `StrutJob` graph nodes | Planned only |

**For Peel:** Hive's two tools and result shapes, Strut's caller-minted id
and `ask`, Peel's own Job record in place of chat-text ids, and SSE in
place of callbacks.

### Steps as a job's tools

- **The job workflow lives outside Strut.** It is seeded in Stakwork's lab
  (`mcp/src/lab/job/`), not in Strut itself. Its shape is in
  `plans/jobs.md`: `job/dir`, a `git/checkout` for each repo, then `agent`
  with `session: {{ $job }}` and `agentTools: {{ params.tools }}`, then
  `pack`. A Strut on Tom's Mac does not have it, so Peel's setup must
  publish it (PR J2).
- **Granting steps.** `agentTools` takes globs such as `slack/*`
  (`expandAgentTools`, `agent.ts:405`). Each step becomes a tool named
  `slack_read_channel`, with the step's input schema
  (`buildRegistryTools`).
- **Choosing grants from outside.** An outside caller can choose the
  grants: `params` on `POST /workflows/:name/run` is merged over the
  workflow's defaults. Nothing on the server limits that list except
  `sealed`, and a run that is granted `bash` can reach anything the
  server can.
- **Discovery tools.** `list_steps`, `search_steps` and `get_step` exist
  only in the builder chat (`src/ai/tools.ts:286-311`). A job agent sees
  only what it is granted.
- **Endpoints Peel would use.** All of these exist:
  - Launch: `POST /workflows/:name/run`.
  - Run state: `GET …/runs/:id`, `/stream` (SSE), `/events`, `/artifacts`, `POST …/cancel`.
  - One step: `POST /steps/:type/run`.
  - Jobs: `GET /jobs`, `GET /jobs/:id`, `DELETE /jobs/:id`.
  - Steps and secrets: `GET /steps`, `PUT /secrets/:name`.
- **Missing:** step effects and an approval stop (J1), and token refresh
  for OAuth services.

### Read and write labels

None exist. `StepDef` (`src/core.ts:18-42`) has `type`, `description`,
`input`, `output`, `source`, `sealed` and `run`. Nothing like
`readOnly`, `sideEffect` or `effect` appears anywhere in `src/`. The
smallest addition is J1 above: one optional field, one check in the
agent's tool executor, and one field in `GET /steps`.

### How Peel already talks to Strut

Checked on `main` at 71af1bc.

- **Finding Strut.** `Sources/PeelAgent/MemoryServer.swift` is Peel's
  handle on one Strut: its address and bearer key, loopback only. It is
  found from Strut's connection file
  (`~/Library/Application Support/strut-memory/connection`), with nothing
  to set up (#224, #226).
- **Calling it.** The memory tools call `POST /steps/memory/<verb>/run`.
  `AutomationsClient` reuses the same `MemoryServer` and calls through
  `Web.requestThisMac` for every method. `JobsClient` is a third client of
  that kind, about 150 lines; it is not a second way to reach Strut. Once
  Strut does more than memory, `MemoryServer` should be renamed
  `StrutServer`.
- **Strut calling Peel.** `AutomationServer` is a swift-nio HTTP server on
  127.0.0.1 with a bearer token from the Keychain. Strut already calls it
  for automations, and the `/jobs/done` callback is one more route on it.
- **What is new.** Only the SSE reader is new: AgentKit's `SSEParser` over
  a streamed loopback `GET` in `Web`.
- **Next on the agent phase** (#229): Peel bundles Strut and starts it, as
  Sphinx Mac does. It reads the address and key from Strut's ready line,
  and the connection file then serves only a Strut started outside Peel.

## Considered

- **A Swift sub-agent per connector** (this PR's first draft). Peel would
  hold the MCP tools, run its own `AgentLoop` per `use_connector` call,
  and pass approvals straight through.
  - Dropped: it duplicates what Strut's steps and job agent already do,
    and keeps tokens and connector code in Peel.
  - What carries over: the main agent sees one line per service, never
    the tools, and writes inside delegated work reach the same card.
- **MCP tools loaded into Peel's main loop.** Dropped: the tool schemas
  ride on every turn, and changing the tool list mid-conversation breaks
  prompt caching.
- **MCP in Swift** (modelcontextprotocol/swift-sdk 0.12.1, which has OAuth
  with dynamic registration). Kept only as the fallback if Strut cannot
  run where it is needed.
- **Coding agents over ACP** (Claude Code, Codex). These are now jobs: a
  coding job is the `job` workflow with `git/*` and its agent, or a named
  workflow. An ACP harness, if wanted, is a Strut step.

## Build order

Each PR runs the full AGENTS.md pipeline. At most three are built at
once. J1 and J2 are Strut PRs, in its repo and under its own rules.

| PR | Repo | What | Depends on |
|---|---|---|---|
| **J1** | strut | `effect` on `StepDef`, labelled on the existing connector steps; the approval stop in the job agent (`params.allow`, `ask.approval` with `describe`); `effect` in `GET /steps` | — |
| **J2** | strut | A local `job` workflow that Strut can publish on a fresh workspace, matching the lab's, so a Mac Strut has one | — |
| **P1** | peel | `JobsClient` over the same `MemoryServer`: launch, get run, run step, put secret; the `/jobs/done` route on `AutomationServer`; offline tests against recorded Strut replies | — |
| **P2** | peel | `start_job` / `continue_job`, the `Job` record, the Active jobs block, the job message with artifacts and the Needs you card; live steps in the thread panel over SSE | P1, J2 |
| **P3** | peel | Approvals from jobs: `ask.approval` → the card; Allow runs the exact step; Always allow becomes `params.allow`; Deny | P2, J1 |
| **P4** | peel | Calendar: EventKit tools in the main loop, writes behind the card, event cards | — |
| **P5** | peel | The Connections screen: services from `GET /steps`, enabled grants, pasted tokens to `PUT /secrets` | P1 |
| **P6** | both | Google sign-in: Peel's PKCE flow; Strut's refresh helper; Gmail steps | P5 |

```
wave 1   J1   J2   P1          (P4 can run whenever a slot is free)
wave 2   P2   P4   P5
wave 3   P3   P6
```

## Open questions for Tom

1. **Should a finished job wake Peel's agent?** Hive wakes its canvas
   agent, gated and capped. Proposed: no. The job's message stands on its
   own.
2. **Where should the Strut changes live?** J1 and J2 change Strut itself.
   Do they go upstream (stakwork/strut), or stay in a Peel-specific
   workspace on Tom's Mac?
3. **What should the base grants be?** Every job gets `memory/*` and
   `graph/*`. Should general jobs also get bash and file tools in the job
   directory, as Hive's do, or only named workflows?
4. **Where does `STRUT_SECRET_KEY` live?** Strut's tokens are only as
   safe as this key, and without it Strut falls back to a development key.
   Once Peel bundles and starts Strut (next on the agent phase, #229),
   Peel can generate the key and keep it in the Keychain. Should
   connectors wait for that, or can tokens go into a hand-started Strut
   before then?
5. **Can jobs reach Sphinx?** Phase 12 notes that `AutomationServer` "later
   lets strut jobs reach Sphinx tools". Should the `job` workflow get
   Sphinx read steps that call back into Peel, or does Peel put what a job
   needs into its prompt?
6. **Calendar for jobs.** Does a job that needs the calendar get it in the
   prompt, or should Strut have its own calendar step (Google Calendar,
   once P6 lands)?
