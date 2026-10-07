# Phase 9 — Agents as contacts: any ACP harness behind a Sphinx identity

Status: planned. Decided 2026-10-07 after reading Block's Buzz; the harnesses
were tried the same day, `../research/acp-harnesses.md`, cited below by
section. The app side comes after the audit, phase 8. Wave A of the build
plan starts now, in its own target, on the local test stack.

## Idea

An agent in Peel is a contact: a Sphinx account you DM, with a name, an avatar
and the AGENT label. What answers behind it is a harness: Claude Code, Codex,
goose, or anything else that speaks the Agent Client Protocol (ACP). The
contact is the identity. It keeps the conversation, the trust and the grants.
The harness is a setting and can change underneath it.

Peel writes no agent loop and holds no model keys. The harnesses already have
the tools, the file edits, the shell, the sandboxing and the permission
prompts. Peel owns the identity, the encrypted transport, and the place where
you say yes or no, from the Mac or from the phone.

ACP is the one interface, so there is one client for every runtime. It is
JSON-RPC over stdio, published by Zed in August 2025, community-governed with
JetBrains as co-maintainer, with a public registry of more than forty agents.
Block's Buzz (`block/buzz`, July 2026) connects agents the same way; the rules
of its harness in `crates/buzz-acp` are the reference for the host loop below,
not its code, which is Nostr-typed and auto-approves permissions. Research 8.

## Shape

```
 you (Mac or phone) ──Sphinx DM──▶ agent account: an engine in the host
                                          │  ACP over stdio
                                          ▼
                                   harness process in a granted folder
                       claude-agent-acp · codex-acp · goose acp · buzz-agent · custom
```

- **Agent record.** Name, Sphinx profile (a child account; from an invite
  until derivation from the master seed lands), harness id, folders, mode,
  owner pubkey, allowlist.
- **Harness registry.** Built-in definitions for Claude Code, Codex, goose and
  buzz-agent, each with its adapter version pinned. A custom harness is one
  JSON file: id, label, command, args, env, install hint. Peel probes PATH for
  availability and shows the install hint when a harness is missing.
- **ACP client, in Swift.** Spawns the harness; `initialize` at protocol
  version 1; `session/new` with the working directory and the MCP servers the
  grant allows; `session/set_mode` and the model before the first prompt;
  `session/prompt`; reads `session/update`; answers
  `session/request_permission`; `session/cancel`; `session/load` to resume.
  A few hundred lines, and every registered agent works with it.
- **Host loop, per agent.** Buzz's rules, adopted as they are: owner-only
  author gate by default, allowlist optional; one session per Sphinx thread,
  with top-level DMs as the main session; one prompt in flight per session
  and a queue behind it; an idle timeout and a maximum turn length; replay of
  messages that arrived while the host was offline, which the server queues
  anyway; respawn on crash; an optional heartbeat prompt for agents that
  should look for work on their own.
- **What you see.** Progress lines from updates, collapsed; the answer; an ask
  card for each permission request with the options the harness offers, for
  Claude Code allow once, allow for the session and reject; result cards.
  The header shows folder, mode, harness, running or idle, Stop and New
  session.

## Message shapes

- A task is plain text in the DM. A reply inside a Sphinx thread goes to that
  thread's session.
- Ask cards and their answers are typed JSON in the message's `metadata`
  field, a string the core carries (`sphinx/src/msg/mod.rs`). The official
  Mac app already uses it: it sends a JSON object with a `tz` key and, on
  receipt, parses the object and reads only `tz`, ignoring other keys
  (`SphinxOnionManager+ChatExtension.swift`, checked 2026-10-07). So
  `metadata` stays a JSON object, Peel's payload sits under one key, `peel`,
  and the parser tolerates objects without it.
  `content` holds the readable fallback with numbered options, so the phone
  app shows the ask as text and a plain `1`, `2` or `3` still counts. An
  answer counts only when its signature recovers the owner's pubkey. The
  message uuid is the idempotency key.
- Results are text; large outputs travel as encrypted attachments (phase 3).
- Every typed message carries a version field.

## What it rests on

- The core recovers each message's sender from its signature, so a task is
  bound to exactly one account (verified during phase 2).
- The app has a stable signed identity, which macOS requires before it grants
  folder access, Automation or Accessibility to a bundle.
- Replay protection already exists: the unique time on every core call and the
  message uuid the store deduplicates on.

## The gate lives in Peel, outside the model and outside the harness

Outsourcing the execution does not outsource the decision. This is remote
execution of your machine by a chat identity, so the permission model is the
design; the ACP client is the easy part.

- An explicit allowlist per agent, owner first. Never "any contact", never
  your root identity acting as an agent.
- Grants per agent: harness, folders, mode. Peel puts every harness in its
  conservative mode before the first prompt; Codex defaults to `agent`, so it
  is set to `read-only`, research 3. Automatic approval is allowed only for a
  read-only configuration, and Peel never passes "skip permissions".
- Permission requests reach a person, in the app or on the phone. "Allow
  always" lasts for the session, never beyond the grant.
- Every task, answer and result is visible in the conversation and logged.
- Revoking a grant drops the agent's queue and cancels its sessions.

## Decisions from the research

- Own ACP client over Foundation `Process`, Swift 6 strict concurrency: the
  surface is small and the one maintained Swift 6 package brings five
  dependencies and a daemon. Research 6.
- Protocol version 1, pinned; 2 is a draft, all adapters answered 1. Research 5.
- Adapters pinned in the command, `claude-agent-acp@0.87.0` and
  `codex-acp@2.1.1` via `npx -y`; unpinned `npx` served a stale 0.49.0. Research 1, 3.
- Subscription logins for both, no API keys; the print-mode fallback is
  dropped. Research 1, 3.
- `session/set_mode read-only` before Codex's first prompt; for Claude the
  model set explicitly and an own config home, or every turn carries Tom's
  40k-token setup. Research 1, 3.
- Storage: host state in `agent.sqlite` beside `peel.sqlite` in the agent's
  profile directory, owned by `PeelAgent` with its own migrator. It is not
  core state, never shares a transaction with a core commit, and the
  directory is already one process per profile. PeelCore's migrations stay
  with #9, boosts and #13 for v9 to v11.
- Child accounts later, invites now: a child of a registered root registers
  free with no invite at zero balance; a fresh root needs an invite. Research 9.
- No buzz-acp fork: its rules and defaults, not its code. Research 8.

## Build plan

One branch and one PR per task through the chain in `AGENTS.md`: `swift
build`, the task's own check, `/code-review`, `/simplify`,
`/security-review`, then this file. The security review looks hardest at
tasks 2, 6, 7 and 11: the process environment, no skip-permissions flag,
the owner gate, the answer gate. No two sessions edit the same file. Wave A
tasks run in parallel with each other and with PRs #9 and #13 unless "needs"
says otherwise, and touch nothing that exists under `Sources/`. `$S` is the
session scratchpad.

### Wave A: now

1. **Targets.** `PeelAgent` library on `PeelCore` and GRDB, `peel-agent`
   executable, `PeelAgentTests`, a placeholder file each. Files:
   `Package.swift`, `Sources/PeelAgent/PeelAgent.swift`,
   `Sources/peel-agent/AgentCommand.swift`, `Tests/PeelAgentTests/PeelAgentTests.swift`.
   Needs nothing; #9 and #13 leave `Package.swift` alone. Merges first and
   alone. Verify: `swift build && swift test --filter PeelAgentTests`. An hour.
2. **ACP client.** Spawn, `initialize` at version 1, `newSession`,
   `loadSession`, `setMode`, `setConfigOption`, `prompt` as a stream ending
   in the stop reason, `cancel`, `answer`; `-32601` to `fs/*` and
   `terminal/*`; `_meta` and `_`-prefixed notifications ignored; bounded line
   length. Files under `Sources/PeelAgent/ACP/`: `JSONRPC.swift`,
   `ACPTypes.swift`, `ACPConnection.swift`, `ACPClient.swift`. Needs 1.
   Verify: task 4, then task 6's `run`. One to two days.
3. **Fake agent.** `Tests/PeelAgentTests/Fixtures/fake-agent.py`, stdlib
   only, a script per prompt word: `pong`, `ask` with Claude Code's three
   options and a numeric id, `slow` until `cancel`, `fs` expecting `-32601`,
   `junk` with `_meta` and `_` notifications, `crash` mid-turn. Needs
   nothing. Verify: `python3 Tests/PeelAgentTests/Fixtures/fake-agent.py --self-test`. Half a day.
4. **Client tests.** `Tests/PeelAgentTests/ACPClientTests.swift` on the fake
   agent: handshake, update order, permission round trip, cancel, `-32601`,
   junk, an oversized line, a crash surfacing as an error with the process
   reaped. `ACPHandshakeTests.swift` on `goose acp` when on PATH, else
   skipped: `initialize` works with no provider, `session/new` throws;
   research 4. Needs 2, 3. Verify: `swift test --filter PeelAgentTests`. A day.
5. **Harness registry and probe.** Built-ins claude, codex, goose: id,
   label, command, args, env, install hint, modes conservative first, config
   home policy. The probe checks PATH, the `node` version since the Claude
   adapter wants 22 and this Mac has 20, and after task 2 an `initialize`
   within 15 s. Files: `Sources/PeelAgent/Harness/Harness.swift`,
   `HarnessRegistry.swift`, `HarnessProbe.swift`, `Tests/PeelAgentTests/HarnessTests.swift`.
   Needs 1. Verify: the tests; `peel-agent harnesses` prints found or the
   install hint. Half a day.
6. **`peel-agent` executable.** Development profiles only, never `default`.
   `harnesses`; `probe <harness>`; `run <harness> --cwd <dir> [--mode m]
   [--model id] <prompt>` printing updates and reading an ask's answer from
   stdin; `serve --profile <dev> --owner <pubkey> --harness <id> --folder
   <dir> --mode <mode> [--server host:port]` running task 7; `--command`
   points either at the fake agent. Files: `Sources/peel-agent/AgentCommand.swift`,
   `Arguments.swift`, its own parser since the CLI's is in `PeelCommand.swift`.
   Needs 2 and 5 for `run`, 7 for `serve`. Verify: `.build/debug/peel-agent
   run claude --cwd $S/cwd "Reply with the single word pong."` prints pong;
   with "Create a file named hello.txt containing hi" it shows the ask, `3`
   rejects, `ls $S/cwd` stays empty. A day.
7. **Host loop, state and gate.** One actor per agent: `Account.load`,
   consume `engine.events`, a main session for top-level DMs and one per
   `threadUUID`, one prompt in flight per session with a queue behind it,
   idle 1,500 s and max turn 7,200 s as Buzz defaults them, respawn on crash
   with `session/load`, replies through `sendText(_:to:replyTo:inThread:)`.
   Gate: `chat` is the owner, `fromMe` is false, type is text; allowlist
   optional; an answer passes the same gate and names a pending ask. Tables:
   `agent`, `session` from thread uuid or `main` to ACP session id, `ask`,
   `audit`. Queued messages arrive as `.message` events on connect, so
   replay needs nothing extra. Asks are numbered text answered `1`, `2` or
   `3`; the typed carrier is Wave B. Files under `Sources/PeelAgent/Host/`:
   `AgentRecord.swift`, `AgentStore.swift`, `Gate.swift`, `Runner.swift`
   with `ACPRunner` and a `ScriptedRunner`, `AgentHost.swift`;
   `Tests/PeelAgentTests/HostTests.swift`. Needs 1; 2 for `ACPRunner` only.
   Verify: the tests, then two development profiles on the local stack,
   `init` each, `add` each other, `peel-agent serve --profile agent1 --owner
   <alice> --command "python3 .../fake-agent.py" --folder $S/cwd --mode
   read-only`, `peel --profile alice send <agent1> pong`, `listen` prints
   the reply; then `--harness claude`. Two days.
8. **Typed message codec.** `ask`, `answer`, `progress`, `result` as
   versioned JSON under the `peel` key of the `metadata` object, keeping any
   other keys such as `tz`, the readable `content` for each, and a
   parser taking a plain `1`, `2`, `3`, `yes` or `no` for the newest pending
   ask. Conventions live in the engine, so this is the one new file outside
   `PeelAgent`: `Sources/PeelCore/AgentMessage.swift`,
   `Tests/PeelCoreTests/AgentMessageTests.swift`; nothing existing changes.
   Needs nothing. Verify: `swift test --filter AgentMessageTests`. Half a day.

Sessions. Session 1, client: 1 first and alone, then 2, 3, 4; owns
`Package.swift`, `Sources/PeelAgent/ACP/`, the client tests, `Fixtures/`.
Session 2, host: 7 and 8; owns `Sources/PeelAgent/Host/`, `HostTests.swift`,
the `AgentMessage` files. Session 3, harness and CLI: 5 and 6; owns
`Sources/PeelAgent/Harness/`, `HarnessTests.swift`, `Sources/peel-agent/`.
Task 6's `run` lands after 2 merges, `serve` after 7.

### Wave B: after #9 and #13 merge, one session

`docs/design/agents.md` is not written yet; until it lands, design against
the Agents section of `docs/design/README.md` and this file, with `tom-ui`
and `taste` loaded. Verify every task from `scripts/bundle-app.sh
.build/Peel.app` launched with `-profile alice` on the local stack, never
`run-app.sh`.

9. **Agents views**, all new under `Sources/PeelApp/Agents/`:
   `AgentsModel.swift`, `@MainActor @Observable`, finds the profiles of the
   owner's kind holding an `agent.sqlite` and runs one `AgentHost` each from
   the owner's PIN at unlock; `AddAgentForm.swift`, name, harness with
   availability and install hint, folder via `NSOpenPanel`, mode, account
   from a pasted invite or `Account.create` locally; `AgentHeader.swift`;
   `AskCardView.swift`; `GrantsView.swift` with Revoke confirmed inline;
   `HarnessViews.swift`. Needs 5, 7, 8 and the merges. Verify: agent1
   served in-app with the fake agent, then Claude. Two to three days.
10. **Hooks**, one line each, one PR, after `gh pr view 9 13 --json state`
    says merged: `MainView.swift` adds `SidebarActionLink(title: "Add agent")`
    after "Add contact"; `AppModel.swift` gets `let agents = AgentsModel()`,
    started in `unlock(pin:)`; the bubble view from #13 renders `AskCardView`
    when `AgentMessage` decodes an ask; the conversation header shows
    `AgentHeader`; `AccountView.swift` mounts the harnesses group. Without
    the hooks an ask still shows as text. Needs 9. Verify: task 9's check
    through each hook. Half a day.
11. **Typed asks end to end.** `sendText` in `Engine.swift` gains an
    optional `metadata:` argument, three lines; the host sends through task
    8 and accepts typed and plain answers. Needs 8, 10. Verify: an ask is a
    card in Peel and numbered text in `peel --profile alice messages`; Reject
    in the card and `send <agent1> 3` both stop the write. A day.
12. **Add-agent flow and grants.** Name, harness, folder, mode, the account,
    the contact exchange, the first task; a grant edit applies at the next
    session. Files: `AddAgentForm.swift`, `GrantsView.swift`,
    `AgentsModel.swift`. Needs 9 to 11. Verify: a new agent from the form
    answers `pong` with no CLI involved. A day.

### Wave C: after Wave B

Each task needs Wave B and the earlier task that owns the files it names.

13. **Codex and goose.** `set_mode read-only` before Codex's first prompt,
    `workspace-write` only by grant; goose once a provider is configured.
    Files: `HarnessRegistry.swift`, `Runner.swift`. Verify: `peel-agent run
    codex` and `run goose` print pong; Codex's mode reads back `read-only`. A day.
14. **Custom harness JSON** in `~/Library/Application Support/Peel/harnesses/`:
    id, label, command, args as an array, env names allowlisted, install
    hint, modes; never a shell. Files: `HarnessRegistry.swift`, `HarnessViews.swift`.
    Verify: a JSON for the fake agent shows in the group and runs. Half a day.
15. **Heartbeat.** An optional prompt per agent on an interval, only while
    idle and only when the grant allows. Files: `AgentHost.swift`,
    `GrantsView.swift`. Verify: one prompt per interval on the local stack. Half a day.
16. **Audit log.** Every task, ask, answer and result as an `audit` row with
    its message uuid, shown as Activity in `GrantsView.swift`. Verify: the
    rows match the conversation after the acceptance run. Half a day.
17. **Revocation and contact kind.** Revoke kills the harness, cancels
    sessions, drains the queue, marks the record; the contact stays and says
    so. The `kind` column on PeelCore's `contact`, person, your agent or
    someone else's, is the phase's one PeelCore migration, numbered after
    #9, boosts and whatever #13 adds, agreed with that session first. Files:
    `AgentHost.swift`, `Storage.swift`, `MainView.swift` for the avatar
    shape. Verify: `StorageTests`; revoke mid-turn stops the write. A day.
18. **Child seed and free registration.** A hardened child seed from the
    master, registration with the master's `root` and a new `idx`, no
    invite, a keysend from master to child; research 9, agent-native spike
    1. Replaces the invite step in `AddAgentForm`. Files: `Account.swift`,
    `Engine.swift`, after coordination. Verify: a child registers on the
    local stack with no code and `whoami` shows the keysend; read `GET
    /info` on production for the real `invite_price` first. Two days.

Wave C sessions: 13 and 14 to the harness session, 15 to 17 to the host
session, 18 to a core session; the same no-shared-file rule.

## Acceptance for the phase

The chef story from `docs/agent-native.md`, run twice.

1. **Local stack, free.** Owner `alice`, agent `agent1`, the fake agent then
   Claude on a scratch copy of a small repo in `read-only`. From Peel with
   `-profile alice`: "List the files and summarise the README" shows
   collapsed progress then the answer; "Create hello.txt containing hi"
   shows an ask card; Reject; the result says nothing was written and `ls`
   agrees. A message from a third profile `carol` gets no answer and one
   `audit` row saying why.
2. **Production, throwaway only.** The agent is a new account from an invite
   Tom makes in the official app, `peel --profile agent-claude signup
   <invite>`; its owner is the throwaway. `peel-agent serve --profile
   agent-claude --owner <throwaway pubkey> --harness claude --folder
   <scratch repo> --mode read-only`, one process, nothing else on either
   profile. From the CLI: `peel --profile throwaway send <agent> "List the
   files and summarise the README"`, `listen` prints progress and the
   answer; `send <agent> "Create hello.txt containing hi"`; `messages
   <agent>` prints the ask as `content`, the text the official phone app
   would render; `send <agent> 3`; the result arrives and `ls` shows no
   file. Record sats per turn from `whoami` before and after, and the
   latency from send to first progress, here. The throwaway's words are
   never restored on the phone and Tom's real account is never owner or
   allowlisted, so this phase's phone leg is the CLI's `content` output.

The phase ships only when both runs pass with every gate item in place.

## Still open

- Which variable the Claude adapter honours for a separate config home,
  `CLAUDE_CONFIG_DIR` or `HOME`; unverified in research 1, task 5's probe settles it.
- Cost per turn through the mixer in sats and latency, agent-native spike 3;
  measured in acceptance run 2.
- Where the agent's words live in the app: a `.app` profile under the
  owner's PIN, as Wave B assumes, or a separate agents root for an always-on
  host that cannot ask for a PIN.
- Production `invite_price`, and whether the official apps add an invite
  requirement of their own; `GET /info` answers the first.
- The open design questions at the end of `docs/design/agents.md`; Wave B
  follows that spec and settles them with Tom as it goes.
- How someone else's agent is recognised for the AGENT label; no convention yet.
- goose needs a provider before `session/new`; its `session/load` is unverified.
- A phone check against a real account; a second phone-side throwaway would allow it.

## Risk to keep in view

A compromised agent account is remote execution on the Mac. The mitigations
are the allowlist, per-agent keys with narrow grants, conservative harness
modes and a person answering anything destructive; if those are not in place,
the phase does not ship.
