# System automations

Last updated 2026-10-14. **Agreed with Tom 2026-10-14; being built.**
It adds built-in automations to [phases/12-automations.md](phases/12-automations.md)
(v1 built, PR #221). The first one is the duplicates janitor from
[agent-brain.md](agent-brain.md) ("Janitors") and from strut's
`plans/memory-ontology.md` ("Jobs", branch `docs/memory-ontology`).

## Goal

Every user gets a few automations that ship with strut, and each user can
turn them on or off in Peel. The first is **Tidy memory**: once a day it
finds people and things saved twice and merges them when it is sure.

**A built-in is a strut workflow plus an automation on it, shipped with
strut.** It runs entirely in strut: the scheduler fires the workflow, and
the workflow's `agent` step uses memory steps as its tools. Peel defines
nothing. It reads built-ins with the same `GET` calls it uses for its own
automations, shows them, and toggles them. Later the same format (a
workflow plus an automation, from somewhere else) can serve a
marketplace. This plan only sketches that.

Not goals: a review queue (Tom, 2026-10-14: "the janitor's changes apply
and are logged"), and duplicate facts worded differently. strut plans to
fix those deterministically in code (the Facts janitor), not with this
job.

## Two kinds of automation

| | Peel's automations (built) | Built-ins (this plan) |
|---|---|---|
| Workflow | `peel-automation`, one for all of them | One per built-in: `tidy-memory`, … |
| Defined by | The user, by asking the agent | strut's repo, shipped with strut |
| Runs | strut fires → `peel/run-automation` → Peel's agent (Sphinx data lives in Peel) | strut fires → the workflow's own `agent` step, in strut |
| Model | The connected model, in Peel | The same connected model. Peel puts its key in strut's secret store |
| Peel's part | Create, edit, toggle, see runs | Toggle, Run now, see runs |

The split is by data. An automation that needs Sphinx chats goes through
Peel. One that only touches strut's data (memory, connectors) stays in
strut and never calls Peel.

## What strut already has

- **Workflows and versions.** A workflow has YAML versions, and one of
  them is active. Automations are metadata on the workflow, so pausing
  one publishes no new version (`plans/automations.md`).
- **Automations.** `GET /automations` lists every workflow's automations.
  `PATCH …/automations/:id { enabled }` pauses or resumes one, and
  `POST …/fire` is Run now. Runs are stamped with the automation id.
  Missed fires are skipped, and a fire is skipped while the previous run
  is still going (`src/scheduler.ts`). There are no event triggers.
- **The `agent` step.** `agentTools` turns step types into tools ("tools
  are steps", with globs). The model is resolved through `src/llm.ts`,
  with keys read from the secret store first, then the environment. It
  covers Anthropic, OpenAI and OpenRouter, which are all three of Peel's
  providers (`AgentProvider`). Its output includes `usage` and `cost`.
- **The memory steps.** `memory/recall`, `memory/get` and `memory/merge`.
  `merge` refuses to merge `Self` into another entity, so "never merge the
  user away" is already enforced. What is missing:
  - `merge` takes no `created_by`.
  - `merge` records only counts of what moved, so it cannot be undone
    (not needed in v1).
  - Nothing lists entities. `recall` needs words to match on, so a job
    has no way to sweep for duplicates.

## A built-in's definition

It lives in strut's repo, for example `system/tidy-memory/`. It is the
two things strut already stores:

```yaml
# workflow.yaml: the workflow, as any strut workflow
name: tidy-memory
description: Once a day, merges people and things saved twice.
category: system
steps:
  - id: tidy
    type: agent
    config:
      prompt: |
        …(below)
      agentTools: [memory/duplicates, memory/get, memory/recall, memory/merge]
      maxSteps: 40
```

```json
// automation.json: the automation on it
{ "name": "Tidy memory", "trigger": { "every": "day", "at": ["12:30"] }, "enabled": false }
```

- **Name, description, prompt and tools** are in the workflow. The
  description is the workflow's existing `description`, and Peel shows
  it.
- **The schedule and on/off** are in the automation.
- **The version** is the workflow version. strut labels shipped versions
  `s-` plus a hash of their content, the way Peel labels
  `peel-automation` versions `p-` plus a hash (`AutomationsClient.install`).
- **`category: system`** is how Peel tells built-ins apart from other
  workflows. `GET /automations` carries each automation's workflow
  category, so a single call is enough.

The workflow names no model. An `agent` step with no `model` uses the
secret `STRUT_DEFAULT_MODEL` when it is set. Peel stores the connected
model there (`anthropic/…`, `openai/…`, `openrouter/<org>/<id>`), next
to the provider's key. Changing the model is then one secret write, with
no restart and no new workflow version.

### Install and update (strut, on start)

| strut's workspace has | strut does |
|---|---|
| No `tidy-memory` workflow | Creates it at the shipped version, plus the automation, **off** |
| An active version that is an older shipped `s-` version | Publishes the new shipped version and makes it active |
| An active version that is not a shipped one (the user edited it in strut) | Nothing. The user's version wins. The shipped one is published but not made active, so strut's version list offers it as "restore" |
| The workflow, but its automation was deleted | Recreates the automation, off |

The automation's `enabled` and schedule are never touched after it is
created. Updates and edits use strut's own versions, with no new
mechanism: a user's edit is a new version, and strut only moves the
active version forward when it was a shipped one.

## On and off

Peel's toggle is `PATCH { enabled }`, the same call as Pause and Resume
today. Turning a built-in off pauses its automation. It never deletes it,
so the run history stays attached to the same automation id. Peel offers
no Delete for built-ins. If one is deleted in strut, strut recreates it,
off.

## On or off by default

Tom's lean: **on, but only once a model is connected.** This holds up.

- strut ships every built-in **off**, because strut cannot know whether a
  model is there.
- When a model is first connected, Peel does two things:
  - stores the key in strut's secret store, under the provider's name
    (`ANTHROPIC_API_KEY`, …), as it already does for the automation token
  - turns on every built-in whose `enabled` it has never set

  Peel keeps a per-profile flag for that one-time turn-on, so a built-in
  the user turned off stays off.
- **Disconnecting the model** removes the key from strut's secret store.
  The built-ins stay on and their runs fail with strut's "missing key"
  error. Peel shows those failures as failed runs.
- **Cost.** Every run uses the user's model and is billed to their key.
  strut records `usage` and `cost` per run, so the cost is a real number
  in the run history, not an estimate. A quiet day (no candidates) is one
  short turn.
- **Privacy.** Memory text goes to the model's provider without the user
  asking. The chat agent already sends recalled memory to that provider,
  but only when the user asks something. This is new, so it is said once,
  plainly, at the top of the System tab: "Built-in automations run on your
  connected model (Claude Sonnet 5.5). They send parts of your memory to
  Anthropic."
- **The key in strut's store.** Any strut workflow can read it: `agent`
  and `exec` steps can name any stored secret in `secretsEnv`. That is the
  same caveat 12-automations.md gives for the automation token. On the
  Mac this is the user's own strut.

This differs from strut's memory-ontology decision of 2026-10-14
("Background jobs will use the connected model … not v1"). See open
question 1.

## Tidy memory v1

### When

Tom asked for nightly. On a laptop that sleeps at night, strut skips the
missed fire, so a nightly run would rarely happen. **Default: every day
at 12:30 local**, when the Mac is more likely to be awake with strut
running. A day missed costs nothing: the next run picks up the same
duplicates.

### Finding candidates: `memory/duplicates`

A new read step. It is the deterministic matcher from the ontology plan's
Duplicates row ("merge when the matcher and a model call agree"). It
returns at most `limit` (20) candidate pairs, strongest first, each with
the reason it matched:

- the same normalized name or alias on two entities of different types
- a `Person` whose name matches the user's `name` fact on `Self`
- one name the first-name form of the other: "Kate" and "Katie Moss",
  matched by a shared first token, or a prefix of at least 3 letters, or
  a nickname from strut's language data

### The prompt

> Tidy the user's memory. Call memory/duplicates. For each pair, call
> memory/get on both. Merge with memory/merge only when you are sure they
> are the same person or thing: the names fit (a nickname or a full
> name), nothing conflicts (different surnames, employers, cities, or
> relationships to the user), and at least one thing links them (a shared
> fact, the same relationship to the user, or a Person named as the
> user). Keep the entity with more facts, and always keep Self: merge the
> Person into Self, never the other way. Merge at most 10 pairs. Finish
> with one line per merge ("Kate into Katie Moss: same sister, same
> city"), then one line naming the pairs you left alone. If nothing was
> merged, say "Nothing to merge".

The rules that matter are also enforced in code, not only in the prompt:
- strut refuses to merge `Self` away.
- `agentTools` holds no `memory/remember` and no `memory/forget`.
- The run has no Sphinx data at all.

### Who wrote it

`memory/merge` gains `created_by`, stored on the duplicate next to
`deleted_reason` ("merged into … by janitor"). The model must not choose
it. When a memory step runs as an agent tool inside a workflow, strut
stamps `created_by` itself: `janitor` for `category: system` workflows,
otherwise the workflow's name. Whatever the model passes is ignored.
Peel's own calls keep setting `agent` or `user`, as today.

### What the user sees

- **Run history in Peel:** each run's final text, from strut's run
  output ("Kate into Katie Moss …" or "Nothing to merge"), with its cost.
- **No chat message and no notification in v1.** A strut-only run does
  not reach Peel's agent chat. A janitor working quietly is the point,
  and its history is one click away (open question 4).
- **No undo in v1** (Tom, 2026-10-14: get it running first). `merge` is
  soft (the duplicate stays, marked deleted, as an alias), so an
  unmerge can be added later. That needs a merge record and a
  `memory/unmerge` step, and fits with a QA or review step when one comes.

## UI (Peel)

`AutomationsClient.list` reads `GET /automations` for all workflows
instead of only `peel-automation`. The existing `AutomationsView` gains:

- **Two tabs under the header: "Yours" and "System".** "Yours" is today's
  view, with Upcoming, Recurring and Done. "System" lists the
  `category: system` automations. Under its header goes the one muted
  line about the model and provider.
- **Row:** the name, then the workflow's description where the schedule
  summary goes. Trailing: the last run ("Ran 12:30", "Didn't finish" in
  attention colour, "Running…"), then a switch. When the switch is off,
  the row is dimmed as Paused rows are today.
- **Opened:** the schedule sentence, Run now, and the runs list (the final
  text and the cost of each run). There is no prompt editor and no Delete.
  The prompt is the workflow's, and it is edited in strut, where editing
  makes a version of the user's own.
- **Empty state:** the System tab says when this strut ships no built-ins
  (an older strut).
- **The agent's tools** stay scoped to `peel-automation`. In v1 the agent
  cannot create, edit, pause, delete or run system automations. Only the
  user can, from the switch in the System tab.

## Where it runs

This fits how automations work now and how the home server will work:

- **Work that doesn't need Sphinx** runs inside strut, in its own
  workflows. Tidy memory is one.
- **Work that needs Sphinx chats** goes to Peel. Today strut pushes it to
  Peel's loopback `AutomationServer`. With a home server, strut can't
  reach a laptop's loopback, so the run waits for Peel instead:
  - whichever Peel is online asks strut for waiting runs
  - it claims one with a lease, so two Peels never both run it, and a
    run whose Peel dies goes back in the queue
  - it does the run and posts the result back

  A run made while Peel is closed then waits instead of failing, until a
  deadline after which it counts as missed. strut has none of this yet:
  it needs a wait-for-a-worker step plus claim and result routes. It is
  built with the home server, and nothing in this plan needs it.

## Marketplace (sketch)

A shared automation is the same pair, a workflow and an automation, from
another source: exported from someone's strut, or later from a catalog.
It installs as a strut workflow with its own version labels, and updates
by the same rule (only when the active version is the publisher's).

**The open problem is trust.** An automation is an agent with tools that
runs with no one watching:
- `agentTools` could name any step: connectors, `exec`, or memory writes.
- The prompt is untrusted text written by someone else.
- The key in the secret store pays for it.

Some pieces are clear:
- the install card lists `agentTools` in plain words ("changes your
  memory", "reads your Slack")
- a spend cap per run (`maxRunCostUsd`)

What is still open:
- whether shared workflows may name write steps at all
- signing or a reviewed catalog
- what a publisher's update may change without asking again (prompt
  only? tools never?)

## Phases

1. **strut: memory.**
   - `memory/duplicates`
   - `created_by` on `memory/merge`, stamped by strut inside workflows

   Done when, on the bench memory, `memory/duplicates` returns the
   auto-safe pairs (Self and a Person with the user's name; Kate and
   Katie Moss).
2. **strut: system workflows.**
   - shipped `system/` workflows installed on start with `s-` versions,
     and the update rule above
   - the `tidy-memory` workflow and its automation

   Done when a fresh workspace gets `tidy-memory`, off, and a changed
   shipped version moves an unedited workflow forward but leaves an
   edited one alone.
3. **Peel.**
   - the model key and default model handed to strut
   - the one-time turn-on
   - the System tab, with the switch, Run now and runs with their cost

   Done when:
   - a fresh profile with a model connected gets Tidy memory switched on
   - Run now merges the duplicate of the user into Self, and the run says
     so
4. **Later.** Undo (`memory/unmerge`) and some QA of merges. More
   built-ins (the Ontology janitor, the Facts janitor if it
   needs a model), and the marketplace.

## Open questions for Tom

1. **The model in strut now?** strut's 2026-10-14 decision puts background
   jobs on the connected model "not v1". Is Tidy memory fine to ship on
   it, given that it sends memory text to the provider without the user
   asking?
2. **Which model:** v1 uses the connected model (`STRUT_DEFAULT_MODEL`).
   Should janitors use a cheaper model later (for example Haiku when the
   key is Anthropic)?
3. **12:30 daily instead of nightly**, given that strut skips missed fires
   on a sleeping Mac. Or should strut gain a "run once if missed" option
   for system automations?
4. **Tell the user about merges?** v1 keeps them in run history only. The
   other option is a notification when a run merged something, which
   needs a way for strut to tell Peel that a run ended. jobs-architecture.md
   plans that callback.
5. **Cap of 10 merges a run** and 20 candidates. Are those the right
   numbers for a first run on an older, messier memory?
