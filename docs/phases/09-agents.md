# Phase 9 — The Sphinx agent, v1

## Status (2026-10-12)

**In progress.** Tom decided the v1 scope on 2026-10-10. This file is the
build plan; the design is in `../agent-architecture.md`. Built: PR 1 (this
plan, #157), PR 2 (the AgentKit data layer, #171), PR 3 (model clients
and the turn loop, #178), PR 4 (the Sphinx read tools, #181) and PR 5
(the Agent chat in the app). PR 6, the approval gate and the send tool,
is in review (2026-10-12, Tom's brief: every send asks first, so the gate
came with it). `mark_chat_as_seen` is deferred to a PR of its own: it
needs the gate's "always" wording for a tool that changes no message.
Hardening the loop: automatic retry and concurrent reads, and compaction
stacked on it (both in review). Then memory.

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
- **Sphinx tools,** with the official apps' names (below). Every send
  asks first, on a card in the Agent chat (changed 2026-10-12 from "sends
  go out directly"), and shows as a row linking to the message.
- **Each tool declares its effect,** read or send; every call of a tool
  that acts waits on the approval gate.

Out of v1: payments, memory, the graph, sync, Hive tools,
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
- **Context:** the system prompt, a summary of older turns once there is
  one (a Summary record), and the most recent turns that fit a token budget.

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

Hardening the loop (Tom, 2026-10-12: no evals, tracing, cost or
extended thinking; keep it simple), two stacked PRs:

- **Retry and concurrent reads.** A model call that fails with a rate
  limit, an outage, a dropped connection or a 408 (`ModelError.isRetryable`)
  is made again on its own, honouring `retry-after`, else waiting 2, 4 and
  8 s with jitter: at most three retries, 30 s a wait and 60 s in all, and
  only while nothing of that call has been shown (no text streamed), so a
  retry never repeats words or runs a tool twice. Stop ends the wait at
  once. The chat shows a quiet "Rate limited by the provider. Retrying in
  4 s…" under the reply, in the failure row's style, until the call goes
  again. Reads next to each other in a step run side by side, four at a
  time; any other call runs alone, after them, in order; rows and results
  stay in call order. Done
  when tests cover retry-after, the caps, no retry after words, Stop
  during the wait, overlap, order, and a failing read leaving the others.
- **Compaction,** stacked on it, by OpenClaw's rules
  (docs.openclaw.ai/concepts/compaction). Before a turn, when the history
  the model would see (summary included) passes 45,000 estimated tokens,
  the older whole turns become one summary, made by one model call with a
  short fixed prompt (names, decisions, open questions, what the person
  asked for, message references with their chat ids and uuids; capped at
  6,000 characters), and the most recent turns within 15,000 tokens stay word
  for word. A cut falls only where the person typed, so a tool call is
  never split from its result. The summary is a `Summary` record linked
  from the conversation and to the turns it covers; the next one is made
  from it and the turns after. The model is sent the summary, then the
  turns after it; every message still shows, with a quiet "Summarised
  earlier conversation" row that opens to the summary. A failed summary
  sends what was sent before (the window keeps what fits) and never stops
  the turn; Clear forgets it. Done when tests cover the trigger, the cut,
  tool pairs, the summary kept and reused after a reopen, the fallback
  and Clear.

**Memory, first slice (experiment, 2026-10-13).** The proposal in
`../agent-brain.md`: strut owns a Ladybug graph and Peel reaches it over
HTTP. strut runs seven custom workspace steps (`memory/remember`, `recall`,
`get`, `ontology`, `forget`, `merge`, `graph`), not yet in strut's repo.
In Peel:

- Six tools. `remember`, `forget_memory` and `merge_memory` have a new
  effect, `write`: they change the person's own data, so they never ask,
  and run alone like an action. Whether an effect asks
  (`Tool.Effect.asks`) and runs beside others (`runsSideBySide`) are
  exhaustive switches, so a new effect does not compile until it decides.
  Peel, not the model, sets a memory's `created_by`. The reads are `recall` (search),
  `read_memory` (one node) and `memory_ontology`. Each is one
  synchronous `POST /steps/memory/<verb>/run`, and its result starts
  with one plain line, the row's summary ("Remembered 'The user's name
  is Tom.', replacing what it knew"), before the step's JSON.
- Forget is a soft delete with a reason: an entity takes its facts, an
  episode the facts that came only from it; Self cannot be forgotten
  whole. Merge moves a duplicate's facts and mentions to the kept
  entity, adds its names as aliases, links it `ALIAS_OF` (its ref_id
  then reads as the kept one), and supersedes repeats and a one-value
  predicate held twice. Nothing is deleted.
- The graph's tables change by an append-only list of migrations, each
  safe to run again (`ALTER TABLE … ADD IF NOT EXISTS`), run on open.
- The vocabulary lives only in strut's `Ontology` table: entity types and
  predicates, each with aliases, a status (`active` or `proposed`) and,
  for a predicate, its cardinality and the types it connects. Peel names
  none. An alias resolves (`full_name` → `name`); a one-value predicate
  supersedes the current fact by itself; anything new is kept as
  `proposed` and reported, never refused.
- Nothing to set up (Tom, 2026-10-13: "the moment you create an
  account, there should be a connection"). strut, started with
  `STRUT_CONNECTION_FILE` naming
  `~/Library/Application Support/strut-memory/connection`, writes
  `{url, key, pid}` there once it is listening (only on 127.0.0.1 with a
  `STRUT_API_KEY`) and removes it when it closes. When an app account
  opens its agent, Peel reads it (`MemoryServer.onThisMac`): opened once
  without following a link, and refused unless it is a plain file of
  this user's no one else may read or write, naming a server on this Mac
  with a key. A file whose strut has stopped is ignored, since its port
  may now be anyone's. A refused file is said in the notice when the
  agent opens; no file means no memory, quietly. Peel reads it again
  before each reply (`AgentSession.willRun`), so a strut started after
  Peel is found and one that stopped is dropped before the key or memory
  text goes to its port. No row in Account and nothing in the Keychain
  (#219's item is removed on each open and with the profile). A
  development profile reads only a file named by the `memoryConnection`
  default (`-memoryConnection <path>`), so a test account never writes
  to the real graph and the offscreen check can still reach a test
  strut; it listens for automations only with an `automationPort` of its
  own, so it never takes the app's port. Anything on the Mac can reach a
  loopback port, so the key is what makes the memory Peel's.
- Decided and left, from the independent review (2026-10-13):
  - **One graph per Mac, for one account** (Tom, 2026-10-13): assume
    one Sphinx account on the Mac, its graph synced to all its clients.
    A graph per account comes with sub-accounts.
  - **Peel does not check that strut answers.** The key proves Peel to
    strut, not strut to Peel. The pid check covers a strut that has
    stopped; a challenge (Peel sends a nonce, strut answers with an HMAC
    under the key) would also cover a process that took the port while
    strut was still running. Left for now (Tom, 2026-10-13); it belongs
    with strut's ready line, when Peel starts strut itself.
  - Only `127.0.0.1` is announced, not `::1` or `localhost`.
  - A pid reused after strut was killed with SIGKILL makes a stale file
    look live; the challenge above is the fix.
  - Nothing on screen says whether memory is on (Tom: no memory UI for
    now); a missing strut shows only as an agent without memory tools.
  - Automations and memory links wait for the first reply after a strut
    starts late; watching the connection file's folder would find it at
    once.
- Memory text goes to strut as the run's `input`, never as config,
  which strut templates (`{{ … }}` would be evaluated).
  Without it the tools are absent.
- Memory shows as the tools' quiet rows (Tom, 2026-10-13: a first side
  panel drawing the whole graph was taken out). Opened, a row reads in
  sentences, not JSON (variation A of three prototyped, Tom, 2026-10-13):
  Remembered lists the facts written, each over the fact it replaced
  (struck through), the entities as chips ("new" when made) and any
  proposed words; Searched memory the results with their types; Read
  memory the node's name and current facts. A memory tool's result
  carries its step JSON for the row (`Tool.Output.kept`, kept on the
  tool call's record); other tools keep only their first line, as their
  results copy chats. A fact or a name opens that one memory beside the
  chat (`MemoryPanel`, `SidePanelSplit` as a thread): read from strut when
  it opens; an entity with what it knows now, a fact with who it is
  about, since when, what it replaced and the words it came from. Its
  facts and names open in its place, with Back; Escape closes it.
  Strut is asked to return a replaced fact's text in `superseded`; a bare
  ref_id reads "An earlier fact". Reviews' findings not applied, with
  why: a fact forgotten later still shows in the row that wrote it (the
  row is a record of what was done, and its first line already held the
  sentence); every kept row loads with the chat (each is capped at 12,000
  characters, and only remember, recall and read_memory keep one);
  `AppModel.agentRowsOpened` is the offscreen driver's alone (a tool-call
  id may repeat across steps, so open rows cannot be keyed by it); a
  fact's link rests in the text's colour, not the link's (quiet rows);
  aliases show as strut keeps them, lowercased; the panel opening
  animates the chat's reflow, as a thread's does.

Done when "Remember: my name is Tom" stores Self and a fact, "call me
Thomas" supersedes it, and a cleared conversation answers "What's my
name?" from memory.

Next for memory, in order (updated 2026-10-13):

Done: the tools (#218); strut's key, the graph's folder owner-only
(#219); connecting with nothing to set up, from strut's connection file,
replacing #219's Keychain item and Account row (strut's side a local
commit beside the memory steps); `@ladybugdb/core`
proposed to strut as an optional dependency (stakwork/strut#154, Evan's
call). In the product, Sphinx or Peel starts strut and reads its address
and key from strut's ready line (`STRUT_READY_KEY`), as Sphinx Mac does
with its bundled strut.

1. **Next up: one tool builder for the app and the CLI.** The tools and system
   prompt are put together twice (`AppModel+Agent`, `peel`'s
   `Commands+Agent`); one PeelAgent builder taking storage, an optional
   engine and an optional `MemoryServer` gives `peel agent` memory
   (`--memory`), so memory can be tried and tested from the terminal.
2. **Encrypted backup.** The memes server holds one preferences file per
   account and no other named files (stakwork/sphinx-meme router.go), so:
   strut's `memory/export` makes a snapshot; Peel encrypts it with
   `MediaCrypto` (RNCryptor, as the preferences file) under a key derived
   by HKDF from the node secret for this use only; uploads it with
   `POST /file` under a fixed, unsearchable file name; a new device
   finds the newest in its own `GET /mymedia` and restores with
   `memory/import`. Daily while Peel runs, with no button until memory
   has a place on screen. Old copies pile up until the server can overwrite a
   personal file in place.
3. **Memory quality.** Fuzzy name matching and embeddings (MiniLM through
   strut's onnxruntime) for duplicates and recall; Ladybug's full-text and
   vector indexes instead of the word scan; a strut job that draws facts
   from conversation episodes after the fact, so the front agent only
   saves what is said explicitly; janitors for duplicates, proposed
   vocabulary, contradictions and summaries; restore after forget.
4. **Later.** Readable memory rows that open one memory (a session is on
   it); caching the ontology instead of a call per conversation; the
   agent's procedures as concepts it walks to (Glimmer) rather than a
   longer prompt; the memory steps in a place other swarms can learn from
   (today Tom's local commits, `exp/ladybug-memory`); the Ladybug backend
   behind strut's `GraphBackend`, so `StrutJob` and the `graph/*` steps
   share the memory's graph.

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

**PR 5, the Agent chat (2026-10-12).**
- Done: a "Peel" row first in Direct messages (the logo on a rounded
  square; "Set up" in link blue until a model is connected, then AGENT;
  bold with a count for replies that came while it was not open). The chat
  opens on Peel's first message with a Connect card (option 1A). Connect
  opens beside its button (provider, API key with Paste and "Get a key"
  in the web pane, model with a recommended default), one small test call
  with the spinner in Connect, failures in `ModelError`'s words under the
  key. Replies stream in as Markdown, Send turns into Stop (Escape too),
  a stopped reply keeps its words marked Stopped, tool rows are quiet
  lines ("Read unseen messages · Unseen messages in 6 chats · 0.1 s")
  that open to what was asked and answered, failures are a row with
  Retry (Connect with no model, Replace key for a refused one). The
  agent's `[View](https://peel.invalid/message?chat=…&uuid=…)` links open
  the message as a jump from a quote does (`AgentMessageLink`, in
  PeelAgent). Account › Peel agent: name, provider (Change), the key's
  last four (Replace, Remove confirmed in place), model, Clear
  conversation. The model talks to `current_time` and PR 4's five read
  tools over the open account.
- Where it lives: `AgentSession` (AgentKit, `@MainActor @Observable`)
  holds the conversation, the reply streaming now, the failure, the
  connection (no key) and the actions (`send`, `stop`, `retry`,
  `connect`, `setModel`, `removeKey`, `clear`, `rename`, `close`); views
  only render it. The conversation is `Conversation`, `Turn` and
  `ToolCall` records in `agent.sqlite` beside `peel.sqlite` (each tool
  call is its own record with the reply that made it as `source`, the
  item PR 4 left for this one). The key lives with its provider and model
  as one Keychain item per profile (`dev.peel.agent`, this device only),
  read for each turn; a development profile keeps it in an owner-only
  file beside its words. The words' Keychain code and the key's share
  `KeychainItem` now.
- Checked: `AgentSessionTests` (20) with a scripted provider, the full
  suite once, and the whole flow offscreen on a development profile with
  unread chats against a local stub of the Messages API (set up, a bad
  key, connect, a streamed reply, `current_time`, `read_unseen_messages`
  and its View, Stop, a 529 and Retry, Account, Remove key, then no key).
  Idle on the chat: 0% CPU.
- Learned: offscreen, Peel is never active, so a panel never becomes key
  and its field never takes the keyboard; the driver now hands a visible
  panel its keys itself, and a drive Tabs into the field. The model's
  words after a tool ran need a paragraph break, or "Let me look." and the
  answer run together. What the model sees after a turn is what a
  relaunch rebuilds (each message and the words that answered it); tool
  results are not kept, being copies of chats Peel stores, so a reply
  that needs one names it (the View link carries the ids).
- Reviews: /code-review found tool rows reloading out of order, a
  half-done Clear able to bring a chat back, repeated call ids across
  steps, a Keychain read error taken for no key, a reply finishing after
  the account closed saved into it, the row hidden while collapsed with
  a reply waiting; all fixed. /simplify (four passes): `ComposerID.agent`
  in place of a sentinel chat id and the composer's own send path, the
  streaming reply drawn by a view of its own with deltas shown every 50
  ms, one rule for the driver's panel, `Avatar.outline`, `rowChrome`,
  `Callout`, `Card`, `Badge`, `PeelError.problem`, `Duration` arithmetic,
  the message link moved to PeelAgent. /security-review: nothing at
  confidence 8 or more (the key's path, the Keychain refactor, the file,
  the links checked). Independent review: steps' text run together,
  history differing after a relaunch, Cancel during the test call still
  keeping the key (and a connect finishing after the account closed), a
  finished reply pulling the list down, flushes cancelling each other, a
  failed save giving replies one id, an empty reply left unanswered, the
  intro promising sends, the driver's panel rule taking the call window,
  keys typed into an agent chat that failed to open, the row missing from
  search; all fixed. It found no regression in the words' Keychain code.
- Not applied, with reasons: paging and batched writes for a very long
  conversation (load, save and Clear are one SQLite read or write per
  record, fine at today's sizes; the store needs a batch API first);
  `FileSecretStore` on `FileItem` (the mnemonic's write path, kept as it
  is in this PR); a typed notice and unread state out of AgentKit (one
  front end today); `AgentRow` sharing `RunHeader` (that header is built
  around `ChatRow`); a generic `NameRow`; `DetailHeader` taking any title
  accessory (one use); the agent row inside `ChatSections`. Clear forgets
  the records, but the event log keeps their add events, as every forget
  does (`../agent-architecture.md`, "nothing is hard-deleted"); the
  Account line says it clears the chat on this Mac. The OpenAI and
  OpenRouter model ids are a best guess (unverified without keys); a
  wrong one shows the provider's refusal at Connect.

**PR 6, the approval gate and the send tool (2026-10-12).**
- Done: a gate for every tool that acts, in AgentKit. A tool plans first
  (`Tool.Plan`): an answer for the model at once, or an action with a
  `ToolIntent` (what will happen in plain words, the exact content, the
  details, the cost, the target an "always" would cover) and the work,
  run only once allowed, so what runs is what was shown. A tool with only
  a handler is asked by its name and arguments. The loop asks its
  `ToolApprover` before every action and waits; with none, the call is
  refused. `ApprovalGate` (shared by the app and the CLI) allows by a
  remembered rule or asks the person: Allow once, Always allow (per tool
  and target, kept as `ApprovalRule` records in `agent.sqlite`, listed
  and revoked in Account › Peel agent), Deny ("The user declined: …" to
  the model). An action that costs anything, or names no target, is
  asked every time. Stop, Clear and close take a waiting card down as
  stopped. `send_sphinx_message(chat, text, thread_uuid?,
  reply_to_uuid?)` in PeelAgent resolves the chat with the read tools'
  resolver (ambiguity lists the candidates), checks the thread and reply
  with the engine's own `checkLinks`, words the card with the tribe's
  price ("Costs 3 sats, the minimum. Paid from your balance."), and sends
  through the composer's `Engine.sendText`, with `priceAtMost` the price
  on the card (a tribe whose price rose is refused, `tribePriceRose`; a
  contact sends with a cap of 0). Text with control characters or
  anything that draws nothing (default-ignorable code points; the joiner
  and emoji selector only after an emoji) is refused, so nothing rides
  along unseen. The row: "Send to Kate · Allowed once · Sent to 'Kate' ·
  0.4 s · View", View through the agent's message link. The card sits
  where the row will be (`Callout` in attention, `Card` for the text,
  `PeelButton`s), takes the keys from an empty composer (Return Allow
  once, Escape Deny; a paid send needs a click), gives them back once
  answered; the sidebar row says "Waiting on you" in orange. `peel
  --profile <dev> agent --send` connects and asks in the terminal (y,
  a for always, n), control characters written out, typed-ahead lines
  dropped before each question.
- Checked: `ApprovalTests` (the loop with a scripted approver: allow,
  deny, no approver, reads never ask, an answer without action, a
  handler-only tool, Stop while waiting; the gate: once, always per
  target, a cost never remembered, a tool with no target, across a
  reopen, revoke, what shows whole; the session: the card, deny, Stop,
  always across a reopen then revoke, Clear and close while waiting),
  `SendToolTests` (a real engine on a connection that takes every
  write: the card's words, a send and its link, the tribe price and its
  cap, threads and replies, ids from another chat, ambiguity, hidden
  characters, the link only at the end of a row's line). In the app
  offscreen on a development profile against the local stack and a stub
  of the Messages API: the card, Return sends (the message in Kate's
  chat), Always skips the card next time, Account lists and revokes the
  rule, the card again, Escape denies and the model is told. The CLI
  against the same stub: once, no, always, then no question.
- Reviews: /code-review found Return on a focused Deny allowing, the card
  taking a Return meant for a typed message, a planted "(chat= uuid=)" in
  a name redirecting View, thread and reply checked only in part,
  format characters, a stale run writing on a new reply, the CLI's
  cancel resuming a newer wait, rules failing to load hiding the chat,
  the CLI connecting before checking its key; all fixed. /simplify: the
  refusal words out of the loop (`ApprovalOutcome.refusal`), every
  `.action` asked (no effect check twice), `ToolIntent.lines` and
  `alwaysLabel`, `TribePrice.described`, the price cap in `deliver`,
  `SQLiteAgentStore.open(for:storage:)` shared by app and CLI.
  /security-review: invisible characters (variation selectors, fillers,
  a joiner between letters) carrying data past the card; fixed.
  Independent review: a tribe with no price yet offered "always" and no
  cap, typed-ahead CLI answers, Return paying, the card off screen, an
  allowed-then-stopped row saying allowed, a failed "always" silent, a
  generic tool's "always" covering any arguments; all fixed.
- Not applied, with reasons: the send's link as data on the tool's
  result rather than parsed from its summary (it changes `LoopEvent` and
  `Tool.Output`, which the loop-hardening branch is changing; the summary
  cap went from 120 to 240 characters so the ids fit, and the parse only
  takes fixed-length hex ids at the end of the line); one piece of state
  for "a card waits" in place of `waiting` and the row's approval (both
  are set on the main actor in one place); two contacts of one name show
  alike on a card (the target id is the chat's, so a rule never covers
  the other); a test for a tribe the engine does not hold (the fixture
  cannot make one; the plan refuses it).
- Learned: the provisioning profile had under two days left, which
  `sign-app.sh` refuses, so the offscreen checks ran with the threshold
  lowered to one day in the worktree, not committed; Tom's weekly
  `scripts/run-app.sh` renews it.

**Hardening A, retry and concurrent reads (2026-10-12).**
- Done: `RetryPolicy` and `AgentLoop.call`: a retryable model failure
  (`ModelError.isRetryable`: 429, 5xx, a dropped connection, 408) with no
  text shown yet is made again: after the provider's `retry-after`, else
  2, 4 and 8 s halved at random by up to half; at most three retries, no
  wait over 30 s and none that would take the call past 60 s from its
  first try. The tool calls of a failed reply were never run, so they go
  with it; a later step is retried with the earlier steps' results, which
  never runs a tool twice. `LoopEvent.retrying(after:_:)` says how long it
  waits, then `.zero` as it goes; `AgentSession.retrying` holds it and the
  chat shows "Rate limited by the provider. Retrying in 4 s…" under the
  reply (`RetryPolicy.note`, which the CLI prints too), a `Callout` with
  the spinner, laid out as the failure row (`agentNoteRow`). Stop cancels
  the wait at once. `ModelError.reason` is a failure without its "Try
  again" advice. `runTools`: reads next to each other run side by side in
  a task group, four at a time, each row opened as it starts; any other
  call runs alone after the reads before it, so a read after a send sees
  it. Results keep call order; a failing read is just its own error.
- With the gate (#210, rebased onto it): an action runs alone after the
  reads before it, its approval included, so nothing runs while its card
  waits and the reads after it start only once it is answered and done;
  a declined action leaves the reads around it as they were. A `.read`
  tool that plans an action is refused rather than run side by side.
  /code-review of the resolution: a failure after an allowed action threw
  the reply away and offered Retry, which could send again (the reply is
  now kept with what ran, ending "The provider failed after this ran",
  no Retry); OpenAI's 429 `insufficient_quota` was retried as a rate
  limit (now a refused request); a call with no tool split a run of
  reads (it now goes with them); tests made stricter (the reads after an
  action proven side by side, nothing started while a card waits, Stop
  while a card waits leaves the reads after it unrun). Not applied: a
  `Tool` type that cannot plan an action for a read (a change to #210's
  API; the loop refuses it instead).
- Checked: `swift test` in full; `AgentLoopHardeningTests` (retry-after
  kept, the caps, no retry once words were shown, a refused key not
  retried, a later step retried without its tools again, Stop in the wait,
  overlap proven by tools that wait for each other, the cap of four, a
  failing read, sends as barriers in order, Stop during reads) and two
  `AgentSessionTests` (the note shown then cleared, Stop during it).
  `peel --profile <dev> agent` against a local stub of the Messages API:
  a real 429 with `retry-after: 4` was waited and retried, and its three
  read tools opened in call order and closed as each finished. The app
  was not checked offscreen: `scripts/check-app.sh` stops at signing (the
  Personal Team profile has under two days left and Xcode could not
  fetch a new one; Xcode › Settings › Accounts needs the Apple ID).
- Reviews: /code-review found reads run ahead of an earlier send (now a
  barrier), the note redrawing the reply on every token, the note staying
  up through the retried call (now "Retrying…" once it goes), the total
  cap counting only waits (now time since the first try), queued reads
  shown as running (each now opens as it starts), the wording kept three
  times (now `ModelError.reason` and `RetryPolicy.note`) and timing-based
  tests (now tools that wait for each other); all fixed. /simplify: one
  task-group path for reads and sends, each call's tool looked up once,
  the retry note its own view, `sleep` internal, the test recorders in
  `TestSupport`. /security-review: nothing at confidence 8; a non-finite
  `retry-after` that would have crashed is now not waited.
- Not applied, with reasons: `retry-after` on a 503 or 529 (only 429
  carries it in `ModelError`; adding it changes a case fourteen places
  match, and the model clients take fixes only); a duration shared with
  the tool rows' "0.3 s" (a countdown reads in whole seconds); a session
  init that configures its loop (one knob, `retryPolicy`, for tests);
  the tool rows' inset shared with `agentNoteRow` (existing code).

**Hardening B, compaction (2026-10-12).**
- Done: `Compaction` (AgentKit `Loop/`): `isDue` (history the model
  would see, summary included, over 45,000 estimated tokens), `split`
  (how many whole turns to summarise so the newest within 15,000 stay
  word for word; the latest always stays; whole turns only, so a tool
  call never leaves its result), the fixed summarising prompt and one
  call (no tools, 1,500 tokens out, not retried: the turn after it
  retries as always). The request is the summary so far plus the newer
  turns, the newest 40,000 tokens of them, each message at most 4,000
  characters; a summary over 6,000 characters, or cut off by its token
  limit, is cut at a line. `AgentSession` runs it before a turn, never
  mid-reply; keeps it as a `Summary` record (`through`, the last turn it
  covers) linked to each turn it newly covers and the summary it
  replaces, then from the conversation, last, so a relaunch never finds
  one half written; loads the one reaching furthest; Clear forgets them
  all. `AgentLoop.summary` is sent as the first exchange, in the
  person's turn, marked as notes that retell other people's messages and
  are never instructions, then the turns after it through the window as
  before (the window stays the fallback). A failed or unsaved summary
  sends what was sent before and is not tried again for three exchanges.
  The chat shows "Summarised earlier conversation" under the last turn
  it covers, opening to the summary (`AgentDisclosureRow`, which the tool
  rows now use too, builds its detail only while open).
- With the gate (#210, rebased onto it and on hardening A): what each
  reply's actions came to now opens the reply the model is sent ("(Peel's
  actions this turn, as the app recorded them:)", then "- Send to Kate:
  declined by the person, not done"; stopped, failed and done alike),
  ahead of its words, so no message cut reaches it and a reply with no
  words but an action still counts. The summariser reads the same, and
  its prompt says only that opening record tells how an action came out
  and that one declined, stopped or failed is settled as not done: a
  summary never turns a "no" into a task the model would retry. Tool
  rows and their approval answers are records of their own, which
  compaction never touches. /code-review of the resolution found the
  record appended after the words (cut by the 4,000-character limit),
  replies with no words dropped with their outcome, a failed allowed
  send recorded as done, the record reaching only the summariser, a
  test that checked a constant, and a tool row closing when its card
  came and went (the row keeps `open` again); all fixed. Not applied:
  one outcome wording shared with `ApprovalOutcome.refusal` (that one is
  the tool result's sentence, this a line of a record).
- Checked: `swift test` in full; `CompactionTests` (the trigger, the cut,
  a tool turn kept whole, the request and its caps, a summary made before
  the turn and kept, its links, reused after a reopen, a second summary
  built on the first, a failed summary and no retry the next turn, Clear).
  The app was not checked offscreen: `scripts/check-app.sh` stops at
  signing, as for hardening A.
- Reviews: /code-review found a failed summary retried before every turn
  (now three exchanges later), a request larger than any turn (now
  40,000 tokens), unknown finish reasons refused, an over-long message
  dropping everything older, a cut summary splitting a reference, the
  split counting messages by twos (now whole turns) and a dead
  `history(of:)`; all fixed. /simplify: an `Exchange` alias, `compact`
  returning the summary it made, the covered turns from `unsummarised`,
  `Summary.init(record:)`, one gate (`nextCompaction`), the dead
  `turns(of:)` removed, the disclosure's detail built lazily.
  /security-review: nothing at confidence 8 (keys never reach the
  request; the summary is plain `Text`; Clear forgets it). Risk raised to
  high (writes to the agent store; other people's words re-enter the
  context): the independent review found the summary call retrying on
  top of the turn's own retries, an unsaved summary made again each turn
  and a half-written record, "which you wrote" lending the notes the
  person's word, "what Peel said it would do" keeping injected promises,
  ties on load, a summary cut by its token limit kept whole, and no test
  of a second summary; all fixed.
- Not applied, with reasons: summarising turns older than the 40,000
  read in further passes (the window dropped them before; the model sees
  as much as it did); thresholds derived from `historyBudget` (one place
  sets each, beside it); a single-call API beside `AgentLoop` (the loop
  with no tools and one step is that call); compaction in the CLI (it
  keeps no records); batched store writes (the store has no batch API;
  see PR 5); compacting after a reply rather than before a turn (the
  brief says before a turn); the test helpers shared with
  `AgentSessionTests` (separate suites, small).

**Agent tests: audit, journeys and live checks (2026-10-12).**
- Audit, by the test-audit skill, of the 169 agent tests: 161 retained;
  2 fixed, being vacuous (the failure after an allowed send now scripts a
  Retry that would really send twice under an "always" rule; the tribe
  price cap is now proven through the send tool, not by calling the
  engine around it, with the price raised by `saveRecords` while the
  card waits); 6 folded into the tests that already owned them (Stop
  during a tool, Stop while a card waits, streaming and Stop, tool rows,
  the send row's link moved to `AgentMessageLinkTests`). The shared
  fixtures moved to `AgentKitTests/TestSupport`. The `Fixtures/` streams
  were written by hand from the providers' docs, never recorded; they
  now say so.
- Gaps filled: `AgentJourneys` (the read tools over a real account; a
  send allowed once, then denied; a paid tribe send costing exactly the
  card's price, and refused when the price rises while the card waits),
  with the model scripted and the rest real; `LiveProviderTests`, opt-in
  checks against the real providers (a streamed reply, a tool round trip
  and a bad key per provider), since replaced by recorded streams (below).
- Found by the journey and fixed: a send the engine refused reached the
  model and the row as "The operation couldn't be completed.
  (PeelCore.Engine.Failure error 6.)". `SendTool` now words a refusal
  "Not sent to 'X'. <the engine's words> Ask the user before trying
  again." and any other error as "may or may not have gone; check the
  chat"; a sent message whose row cannot be read back is still "Sent".
- Regression proofs (fix reverted, test run, restored): unlink (three
  `ApplyTests` fail), the double send after an allowed send (fails,
  sending twice), the declined action through compaction (fails),
  the tool's price cap (the unit test and the tribe journey fail).
- Reviews: /code-review, /simplify (four lanes), /security-review
  (nothing at confidence 8) and an independent review (risk raised to
  high: the send path moves money); their findings applied.
- Follow-ups: "Return on a focused Deny allowed the send" is not proven
  by a test: the fix is SwiftUI focus in `AgentViews`, PeelApp has no
  test target, and focusing Deny offscreen needs Full Keyboard Access, a
  system setting agents may not change; Tom checks it by hand, or an app
  check once keyboard navigation is on. `Engine.Failure` (and
  `MediaCrypto.Failure`) as `LocalizedError`, the deeper fix for "error
  6" wherever `localizedDescription` is used. One agent tool list and
  prompt in PeelAgent, shared by the app, the CLI and the journeys
  (today each builds its own).

**Tests: no real keys; recorded streams (2026-10-13).** Tom decided no
test may call a model provider or use a real API key, even opt-in: a key
in a test's environment is a key an agent can be handed, and a suite that
reaches the network is one a plain run can reach it with by mistake.
`LiveProviderTests` is deleted. In its place `scripts/record-agent-fixtures.sh`,
run by hand by Tom with his own key, records one provider's streamed text
reply and tool call into `Fixtures/recorded/` (response bodies only, ids
scrubbed, nothing written if the key or an `sk-` token is in it), and
`StreamCaseTests` decodes each provider's stream from there, or the
hand-written one until there is a recording (a reply in several pieces,
its usage, a tool call with arguments). The bad key per provider is now a
stubbed `ProviderTests` case, against bodies written from the docs, not
the providers' own. What no test proves any more: that a real provider
accepts Peel's request bodies, above all the second step of a tool loop
(tool results, replayed thinking, assistant tool calls); the request
bodies are pinned only by `ProviderTests`' own expectations. The
recorder's requests are written by hand to match the providers' bodies
and must be kept in step with them. No streams are recorded yet.

## Capabilities against agent SDKs

Checked against the code on 2026-10-12, and compared with Vercel's AI SDK,
the Claude Agent SDK and Claude Code, OpenAI's Agents SDK, LangGraph and
Mastra. Have = built, Partial = some of it, Missing = not built.

| Area | Capability | State | Notes |
|---|---|---|---|
| Model | Providers behind one interface | Have | Anthropic; OpenAI-compatible (OpenAI, OpenRouter) |
| | Streaming text and tool calls, Stop | Have | |
| | Typed errors in plain words | Have | Bad key, rate limit, outage, network |
| | Prompt caching | Have | Anthropic's cache on the whole request |
| | Automatic retry with backoff | Have | Retry-after, else 2-4-8 s with jitter; three retries, only before anything is shown; manual Retry after |
| | Extended thinking | Partial | Blocks parsed and kept; never requested |
| | Usage and cost | Partial | Tokens counted; no cost, nothing shown |
| | Structured output | Missing | |
| | Images and files | Missing | |
| | Model lists from the provider | Missing | Hard-coded; OpenAI and OpenRouter names unverified |
| Loop | Model and tool steps, step cap | Have | Cap 10 |
| | Context window | Have | A summary of older turns, then the recent turns that fit a budget |
| | Compaction | Have | Older turns summarised into a Summary record past 45,000 tokens; the window is the fallback |
| | Tools run concurrently | Have | Reads next to each other, four at a time; any other call alone, in order, each through the approver |
| | Per-step and lifecycle hooks | Missing | |
| | Guardrails on input and output | Missing | |
| Tools | Registry with schemas and an effect (read, send) | Have | |
| | Caps and untrusted-text markers on tool output | Have | |
| | Sphinx read tools | Have | Five, PR 4 |
| | Approval gate | Have | PR 6: once, always per tool and chat, deny; a cost always asks; Account revokes |
| | Sphinx send and pay | Partial | Send (PR 6), price capped at the card's; pay missing |
| | Connectors (MCP) | Missing | Use the official MCP Swift SDK, not our own |
| | Calendar | Missing | EventKit, read only first |
| | Web search | Missing | |
| State | Persistent conversation, tool calls recorded | Have | `agent.sqlite` |
| | Event log; tables rebuildable from it | Have | |
| | Long-term memory | Missing | The graph |
| | Search by meaning (embeddings) | Missing | Keyword search only |
| | Instruction memory (a rules file) | Missing | |
| | Resume or branch a conversation | Missing | One timeline |
| Agents | Subagents, handoffs, skills | Missing | |
| Running | On the device | Have | |
| | Durable runs, always-on, scheduled, proactive | Missing | Needs a server |
| Observability | Tracing per step | Partial | Tool rows show durations; nothing exported |
| | Evals of agent behaviour | Missing | Unit tests with fake providers only |
| UI | Streamed loop events; View links into the app | Have | |

**Own versus rent** (Tom, 2026-10-12: avoid rebuilding what packages
already maintain). Peel owns what is Peel's: the Sphinx tools, the
session and UI, the event log and sync, and small pieces tied to our
storage and UI (compaction, the approval gate). Peel rents what is the
providers': the model clients (structured output, images, thinking, retry,
model lists, provider tools) and MCP. Until a spike settles the
replacement, the model clients get fixes only, no new features. The
candidates: Apple's Foundation Models with Anthropic's Claude provider
(needs macOS and iOS 27), and Hugging Face's AnyLanguageModel (macOS 14
and up), each behind `ModelProvider`.

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
