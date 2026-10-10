# Peel and the Sphinx agent: architecture

Last updated 2026-10-10. The single source of truth for the Sphinx agent
that Peel is the client for. Nothing here is built.

This replaces the plan of 2026-10-08–09 (an always-on agent host with its
own Sphinx account, Strut jobs, ACP workers and a graph only the host could
open). Tom judged that too much, too early. The decisions below were agreed
with Tom on 2026-10-10. Those parts of the old plan now come later, as
other places to run the same code ("Later", below).

## Summary

- **The agent runs on the client.** It runs inside Peel on the Mac now,
  Peel on iPhone next, and a cloud or home server later. The agent code is
  platform-neutral Swift; only the chat UI is per platform.
- **For every Peel user,** not just Tom. Onboarding, keys and costs must
  work for anyone.
- **One graph per user, the same data everywhere.** Every device, in Peel
  and in the official Sphinx apps, holds the same graph. Tom T is adding
  LadybugDB to the official apps first (below); Peel reuses what he learns.
- **Sync is an encrypted change log,** the way Sphinx already works: each
  write is a small event, sent as Sphinx messages to the user's own
  account, and every device replays it into its local LadybugDB file.
  Last write wins per field.
- **The graph is the knowledge.** The agent has a short system prompt and
  walks the graph toward its goal. Glimmer, the concept tree, is content
  in the graph: Concept is one node type among others, read and walked
  with the same generic tools.
- **Version 1 can:** answer by walking the graph, remember, and act in
  Sphinx (read chats, send, pay).
- **Only payments ask for approval.** Sends go out directly (see "Risks").
- **Memory comes from the agent chat and explicit Remember only.** The
  agent never reads other chats to learn, only to carry out a task.
- **Agent conversations are graph nodes,** so they sync with everything
  else.
- **The agent builds the graph itself,** from a starter template, with no
  proposal cards. It may add node types beyond a small starter set.

## What exists today

Tom T's branch `tt/feature/graph-db`, in `sphinx-ios-v2` and
`sphinx-mac-v2` (2026-10-07 to 10-09):

- **The driver only.** [swift-ladybug](https://github.com/LadybugDB/swift-ladybug),
  product `Ladybug`: `Database`, `Connection`, `PreparedStatement`,
  `QueryResult`. Queries are Cypher.
- **iOS:** a vendored source copy in `LocalPackages/swift-ladybug`, pinned
  to upstream `c071a7c`, because upstream ships no iOS binary
  ([swift-ladybug#14](https://github.com/LadybugDB/swift-ladybug/issues/14)).
  Needs iOS 17.
- **Mac:** the remote package, with `scripts/embed-liblbug.sh` downloading,
  signing and embedding the prebuilt library for arm64 and x86_64.
- **Not yet:** a graph layer, sync, or any app code that uses it.

Peel is a SwiftPM package, not an Xcode project, so the Mac Run Script
does not carry over. The likely route is the vendored source package for
both platforms; building it for macOS is still to be tried.

## The pieces

```
 Peel (Mac now, iPhone next)          official Sphinx apps (Tom T)
 ┌────────────────────────────────┐   ┌───────────────────────────────┐
 │ Agent chat UI (per platform)   │   │ their own UI                  │
 │ AgentKit: loop · tools · gate  │   │                               │
 │ PeelCore engine                │   │ their engine                  │
 │ GraphKit + GraphSync ──────────┼───┼─ GraphKit + GraphSync         │
 │ Ladybug: local file            │   │ Ladybug: local file           │
 └───────────────┬────────────────┘   └───────────────┬───────────────┘
                 │   change-log events, encrypted,    │
                 └──── Sphinx messages to yourself ───┘
                                 │
                         broker + mixer: queues for
                         devices that are offline
```

Proposed packages, all platform-neutral Swift with no AppKit or UIKit.
None is built yet; GraphKit and GraphSync are to be agreed with Tom T.

| Package | Owner | Holds |
|---|---|---|
| GraphKit | Shared with Tom T | The graph tools over `Ladybug`, on the generic Node and Edge tables |
| GraphSync | Shared with Tom T | The change log, field timestamps, encryption keyed from the seed, batching, snapshots, and a transport protocol |
| AgentKit | Peel | The loop, model providers, tool registry, payment gate, compaction and context assembly |
| PeelCore | Peel | The Sphinx engine the Sphinx tools call |

### Where things run

Each part sits behind a protocol, so moving the agent to a server swaps the
implementation, not AgentKit.

| Part | Now (inside Peel) | Later (always-on server) |
|---|---|---|
| Channel: how you talk to the agent | A local Agent chat in Peel, calling AgentKit directly | Sphinx messages to the agent's own account; the agent is a contact |
| Graph | The local LadybugDB file | A local file on the server, synced the same way |
| Tools | Graph, then Sphinx actions | Adds schedules, coding agents (ACP) and connectors |
| Gate | Payments ask | The same, plus spending caps for unattended runs |

## The graph

### Storage

LadybugDB needs its tables defined before any insert, so the stored tables
are fixed and generic. The ontology (which node and edge types exist and
what they mean) lives in the data, not in the tables:

```
NODE Node (ref_id PK, type, name, body, props, created_ms, updated_ms,
           created_by, source, deleted_ms)
REL  Edge (Node → Node: ref_id, type, props, created_ms, created_by,
           deleted_ms)
```

`type` is a string. `props` holds the type's own fields, as a MAP if the
Swift wrapper handles it, else a JSON string (to find out first). A type
that becomes heavy and stable can move to its own table later.

### Starter template and ontology

Every new graph starts with a small tree the agent grows from: Me, People,
Projects, Interests. The starter types are Concept, Memory, Person, Task,
Source, Conversation, Turn and Summary. The agent creates nodes, edges
and new types directly. Each type is also a Type node with a description
and an example, so `ontology()` can show it. A tidy-up job merges synonyms
such as Note and Memory.

### Principles

1. **Identity is the `ref_id`,** never the name or the wording.
2. **Every tool works on any node type.** No tool is specific to Concept,
   Memory or anything else; the type is a field.
3. **Writes change only the fields sent.** Nothing is replaced whole.
4. **Nothing is hard-deleted.** Forgetting sets `deleted_ms`; a changed
   fact is a new node that supersedes the old one.
5. **Every node and edge records who wrote it and from what.** `created_by`
   is the user or the agent; `source` points at the turn or message.
6. **Pointers, not copies.** A Sphinx message is referenced by its id, not
   copied.
7. **Reads return small results.** Search and walk return ids, names and
   snippets; `read` expands one node.
8. **`add` returns similar existing nodes,** so the agent links to one
   instead of making a near-copy.
9. **People and the agent use the same actions.** What the UI does is also
   a tool.

### Graph tools

The same set is GraphKit's API and the agent's graph tools.

| Tool | Does |
|---|---|
| `search(q, type?, limit)` | Keyword and vector search over all nodes; ids, names and snippets |
| `read(ref_id)` | One node in full, with a one-line summary of each neighbour |
| `walk(ref_id, edge_types?, direction?, depth ≤ 2, limit)` | Neighbours of any node |
| `add(type, name, body?, props?, links?)` | Creates a node; returns its `ref_id` and up to 3 similar nodes |
| `update(ref_id, props)` | Changes only the fields given |
| `link(from, type, to, props?)` / `unlink(edge)` | Adds or soft-removes an edge |
| `forget(ref_id, reason)` | Soft delete, restorable |
| `ontology()` | The node and edge types in use, with counts, descriptions and an example |

Remembering is `add(type: "Memory", …)` with links to what it is about;
growing the concept tree is `add(type: "Concept", …)` and `link`. Later,
only if needed: `supersede(old, new)` and a read-only `query(cypher)`.

## Sync

Every write becomes one event:

```
{ v, event_id, ref_id, op: add | update | link | unlink | forget,
  fields: {name: value, …}, ts (hybrid logical clock), device }
```

- **Applying.** Each device applies events in order into its LadybugDB
  file. For each field the value with the latest `ts` wins; ties go to the
  higher `device`. The local file is a view of the log and can be rebuilt
  from it.
- **Encryption.** Events are encrypted with a key derived from the user's
  seed. The broker, the mixer and anyone else see only ciphertext.
- **Transport.** Events are batched (one message per few seconds of
  activity, not one per event) and sent as Sphinx messages to the user's
  own account. Each device catches up by message index, as it already does
  for chats and read markers (verified on two devices of one account in
  [phases/02-messaging.md](phases/02-messaging.md)).
- **New devices.** A new device loads an encrypted snapshot, then the
  events after it, instead of replaying everything.
- **Not synced.** Embeddings; each device computes its own.
- **The event format is a contract** between Peel and the official apps.
  It is agreed with Tom T before either side writes data, and versioned
  by `v`.

Open: whether the core can send a message to your own account, and what
each message costs in sats and latency. If it cannot, the fallback is a
relay that stores encrypted batches it cannot read, behind the same
transport protocol.

## The agent

### The loop

One turn per message in the Agent chat:

1. Write the user's message as a turn node in the Conversation.
2. Assemble context: the short system prompt, the recent turns, and the
   results of a first `search` on the message.
3. Call the model with the tool list. Run each tool call; ask before any
   payment.
4. Write the reply as a turn node, and any memories with `source` set to
   the turn.

**Compaction.** When a conversation grows past the model's budget, older
turns are folded into a Summary node linked to the turns it covers. The
loop then reads the summary instead of those turns; the turns stay.

### Storage before the graph

AgentKit is built before GraphKit (see "Phases"). Until then it stores its
records (conversations, turns, summaries, memories) behind one storage
protocol, in SQLite through GRDB as Peel already does. Each record is
shaped like a graph node from the start: a `ref_id`, a type, `created_by`,
`source`, `deleted_ms` and edges to other records. Moving to the graph is
then a one-off import, each record written as an event, not a redesign.

Everything the agent writes ends up in the graph. Three things never do:
Sphinx messages themselves (PeelCore keeps them; the graph points at their
ids), secrets such as API keys (Keychain only), and embeddings (each
device computes its own).

### Tools

The graph tools above, plus the Sphinx tools through PeelCore:

| Tool | Does |
|---|---|
| `read_chat(chat, limit)` | Recent messages from a Sphinx chat, for a task |
| `send(chat, text)` | Sends a Sphinx message |
| `pay(contact or invoice, amount)` | Pays, after the user approves |

### Models

AgentKit has one provider interface with two kinds of provider:

- **Pasted API keys:** Anthropic, OpenAI, OpenRouter and others. These
  work on every platform. Keys are kept in the Keychain.
- **Linked accounts:** a Claude or Codex subscription. Vendors limit their
  subscription sign-ins inside third-party apps, so check each vendor's
  terms before building this. On the Mac, the route that stays inside the
  terms is running the vendor's own CLI over ACP under the user's login;
  that is not possible on iPhone.

## Risks

- **Sends without approval.** To carry out a task the agent reads a chat,
  and text in that chat could tell it to message someone. Guard: sends go
  out without asking only to contacts the user named in the request;
  anything else asks.
- **Message cost.** Unknown until the sync spike; batching keeps the count
  low.
- **Search on iPhone.** Whether LadybugDB's full-text and vector extensions
  work on iOS is unknown. The fallback is a SQLite FTS index beside the
  graph.
- **Two writers to one event format.** Peel and the official apps must
  agree on the format and change it only together.

## Phases

AgentKit comes first, while the graph plan is agreed with Tom T. Two tracks
run in parallel and meet at one gate.

**Peel, now: AgentKit**

1. **Models.** Pasted API keys for any provider and OpenRouter; linked
   Claude or Codex accounts where the vendor's terms allow.
2. **Agent chat.** The loop, chat messages, the tool registry and a short
   system prompt, on the SQLite storage above.
3. **Sphinx tools.** `read_chat`, `send`, and `pay` with approval.
4. **Compaction.**

**With Tom T, in parallel**

- Agree the graph tools, the starting ontology and the event format.
- Tom T builds GraphKit on `Ladybug` and runs the spikes: search on iOS,
  sending to your own account, and the cost per message.

**Gate: the graph plan is agreed.** Then:

5. **The graph in Peel.** AgentKit's storage protocol switches to
   GraphKit; existing records are imported as events; the graph tools are
   turned on.
6. **GraphSync.** Two devices converge, then Peel and the official apps
   share one graph.
7. **Peel on iPhone, then always-on,** running the same AgentKit.

## Later

The old plan's parts, still wanted, now behind the seams above:

- **Always-on.** AgentKit and PeelCore run headless on a server. The
  agent gets its own Sphinx account and becomes a contact; you reach it
  from any Sphinx app while your devices sleep.
- **Coding agents over ACP** (Claude Code, Codex), on the Mac or the
  server. The ACP research stays in
  [research/acp-harnesses.md](research/acp-harnesses.md).
- **Strut** for jobs, schedules and workflows, when the agent needs
  long-running work.
- **Threads and typed cards in DMs**, once the agent is a contact.
- **The Inbox** ([phases/09b-inbox.md](phases/09b-inbox.md)), with Items as
  graph nodes that sync like everything else.
- **Connections:** calendar first (EventKit on the Mac, OAuth through MCP
  on a server), then email, contacts, files and notes. Read only by
  default; tokens never travel in a Sphinx message.

## Open questions

1. Can the core send a message to your own account, and at what cost?
2. The exact event format, agreed with Tom T.
3. How Tom T plans to store and sync the graph in the official apps.
4. Do LadybugDB's search extensions work on iOS?
5. Do MAP properties work through the Swift wrapper?
6. One pinned swift-ladybug commit and one build recipe for both apps.
7. Which vendors allow linked accounts in a third-party app.
