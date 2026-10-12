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
- **Sync is an encrypted change log:** each write is a small event, kept
  in a local log and uploaded as encrypted files to the memes server, as
  the official apps already do for their preferences file. Every device
  replays the others' events into its local LadybugDB file. Last write
  wins per field.
- **The graph is the knowledge.** The agent has a short system prompt and
  walks the graph toward its goal. Glimmer, the concept tree, is content
  in the graph: Concept is one node type among others, read and walked
  with the same generic tools.
- **Version 1 is the foundational agent:** connect a model, chat, read
  and search your Sphinx chats, and send messages. No memory, graph,
  payments or approvals yet; the plan is in
  [phases/09-agents.md](phases/09-agents.md).
- **Sends go out directly,** as in the official apps, and every send shows
  in the agent chat. Each tool declares its effect (read or send), so an
  approval gate can come later without changing the tools.
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
 │ AgentKit: loop · tools         │   │                               │
 │ PeelCore engine                │   │ their engine                  │
 │ GraphKit + GraphSync ──────────┼───┼─ GraphKit + GraphSync         │
 │ Ladybug: local file            │   │ Ladybug: local file           │
 └───────────────┬────────────────┘   └───────────────┬───────────────┘
                 │   change-log events, encrypted,    │
                 └──── files on the memes server ─────┘
```

Proposed packages, all platform-neutral Swift with no AppKit or UIKit.
None is built yet; GraphKit and GraphSync are to be agreed with Tom T.

| Package | Owner | Holds |
|---|---|---|
| GraphKit | Shared with Tom T | The graph tools over `Ladybug`, on the generic Node and Edge tables |
| GraphSync | Shared with Tom T | The change log, field timestamps, encryption keyed from the seed, batching, snapshots, and a transport protocol |
| AgentKit | Peel | The loop, model providers, tool registry, compaction and context assembly; an approval gate later |
| PeelCore | Peel | The Sphinx engine the Sphinx tools call |

### Where things run

Each part sits behind a protocol, so moving the agent to a server swaps the
implementation, not AgentKit.

| Part | Now (inside Peel) | Later (always-on server) |
|---|---|---|
| Channel: how you talk to the agent | A local Agent chat in Peel, calling AgentKit directly | Sphinx messages to the agent's own account; the agent is a contact |
| Graph | The local LadybugDB file | A local file on the server, synced the same way |
| Tools | Graph, then Sphinx actions | Adds schedules, coding agents (ACP) and connectors |
| Approvals | None in v1 | An approval gate, with spending caps for unattended runs |

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
- **Encryption.** Events are encrypted with the account's key, as the
  preferences file is (RNCryptor with the node secret key; see
  [phases/11-preferences-sync.md](phases/11-preferences-sync.md)). The
  memes server sees only ciphertext. Only the official preferences file
  uses the raw node secret (the official apps need it); Peel-only graph
  data uses its own key, derived from the node secret by HKDF with a
  label, so one key never serves two formats.
- **Transport** (Tom T's plan, 2026-10-10: every write logged locally with
  its timestamp, uploaded to the memes server as an encrypted file; the
  fetch and push rules are still to be agreed). Proposed rules:
  - Each device writes only its own append-only segment files (such as
    `graph/<device>/<seq>`), so no two devices write the same file.
  - Push new segments in batches after a few seconds of quiet; never
    re-upload history.
  - Fetch other devices' new segments on launch, on return to the
    foreground and on an interval; apply them idempotently by `event_id`.
  - Never overwrite on a failed read: the memes server answers 404 for
    any storage error, not only a missing file. A bad event is skipped,
    not treated as an empty log; unknown ops and fields are kept.
- **Not like the preferences file:** that file is one shared document
  that each device reads, merges and re-uploads whole, so two devices can
  overwrite each other and one unreadable item can wipe it. A growing graph
  log cannot work that way.
- **New devices.** A new device loads an encrypted snapshot, then the
  events after it, instead of replaying everything.
- **Not synced.** Embeddings; each device computes its own.
- **The event format is a contract** between Peel and the official apps.
  It is agreed with Tom T before either side writes data, and versioned
  by `v`.

Open: whether the memes server can store several named files per account,
or only the one `/preferences` slot. Per-device segments need named files
or a new endpoint.

## The agent

### The loop

One turn per message in the Agent chat:

1. Write the user's message as a turn node in the Conversation.
2. Assemble context: the short system prompt and the recent turns (later,
   the latest summary and the results of a first `search` on the message).
3. Call the model with the tool list, streaming the reply, and run each
   tool call.
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

The Sphinx tools through PeelCore, under the official apps' names where
they exist; the full v1 list is in [phases/09-agents.md](phases/09-agents.md).
The graph tools above join them once the graph lands.

| Tool | Effect | Does |
|---|---|---|
| `get_contacts_and_tribes` | read | Contacts and tribes, with names and keys |
| `read_recent_messages`, `read_unseen_messages` | read | Messages from a chat, for a task |
| `read_threads`, `search_messages` | read | Peel's own: tribe threads; search across chats |
| `send_sphinx_message` | send | Sends a message, optionally in a thread or as a reply |
| `mark_chat_as_seen` | send | Marks a chat read |

### Models

AgentKit has one provider interface, implemented by two small clients of
our own (Anthropic, and OpenAI-compatible for OpenAI and OpenRouter), not
swift-ai-sdk; the reasons are in [phases/09-agents.md](phases/09-agents.md).
Two kinds of provider:

- **Pasted API keys:** Anthropic, OpenAI, OpenRouter and others. These
  work on every platform. Keys are kept in the Keychain.
- **Linked accounts:** OpenRouter's sign-in first (the user signs in on
  openrouter.ai and Peel receives a key they control). Claude and ChatGPT
  subscriptions only once each vendor's terms are checked; on the Mac the
  route inside the terms may be the vendor's own CLI over ACP, which is not
  possible on iPhone.

## Own versus rent

Peel owns what no package does for it: the Sphinx tools, the session and
UI, the event log and sync, and small pieces tied to its storage and UI.
It rents what providers change every month: the model clients and MCP.
The full list of what the agent has and lacks is in
[phases/09-agents.md](phases/09-agents.md), "Capabilities against agent
SDKs".

## Risks

- **Sends without approval.** To carry out a task the agent reads a chat,
  and text in that chat could tell it to message someone. v1 accepts this,
  as the official apps do, and shows every send in the agent chat. The
  first gate rule, when it comes: sends go out without asking only to
  contacts the user named in the request.
- **Search on iPhone.** Whether LadybugDB's full-text and vector extensions
  work on iOS is unknown. The fallback is a SQLite FTS index beside the
  graph.
- **Two writers to one event format.** Peel and the official apps must
  agree on the format and change it only together.

## Phases

AgentKit comes first, while the graph plan is agreed with Tom T. Two tracks
run in parallel and meet at one gate.

**Peel, now: AgentKit**

The pull requests and what "done" means for each are in
[phases/09-agents.md](phases/09-agents.md): the data layer, models and the
turn loop, the Sphinx read tools, the Agent chat, the send tool. Then
compaction and the memory tools.

**With Tom T, in parallel**

- Agree the graph tools, the starting ontology and the event format.
- Tom T builds GraphKit on `Ladybug` and runs the spikes: search on iOS,
  and named files per account on the memes server.

**Gate: the graph plan is agreed.** Then:

5. **The graph in Peel.** AgentKit's storage protocol switches to
   GraphKit; existing records are imported as events; the graph tools are
   turned on.
6. **GraphSync.** Two devices converge, then Peel and the official apps
   share one graph.
7. **Peel on iPhone, then always-on,** running the same AgentKit.

## Later

The old plan's parts, still wanted, now behind the seams above:

- **Always-on.** Proactive work, and an agent reachable while your devices
  sleep, need a server. Strut (TypeScript, already bundled in the official
  Mac app) is the alternative to weigh then, against AgentKit and PeelCore
  run headless on a server; the tool, event and provider contracts keep
  either move cheap. Either way the agent gets its own Sphinx account and
  becomes a contact, reachable from any Sphinx app.
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

1. Can the memes server hold several named files per account?
2. The exact event format and the fetch and push rules, agreed with Tom T.
3. Do LadybugDB's search extensions work on iOS?
4. Do MAP properties work through the Swift wrapper?
5. One pinned swift-ladybug commit and one build recipe for both apps.
6. Which vendors allow linked accounts in a third-party app.
