# Phase 9 — The Sphinx agent, v1

## Status (2026-10-10)

**Planned, not built.** Tom decided the v1 scope on 2026-10-10. This file
is the build plan; the design is in `../agent-architecture.md`.

The plan of 2026-10-08 (an agent host with its own Sphinx account, workers
over ACP, Strut jobs, graph memory) was replaced on 2026-10-10. It is in
git history: this file before this PR, at the base of PR #156. The ACP
research it cited stays in `../research/acp-harnesses.md`.
`09b-inbox.md` predates the replan and is kept for its research.

PRs: 1 this file, 2 the data layer, 3 models and the turn loop, 4 tools
and the Sphinx read tools, 5 the Agent chat, 6 the send tool. Each is
described under "Build plan".

## Scope of v1

v1 is the foundational agent: a chat in Peel that can talk to a model and
act in Sphinx.

- **It runs inside Peel on the Mac.** The agent code is platform-neutral,
  so Peel on iPhone and an always-on server can run it later.
- **Connect a model.** Either a pasted API key (Anthropic, OpenAI,
  OpenRouter) or a linked account. OpenRouter sign-in comes first. Claude
  and ChatGPT subscriptions come only after each vendor's terms are
  checked. Keys are kept in the Keychain, per device.
- **The Agent chat.**
  - A "Sphinx Agent" row in Direct messages.
  - An explainer and the setup as the chat's empty state.
  - Replies stream in, as Markdown. Stop ends a reply.
  - Tool activity shows as quiet rows that expand on click.
  - New conversation adds a divider; it is one timeline.
  - Errors show inline, with Retry.
  - Settings in an Agent section of the Account page.
- **Sphinx tools,** with the official apps' names (below). Sends go out
  directly, without asking. Every send shows as a row in the Agent chat,
  linking to the message.
- **Each tool declares its effect,** read or send, so a gate can be added
  later without touching the tools.

Out of v1: payments, approval gating, memory, the graph, sync, Hive tools,
web search (optional, if it is cheap), iPhone, always-on, ACP workers,
connectors, and reading the official apps' synced `ai_agent_config`.

## Screens

The UI is being designed on a design board now. This section will link to
it once agreed. The screens:

1. The empty state: what the agent is, and the setup.
2. Connect a model: the provider, the key or sign-in, and a test call.
3. The chat: streamed replies, tool rows, send rows, the New conversation
   divider, inline errors.
4. Account › Agent: the connected model, change or remove it.

`../design/agents.md` was drawn for the old plan (one agent contact on a
host, workers, ask cards) and will be replaced by the board.

## Sphinx tools

The names match the official Mac app (`sphinx-mac-v2`,
`Managers/AI Agent/AIAgentManager.swift`), so the agent behaves the same
in both clients.

| Tool | Effect | Does |
|---|---|---|
| `get_contacts_and_tribes` | read | Contacts and tribes, with names and ids |
| `read_recent_messages` | read | The last messages of one chat |
| `read_unseen_messages` | read | Unseen messages, per chat |
| `read_threads` | read | The threads of a chat, and one thread's messages |
| `search_messages` | read | Search across chats, reusing Peel's chat search |
| `send_sphinx_message` | send | Sends to a contact or tribe, in a thread or as a reply |
| `mark_chat_as_seen` | send | Marks a chat as read |

`read_threads` and `search_messages` are Peel's own; the official app has
no tool by those names. Its `send_sphinx_message` takes a contact or tribe
name and text; Peel adds optional thread and reply fields.

## Core primitives

All in `AgentKit`. Record and Event are shared with Tom T's graph work in
the official apps (branch `tt/feature/graph-db`, which adds swift-ladybug;
his plan is a timestamped log of every write, synced as encrypted files on
the memes server, like the preferences file). Their shapes must be agreed
with him before PR 2 merges.

- **Record:** `ref_id`, `type`, `name`, `body`, `props`, `created_by`,
  `source`, `created_ms`, `updated_ms`, `deleted_ms`. Records are linked
  to each other. Conversations, turns and tool calls are records.
- **Event:** `v`, `event_id`, `op` (`add`, `update`, `link`, `unlink`,
  `forget`), `ref_id`, `fields`, `ts` (a hybrid logical clock) and
  `device`. There is one write path: append the event to the log, then
  apply it.
- **Store:** a protocol with `write(event)`, `read`, `search`, `walk` and
  `ontology`. SQLite now, LadybugDB later.
- **ModelProvider:** a protocol. The first implementation wraps
  swift-ai-sdk, which the official apps use, behind our interface.
- **Tool:** a name, an input schema, a handler and an effect.
- **Turn loop:** one turn per message: build the context, call the model,
  run its tool calls, write the reply.
- **Context:** the system prompt and the recent turns. Compaction comes
  later, as a Summary record.

## Package layout

| Target | Depends on | Holds |
|---|---|---|
| `AgentKit` | GRDB only; no PeelCore, AppKit or UIKit | The primitives above |
| `PeelAgent` | AgentKit, PeelCore | The Sphinx tools and the wiring to the engine |
| `PeelApp` | everything | The Agent chat and settings UI |

Storage: `agent.sqlite`, one per account, beside `peel.sqlite`. API keys
never go in it.

## Build plan

Each PR goes through "How a change ships" in `../../AGENTS.md`.

1. **This phase file.** Done when Tom has agreed it.
2. **AgentKit data layer.** Record, Event, the hybrid logical clock,
   Store, and the SQLite event log. Done when unit tests cover write,
   apply, read, search, walk, forget and rebuilding the tables from the
   log, and the shapes are agreed with Tom T.
3. **ModelProvider and the turn loop.** Driven from the `peel` CLI first.
   Done when a CLI command holds a streamed conversation with a pasted
   key, Stop works, and a bad key, a rate limit and no network each give
   a plain error.
4. **Tool registry and the Sphinx read tools.** Done when, from the CLI,
   the agent answers "what's new?" and "find the message about X" on a
   development profile, with every tool call recorded.
5. **The Agent chat UI and setup,** after the design board is agreed.
   Done when the journeys below, other than "do it for me", pass in the
   app with `scripts/check-app.sh`.
6. **The send tool.** `send_sphinx_message` and `mark_chat_as_seen`. Done
   when "do it for me" passes on a development profile against the local
   test server.

Later: compaction, then memory.

## User journeys

Each is done when it works in the app on a development profile.

- **Set up.** From the empty chat, connect a model. A test call verifies
  it. A wrong key or a failed call says what went wrong in plain words.
- **Ask anything.** A question gets a streamed Markdown reply. Stop ends
  it and keeps what arrived.
- **Catch me up.** "What did I miss?" summarises unseen messages per chat,
  each with a link to the chat.
- **Find something.** "Find the message about X" answers with links to the
  messages.
- **Do it for me.** "Tell Kate I'm late", "reply in that thread": the
  message goes out, in the right thread or as a reply, and a send row
  links to it.
- **New conversation.** Adds a divider; the agent no longer sees the turns
  above it.
- **Things go wrong.** No key, a bad key, a rate limit and no network each
  show an inline error with Retry; nothing is lost.

## Still open

- The Record and Event shapes, agreed with Tom T.
- Which vendors allow a linked subscription in a third-party app.
- Whether web search is worth adding in v1.
