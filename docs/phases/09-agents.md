# Phase 9 — The personal agent: one agent contact, workers over ACP, graph memory

Status: planned. Refreshed 2026-10-08 to the one-agent-contact model in
`../agent-architecture.md`, which is the source of truth for the design;
this file is the build plan. It replaces PR #15's version of this file
("an agent is a contact; the harness is a setting") and the older
`09-local-tools.md`. The harnesses were tried on 2026-10-07,
`../research/acp-harnesses.md`, cited below by section.

In the order set on 2026-10-08 (`../PLAN.md`), this phase comes after the
cleanup, the polish pass and Markdown in messages, and before the rest of
phase 10.

## What changed from PR #15

- **One agent contact.** Tom has one agent. Claude Code, Codex, goose and
  others are workers that the agent starts for a bound thread. They are not
  contacts, have no Sphinx account and no "Add agent" flow each. The
  harness registry stays, as the list of workers the host can start.
- **The host is its own process.** `peel-agent serve` runs on the
  always-on machine under `launchd`. PR #15's Wave B ran the host inside
  the app from the owner's PIN; that is dropped. The app only sends and
  reads messages, as `../agent-native.md` requires.
- **Not every thread is a worker session.** A plain thread goes to the
  agent's own loop (model plus tools). Only a bound thread goes to a
  worker. PR #15 gave every thread a session and top-level DMs a "main
  session".
- **New work:** the agent loop, threads in DMs, the LadybugDB graph, Strut
  jobs and mandates.
- **No Buzz fork.** PR #15 added a line to `agent-native.md` naming a fork
  of `buzz-acp` as the first candidate engine, which its own research
  (section 8) argues against. The line is not carried over.

## Idea

The agent is a Sphinx account on the agent host, a contact in Tom's list
like a person, with the AGENT label. It owns the memory, the permissions
and the budget. Tom talks to it by DM, in threads. In a plain thread it
answers with its own model and tools, or starts a Strut job. In a bound
thread it passes Tom's messages to a worker over the Agent Client Protocol
and stands between the worker and Tom for every permission.

Peel writes one ACP client for every worker. ACP is JSON-RPC over stdio,
published by Zed in August 2025, community-governed with JetBrains as
co-maintainer, with a public registry of more than forty agents. Block's
Buzz (`block/buzz`, July 2026) connects agents the same way; the rules of
its harness in `crates/buzz-acp` are the reference for the host loop, not
its code, which is Nostr-typed and auto-approves permissions. Research 8.

## Shape

The diagram and the components are in `../agent-architecture.md`, "The
shape". In this phase's terms:

```
 Tom (Peel or official app) ──Sphinx DM, thread T──▶ peel-agent (host)
                                                        │ gate
                                   ┌────────────────────┴───────────────┐
                                   │ T unbound                          │ T bound
                                   ▼                                    ▼
                         agent loop: model + tools            ACP session, granted folder
                         graph · Strut jobs · MCP             claude-agent-acp · codex-acp ·
                                                              goose acp · custom
```

- **Agent record.** The agent's Sphinx profile (from an invite until child
  derivation lands), the owner pubkey, the model setting, worker grants.
- **Worker registry.** Built-in definitions for Claude Code, Codex, goose
  and buzz-agent, each with its adapter version pinned. A custom worker is
  one JSON file: id, label, command, args, env, install hint. The host
  probes PATH and reports a missing worker with its install hint.
- **ACP client, in Swift.** Spawns the worker; `initialize` at protocol
  version 1; `session/new` with the working directory and the MCP servers
  the grant allows; `session/set_mode` and the model before the first
  prompt; `session/prompt`; reads `session/update`; answers
  `session/request_permission` through the gate; `session/cancel`;
  `session/load` to resume.
- **Host loop.** Buzz's rules: owner-only author gate; one prompt in
  flight per thread with a queue behind it; an idle timeout and a maximum
  turn length; replay of messages that arrived while the host was offline,
  which the server queues anyway; respawn on crash. A thread binding maps a
  thread uuid to one worker session.
- **What Tom sees.** Replies in threads, in Markdown. In a bound thread:
  progress lines, collapsed; ask cards with the options the worker offers
  (for Claude Code allow once, allow for the session, reject); result
  cards. The thread header shows the worker, folder, mode, running or idle,
  Stop and Unbind.

## Message shapes

- A task is plain text in the DM. The agent replies in a thread rooted at
  Tom's message; replies in that thread continue it.
- Typed messages (`ask`, `answer`, `progress`, `result`, `bind`, `unbind`,
  `status`, `mandate`, `revoke`) are versioned JSON in the message's
  `metadata` field, a string the core carries (`sphinx/src/msg/mod.rs`).
  The official Mac app already uses it: it sends a JSON object with a `tz`
  key and, on receipt, parses the object and reads only `tz`, ignoring
  other keys (`SphinxOnionManager+ChatExtension.swift`, checked 2026-10-07).
  So `metadata` stays a JSON object, Peel's payload sits under one key,
  `peel`, and the parser tolerates objects without it.
- `content` holds the readable fallback, with numbered options for an ask,
  so the official app shows it as text and a plain `1`, `2`, `3`, `yes` or
  `no` still counts. An answer counts only when its signature recovers the
  owner's pubkey and it names a pending ask. The message uuid is the
  idempotency key.
- Results are Markdown text; large outputs travel as encrypted attachments.

## What it rests on

- The core recovers each message's sender from its signature, so a task is
  bound to exactly one account (verified during phase 2).
- Messages already carry `threadUuid` in DMs, as the official Mac app sends
  it (`03-chat.md`, "Conventions").
- Replay protection already exists: the unique time on every core call and
  the message uuid the store deduplicates on.
- The engine's `checkPayment` already gates every send of sats.

## The gate lives in the host, outside the model and outside the worker

This is remote execution of a machine by a chat identity, so the
permission model is the design; the ACP client is the easy part.

- Only the owner's messages reach the loop or a worker. Never "any
  contact", and never Tom's root identity acting as the agent.
- Grants per worker: folders and mode. The host puts every worker in its
  conservative mode before the first prompt; Codex defaults to `agent`, so
  it is set to `read-only`, research 3. Automatic approval is allowed only
  inside a grant's rules (by default, reads in a granted folder), and the
  host never passes "skip permissions".
- Permission requests the rules do not cover reach Tom, in Peel or the
  official app. "Allow for the session" never outlives the grant.
- Payments pass `checkPayment` and then a mandate check: signed by Tom,
  capped, with an expiry, revocable by message. No mandate, no payment
  without an ask.
- Every task, answer, payment and result is in the conversation and the
  audit log.
- Revoking a grant cancels its sessions and drops its queue.

## Decisions from the research

- Own ACP client over Foundation `Process`, Swift 6 strict concurrency: the
  surface is small and the one maintained Swift 6 package brings five
  dependencies and a daemon. Research 6.
- Protocol version 1, pinned; 2 is a draft, all adapters answered 1. Research 5.
- Adapters pinned in the command, `claude-agent-acp@0.87.0` and
  `codex-acp@2.1.1` via `npx -y`; unpinned `npx` served a stale 0.49.0.
  Research 1, 3.
- Subscription logins for both workers, no API keys. Research 1, 3.
- `session/set_mode read-only` before Codex's first prompt; for Claude the
  model set explicitly and an own config home, or every turn carries Tom's
  40k-token setup. Research 1, 3.
- Host state in `agent.sqlite` beside `peel.sqlite` in the agent's profile
  directory, owned by `PeelAgent` with its own migrator. It is not core
  state and never shares a transaction with a core commit. The graph is a
  separate LadybugDB file (`../agent-architecture.md`, decision 6).
- Child accounts later, invites now: a child of a registered root
  registers free with no invite at zero balance; a fresh root needs an
  invite. Research 9.
- No buzz-acp fork: its rules and defaults, not its code. Research 8.

## Build plan

One branch and one PR per task through the chain in `AGENTS.md`: `swift
build`, the task's own check, `/code-review`, `/simplify`,
`/security-review`, then this file. The security review looks hardest at
tasks 2, 6, 7, 8 and 20: the process environment, no skip-permissions
flag, the owner gate, the answer gate, the mandate check. No two sessions
edit the same file. `$S` is the session scratchpad. Development profiles
and the local test stack only; the agent never runs on `default`.

### Wave A: the agent host and workers

Touches nothing that exists under `Sources/`, so it cannot conflict with
work in the app.

1. **Targets.** `PeelAgent` library on `PeelCore` and GRDB, `peel-agent`
   executable, `PeelAgentTests`, a placeholder file each. Files:
   `Package.swift`, `Sources/PeelAgent/PeelAgent.swift`,
   `Sources/peel-agent/AgentCommand.swift`,
   `Tests/PeelAgentTests/PeelAgentTests.swift`. Merges first and alone.
   Verify: `swift build && swift test --filter PeelAgentTests`. An hour.
2. **ACP client.** Spawn, `initialize` at version 1, `newSession`,
   `loadSession`, `setMode`, `setConfigOption`, `prompt` as a stream ending
   in the stop reason, `cancel`, `answer`; `-32601` to `fs/*` and
   `terminal/*`; `_meta` and `_`-prefixed notifications ignored; bounded line
   length. Files under `Sources/PeelAgent/ACP/`: `JSONRPC.swift`,
   `ACPTypes.swift`, `ACPConnection.swift`, `ACPClient.swift`. Needs 1.
   Verify: task 4, then task 6's `run`. One to two days.
3. **Fake worker.** `Tests/PeelAgentTests/Fixtures/fake-agent.py`, stdlib
   only, a script per prompt word: `pong`, `ask` with Claude Code's three
   options and a numeric id, `slow` until `cancel`, `fs` expecting `-32601`,
   `junk` with `_meta` and `_` notifications, `crash` mid-turn. Needs
   nothing. Verify: `python3 Tests/PeelAgentTests/Fixtures/fake-agent.py --self-test`.
   Half a day.
4. **Client tests.** `Tests/PeelAgentTests/ACPClientTests.swift` on the
   fake worker: handshake, update order, permission round trip, cancel,
   `-32601`, junk, an oversized line, a crash surfacing as an error with
   the process reaped. `ACPHandshakeTests.swift` on `goose acp` when on
   PATH, else skipped; research 4. Needs 2, 3. Verify: `swift test --filter
   PeelAgentTests`. A day.
5. **Worker registry and probe.** Built-ins claude, codex, goose: id,
   label, command, args, env, install hint, modes conservative first,
   config home policy. The probe checks PATH, the `node` version since the
   Claude adapter wants 22 and this Mac has 20, and after task 2 an
   `initialize` within 15 s. Files: `Sources/PeelAgent/Harness/Harness.swift`,
   `HarnessRegistry.swift`, `HarnessProbe.swift`,
   `Tests/PeelAgentTests/HarnessTests.swift`. Needs 1. Verify: the tests;
   `peel-agent workers` prints found or the install hint. Half a day.
6. **`peel-agent` executable.** Development profiles only, never
   `default`. `workers`; `probe <worker>`; `run <worker> --cwd <dir>
   [--mode m] [--model id] <prompt>` printing updates and reading an ask's
   answer from stdin; `serve --profile <dev> --owner <pubkey> [--server
   host:port]` running task 7, with workers and folders granted by
   `grant <worker> --folder <dir> --mode <mode>`; `--command` points either
   at the fake worker. Files: `Sources/peel-agent/AgentCommand.swift`,
   `Arguments.swift`, its own parser. Needs 2 and 5 for `run`, 7 for
   `serve`. Verify: `.build/debug/peel-agent run claude --cwd $S/cwd "Reply
   with the single word pong."` prints pong; with "Create a file named
   hello.txt containing hi" it shows the ask, `3` rejects, `ls $S/cwd`
   stays empty. A day.
7. **Host loop, router, state and gate.** One actor: `Account.load`,
   consume `engine.events`; the gate (`chat` is the owner, `fromMe` is
   false, type is text, uuid unseen); the router (a thread with a binding
   goes to its worker session, anything else to the agent loop); one
   prompt in flight per thread with a queue behind it; idle 1,500 s and max
   turn 7,200 s as Buzz defaults them; respawn on crash with
   `session/load`; replies through `sendText(_:to:replyTo:inThread:)`.
   Tables: `agent`, `grant`, `binding` (thread uuid to worker, folder and
   ACP session id), `ask`, `audit`. Queued messages arrive as `.message`
   events on connect, so replay needs nothing extra. Asks are numbered
   text answered `1`, `2` or `3` until task 8. Files under
   `Sources/PeelAgent/Host/`: `AgentRecord.swift`, `AgentStore.swift`,
   `Gate.swift`, `Router.swift`, `WorkerRunner.swift` with `ACPRunner` and
   a `ScriptedRunner`, `AgentHost.swift`; `Tests/PeelAgentTests/HostTests.swift`.
   Needs 1; 2 for `ACPRunner` only. Verify: the tests, then two
   development profiles on the local stack, `init` each, `add` each other,
   `peel-agent serve --profile agent1 --owner <alice>`, `peel --profile
   alice send <agent1> pong`, `listen` prints the reply in a thread. Two days.
8. **Typed message codec.** `ask`, `answer`, `progress`, `result`, `bind`,
   `unbind`, `status`, `mandate`, `revoke` as versioned JSON under the
   `peel` key of the `metadata` object, keeping any other keys such as
   `tz`, the readable `content` for each, and a parser taking a plain `1`,
   `2`, `3`, `yes` or `no` for the newest pending ask. Conventions live in
   the engine, so this is the one new file outside `PeelAgent`:
   `Sources/PeelCore/AgentMessage.swift`,
   `Tests/PeelCoreTests/AgentMessageTests.swift`; nothing existing
   changes. Needs nothing. Verify: `swift test --filter AgentMessageTests`.
   Half a day.
9. **Agent loop.** One turn per message in an unbound thread: the thread's
   history from the host's store, a model call with a small tool list
   (reply, read this chat, bind a thread by proposal card), the reply in
   the thread. The model provider follows `../agent-architecture.md`,
   decision 1; the key lives in the host's Keychain, never in a message.
   Files under `Sources/PeelAgent/Loop/`: `AgentLoop.swift`,
   `ModelClient.swift`, `Tools.swift`; `Tests/PeelAgentTests/LoopTests.swift`
   on a scripted model. Needs 7. Verify: alice asks agent1 "what can you
   do?" and gets a Markdown reply in a thread. Two days.
10. **Running always on.** `peel-agent install --profile <dev>` writes a
    `launchd` LaunchAgent plist and `uninstall` removes it; the agent's
    words sit in the host's Keychain with no PIN (decision 9); the host
    keeps the Mac awake while it runs (decision 12). Files:
    `Sources/peel-agent/Install.swift`. Needs 6. Verify: reboot the Mac, send
    `pong` from alice, get the reply without opening anything. Half a day.

### Wave B: the agent in Peel

After Markdown in messages (phase 10 item 2) merges. Design against
`../design/agents.md`, with `tom-ui` and `taste` loaded. Verify every task
from `scripts/bundle-app.sh .build/Peel.app` launched with `-profile alice`
on the local stack, never `run-app.sh`.

11. **Threads in DMs.** The tribe thread rule in 1:1 chats: a thread of
    two or more collapses into its thread row, and the thread panel opens
    from it. The rows builder's `inTribe` rule in `MessageViews.swift` and
    the thread list in `ChatModel.swift`. Peel already stores `threadUuid`
    in DMs. Verify: a DM thread from the CLI collapses and opens in the
    panel; the official app still shows the replies inline. A day.
12. **The agent contact.** A `kind` on PeelCore's `contact` (person, your
    agent, someone else's agent), the next migration number, agreed with
    whoever holds migrations then; the rounded-square avatar and the AGENT
    label; a status line from `status` messages. Files: `Storage+Migrations.swift`,
    `Avatar.swift`, the conversation header. Verify: `StorageTests`; agent1
    shows as the agent in alice's sidebar. A day.
13. **Cards.** `sendText` gains an optional `metadata:` argument; ask,
    result and progress views under `Sources/PeelApp/Agent/`; the bubble
    renders a card when `AgentMessage` decodes one. Needs 8, 12. Verify: an
    ask is a card in Peel and numbered text in `peel --profile alice
    messages`; Reject in the card and `send <agent1> 3` both stop the
    write. A day.
14. **Bind a thread.** A thread action, "Hand to a worker", that sends
    `bind` with the worker and folder from the agent's grants; the thread
    header shows the worker, Stop and Unbind. The agent may propose a
    binding with a card (decision 3). Needs 13. Verify: bind a DM thread to
    the fake worker, then to Claude, and get `pong` back in it. A day.
15. **Account › Agent.** The agent's account, worker grants (folders and
    mode), mandates, activity from the audit log, and Remove, confirmed in
    place. Every control sends a typed message and shows the host's answer.
    Files: `Sources/PeelApp/Agent/AgentSettingsView.swift`, a row on
    `AccountView.swift`. Needs 13. Verify: a grant changed in Peel applies
    to the next session; revoke mid-turn stops the write. One to two days.

### Wave C: graph memory and Strut

16. **LadybugDB in the host.** Add the Swift binding to `Package.swift`
    (a spike first: build, open, schema, one write and read, on macOS 15
    and Swift 6); `GraphStore` as the only code that opens the file; the
    schema from `../agent-architecture.md`, "Schema sketch", created by a
    versioned migration. Files: `Sources/PeelAgent/Graph/`. Needs 1.
    Verify: `GraphTests` on a temporary file; a second process opening the
    file read-write is refused. Two days.
17. **Records from events.** Job, Run and Artifact written by host code
    when a bound session starts and ends, Claims only with Evidence; the
    `graph_query` tool for the loop and as an MCP tool for workers. Needs
    9, 16. Verify: after acceptance run 1, the graph holds one Job, its
    Runs and an Artifact per changed file. A day.
18. **Strut jobs.** The host starts Strut as a child process on localhost,
    `start_job`, `continue_job` and `set_schedule` as loop tools, the
    callback on a localhost port only the host listens on, results in the
    job's thread. Needs a standalone Strut (`../agent-architecture.md`,
    "What Strut and the company needs"). Verify: a job started from a DM
    returns its result in the same thread while Peel is closed. Two days.
19. **Glimmer.** Rebuild the Concept tables from Tom's seed files
    (decision 7); `concept_open` and `concept_walk` as loop tools and MCP
    tools for workers; a proposal card whose approval edits a seed file.
    Needs 16. Verify: the rebuild matches the seed files; an approved
    proposal shows up after the next rebuild and nothing writes a Concept
    directly. A day.
20. **Mandates.** `mandate` and `revoke` handled by the gate on top of
    `checkPayment`; a payment outside every mandate sends an ask with the
    amount. Needs 8, 15. Verify on the local stack: a payment inside the
    cap goes, one over it asks, one after `revoke` asks. A day.

### Wave D: the Inbox

The agent's commitments to Tom, kept as Item nodes in the graph and shown
in Peel as a read-mostly list. The design is in
[09b-inbox.md](09b-inbox.md).

21. **Items in the host.** The Item node and its edges in the graph
    schema, by a versioned migration. The `inbox_add`, `inbox_update`,
    `inbox_done`, `inbox_list` and `inbox_snooze` loop tools, and the
    `item.*` messages in the codec. Inferred items are suggestions, and
    upkeep (merge, stale, done in a chat) is an ask card. Needs 8, 9 and
    16. Verify: "remind me about this tomorrow at 2" in a thread writes
    one Item about the replied-to message, with `remind_ms` in Tom's
    zone, and the host sends an `item.state`. Two days.
22. **Peel's cache.** The `inboxItem` table and migration, applying
    `item.state` and `item.snapshot`, `tick` and `snooze` sent as
    `item.put` with `pending`, and `item.sync` on a new or restored
    device. Needs 21. Verify on the local stack: two devices of the owner
    converge after a tick on one; a tick made offline syncs on reconnect.
    A day.
23. **The Inbox view.** The sidebar row with its count, the list (Today,
    Later, Suggested, Done folded), tick and snooze on hover, and the
    item's thread opening in the right-hand panel. Needs 11 and 22.
    Verify with click-through tests in both themes. A day.
24. **Reminders per device.** Scheduling from the cache, the lock and quit
    rewrite, the notification actions and the pending list from before
    unlock. Needs 22. Verify: a reminder fires with Peel closed, says
    nothing while locked, and a snooze on one device moves it on the
    other. A day.

### Later

- **Inbox quick capture.** ⌃⌥Space in any app opens a one-line panel
  that sends the line to the agent, or queues it while offline; Carbon
  `RegisterEventHotKey`, no Accessibility permission
  ([09b-inbox.md](09b-inbox.md), "Quick capture").
- **Codex and goose.** `set_mode read-only` before Codex's first prompt,
  `workspace-write` only by grant; goose once a provider is configured.
- **Custom worker JSON** in `~/Library/Application Support/Peel/workers/`:
  id, label, command, args as an array, env names allowlisted, install
  hint, modes; never a shell.
- **Heartbeat.** An optional prompt on an interval, only while idle and
  only when a grant allows; Strut schedules may replace it.
- **Child seed and free registration.** A hardened child seed from the
  master, registration with the master's `root` and a new `idx`, no
  invite, a keysend from master to child; research 9, agent-native spike 1.
- **Connections:** calendar first; `../agent-architecture.md`,
  "Connections".
- **Temporary tribes** for long sessions, when a team use comes up.

Sessions: Wave A splits as client (1 first and alone, then 2, 3, 4), host
(7, 8, 9) and worker CLI (5, 6, 10), each owning its directories. Wave B is
one app session. Wave C is one host session, with 18 waiting on Strut.
Wave D is a host session (21) and then an app session (22 to 24).

## Acceptance for the phase

1. **Local stack, free.** Owner `alice`, agent `agent1` under `launchd`.
   From Peel with `-profile alice`: "What can you do?" gets a Markdown
   reply in a thread. A second thread bound to Claude on a scratch copy of
   a small repo in `read-only`: "List the files and summarise the README"
   shows collapsed progress then the answer; "Create hello.txt containing
   hi" shows an ask card; Reject; the result says nothing was written and
   `ls` agrees. A message from a third profile `carol` gets no answer and
   one `audit` row saying why.
2. **Production, throwaway only.** The agent is a new account from an
   invite Tom makes in the official app, `peel --profile agent-claude
   signup <invite>`; its owner is the throwaway. `peel-agent serve` on it,
   one process. From the CLI: `peel --profile throwaway send <agent> "List
   the files and summarise the README"` in a thread bound to Claude;
   `listen` prints progress and the answer; `send <agent> "Create hello.txt
   containing hi"`; `messages <agent>` prints the ask as `content`, the text
   the official phone app would render; `send <agent> 3`; the result
   arrives and `ls` shows no file. Record sats per turn from `whoami`
   before and after, and the latency from send to first progress, here.
   Tom's real account is never owner or allowlisted in this phase.

The phase ships only when both runs pass with every gate item in place.

## Still open

The design decisions are numbered in `../agent-architecture.md`, "Open
decisions for Tom". Smaller questions for the build:

- Which variable the Claude adapter honours for a separate config home,
  `CLAUDE_CONFIG_DIR` or `HOME`; unverified in research 1, task 5's probe
  settles it.
- Cost per turn through the mixer in sats and latency, agent-native spike
  3; measured in acceptance run 2.
- Production `invite_price`, and whether the official apps add an invite
  requirement of their own; `GET /info` answers the first.
- The LadybugDB Swift binding's state on macOS 15 and Swift 6; task 16's
  spike settles it.
- How someone else's agent is recognised for the AGENT label; no
  convention yet.
- goose needs a provider before `session/new`; its `session/load` is
  unverified.
- The open design questions at the end of `../design/agents.md`.

## Risk to keep in view

A compromised owner key or a gate bug is remote execution on the host and
spending from the agent's balance. The mitigations are the owner gate,
narrow grants, conservative worker modes, mandates with caps, a person
answering anything destructive, and a balance Tom tops up by hand; if
those are not in place, the phase does not ship.
