# ACP harnesses: hands-on findings for phase 9

Date: 2026-10-07. Machine: Tom's Mac, `claude` 2.1.291, `codex` 0.46.0,
`goose` 1.43.0, `node` v20.19.5, `cargo` 1.92.0, `python3` 3.11.5.
Branch `docs/phase9-acp`. Answers the open questions in
`docs/phases/09-agents.md`, in the order they were asked.

Everything below was run from a throwaway driver,
`scratchpad/acp_drive.py` (about 100 lines of Python: JSON-RPC 2.0 over
stdio, one line per message). Raw transcripts are in
`scratchpad/acp/claude.log`, `scratchpad/acp/codex.log` and
`scratchpad/acp/goose.log`, with per-run `.out` files beside them. The
scratchpad is `/private/tmp/claude-501/-Users-tom-Documents/54dd122a-3b00-4250-b75c-a2666539d600/scratchpad`.
Nothing touched Tom's Sphinx account or any Sphinx server. No API key was
set. `ANTHROPIC_API_KEY` was absent from the environment (`env | grep -i
anthropic_api_key` printed nothing) and the driver strips it anyway.

Model prompts spent: two on the Claude subscription (the "pong" prompt and
the permission test), one on the ChatGPT login (pong), none on goose.

## 1. Claude Code through ACP with the subscription login

Short answer: yes. `@agentclientprotocol/claude-agent-acp` 0.87.0 answered
"pong" using the existing Claude Code login from the Keychain, with no API
key and no `authenticate` call.

### First run: the npx cache served a stale adapter

`npx -y @agentclientprotocol/claude-agent-acp` (unpinned) did not run
0.87.0. It ran 0.49.0 from `~/.npm/_npx/d820eb7d96bc2600`, which bundles
`@anthropic-ai/claude-agent-sdk` 0.3.185 and so Claude Code 2.1.185.
Proof: `node -p "require('~/.npm/_npx/d820eb7d96bc2600/node_modules/@agentclientprotocol/claude-agent-acp/package.json').version"`
prints `0.49.0`; `npm view @agentclientprotocol/claude-agent-acp version`
prints `0.87.0`.

That run completed `initialize` and `session/new`, then the prompt failed
before reaching the model:

```
<< {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"72f34d70-...","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"API Error: 400 Claude Code 2.1.185 does not support this model; version 2.1.251 or newer is required. Run 'claude update', or update the Claude desktop app, then try again."},...}}}
<< {"jsonrpc":"2.0","method":"session/update","params":{...,"update":{"sessionUpdate":"usage_update","used":0,"size":1000000,"cost":{"amount":0,"currency":"USD"}}}}
<< {"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"Internal error: API Error: 400 Claude Code 2.1.185 does not support this model; ...","data":{"errorKind":"unknown"}}}
```

The session had picked up Tom's configured model, `claude-fable-5-1[1m]`,
from his Claude Code settings. Zero tokens were used. Full transcript:
`scratchpad/acp/claude-pong.out`.

Lesson for the harness registry: pin the adapter version in the command
(`npx -y @agentclientprotocol/claude-agent-acp@0.87.0`). Unpinned `npx -y`
reuses whatever is cached and never checks for a newer release.

### Second run: pinned 0.87.0

Command: `python3 acp_drive.py --scenario pong --cwd <scratchpad>/acp/cwd-claude -- npx -y @agentclientprotocol/claude-agent-acp@0.87.0`.
Transcript: `scratchpad/acp/claude-pong-087.out`.

stderr first printed an engine warning and kept running:

```
[stderr] npm warn EBADENGINE   package: '@agentclientprotocol/claude-agent-acp@0.87.0',
[stderr] npm warn EBADENGINE   required: { node: '>=22' },
[stderr] npm warn EBADENGINE   current: { node: 'v20.19.5', npm: '10.8.2' }
```

`initialize` request and reply:

```
>> {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false}, "clientInfo": {"name": "peel-acp-probe", "version": "0.0.1"}}}
<< {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"_meta":{"claudeCode":{"promptQueueing":true},"authStatus":{}},"promptCapabilities":{"image":true,"embeddedContext":true},"mcpCapabilities":{"http":true,"sse":true},"auth":{"logout":{}},"providers":{},"loadSession":true,"sessionCapabilities":{"additionalDirectories":{},"close":{},"delete":{},"fork":{},"list":{},"resume":{},"subagents":{}}},"agentInfo":{"name":"@agentclientprotocol/claude-agent-acp","title":"Claude Agent","version":"0.87.0"},"authMethods":[],"_meta":{"steering":{"supported":true}}}}
```

`authMethods` is empty. The adapter only advertises a `claude-login`
terminal method when it thinks it is remote (`NO_BROWSER`, `SSH_*` or
`CLAUDE_CODE_REMOTE` set); see
`~/.npm/_npx/5d576370cad8aebf/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js:1266-1279`.
Otherwise it relies on whatever Claude Code already has.

`session/new` (cwd = scratchpad, `mcpServers: []`) returned session
`9eaa3620-b95b-4c80-82c1-7b61bd93c6bf` with `currentModeId: "default"`
("Manual: Always ask before making changes"), plus `configOptions` for
`mode`, `model` (current value `claude-fable-5-1`, from Tom's settings),
`effort` and `agent`. During `session/new` the adapter sent two extension
notifications a client must tolerate:

```
<< {"jsonrpc":"2.0","method":"_auth/status_update","params":{"authStatus":{"kind":"none","label":"Not logged in"}}}
<< {"jsonrpc":"2.0","method":"_auth/status_update","params":{"authStatus":{"kind":"account","label":"Claude API","account":{"plan":"Claude API","email":"[redacted]","organization":"[redacted]"}}}}
```

`kind: "account"` is the adapter's branch for a stored login, not for an
API key (`dist/auth-status.js:166-199`: `apiKeySource` gives `kind:
"api_key"`, `subscriptionType` gives `kind: "account"`). `claude auth
status` on this Mac prints `"authMethod": "claude.ai"`, `"apiProvider":
"firstParty"`, `"subscriptionType": null`. Why the adapter labels the plan
"API" is unexplained; unverified. The usage meta below carries
`five_hour` and `seven_day` rate-limit windows, which is what a claude.ai
plan login reports.

The prompt:

```
>> {"jsonrpc": "2.0", "id": 3, "method": "session/prompt", "params": {"sessionId": "9eaa3620-...", "prompt": [{"type": "text", "text": "Reply with the single word pong."}]}}
```

Notifications received, in order (kinds counted by the driver as
`{"available_commands_update": 2, "_auth/status_update": 1, "usage_update": 4, "agent_message_chunk": 2}`):

1. `session/update` `available_commands_update`, twice, listing Tom's
   skills and slash commands.
2. `_auth/status_update` with `kind: "none"` again, then nothing further
   on auth.
3. `session/update` `usage_update` `{"used":40877,"size":1000000,"_meta":{"_claude/model":"claude-fable-5-1"}}`.
4. `session/update` `agent_message_chunk` text `"p"`, then `"ong"`, same
   `messageId`.
5. `usage_update` twice more; one carries
   `"_claude/rateLimit":{"status":"allowed","rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.14,...},"seven_day":{"utilization":0.21,...}}}`.
6. `usage_update` with `"cost":{"amount":0.8177,"currency":"USD"}`.

stderr also logged `Unexpected case: {"type":"system","subtype":"post_turn_summary",...}`,
which is the adapter not mapping a newer SDK message. Harmless.

Result:

```
<< {"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":2,"outputTokens":4,"cachedReadTokens":0,"cachedWriteTokens":40874,"totalTokens":40880},...}}
```

Two things to carry into phase 9:

- A single "pong" cost 40,874 cache-write tokens. The adapter runs Claude
  Code with Tom's full user context (global `~/.claude/CLAUDE.md`, the
  skills list, agents), even in an empty cwd. An agent account should run
  with its own `HOME` or `CLAUDE_CONFIG_DIR`, or the per-turn cost is
  Tom's whole setup. Not tested; unverified which variable the adapter
  honours.
- The model defaulted to Tom's configured `claude-fable-5-1`. Peel should
  set `model` through `session/set_config_option` (id `model`), or the
  agent runs on the most expensive model by accident.

## 2. Permission requests

Command: same as above with `--scenario perm`, prompt "Create a file named
hello.txt containing hi". New session `33fcdae1-219b-430c-8b9f-a7fbedbec9ed`.
Transcript: `scratchpad/acp/claude-perm.out`.

Before asking, the agent streamed `agent_message_chunk` ("Creating
hello.txt in the working directory.") and a `tool_call` with
`status: "pending"`, `kind: "edit"`, `title: "Preparing file…"`, then two
`tool_call_update`s filling in `rawInput`, `title: "Write hello.txt"`,
`locations` and a `content` diff. Then the request, verbatim:

```
<< {"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"toolu_01BXmwnDMDEQ5yb7Ga6euVbe","name":"Write","status":"pending","rawInput":{"file_path":"<cwd>/hello.txt","content":"hi\n"},"title":"Write hello.txt","kind":"edit","content":[{"type":"diff","path":"<cwd>/hello.txt","oldText":null,"newText":"hi\n"}],"locations":[{"path":"<cwd>/hello.txt"}]},"options":[{"optionId":"allow-once","name":"Yes","kind":"allow_once"},{"optionId":"allow-with-updates","name":"Yes, allow all edits during this session","kind":"allow_always"},{"optionId":"reject","name":"No","kind":"reject_once"}],"sessionId":"33fcdae1-..."}}
```

The options array:

| optionId | name | kind |
| --- | --- | --- |
| `allow-once` | Yes | `allow_once` |
| `allow-with-updates` | Yes, allow all edits during this session | `allow_always` |
| `reject` | No | `reject_once` |

No `reject_always` option was offered. The request id is `0`, a number.

Answer sent and what followed:

```
>> {"jsonrpc": "2.0", "id": 0, "result": {"outcome": {"outcome": "selected", "optionId": "reject"}}}
<< {"jsonrpc":"2.0","method":"session/update","params":{...,"update":{"_meta":{"claudeCode":{"toolName":"Write","nonExecutionKind":"permission-rule"}},"toolCallId":"toolu_01BXmwnDMDEQ5yb7Ga6euVbe","sessionUpdate":"tool_call_update","status":"failed","rawOutput":"User refused permission to run tool","content":[{"type":"content","content":{"type":"text","text":"```\nUser refused permission to run tool\n```"}}]}}}
```

The agent then said, in `agent_message_chunk`s: "The write was declined,
so hello.txt was not created. If you want it elsewhere, tell me the path
and I'll create it there." Result `stopReason: "end_turn"`, 70,263 total
tokens (56,584 cached read).

No file was written: `ls -la <cwd>/acp/cwd-claude` printed only `.` and
`..` (appended at the end of `claude-perm.out`).

## 3. Codex through ACP

`codex login status` with the installed 0.46.0 CLI fails to start:

```
Error loading configuration: unknown variant `ultra`, expected one of `minimal`, `low`, `medium`, `high`
in `model_reasoning_effort`
```

`~/.codex/config.toml` line 2 is `model_reasoning_effort = "ultra"`. The
file was not edited. With a one-off override,
`codex -c model_reasoning_effort=high login status` prints
`Logged in using ChatGPT`. `~/.codex/auth.json` exists (mode 0600, dated
Sep 5); its contents were not read.

`@agentclientprotocol/codex-acp@2.1.1` (pinned, `npx -y`) bundles its own
Codex core and accepted the same config file without complaint; its
`reasoning_effort` option even lists `ultra`. Transcript:
`scratchpad/acp/codex-pong.out`.

`initialize` reply:

```
<< {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"@agentclientprotocol/codex-acp","title":"Codex","version":"2.1.1"},"agentCapabilities":{"auth":{"logout":{}},"providers":{},"loadSession":true,"promptCapabilities":{"embeddedContext":true,"image":true},"sessionCapabilities":{"resume":{},"list":{},"close":{},"delete":{},"fork":{},"additionalDirectories":{},"subagents":{}},"mcpCapabilities":{"acp":false,"http":true,"sse":false},"_meta":{"authStatus":{}}},"authMethods":[{"id":"api-key","name":"API Key","description":"Use an API key to authenticate","_meta":{"api-key":{"provider":"openai"}}},{"id":"chat-gpt","name":"ChatGPT","description":"Use ChatGPT to authenticate"}],"_meta":{"steering":{"supported":true}}}}
```

`authMethods` has two entries: `api-key` and `chat-gpt`. No `authenticate`
call was needed. On `session/new` the adapter sent
`_auth/status_update` with `{"kind":"account","label":"ChatGPT Plus","account":{"email":"[redacted]","plan":"plus"}}`
and returned session `01a1175a-52d7-71b0-ae08-5bc06bf5ff87` with
`currentModelId: "gpt-6-astra[ultra]"` and `currentModeId: "agent"`.

That default mode matters. Codex's modes are `read-only`,
`workspace-write`, `agent` ("Auto review: only ask for actions detected
as potentially unsafe") and `agent-full-access`. The default was `agent`,
not the conservative one. Peel must call `session/set_mode` with
`read-only` or `workspace-write` before the first prompt. The phase doc's
"harnesses start in their conservative mode" is not true for Codex.

The prompt worked with the ChatGPT login:

```
<< {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"01a1175a-...","update":{"sessionUpdate":"agent_message_chunk","messageId":"msg_0edeb231...","content":{"type":"text","text":"pong"}}}}
<< {"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"totalTokens":16401,"inputTokens":3340,"cachedReadTokens":13056,"outputTokens":5,"thoughtTokens":0},"_meta":{"quota":{...,"model_usage":[{"model":"gpt-6-astra",...}]}}}}
```

Notification kinds: `available_commands_update` 1, `session_info_update`
3 (Codex `threadStatus` active then idle in `_meta`, then a `title`),
`agent_message_chunk` 1, `usage_update` 1 (`used: 16401, size: 258400`).

So Buzz's note that the Codex adapter needs an OpenAI key is out of date
for codex-acp 2.1.1. The ChatGPT login works.

## 4. goose through ACP

Provider: not configured. `~/.config/goose/config.yaml` (149 bytes, dated
Sep 1) contains only the bundled `developer` extension. There is no
`GOOSE_PROVIDER` or `GOOSE_MODEL` in it or in the environment
(`env | grep -E '^GOOSE_(PROVIDER|MODEL)'` printed nothing).
`GOOSE_DISABLE_KEYRING=1 goose info` shows the sessions DB as "missing
(can create)". Nothing was configured or edited.

`GOOSE_DISABLE_KEYRING=1 goose acp` with the driver in `new-only` mode
(`scratchpad/acp/goose-new.out`):

```
<< {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},"mcpCapabilities":{"http":true,"sse":false,"acp":false},"sessionCapabilities":{"list":{},"close":{}},"auth":{},"_meta":{"goose":{"localInference":{}}}},"authMethods":[{"id":"goose-provider","name":"Configure Provider","description":"Run `goose configure` to set up your AI provider and API key"}],"agentInfo":{"name":"goose","version":"1.43.0"}}}
<< {"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error","data":"Failed to resolve provider: Configuration value not found: GOOSE_PROVIDER"}}
```

`initialize` works without a provider. `session/new` fails until one is
configured. No prompt was sent. goose's `authMethods` entry is only a
hint to run `goose configure`; it is not an `authenticate` flow a client
could complete over the wire. For task 1 of the phase (test the Swift
client with no UI) goose needs a provider first, or use Claude or Codex,
which both worked.

## 5. Session resume

All three agents advertise `loadSession: true`. Two were tested with one
`session/load` each, in a fresh adapter process, after the original
process had exited.

Claude (`scratchpad/acp/claude-load.out`): `session/load` with
`sessionId: "9eaa3620-..."`, the same cwd and `mcpServers: []` replayed
the history as `session/update` notifications before returning:

```
<< {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eaa3620-...","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Reply with the single word pong."},"messageId":"4538362c-..."}}}
<< {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"9eaa3620-...","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"pong"},"messageId":"msg_011CfoFUEBSQRUcoWXWesmTG"}}}
<< {"jsonrpc":"2.0","id":2,"result":{"sessionId":"9eaa3620-...","modes":{...},"configOptions":[...]}}
```

stderr showed `[session/query] ... resume=9eaa3620-...` and the load took
about 3.5 s (`phase=session-ready totalMs=3485`). No model call was made.
(The driver itself exited 134 afterwards from a Python daemon-thread
shutdown race; the adapter was fine.)

Codex (`scratchpad/acp/codex-load.out`): `session/load` with
`sessionId: "01a1175a-..."` replayed `available_commands_update`,
`session_info_update` (title), `user_message_chunk` and
`agent_message_chunk` ("pong"), then returned the same `models`, `modes`
and `configOptions` shape as `session/new`.

goose: `loadSession: true` in capabilities, but no session could be
created, so `session/load` is unverified.

Note on versions: the current spec is a single integer, version 1
(https://agentclientprotocol.com/protocol/initialization: "If the Agent
supports the requested version, it MUST respond with the same version.
Otherwise, the Agent MUST respond with the latest version it supports.").
Version 2 is a draft. The TypeScript SDK 1.7.0 ships it under `v2/`
(`@agentclientprotocol/sdk/dist/v2/schema/index.js:40`
`PROTOCOL_VERSION = 2`), the TCK pins it at schema `2.0.0-alpha.5`
(`acp-tck/src/tck/v2/schema/VENDORED.md`), and buzz-acp already sends
`"protocolVersion": 2` (`crates/buzz-acp/src/acp.rs:135`). All three
adapters here answered `protocolVersion: 1` to a version 1 request.
`session/load` is the version 1 resume; `session/resume` and
`session/list` are version 2 draft methods that Claude and Codex also
expose through `sessionCapabilities`. Pin 1 now.

## 6. Swift ACP client options

Metadata from `gh api repos/<owner>/<repo>` and
`gh api repos/<owner>/<repo>/commits?per_page=1` on 2026-10-07. Line
counts from `find <clone> -name '*.swift' -not -path '*/Tests/*' | xargs wc -l`
on shallow clones in `scratchpad/acp/clones/`. Concurrency figures are
grep counts over `Sources/`. None of the four was compiled here, so
"builds under Swift 6 strict concurrency" is unverified for all of them.

| Package | Licence | Last commit | Stars | Tools version | Source lines | Test lines |
| --- | --- | --- | --- | --- | --- | --- |
| wiedymi/swift-acp | MIT | 2026-07-22 | 32 | 5.9 | 10,707 | 4,011 |
| aptove/swift-sdk | Apache-2.0 | 2026-04-25 | 11 | 6.0 | 10,857 | 7,923 |
| Cocoanetics/SwiftACP | BSD-2-Clause | 2026-10-02 | 2 | 6.1 | 49,869 (SwiftACP target 16,186; its `Client/` dir 10,614) | 37,945 |
| RayZhao1998/acp-swift-sdk | Apache-2.0 | 2025-12-17 | 4 | 6.2 | 4,794 | 7 |

Detail per package:

- **wiedymi/swift-acp.** Client and agent sides (`public actor Client`,
  `public actor Agent`, `ClientDelegate`). 14 actors, 256 `Sendable`
  mentions, 1 `@unchecked Sendable`, 3 `DispatchQueue`, 1 `NSLock`.
  `Sources/ACP/Transport/StdioTransport.swift:73` spawns the agent with
  `Process()`. Protocol version 1 (`protocolVersion: Int = 1`). No
  package dependencies. Four modules (ACPModel, ACP, ACPHTTP,
  ACPRegistry). Swift tools 5.9, so no Swift 6 language mode by default.
- **aptove/swift-sdk.** A port of the Kotlin SDK v0.15.2 (README).
  Client and agent (`public actor ClientConnection`,
  `public actor AgentConnection`). 3 actors, 171 `Sendable`, 3
  `@unchecked Sendable`, no `DispatchQueue` or `NSLock`.
  `StdioTransport` is `final class ... @unchecked Sendable` and takes
  streams; it does not spawn the process (only
  `TerminalOperations.swift` mentions `Process`). Protocol version 1
  (`Sources/ACPModel/ProtocolVersion.swift:18`). Depends on swift-log and
  swift-collections. Swift tools 6.0.
- **Cocoanetics/SwiftACP.** The most active and by far the largest.
  Client (`public final class ACPAgent`, `public actor
  ACPAgentConnection`, `Client/AgentProcessTransport.swift`,
  `Client/ChildSpawn.swift`), agent server, a daemon (`acpxd`), a CLI
  (`acpx`) and a mock agent. 12 actors, 636 `Sendable`, 88
  `@unchecked Sendable`, 10 `DispatchQueue`, 81 `NSLock`. Protocol
  version 1 (`Sources/SwiftACP/Protocol/Initialization.swift:6`).
  Depends on JSONFoundation (its own JSON-RPC stack), SwiftMCP,
  swift-argument-parser, swift-log and swift-service-lifecycle. Swift
  tools 6.1. Two stars; one author.
- **RayZhao1998/acp-swift-sdk.** Client and agent
  (`public actor ClientSideConnection`); `MessageStream.connectingProcess`
  spawns a `Process` (`Sources/ACP/Base/MessageStream.swift:45-50`).
  4 actors, 147 `Sendable`. Protocol version 1 (`PROTOCOL_VERSION = 1`).
  Only dependency is swift-docc-plugin. Swift tools 6.2. 7 lines of
  tests, no commits since December 2025.

What Peel needs from a client: spawn, `initialize`, `session/new`,
`session/load`, `session/prompt`, `session/cancel`, `session/set_mode`,
`session/set_config_option`, read `session/update`, answer
`session/request_permission`, reply `-32601` to `fs/*` and `terminal/*`,
and tolerate `_`-prefixed extension notifications. The Python driver that
did all of that against three harnesses is about 100 lines.

Recommendation: write our own. The surface is small, the protocol is
still moving (version 2 draft, extension `_meta` fields on every reply),
and the only package that is both Swift 6 and maintained (SwiftACP) brings
five dependencies, 88 `@unchecked Sendable` and a daemon we do not want.
If a package is wanted later, aptove/swift-sdk is the closest fit (Apache,
Swift 6 tools, actor connection, two small dependencies) but it is six
months stale and leaves process spawning to the caller anyway.

## 7. ACP TCK

`agentclientprotocol/acp-tck` (Apache-2.0, created 2026-09-18, 0 stars,
last commit 2026-10-02, Python, "experimental") tests agents only. Its
README opens with "It launches an agent implementation as a stdio
subprocess, drives it through the protocol". Everything after `--` on its
command line is the agent command; the TCK is itself the client. The
only client-named module,
`src/tck/v1/conformance/test_client_capabilities.py`, is a negative test
on the agent: the TCK advertises `clientCapabilities: {}` and checks the
agent never calls `fs/*`, `terminal/*` or `elicitation/create`. There is
no mode that connects to a client under test. It is useful to us only
indirectly: its v1 requirement list is a checklist of what agents will do
to our client, and `--protocol-version 2` runs against the draft schema.
For a buzz-agent or custom harness we would run it; for the Peel client we
test against real adapters as above.

## 8. buzz-acp as an always-on host

Shallow clone of `block/buzz` at `c96d707` (2026-10-07) in
`scratchpad/acp/clones/buzz`. `crates/buzz-acp` by `wc -l`:

| File | Lines | First `#[cfg(test)]` |
| --- | --- | --- |
| `src/lib.rs` | 13,477 | 2,444 (tests are interleaved; `run()` is at 2,718, `run_harness()` at 2,838) |
| `src/pool.rs` | 12,447 | 4,598 |
| `src/queue.rs` | 7,417 | 2,572 |
| `src/relay.rs` | 6,984 | 4,185 |
| `src/acp.rs` | 5,220 | 2,526 |
| `src/usage.rs` | 3,489 | 925 |
| `src/config.rs` | 3,216 | 1,536 |
| `src/setup_mode.rs` | 1,498 | 735 |
| `src/filter.rs` | 787 | 462 |
| `src/git.rs` | 783 | 421 |
| `src/scope.rs` | 461 | 172 |
| `src/pool_lifecycle.rs` | 312 | |
| `src/run_task.rs` | 285 | |
| `src/prompt_project.rs` | 264 | |
| `src/engram_fetch.rs` | 251 | |
| `src/acp_frame_writer.rs` | 233 | |
| `src/edit_routing.rs` | 180 | |
| `src/observer.rs` | 166 | |
| `src/runtime.rs` | 125 | |
| `src/prompt_framing.rs` | 112 | |
| `src/recovery_wake.rs` | 105 | |
| `src/isolated_execution.rs` | 95 | |
| `src/acp/launch.rs` | 83 | |
| `src/main.rs` | 3 | |
| other (`relay/`, `pool/`, `acp/*tests*`, `tests/`, docs, Cargo.toml) | about 3,600 | |
| **Total** | **61,867** | |

Roughly half of the big files is inline tests. The non-test core is in
the order of 20,000 lines, not the "few hundred lines" of host loop the
phase doc imagines. Dependencies (`Cargo.toml`): `nostr`, `buzz-core`,
`buzz-sdk`, `buzz-persona`, `git-credential-nostr`, `git-sign-nostr`,
tokio, tokio-tungstenite, reqwest, rustls, evalexpr, clap, toml.

Where things live:

- **ACP client**: `src/acp.rs`. `AcpClient::spawn`, `initialize`,
  `session_new`, `session_prompt_with_idle_timeout`, `session_cancel`,
  `cancel_with_cleanup` (module doc, lines 1 to 10). Bounded line reads
  via `LinesCodec::new_with_max_length`. Zero references to `nostr`
  (`grep -c nostr src/acp.rs` prints 0). Sends `"protocolVersion": 2`
  (line 135). **It auto-approves every `session/request_permission` with
  `allow_once`, falling back to `reject_once`** (`acp.rs:1265` and
  `handle_permission_request` at `acp.rs:2005-2045`). That is the opposite
  of Peel's gate and would have to be replaced, not configured.
- **Nostr relay client**: `src/relay.rs`. NIP-01 WebSocket, NIP-42 auth,
  REST channel discovery, NIP-98 signed HTTP, typing events
  (module doc). `HarnessRelay::connect` (line 765), `next_event` (980),
  `publish_event` (990), `discover_channels` (825), `subscribe_channel`
  (904), `RestClient::query` with `nostr::Filter` (493). The inbound unit
  is `BuzzEvent { connection_generation, channel_id: Uuid, event:
  nostr::Event }` (lines 593-602). 48 `nostr` references.
- **Main loop**: `run_harness` in `src/lib.rs:2838`. Connects with
  `HarnessRelay::connect` at 2,908 and selects on `relay.next_event()` at
  3,439. 155 `nostr` references in `lib.rs`.
- **Author gate**: `mod inbound_author_gate` at `lib.rs:534`.
  `author_allowed` (`lib.rs:569`) takes `RespondTo` (`Anyone`, `Nobody`,
  `OwnerOnly`, `Allowlist`), an allowlist `HashSet<String>` of hex
  pubkeys, and `is_dm`. DMs are owner-or-sibling only; owner resolution is
  `is_owner_or_sibling` (`lib.rs:383`) which fails closed with no owner
  and consults an `OwnerCache` plus `relay::RestClient` lookups. The
  author is `effective_prompt_author(event: &nostr::Event, ...)` at
  `lib.rs:509`, which is `event.pubkey.to_hex()` unless a verified workflow
  owner overrides it. Config: `respond_to`, `respond_to_allowlist`
  (`config.rs:486-491`).
- **Session scoping**: `src/scope.rs`. `SessionScope::Conversation {
  channel_id }` for DMs and channel policy, `SessionScope::Thread {
  channel_id, root_event_id }` for thread policy (lines 71-80). Derived
  once at admission from the operator `SessionPolicy`, whether the
  channel is a DM, and the event's NIP-10 thread tags (module doc).
- **Queue**: `src/queue.rs`. Per-scope queues, one in-flight prompt per
  scope, batch flush of all pending events for the oldest scope, dedup
  modes `Drop` (default) and `Queue` (module doc). `QueuedEvent` carries
  `scope`, `event: nostr::Event`, `prompt_tag` and edit routing (lines
  101-116). `parse_thread_tags(event: &Event)` at 1,392. 11 `nostr`
  references.
- **Timeouts**: `src/config.rs`. `DEFAULT_IDLE_TIMEOUT_SECS = 1_500`
  (line 31), `DEFAULT_MAX_TURN_DURATION_SECS = 7200` (line 35),
  `heartbeat_interval` (309), `turn_liveness_secs` (314),
  `heartbeat_prompt` (322), `max_turns_per_session` (398),
  `exit_after_inactivity` (512), `idle_pool_sleep` (523). Enforced in
  `acp.rs` (`session_prompt_with_idle_timeout`) and `pool.rs`
  (`TimeoutKind`, line 701).
- **Pool**: `src/pool.rs`. N `AcpClient`s, claim and dispatch, panic
  recovery, steering (module doc). Holds `agent_keys: nostr::Keys` and
  `agent_owner_pubkey: Option<nostr::PublicKey>` (lines 923-926) and runs
  `nostr::Filter` queries for canvas and guideline events (3,678 to
  3,948). 74 `nostr` references, 43 `buzz_core` references (event kinds
  such as `KIND_CANVAS`, `KIND_STREAM_MESSAGE`, turn metrics).
- **Outbound messages**: built with `buzz_sdk::build_message`,
  `build_reaction`, `build_agent_observer_frame`, `ThreadRef`, and signed
  with the agent's `nostr::Keys` before `publisher.publish_event`
  (`lib.rs:1828`, `1955`).

Coupling, honestly: only `acp.rs`, `acp_frame_writer.rs`, `acp/launch.rs`
and the timeout config are transport-free. `relay.rs` is entirely Nostr.
`lib.rs`, `pool.rs`, `queue.rs`, `scope.rs`, `filter.rs`, `setup_mode.rs`
and `edit_routing.rs` all take `nostr::Event`, `nostr::Keys` or
`nostr::PublicKey` directly, and the policy layer reasons in Buzz event
kinds and NIP-10 tags. There is no transport trait to implement.

Could a Sphinx transport replace the relay client? Not as a swap. It is a
fork in which:

1. `relay.rs` is rewritten against the Sphinx core (sphinx-rs bindings in
   Rust; not evaluated here, unverified) exposing the same shape:
   `next_event`, `publish_event`, owner lookup.
2. An inbound event type replaces `nostr::Event` in `BuzzEvent`,
   `QueuedEvent`, `scope.rs` and the author gate. Sender pubkey comes from
   the Sphinx message signature instead of `event.pubkey`; thread root
   comes from the Sphinx thread uuid instead of NIP-10 tags.
3. `pool.rs` loses its Nostr key types and the canvas/guideline filter
   queries, or they are reimplemented over Sphinx message history.
4. Outbound `buzz_sdk` builders become Peel's typed message JSON.
5. `handle_permission_request` is replaced by a round trip to the owner
   over Sphinx, with the queue holding the turn open.
6. `setup_mode.rs`, `git-credential-nostr`, `git-sign-nostr`, NIP-98 and
   `engram_fetch.rs` are dropped or replaced.

Reusable as-is: the ACP client (about 2,500 non-test lines), the queue
state machine once the event type is abstracted, the pool's claim and
dispatch and timeout kinds, the config defaults, and the policy shape
(`RespondTo`, `SessionPolicy`, `SessionScope`). My estimate is that more
than half of the non-test code would be touched, and the result would
inherit a Rust engine with sphinx-rs that Peel does not yet have. Buzz is
best used as the reference for rules and defaults (owner-only, one
in-flight per scope, 1,500 s idle, 7,200 s max turn, heartbeat prompt),
which is what phase 9 already says, rather than as a codebase to fork
first.

## 9. Cost of a child account

Source: `~/Documents/sphinx` at `caa76a12` (2026-09-25), read only.
Whether production runs this revision is unverified.

The invite is optional in the request type. `mixer/src/http.rs:70-77`:

```rust
pub struct RegisterReq {
    pub root: String,
    pub pubkey: String,
    pub idx: String,
    pub sig: String,
    pub ms: String,
    pub code: Option<String>,
}
```

The route is `#[rocket::post("/register", data = "<body>")]` at
`http.rs:79`, and it passes `body.code.as_ref()` to
`routes::register(... code_hex: Option<&String>)` (`http.rs:102-103`,
`routes.rs:172-180`).

Whether a code is required depends on whether the root already exists
(`routes.rs:244-285`):

- `root_exists = db.check_root_exists(&root_slice)` (line 244). A child
  account registers with the master's `root` and a new `idx`, so for the
  second and later children of a registered root this is true, and the
  whole invite block is skipped: `} else { 0 }` at lines 283-284 sets
  `initial_msats = 0` and no code is checked.
- For a brand-new root with `invite_price() > 0` (line 248), the server
  calls `is_peer` (with a 5 s timeout, fail-safe to "require code"); a
  peer registers free, otherwise `redeem_initial_amt(code_hex, db)` at
  line 274 requires a code (`routes.rs:101-105`: `"invite code
  required"`, then `db.redeem_invite`).
- For a brand-new root with `invite_price() == 0`, the code is optional
  (lines 276-281: a failed redeem falls back to 0).

What it costs: the register route itself charges nothing. It writes the
scid mappings and then `db.incr_balance(scid, initial_msats)`
(`routes.rs:331`), which for a child is 0 msats. So a child account is
free to register and starts with a zero balance; it has to be funded by
keysend from the master afterwards (agent-native spike 1).

The price only exists for new roots and lives in the invite. The invite
is bought by keysend (`mixer/src/ping.rs:58-68`): the inviter's
`amt_received` must exceed `invite_price()`, and the invitee's starting
balance is `amt_received - invite_price()`. `invite_price()` reads the
`INVITE_PRICE` environment variable with a default of `0`
(`ping.rs:150-153`). The production value is not in the source and was
not queried (unverified). It is public: `GET /info` returns
`{ pubkey, invite_price }` (`http.rs:33-43`), so Tom can read it from the
production mixer himself without side effects.

Caveat: this is the mixer's view. The official apps may require an invite
in their own registration flow regardless; that is outside this file.

## Summary of what changes in phase 9

- Pin adapter versions in the harness registry. `npx -y` without a version
  served a stale 0.49.0 here.
- Claude Code: subscription login works through ACP, `authMethods: []`,
  no `authenticate`. Set `model` explicitly and give the agent its own
  config home, or every turn carries Tom's user context (40k tokens).
- Codex: ChatGPT login works through ACP. Default mode is `agent`, not
  read-only; set the mode before the first prompt.
- goose: no provider configured, so only `initialize` works today.
- Permission: `session/request_permission` offers `allow_once`,
  `allow_always`, `reject_once`; reject works and nothing is written.
- Resume: `session/load` replays history for Claude and Codex.
- Client: write our own, pinned to protocol version 1, tolerant of
  `_meta` and `_`-prefixed notifications.
- Buzz: adopt its rules and defaults; do not fork `buzz-acp` for the host.
  Its ACP client auto-approves permissions, and the rest is Nostr-typed.
- Child accounts: free to register under an existing root, no invite,
  zero starting balance.
