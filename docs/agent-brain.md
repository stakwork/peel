# The agent's brain: memory graph, strut and jobs

Last updated 2026-10-13. **A proposal, not agreed.** It revisits parts of
[agent-architecture.md](agent-architecture.md) (agreed 2026-10-10): where
the graph lives, who writes it, and how the agent reaches strut. Nothing
here is built. A visual version with diagrams:
<https://claude.ai/artifact/8iRBjxFzqStPDBETnq6EZD>.

> **Superseded in part (2026-10-19).** Peel's agent as the front agent, in
> Swift on the Mac, is replaced: the agent is strut's `orchestrator` on the
> brain, a Sphinx contact behind the bridge, and it starts strut's jobs
> itself. The phone reaches it through the bridge, not through the Mac's
> Peel. Still standing: strut owns the graph and is its only writer, the
> Graphiti model, system types, janitors. The architecture of record is
> [agent-architecture.md](agent-architecture.md).

## Why revisit

The 2026-10-10 plan runs the agent and a full graph copy on every client,
synced by an event log. Working it through, the client is the hardest
place for most of it:

- No always-on: nothing runs while the phone or laptop sleeps, so no
  automations, schedules or janitors.
- Ladybug's full-text and vector extensions are downloaded and loaded at
  run time. iOS forbids that; a signed, notarised Mac app may too.
- Embeddings on the phone, and the same embedding model on every device.
- Every device writes, so duplicates made offline need merging after sync.

## Summary

- **The Mac is the brain; the phone is a remote.** The graph, strut and
  the agent's work live on the Mac. The phone talks to it by Sphinx
  message. No graph on the phone in v1.
- **Strut owns the graph.** It is the only process that opens the Ladybug
  file. Ladybug allows one writer process, and strut is the part that
  already runs anywhere: moving the brain to a Mac mini or a cloud box
  later means moving strut, not converting anything.
- **Peel's agent is the front agent.** It chats, answers simple things
  itself, reads and sends Sphinx messages behind the approval gate, and
  hands real work to strut as jobs. It routes; strut does the work.
- **The model is Graphiti's:** Episodes, Entities and Facts, with facts
  stored as nodes and expired rather than overwritten.
- **Jobs and tasks are graph nodes.** Strut already writes `StrutJob` and
  `StrutRun`. A new `Task` type holds "remember to…" with no job at all.
- **Peel reads and writes the graph only through strut.** Ladybug lets one
  process open a file for writing, or several for reading, never both, so
  Peel cannot open the file while strut has it. Peel's graph tools are
  quick synchronous calls to strut, not jobs.
- **System types are read-only to agents.** Types strut writes from events
  (`StrutJob`, `StrutRun`, workflows, tool calls) are written by code
  only. The agent edits user types: Episode, Entity, Fact, Task.

```
v1                                         later
iPhone (Peel) ── Sphinx msg ──► Mac        iPhone, Mac (Peel) ──► home server / cloud
                                 ├─ Peel agent (front)                ├─ front agent
                                 └─ strut ── Ladybug                  └─ strut ── Ladybug
                                    (only writer)                        (same file, moved)
```

If the Mac is asleep, messages wait on the Sphinx broker and are answered
when it wakes. Always-on is the same setup on a Mac mini.

> **Superseded (2026-10-19):** this section and "Front agent tools". The
> front agent is strut's `orchestrator`, with `job/start`, `job/continue`
> and the `job/*` reads as its tools; job records stay in strut's job index,
> and a job's id survives compaction because a job's message names it
> (`metadata.peel.job`). See [agent-architecture.md](agent-architecture.md).

## The front agent and strut

Three ways to put an agent in front of strut were weighed:

| Option | How | Verdict |
|---|---|---|
| A. Front agent with job tools | Peel's agent answers what it can and calls `start_job` / `continue_job` for real work | **Chosen.** Hive's Canvas agent runs this today, and strut's job contract was built for it |
| B. Every message is a strut job | strut is the agent; one long job is the conversation | "hello" costs a workflow run; Sphinx tools need a channel from strut back into the app; no token streaming |
| C. A strut agent calling subflows | B plus `meta/run-workflow` | Children block the parent: a two-hour child is a two-hour turn |

How strut jobs work (from `strut/plans/jobs.md`, `specs/API.md`): a job
is a caller-chosen id; each turn is one run of the `job` workflow with
its own session, directory and tools. Continuing a job is launching it
again with the same id; one turn at a time (`job_busy`). Each turn ends
with `{text, artifacts, ask}` on a callback. A question is returned as
`ask`, and the answer arrives as the next turn; nothing waits.

### Routing: new job, continue, or just remember

The hard part is not orchestration but routing: which job does this
message belong to? That is a graph lookup, not something the model holds
in its head.

```
"Remember to do this for Kate"   (from the phone, a week later)

1. Look up   Kate → linked jobs: "Friday Night Chef" (waiting, last week)
                                  "Kate's birthday gift" (done)
2. Decide    one strong match    → continue_job(friday-night-chef)
             several matches     → ask: "The Friday cooking plan, or new?"
             no match, a note    → remember: a Task linked to Kate, no job
             no match, real work → start_job, linked to Kate
3. strut runs that job's next turn in its own session; other jobs untouched
4. The job ends → callback → front agent → Sphinx message to the phone
```

Hive's Canvas agent keeps job ids only in the conversation text
(`**Job · <id> · <title>**`) and lets the model read them back. Peel
compacts, so a summary could drop them. The front agent therefore keeps
a small **active-jobs list** (id, title, status, last update), maintained
by code and pinned outside compaction.

### Front agent tools

The job tools and how a job's questions and writes reach Peel are worked
out in [jobs-architecture.md](jobs-architecture.md) (2026-10-13).

The current Sphinx tools and approval gate stay. Added:

| Tool | Does |
|---|---|
| `remember` / `recall` | Write or search the graph (direct strut graph calls, not jobs) |
| `list_jobs(status?)` | What is running or waiting on you now |
| `search_jobs(q)` | Jobs by meaning, by linked people and topics, by recency |
| `get_job(id)` | Status, summary, last question, artifacts |
| `start_job(prompt, about?, task?)` / `continue_job(id, prompt)` | Hand work to strut |

These are a plain HTTP contract against strut, so the front agent can
move into strut later as a small router workflow without redesign. The
graph tools use strut's synchronous `POST /steps/:type/run`, which runs one
step and returns its output; only `start_job` and `continue_job` go
through `POST /workflows/job/run` and a callback.

### Compaction, three levels

1. The front agent compacts its chat (built: #209).
2. strut compacts each job's session at 90% of the window (built:
   `strut/src/compaction.ts`).
3. The graph is long-term memory: conversation turns go to strut as
   Episodes and facts are extracted from them. A detail dropped by a
   summary is already in the graph, which is what makes compaction safe.

Peel's `agent.sqlite` keeps conversation state only; long-term memory is
the strut graph.

## Jobs and tasks in the graph

### Jobs: already there

strut's projector (`strut/src/graph/projector.ts`, schemas in
`strut/src/graph/strut-schemas.ts`) writes:

- `StrutJob`: `job_id`, `title`, `summary`, `last_used_at`, `run_count`,
  `artifact_count`. Real job nodes exist in Hive's graph today.
- `StrutRun -IN_JOB-> StrutJob`, and each run `EXECUTED` the workflow
  version it ran.

To add: a `status` (running, waiting on you, done, failed) and the last
`ask`; `StrutJob -ABOUT-> Entity` for the people and topics involved;
`StrutJob -STARTED_BY-> Episode`; artifacts as nodes rather than a count.

### Tasks: "remember to…" with no job

"Remember to send Kate the recipe on Friday" becomes data, and nothing
runs:

```
Task "Send Kate the recipe"   status: open · due: Fri 17:00 · owner: me
  ├─ ABOUT → Person: Kate
  ├─ ABOUT → Topic: Friday Night Chef
  └─ FROM  → Episode: the phone message
```

"Remember Kate is vegetarian" is not a Task; it is a Fact about Kate.

A Task comes back three ways:

1. **When its subject comes up.** Recall on Kate or Friday surfaces open
   Tasks linked to them, and the agent mentions them.
2. **When it is due.** A strut automation (every ~15 minutes) finds open
   Tasks due soon. Yours: a Sphinx message ("Reminder: send Kate the
   recipe. Want me to do it?"). The agent's, if it may act alone: a job.
3. **When you say "do it".** The front agent starts a job for it.

strut needs no task concept. `start_job` passes the Task's `ref_id`; the
`job` workflow writes `StrutJob -FOR-> Task` and marks the Task done, or
leaves it open with the job's question. A Task can have several jobs: a
failed attempt, a retry, a follow-up a week later.

## The graph

### Model

Three node tables, after Graphiti:

| Table | Holds |
|---|---|
| `Episode` | Something that happened and never changes: a message, an agent chat, a strut run, a note. `kind`, `source` pointer, `content`, `occurred_at` |
| `Entity` | Self, Person, Organization, Place, Topic, Project, Event, Task. `type`, `name`, `summary` (kept current by a janitor), `attributes`, `aliases`, `embedding` |
| `Fact` | A statement, stored as a node: `predicate`, `text`, `confidence`, `valid_at`, `invalid_at`, `expired_at`, `embedding` |

Every node also has `ref_id` (random, never from text), `created_by`,
`created_at`, `updated_at`, `deleted_at`.

Edges: `MENTIONS` (Episode → Entity), `SUBJECT` and `OBJECT` (Fact →
Entity), `FROM` (Fact → Episode), `SUPERSEDES` and `CONTRADICTS` (Fact →
Fact), `ALIAS_OF` (Entity → Entity).

- **"Memory" is not a type.** A memory is a fact plus the episodes behind
  it. Preferences are facts about Self.
- **Facts are nodes** because Ladybug cannot build full-text or vector
  indexes on edge properties; Graphiti does the same.
- **Time.** `valid_at`/`invalid_at` say when it was true in the world;
  `created_at`/`expired_at` when the graph believed it. A newer fact
  `SUPERSEDES` an older one, which gets `expired_at` and stays. Facts that
  disagree with no clear winner get `CONTRADICTS` for a janitor or you.
- **One `Entity` table with a `type` column,** not a table per type. In
  Ladybug a label is a table: per-type tables need a schema change, new
  indexes and edge-table changes for every new type, and search fans out
  across tables. Agents add types, so one table wins. A heavy, stable
  type can move to its own table later.

This changes agent-architecture.md's generic `Node`/`Edge` tables to three
role tables, and drops `Memory` as a type.

### System and user types

| | System | User |
|---|---|---|
| Types | `StrutJob`, `StrutRun`, `StrutWorkflow`, `StrutToolCall`, `StrutChat`, the ontology itself | `Episode`, `Entity` (all its types), `Fact`, `Task` |
| Written by | strut code, from events (the projector) | The agent and you, through the verbs |
| Agent can | Read and link to them | Create, edit, supersede, forget |

The verbs refuse to edit a system node. A user node may point at one
(`StrutJob -FOR-> Task` is written by the job workflow's code, not the
model).

### Ontology

- **A flat core list, versioned in code,** named after schema.org where a
  type exists. No inheritance; system fields are on every node anyway.
- **Agents may propose** a type or predicate. It is usable at once but
  marked `proposed`; the ontology janitor merges, promotes, or asks you.
- **Not OWL** (built for exchanging data between organisations, with
  reasoners you don't need), **not schemaless** (how Mem0's relations and
  Jarvis's 66 migrations happened), **not designed by the user** (people
  approve or reject; they don't design).

### Writing

Every write starts from an Episode: store it, extract entities and facts,
match entities, check facts, write with embeddings. Matching runs
cheapest first (Graphiti's cascade): a unique identifier such as a Sphinx
pubkey or email, then the exact normalised name, then fuzzy name matching
(skipped for short names), then search plus a model call over the
candidates. Unsure matches go to a review queue. A fact that contradicts
an existing one expires it.

### Janitors

strut automations, overnight or while idle. Anything unsure goes to a
review queue in the app, not into the graph.

| Janitor | Does |
|---|---|
| Duplicates | Finds near-duplicate entities, merges them with `ALIAS_OF`, queues the unsure |
| Facts | Contradictions, expiry, confidence fading over time |
| Ontology | Proposed types and predicates; unused types |
| Summaries | Rewrites each entity's summary from its current facts, so reads stay short |
| Tasks | Due and overdue tasks (above) |
| Hygiene | Orphans, broken links, purging soft-deleted data |

## What we learned

From the code of each project, read 2026-10-12/13:

| From | Found | Take |
|---|---|---|
| Graphiti (Zep) | Episodes, entities, facts as nodes on Kuzu; facts expire, never deleted; the matching cascade; text + vector + graph-distance search | The model |
| Jarvis | Ontology as Schema nodes; Scratchpad; merge review; text-built keys that broke (migrations 085, 124); a full-replace write that wiped fields | Ontology as data; partial writes only; never identity from text |
| Cognee | Runs on Ladybug by default today, with generic node and edge tables | Code reference for Ladybug |
| strut | `graph/*` steps in Jarvis's shape; `StrutJob`/`StrutRun` already projected; a Ladybug backend already planned (`plans/local-desktop-and-stt.md` §3.1) | The graph's home |
| stakgraph | `ref_id` changes on re-ingest; user edits saved and restored around rebuilds; raw Cypher behind a leaky denylist | Stable ids; agents get verbs, never Cypher |
| Mem0 | Hard-deleted outdated relations, then dropped graph memory in v3 | Never update facts in place |

Tested directly in Ladybug 0.21.2 (macOS):

- Uniqueness only on the primary key: no `UNIQUE`, no composite key, no
  secondary index. A unique identifier needs its own table keyed by it.
- Tables per type, `ALTER TABLE … ADD` columns and edge pairs at run time,
  `MATCH (n)` across tables and `(n:A:B)` as "either" all work.
- Full-text and vector indexes work, one per table, but the extensions
  are downloaded from `extension.ladybugdb.com` on first use.

> **Superseded in part (2026-10-19):** phases 0 to 3 are built in strut.
> Phase 4's front agent in Peel and phase 6's "headless sphinx-rs service"
> became the orchestrator and the bridge (`sphinx/runner`); moving strut off
> the Mac is Phase 2 of [end-state.md](end-state.md). Open question 4 is
> answered: the front agent is in strut. No read-only graph on the phone or
> change-log sync is planned now.

## Phases

0. **Prove Ladybug inside strut** (2–3 days). strut's graph queries on
   Ladybug; the search extensions from a signed Mac app; one pinned,
   tagged Ladybug release agreed with Tom T; confirm one writer process
   locks out readers.
1. **First slice: remember and recall** (a few days). The smallest thing
   that works end to end, before the full backend:
   - strut: add `@ladybugdb/core` (0.21.2, the release the Swift
     prototype used) and three steps, `memory/remember`, `memory/recall`
     and `memory/get`, on the Episode, Entity and Fact tables. Plain
     text search; no extraction model yet (the agent passes the entity
     and fact it means).
   - Peel: `remember`, `recall` and `get` tools calling
     `POST /steps/memory.<verb>/run` on a local strut, with its URL and
     key in the agent settings.
   - Done when "Remember: my name is Tom" in Peel creates the Self entity
     and a fact, and a new conversation answers "What's my name?" from
     the graph.
2. **Graph core in strut** (~2 weeks). Ladybug behind strut's
   `GraphBackend`; the three tables and core ontology; the write path;
   `forget`, `merge`, `propose-type`.
3. **Finding things** (~1 week). Full-text + vectors + a short walk,
   ranked together; MiniLM through the onnxruntime strut ships.
4. **Peel on the Mac and phone** (1–2 weeks). The front agent's memory
   and job tools; the active-jobs list; callbacks that message the phone.
5. **Janitors and tasks** (1–2 weeks). The automations above, and a
   weekly digest of what was merged, expired and proposed.
6. **Later.** Move strut to a Mac mini or the cloud; a headless sphinx-rs
   service for the agent's identity; a read-only graph on the phone,
   where Tom T's sync log fits.

Estimates are guesses until phase 0.

## Open questions

1. Does the official Sphinx Mac agent move to the same front-agent design,
   or does Peel lead and the official app follow?
2. Can the search extensions be loaded in a notarised Mac app, or built
   into Ladybug?
3. Which Ladybug release do Peel, strut and Tom T's branches pin?
4. Does the front agent stay in Swift, or move into strut once strut
   leaves the Mac?
