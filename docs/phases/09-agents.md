# Phase 9 — The Sphinx agent, v1

## Status (2026-10-11)

**In progress.** Tom decided the v1 scope on 2026-10-10. This file is the
build plan; the design is in `../agent-architecture.md`. Built: PR 1 (this
plan, #157) and PR 2 (the AgentKit data layer). PR 3 (model clients and
the turn loop, driven by `peel agent`) and PR 4 (the Sphinx read tools,
in the new `PeelAgent` target) are in review.

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
  - A "Peel" row in Direct messages, with the Peel logo. Until a model is
    connected the row shows "Set up" in link blue; after that, the AGENT
    label, which also shows on its messages.
  - Before setup, Peel introduces itself as the chat's first message, with
    a card to connect a model.
  - Replies stream in, as Markdown. Stop ends a reply.
  - Tool activity shows as quiet rows that expand on click.
  - One long conversation, like any DM. The model sees only the most
    recent turns that fit a token budget; older messages stay on screen.
    Clear conversation, in Account, starts over.
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

Design board, 2026-10-10:
https://claude.ai/artifact/Kj79C1MsMNQ1oLqRMSzSNf (option 1A chosen for
before setup). The screens:

1. Before setup: Peel's first message introduces it, with a Connect card.
2. Connect a model: a panel beside the button; the provider, the key or
   sign-in, the model, and a test call.
3. The chat: streamed replies, tool rows, send rows, inline errors, Stop.
4. Account › Peel agent: name, provider, key (Replace, Remove), model,
   Clear conversation.
5. Edge cases: checking a key, a rejected key, OpenRouter sign-in, a
   failed send, a stopped reply, offline, rate limit, a dead key.

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
- **ModelProvider:** a protocol: messages and tools in, a stream of text
  deltas, tool calls and usage out, cancellable. Two small clients of our
  own (decided 2026-10-10): Anthropic Messages, and OpenAI-compatible Chat
  Completions, which also covers OpenRouter. About 1,000 lines with
  fixture tests. Not swift-ai-sdk, which the official apps use: about
  100k lines from one author, frequent breaking releases, and 186
  `@unchecked Sendable` escapes. Anthropic's ClaudeForFoundationModels
  (`ClaudeAPI` target, Apache-2.0) is the reference design.
- **Tool:** a name, an input schema, a handler and an effect.
- **Turn loop:** one turn per message: build the context, call the model,
  run its tool calls, write the reply.
- **Context:** the system prompt and the most recent turns that fit a
  token budget. Compaction comes later, as a Summary record.

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

## Journal

**PR 2, the AgentKit data layer (2026-10-11).**
- Done: `Record`, `Link`, `Event` (snake_case JSON, keys sorted, `v` 1),
  `HLC`, the `AgentStore` protocol with writers that build the events, and
  `SQLiteAgentStore`: an append-only event log, records and links applied
  from it, `rebuild()`, FTS5 search, walk to depth 2, and `ontology()`.
- Learned: last write wins per field needs a clock per field, kept in a
  `field_clock` table (one row per ref_id and field, props per key);
  `forget` and `unlink` are just `deleted_ms` under the same rule, and an
  update can arrive before its add. The store owns the clock and seeds it
  from the newest stamp in the log, so a clock set back while closed still
  orders new events after old ones.
- Next: share the Event and Record shapes with Tom T. For sync, cap how
  far ahead a remote stamp may be, and authenticate events.

**PR 3, model clients and the turn loop (2026-10-11).**
- Done: `ModelProvider` with two clients of our own, `AnthropicProvider`
  (Messages, streamed) and `OpenAICompatibleProvider` (Chat Completions,
  OpenAI and OpenRouter), over one shared `URLSession` with no cookies,
  cache or redirects, https only (or http to this Mac). `ModelError`
  words a bad key, a rate limit, an outage, no network and a refused
  request plainly, with the key scrubbed from provider messages. `Tool`
  (with its `read` or `send` effect), `ToolRegistry`, the `current_time`
  tool, `ContextWindow` (recent whole turns within a token budget,
  estimated at three UTF-8 bytes a token) and `AgentLoop` (stream, run
  tools, repeat, at most `maxSteps` model calls). `peel agent` holds a
  streamed conversation in the terminal with the key from
  `PEEL_AGENT_API_KEY` only; Ctrl-C stops the reply, not the process.
  Checked by hand: no key, a fake key (401), nothing listening, an http
  address, Ctrl-C during two replies from a local slow stream (each
  request is cancelled and the process carries on), and two Ctrl-Cs in
  one reply, which quit.
- Learned: `ExpressibleByNilLiteral` on `JSONValue` turns `cond ? nil : x`
  into `.null`, which broke props removal and the Anthropic encoder, so
  the library has every literal but nil. Anthropic refuses whitespace-only
  text blocks, so a stopped reply of "\n\n" would have broken every later
  turn. Signed thinking blocks are bound to the conversation before them,
  so the loop sends them back only within their own turn and strips them
  from earlier ones (removing a leading run is allowed). A refused reply
  is left out of the history, as Anthropic advises; OpenAI words its
  refusals in `delta.refusal` and finishes with "stop". A turn that ends
  on tool results (Stop during a tool, the step cap) gets a closing
  assistant line, since the next turn sends no reasoning and an open tool
  loop without it is refused; a turn with no reply adds nothing, so asking
  again does not send the question twice. A token per four characters
  undercounts code and CJK; a token per three UTF-8 bytes errs high for
  English and is about right for both. The independent review found
  those last three, a recent turn over the budget emptying the whole
  window, and two quick Ctrl-Cs arriving as one signal.
- Not applied, with reasons: server-side refusal `fallbacks` (a mid-stream
  fallback changes which blocks may be echoed back; worth doing with the
  chat UI, when there is somewhere to show it); per-model `effort` (Opus
  5.5 defaults to medium, which suits chat); in-place appends for
  Anthropic thinking and tool-argument text (enum payloads cannot be
  mutated in place, current models send thinking empty, and tool
  arguments are small); `Tool.Effect` and `ModelError.isRetryable`, which
  nothing reads yet, are kept because the plan needs them (the send gate,
  Retry); the `agent` dispatch stays a check on the first argument, since
  it opens no profile and the usage says so; `maxTokens` stays 16,000
  (OpenAI-compatible models cap lower than Anthropic's, and one default
  serves both); a two-chunk HTTP test of the line splitter (its unit
  tests cover CRLF split across reads).
- Next: PR 4, the Sphinx read tools on this loop, with every tool call
  recorded in the AgentKit store.

**PR 4, the Sphinx read tools (2026-10-11).**
- Done: the `PeelAgent` target (AgentKit and PeelCore, no AppKit or
  UIKit) with five `.read` tools over one profile's `Storage`:
  `get_contacts_and_tribes`, `read_recent_messages(chat, limit)`,
  `read_unseen_messages(chat?)` (no chat: every chat the sidebar counts as
  unread, grouped per chat, a muted one only for its mentions),
  `read_threads(tribe, thread_uuid?, limit)` and `search_messages(query,
  chat?, limit)` over Peel's chat search. They read through what the app's
  views read (`conversations`, `readStates`, `timeline`, `thread`,
  `searchMessages`) plus two storage reads beside them that reuse the
  existing SQL: `unreadMessages(in:)` (`countsAsUnreadSQL`) and
  `threads(in:limit:)` (`threadSummaries`). Names resolve as the official
  app resolves them (chat id, exact, normalised, without spaces, part of a
  name, typos), with ambiguity answered by listing the candidates and
  their chat ids. Lines use the official format, under a heading with the
  chat id, so each message carries its chat id and uuid for a later View
  link. `peel --profile <name> agent` (or `peel agent --profile <name>`)
  gives the model these tools, read-only; only the summary line of each
  result is printed. Checked by hand against a local stub of the
  Messages API on development profiles: unseen, search and an unknown
  tribe.
- Untrusted input: other people's words go to the model between marker
  lines that say they are information, never instructions; each message,
  name, uuid and chat id is cleaned to one line (control characters as
  spaces; direction controls, zero-width characters and Unicode tags
  dropped; no run of three "<" left) and capped (text at 400 characters,
  names at 60); every message line starts with a fixed `[sender] date (`
  prefix, so nothing in a message can start a line, end the block or pose
  as another line. Someone named "Me" reads as "Me (not the user)". A
  result is capped at 12,000 characters, cut by whole lines and saying so;
  with no chat named, unseen messages are shared out across the chats
  shown (30 lines in all). The system prompt says that names anywhere in
  a result, and everything between the markers, were written by other
  people. The tools read messages, contacts and tribes only: no setting,
  key or the seed.
- Reviews: /code-review found the `peel agent --profile` order refused, a
  run of five "<" rebuilding the marker, muted chats listed whole, search
  dropping left tribes after its limit, a single chat's count off by one,
  a long thread cut losing its root and a capped reply count; all fixed.
  /simplify: one resolve path that throws, one `agent` dispatch, the
  unread read seeking past the marker (a constant subquery rather than a
  join), the timeline read at the size asked for. /security-review: chat
  names outside the markers (the system prompt now covers names anywhere)
  and invisible characters that could split a marker; fixed. Independent
  review (risk raised to high for untrusted input): "what did I miss?"
  could lose whole chats to the cut, anyone could appear as "Me", a chat
  on mentions only was called muted, a reply's uuid read as a thread, a
  mistyped profile left an empty folder, chat ids uncleaned, Unicode tags
  kept; all fixed.
- Not applied, with reasons: membership-note wording shared with the
  app's `MembershipNote` (it lives in PeelApp, which another PR owns; the
  agent's own wording is short and plain); a one-shot (non-observing)
  read API in Storage for the tools (each tool call is one read, and the
  CLI's read-only commands use the same `first` of an observation); a
  separate PeelAgentTests target (it would need the storage fixtures
  moved into a shared module); renaming PeelCore's `JSONValue` (outside
  this change); a per-tool cut note and a limit for
  `get_contacts_and_tribes` (a list over 12,000 characters is about 150
  chats); local time zones in lines (dates are UTC, and the prompt says
  so; `current_time` gives the zone).
- Learned: PeelCore has its own `JSONValue` (preferences), so code that
  imports both modules names AgentKit's. A read-only `Storage` on a
  profile last opened by an older build fails with SQLite error 1, as the
  read-only CLI commands do; open it once with a current build.
- Not done here: recording each tool call in the AgentKit store. It
  belongs with the Agent chat's conversation records (PR 5); the CLI
  keeps no conversation.

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
- **Things go wrong.** No key, a bad key, a rate limit and no network each
  show an inline error with Retry; nothing is lost.

## Where it runs

v1 runs inside Peel, on the device: Mac now, iPhone later, with no server
(decided 2026-10-10). An agent in Strut was considered: Strut is
TypeScript, already uses Vercel's AI SDK, and the official Mac app bundles
it. It was set aside for v1 because it cannot run on an iPhone, and a phone
talking to Strut on a Mac fails while the Mac sleeps. Always-on and
proactive work need a server either way; Strut or another runtime can be
weighed again then. What keeps that move cheap: the tool names and
schemas, the event log format and the provider interface are contracts,
not Swift types other code depends on.

## Still open

- The Record and Event shapes, agreed with Tom T.
- Which vendors allow a linked subscription in a third-party app.
- Whether web search is worth adding in v1.
