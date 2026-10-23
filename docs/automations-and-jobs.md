# Automations and jobs: one plan

Last updated 2026-10-15. **Agreed with Tom 2026-10-15 (Decisions below);
nothing new is built.** It ties together [phases/12-automations.md](phases/12-automations.md)
(built), [system-automations.md](system-automations.md) (built),
[jobs-architecture.md](jobs-architecture.md) (proposal) and
[peel-brain.md](peel-brain.md) / [brain-handover.md](brain-handover.md)
(home server, partly built). Those stay the detail; this is the shape.

> **Superseded in part (2026-10-19).** The decisions stand. What changed
> with the loop in strut: the agent is strut's `orchestrator`, not Peel's
> front agent; automations fire `peel-automation-run` in strut, not a
> headless Swift run behind `AutomationServer`; the `sphinx/*` steps reach
> your Mac through the bridge as device requests, not Peel's loopback; and
> sends from an automation use a send grant checked on the Mac. The build
> order is redone in [agent-on-strut.md](agent-on-strut.md), section 5. See
> [agent-architecture.md](agent-architecture.md).

## Why

Tom asked the agent: "ping the Hive tribe in 5 mins, saying we're testing
whether an automation can send on my behalf with an always-on Mac." It
said it can't. That was right: `peel-automation` runs Peel's agent with no
approver, so `send_sphinx_message` is never offered (Automation.swift:112).
It is the right tool for "read my chats every Friday and tell me what I
missed", and the wrong one for anything that acts or needs more than
Sphinx reads and memory.

## Goal

Peel's agent does things for you on a schedule, not only tells you
things. You ask in plain words, approve once, and it happens at the right
time without you there, including acting as you (posting to a tribe). It
works the same on the Mac now and on the home server later, and you don't
think about which one is running it.

## User journeys

Agreed with Tom 2026-10-15. The build step that delivers each is in
brackets (Build order below).

1. **One-off send** (step 1). "In 5 mins, post to Hive that we're testing
   automations." A card shows Hive, the text, the price and 13:03. You tap
   Create. At 13:03 "[Agent] Testing…" appears in Hive as you, with no one
   at the Mac. The run is in the Automations sidebar.
2. **Recurring report** (built). "Every Friday at 5, tell me what I
   missed." A summary lands in the agent chat with a notification. Nothing
   is sent to anyone else.
3. **Recurring send, AI-written** (step 1). "Every Monday morning, post a
   recap of last week's Hive discussion to Hive." You approve once: Hive
   only, a sats cap. Each Monday it reads, writes and posts as you with
   `[Agent]`. A post to any other chat is refused.
4. **Bigger work handed to strut** (step 2). "Research flights to Lisbon
   for next month", "Triage my Linear." Peel hands it to strut's `job`
   agent. Progress shows under the job. When it needs you ("Which dates?",
   "OK to post this?"), a Needs you card appears; you answer and it goes
   on.
5. **Scheduled job** (step 2). "Every Monday, triage Linear and draft
   replies." An automation fires `job` with that prompt each week.
   Anything that acts comes back to you for approval.
6. **Job reads your chats** (step 3). "Every evening, check my tribes for
   anything about the launch and add it to the launch doc." `job` reads
   Sphinx through Peel.
7. **The agent makes a workflow** (step 4, later). A weekly job becomes
   fixed steps: the agent shows "fetch merged PRs → summarise → post to
   Hive", you approve it, and it runs the same way each week, cheaper and
   predictable.
8. **Home server** (step 5). Your Mac can sleep and the brain's clock
   still fires. Reports and jobs run on the server. A send as you is
   posted by whichever of your devices is online; with none, the run shows
   "waiting for a device", never a silent failure.

Not in these journeys yet: posting as a separate agent identity, your
Sphinx keys on the server, and safeguards beyond the chat list, the sats
cap and the `[Agent]` prefix (see Open).

## First principles

Every piece of agent work splits into four parts. Each has one owner.

| Part | Question | Owner | Why |
|---|---|---|---|
| **Clock** | When does it run? | strut automations | Already built: a closed trigger grammar, `nextFire`, run history, `{{ last }}`. One clock, never two (Hive has two: its own cron and strut's) |
| **Hands** | What can act? | strut steps | Everything that acts is a step with a declared effect. A workflow is steps wired together |
| **Head** | Who decides what to do? | an agent: Peel's front agent, or strut's `job` agent | Only where judgment is needed. A fixed action needs no model at fire time |
| **Gate** | Who says yes? | the person, on Peel's card | Approve the effect when it is concrete. Enforced in code, never by the prompt alone (Hive's plan approval is prompt-only) |

Three rules follow:

1. **Approve once, at the point the effect is fixed.** "Post *this text*
   to Hive at 13:03" is fixed when created: approve it then, and the run
   needs no one. "Tell Hive what I missed" isn't fixed until it runs: it
   becomes a draft that waits for you (Needs you), never an unattended
   send.
2. **No model at fire time unless the work needs judgment.** A
   deterministic workflow can't be steered by text it reads.
3. **Sphinx is just more hands.** Strut can't hold Sphinx keys today, so
   Sphinx steps call back to whoever holds the identity: Peel.app on
   loopback now, a Sphinx bridge on the brain later. The step names stay
   the same, so workflows don't change when the brain moves.

## The four shapes of request

| Request | Example | Fires | Model at fire time | Gate |
|---|---|---|---|---|
| **A. Send** | "Post 'Testing…' to Hive in 5 mins" | `peel-automation`, with a send tool limited to the approved chats | Peel's agent | Create card shows the chats and a sats cap (Decision 1) |
| **B. Read and report** | "Every Friday, what did I miss?" | `peel-automation` (built) | Peel's agent, reads + memory | None needed: it only tells you |
| **C. Judgment + work** | "Every Monday, triage Linear and draft replies" | `job` with a fixed prompt | strut's job agent | Effects come back as an `ask`, approved on Peel's card |
| **D. A new workflow** | "When a PR merges, post its summary to the tribe" | a workflow the job agent wrote | Depends on what it wrote | Approve the workflow (its steps and effects) before it is scheduled |

A is the Hive test, and it needs **no authoring**: the built workflow
with one more tool. Dynamic workflows (D) are for when no existing
workflow fits, and are the last thing to build.

> **Superseded (2026-10-19):** "Who does what", "Sphinx steps" and "Where
> it runs". The orchestrator in strut makes automations and starts jobs;
> `sphinx/*` steps post to the bridge, which asks your Mac; sends always go
> out as you, from your Mac, never as the agent's identity (decision 2
> below).

## Who does what

```
 You ─► Peel front agent (chat, Sphinx reads, approval card)
          │  A/B: create_automation(peel-automation, sendTo?)  ── card ─► strut
          │  C/D: start_job(prompt) ─────────────────────────────────────► strut job agent
          │                                                                 │ reuse:  meta/run-workflow
          │                                                                 │ create: meta/publish-workflow  (proposed)
          │                                                                 │ schedule: meta/create-automation (proposed)
          │  ◄── ask {approval} ── "Needs you" card ◄──────────────────────┘
          ▼
 strut (clock + hands) ── fires ──► workflow ── sphinx/* steps ──► Sphinx holder
                                                                    (Peel.app loopback now,
                                                                     brain's Sphinx bridge later)
```

- **Peel's front agent** keeps the chat, the card and Sphinx reads. It
  makes A and B itself (the built workflow, no YAML). Anything else it
  hands to `job` with `start_job`, as Hive does.
- **strut's `job` agent** decides: reuse a workflow, write one, schedule
  one. It does not write anything that acts without the gate: publishing a
  workflow with an effect, and creating an automation, stop and come back
  as an `ask` carrying the exact thing to approve. This is J1 in
  jobs-architecture.md (`effect` on steps, the approval stop), extended to
  `publish-workflow` and `create-automation`.
- **Peel never writes workflow YAML for the person's work.** It publishes
  only its own fixed workflow (`peel-automation`) and the
  `sphinx/*` steps.

## Sphinx steps

Published by Peel, like `peel/run-automation` today. Each calls Peel's
loopback `AutomationServer` with the token from strut's secret store.

| Step | Effect | Notes |
|---|---|---|
| `sphinx/send` `{chat, text, maxPriceSats}` | send | Refuses over `maxPriceSats`, the price shown on the card. Refuses any chat not named in the automation's approved input |
| `sphinx/read` `{chat?, since}` | read | So `job` can read chats without going through Peel's agent (jobs-architecture open question 5) |

**Test runs must not send.** strut has no dry-run: cassettes only, and
record mode runs live. So `sphinx/send` takes a `dryRun` flag that
strut's builder and `meta/run-step` always set, and only a scheduled fire
or an approved "Run now" leaves it off. Strut-side: an effect step is
refused in a test run unless it says it supports a dry run.

## Where it runs

| | Mac now | Home server later |
|---|---|---|
| Clock, `job`, workflows | Bundled strut on the Mac | strut on the brain (peel-brain.md) |
| `sphinx/*` steps reach | Peel.app on 127.0.0.1 | The brain's Sphinx bridge (brain-handover.md, "decided 2026-10-14") |
| Sends as | **You** (your Peel account) | **The agent's own identity** by default; sending as you needs a Mac or phone online to claim the run (peel-brain.md "automations by pull") |
| Peel closed / Mac asleep | Run fails, shown in the sidebar | Always on, except sends as you |

The home server changes *where the hands are*, not the shape. The one
real decision it forces is whose name a scheduled send goes out under.

## Build order

Each step is usable on its own.

1. **Sends from automations** (Peel only). `create_automation` takes
   `sendTo` (chats) and `maxPriceSats`. The card shows them. The headless
   run gets `send_sphinx_message` limited to them, prefixed `[Agent] `,
   with an approval rule in place of a person. *Done when the Hive test
   posts at the minute it said, with Peel open and nobody at the Mac.*
2. **C: jobs** (jobs-architecture.md J1, J2, P1–P3). `start_job`,
   `continue_job`, the `effect` + approval stop in strut, Needs you cards.
   Automations can fire `job` with a fixed prompt.
3. **`sphinx/read`** granted to `job`, so C can be about your chats.
4. **D: authoring** (strut). Grant `job` `meta/publish-workflow` and
   `meta/create-step`; add `meta/create-automation`; both stop for
   approval. Strut's builder chat already has `set_automation`, so this is
   the step twin of something that exists.
5. **Home server.** The Sphinx bridge on the brain, the agent's identity,
   and claims for sends as you.

## Not copied from Hive

- **Two clocks.** Hive's cron starts its canvas agent; strut has its own
  scheduler. Peel uses strut's only.
- **Prompt-only gates.** Hive's "Plan Mode" and PR pushes have no gate in
  code. Here a step's effect decides, and `job` stops.
- **Daily-only, skip on failure.** strut's grammar covers once, interval,
  day, week, month; failures show in the sidebar.

Kept from Hive: `start_job` / `continue_job` and their shape, `run.end`
callbacks plus a reconcile for missed ones, and "prefer reuse" in the job
agent's prompt.

## Decisions (Tom, 2026-10-15)

1. **Automations may send, fixed or AI-written, from v1.** Start open and
   add safeguards later. This answers 12-automations.md open question 3
   and replaces rule 1's "drafts" for now. The few kept from the start,
   because they are cheap:
   - The create card names the chats the automation may post to and a
     sats cap per message. The run's send tool refuses anything else.
   - Every post is prefixed `[Agent] `.
   - Each send is in the run's history in the sidebar.

   So v1 needs no `peel-send` workflow. `peel-automation`'s headless run
   gets `send_sphinx_message` limited to the approved chats. "Post X at
   13:03" is a once-automation whose prompt is the text. `sphinx/send`
   stays the plan for `job` (step 2 onward).
2. **Sends go out as you**, with the `[Agent]` prefix. Not the agent's
   own identity, which would have to join every tribe. On the home server
   your keys stay on your devices: the brain's clock fires, and an online
   Mac or phone claims the send and posts it. With none online, the run
   shows "waiting for a device".
3. **Upstream strut.** The `effect` + approval stop and
   `meta/create-automation` go to stakwork/strut. Authoring grants are
   opt-in per host (`createStrut({ job: { tools } })`), so Hive decides
   for itself.
4. **C before D.** Jobs with a fixed prompt on a schedule first. Workflow
   authoring only once a recurring job should become fixed steps.

## Open

- **Safeguards to add** as sends are used: free-form text as a draft,
  a daily sats cap, a quiet-hours rule.
- **Claiming sends on the home server:** which device claims when two are
  online, and how long a run waits.
