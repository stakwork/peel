# Runner as the agent's Sphinx bridge: spike findings

Date: 2026-10-16. Question: can `sphinx/runner` (stakwork/sphinx, `runner/`)
become the bridge that holds the agent's Sphinx account on the brain
(foundation.md, decision 1, "B, with a Rust bridge")? Goal for the spike: on
the local test stack, runner receives a message from a Peel development
profile and its reply shows up in that profile's chat.

**Short answer: yes, and with less code than expected.** The core already
ships a full stateful client behind a cargo feature (`bindings`, the same
API the apps and the wasm reference client use). Switched onto it, runner
registered, answered Peel's key exchange, echoed messages back as threaded
replies, and caught up on what arrived while it was offline. That took
about 360 new lines in runner and no core changes.

This was learning only. The code is on the branch `spike/runner-reply`
(commit `0091640e`), opened as a draft PR for Evan to read, not to merge:
[stakwork/sphinx#382](https://github.com/stakwork/sphinx/pull/382). Evan
and Tomas own that repo, and whether the bridge belongs in runner is
Evan's call.

## What was run

- Stack: `scripts/test-stack.sh start` on random ports (broker, tribes
  server, a `NO_LIGHTNING` auto-mining mixer in `fund` mode, the memes
  stub), from the binaries already built in `~/sphinx-target/debug`.
- Runner: built from the spike branch with `RUNNER_MODE=bridge`, given a
  fresh `openssl rand -hex 32` seed through its `/seed` admin endpoint,
  network `bitcoin` (what `peel init` uses on a loopback server).
- Peel: the CLI (`.build/debug/peel`, from the main checkout, not rebuilt),
  a new development profile `spike-runner-human`. Never `default`, and
  `run-app.sh` was never run.
- Funding: `peel add` needs 6 sats, and `scripts/fund-dev.sh` needs a
  `swift test` build. A `fund` mixer never debits senders, so runner
  keysent the profile 20,000 test sats on start, behind a test-only
  `RUNNER_TESTING_FAUCET` variable. That only works on this stack.

The journey, as Peel's CLI showed it:

```
peel add <runner contact info> Agent      ->  contact 02bffbea…  ready
peel send 02bffbea… "second try: ping"
  <- 02bffbea  Agent: echo: second try: ping
     in reply to me: second try: ping
(runner stopped)
peel send 02bffbea… "sent while agent offline"
(runner started again)
  <- 02bffbea  Agent: echo: sent while agent offline
     in reply to me: sent while agent offline
```

That first catch-up started from index 0, so it also answered the two
earlier messages again, one of them already answered live. Once the index
was stored, a further restart answered nothing twice.

## What the diff took

`runner/` only, +379 / −5 lines:

| File | What |
|---|---|
| `Cargo.toml` | the core's `bindings` feature, and `rmp` |
| `src/main.rs` | `RUNNER_MODE=bridge` starts `bridge::run` instead of today's MQTT handler; the Jarvis path is untouched |
| `src/bridge.rs` (277) | the client: `set_network` once, then `initial_setup` (register, balance, subscriptions) on every start; every MQTT message goes through `bindings::handle`; each `RunReturn` is applied the way `wasm/test/auto/main.ts` `handle_rr` does (state first, then settle, register, asyncpay and topic publishes); a type-0 message from someone else gets `bindings::send` back with `replyUuid` set; catch-up after register; a blockheight refresh every 5 s |
| `src/db/state.rs` (86) | the core's state map in redb, as one msgpack blob, and the highest server index handled |

One lock puts core calls in order, so each sees the state the last one
wrote. That is the same contract as Peel's `Engine.run`.

Four things only showed up by running it:

1. **`Msg.sender` is the sender's JSON** (`{"pubkey", "route_hint",
   "alias", …}`), not a pubkey. The first reply went nowhere until runner
   parsed it.
2. **Stale blockheight breaks payments.** Runner only learned the height
   when it registered. The test mixer mines about a block a second, so a
   few minutes later runner's paid key-exchange answer failed at the mixer
   with "Outgoing CLTV value is too soon". Asking for `get_blockheight`
   every 5 s fixed it. On mainnet blocks are minutes apart, but a bridge
   that stays up for weeks still needs to follow the height (the
   `blockheight` topic, or the same poll).
3. **A failed handle drops the message.** The first message arrived while
   the sender bug was live, and nothing retried it. Catch-up only answered
   it because the stored index started at 0. A real bridge must move its
   index only after the reply is out, and retry what failed.
4. **Publishes before the MQTT client connects are lost.** The core's
   `mqtt_client` only reads its publish channel once it is connected, so the
   first blockheight request logged "pub failed: channel closed". The same
   applies during every reconnect.

The account's own register and a new contact's register share a topic (a
key exchange registers a new child index). Start-up work has to check child
index 0 in the topic, or it runs again for every new contact. The faucet
did, and paid twice.

## Where strut plugs in

The seam is `Bridge::reply(to, text, reply_uuid)`. Today `handle` calls it
with `"echo: " + text`. With strut, following
[agent-on-strut.md](../agent-on-strut.md) ("The layers"): the contact is a
pipe, and the orchestrator is a strut workflow, `peel-agent` (strut's
`agent` step with Peel's prompt and tools). It answers small things itself
and starts or continues `job` for bigger work.

```
Sphinx msg (owner -> agent)
  bridge.handle: owner only; store uuid -> run id once known
  POST {STRUT_URL}/workflows/peel-agent/run
       {input: {prompt: text, session: "peel/agent-1/dm", context},
        callback: {url: http://<bridge>/runs/done, token}}
    -> 202 {runId}      (session_busy: queue the message for the next turn)
  ... the orchestrator runs the turn ...
strut run.end callback -> POST /runs/done  {status, output: {text, artifacts, ask?}}
  bridge: look up runId -> (sender, uuid); reply(sender, text, uuid)

  orchestrator, for bigger work: job/start or job/continue (detached),
    with the bridge as the job's callback
strut run.end callback -> POST /runs/done  {status, output: {text, artifacts, ask?}}
  bridge: the job's result, ask or artifacts as a message in the DM
```

The bridge knows one workflow name, set by Peel at launch, and never picks
a job itself. Strut runs one turn at a time per session (`session_busy`),
so the bridge queues the owner's next message until the turn ends. The
session is the DM's thread, for example `peel/agent-1/dm`. Jobs reach the
bridge another way. The orchestrator starts them detached with the new
strut steps `job/start` and `job/continue` (PR S2 in agent-on-strut.md),
and names the bridge as their callback. So the one `run.end` route takes
both the orchestrator's replies and the jobs' results, `ask`s and
artifacts. Both use `job`'s reply shape, `{text, artifacts, ask?}`.

Runner already has the parts this needs: a Rocket server with a
constant-time admin token check (`AdminAuth`) for the `run.end` route,
reqwest for the call out (`workflow.rs` already posts a Stakwork workflow),
and redb for the `runId -> (sender, uuid)` map. A "working on it" message,
streaming and `ask` as a Sphinx message shape are the next design
question. They are not bridge plumbing.

## What a real bridge still needs

Sizes: S is under a day, M a few days, L a week or more, for someone who
knows the core.

| Part | State after the spike | Missing | Size |
|---|---|---|---|
| Key exchange | Works; the core answers a paid ContactKey on its own, and only allowlisted senders get answers | A starting balance before pairing. The agent's answer costs 3 sats and a 1-sat ping, and the mixer passes the owner's ContactKey to the agent before crediting its 5 sats, so an agent with 0 sats is refused "not enough balance" (corrected 2026-10-17, "After review" below). Peel's PR 4 registers the agent with a 10-sat invite from the owner (stakwork/sphinx#385). | — |
| Contact handling | Answers anyone who completes a key exchange | Only the owner (and later allowlisted people) start strut runs. `db/senders.rs` is the allowlist runner already has. The owner's key is known at pairing. The alias is from `RUNNER_ALIAS`; a photo goes through the same call (`my_img`). | S |
| Reconnect and catch-up | Catch-up by server index works across restarts | Retry and move the index only on success (finding 3); an outbox for publishes made while disconnected (finding 4); fresh broker credentials on reconnect: `mqtt_client` reuses the signed timestamp it was started with (not tested whether the broker rejects an old one). The last two are in the core's `mqtt_client`, which the mixer and tribes server share, or runner owns its own client loop. | M |
| Store | Whole state as one blob, rewritten on every call | One redb row per state key (the graph and hops entries grow); `runId -> message` for jobs; nothing else. The conversation itself lives in strut and on the owner's devices. The bridge keeps no chat history. | S |
| Attachments | Not tried | Strut artifacts out and files in: the memes server's signed token, upload, the media key in the message (official apps' JSON conventions, AGENTS.md "How the core works"). The core has `bindings::media` for the token. | M–L |
| Control messages | Echo only answers type 0; the rest are stored by the core and ignored | Read receipts (`bindings::read`), deletes, boosts and payments to the agent (refuse or keep?), tribe messages if the agent ever joins one, and the `ask` / approval shapes the agent-native rules need. Each is small once its shape is chosen. | S each |
| Account from the user's words | A random seed through `/seed` | The derived seed, set by Peel at pairing through the admin endpoint (decision 2's contract). `/seed` already refuses to replace a seed. | S, once the derivation is agreed |
| Sphinx tools for strut | None | Read, send and pay as bridge HTTP routes strut calls, behind the approval gate. | M |
| strut call and callback | Sketched above | The `run.end` route for the orchestrator and for jobs, the map, `session_busy` queueing, strut's auth (`STRUT_API_KEY`). | S–M |

## For and against hosting it in runner

For:

- It already has the shape a bridge needs: a seed set once through a
  guarded admin endpoint, redb, a Rocket server with admin auth, an MQTT
  client, a Dockerfile, and it builds on Linux.
- It sits in the core's workspace with the core as a path dependency, so it
  builds against the core it ships with. The full client was a feature flag
  away.
- The work is small: the spike is about 360 lines, and the table above is
  mostly policy, not plumbing.

Against, or to settle with Evan:

- Runner's current job (Jarvis triplets, the Stakwork podcast workflow,
  transcripts, S3) has nothing to do with the agent. A bridge mode makes it
  two programs in one binary. A sibling crate in the same workspace (say
  `sphinx/bridge`) would keep the same advantages without that, and runner's
  db, http and Dockerfile could be copied or shared.
- Two cores in the field. Runner builds against sphinx master; Peel pins
  the core through a sphinx-rs release (`scripts/build-ffi.sh`). Today
  they are the same commit (`4d6da519`, sphinx-rs v0.8.38), but they will
  drift, and every core change needs checking against both.
- The weak spots found here (findings 2 to 4) are in the core's
  `mqtt_client` and in how a long-lived client uses the core. Fixing them
  well means core changes that the mixer and tribes server share, in a
  repo the Peel side does not own.
- The core keeps its state encoding private (`bindings::rmp_utils`), so
  the spike copies 25 lines of it. Exporting it would be a one-word core
  change.
- Old dependencies (Rocket `0.5.0-rc.1`, reqwest 0.11); not a blocker.

## Recommended answers for Evan

These are recommendations to put to Evan, not decisions. Tom agreed the
funding flow on 2026-10-16. They are the two questions
[agent-on-strut.md](../agent-on-strut.md) leaves open for Evan (B1's home,
PR 10's derivation), plus the core change B1 would need. A sibling crate
works the same whether Peel.app bundles the bridge (Phase 1) or a brain
runs it (Phase 2).

**1. Where the bridge lives: a new crate beside runner, say
`sphinx/bridge`, not a mode inside runner.** It keeps what makes runner a
good base: it builds against the core in the same workspace, runs on
Linux, and gets a Dockerfile. Runner's db, admin-token HTTP and seed
endpoint can be copied across, and its Jarvis and podcast work stays out.
Evan reviews it in his repo, but it ships on its own and cannot break
runner.

**2. How the agent's account is derived: one keyed hash of the account's
seed, with a fixed label and a number.** For example, HMAC-SHA256 keyed
with the account's 32-byte seed over `sphinx-agent/0`, with the number
leaving room for more agents later (foundation.md's `agent/<n>` entry).
The words always recover the agent's account, and the brain only ever
holds the agent's seed (decision 3, A). It stays out of the core's own key
tree, which numbers a child key per contact, so it can never collide with
one. Shared test vectors in Swift and Rust prove that Peel and the bridge
reach the same account. The question for Evan is whether he knows a
reason to use the core's key tree instead.

**3. Changes to the core's connection code: mostly none; the bridge runs
its own connection loop.** The fixes the spike needs (a send queue while
disconnected, fresh broker credentials on reconnect, following the
blockheight, moving the index only after a reply is out) can all live in
the bridge, so nothing changes for the mixer or tribes server. The one
core change to ask for is exporting the state encoding
(`bindings::rmp_utils`), so the bridge does not keep a copy.

### Who funds the agent

Setting up the agent is one step, like pasting an API key the first time:

1. In Peel, "Set up agent".
2. Peel derives the agent's account and hands its seed to the brain
   through the bridge's admin endpoint.
3. Peel adds the agent as a contact. The agent needs sats to answer:
   the exchange's own 5 sats arrive only after the agent has answered
   (corrected 2026-10-17, "After review" below), so the agent registers
   with an invite from the owner (10 sats in PR 4) and starts with them.
4. The account pays the agent a starting balance the person picks (say
   1,000 sats). It shows as a payment in the chat with the agent.

Creating a Sphinx account does not change: the agent costs nothing until
it is set up. The starting balance is for what the agent pays for later
(tribe messages, the pay tool), not for pairing.

## After review

The spike then went through `/code-review`, `/simplify` and
`/security-review`, and the draft (stakwork/sphinx#382) was updated:

- **Findings 3 and 4 are fixed in the spike.** Handled messages are kept by
  uuid, and each reply commits in the same transaction as its mark. One
  failure no longer stops a batch. Catch-up pages from a cursor that only
  history moves, and the cursor stops below a failure. An outbox holds
  publishes until `mqtt_client` listens again.
- **Finding 2 was the test mixer.** With `NO_LIGHTNING` nothing published
  the blockheight while `TESTING_ONLY_AUTO_MINE` raised it every second.
  The mixer now republishes it every 5 s in that mode, and the bridge's
  poll is gone. In production the mixer already republishes every 30 s.
- **Only allowlisted senders get answers** (runner's existing
  `add_sender`). Logs carry message uuids, never text. The state is one
  redb row per key, and a row that cannot be read stops the bridge instead
  of starting it empty.
- **The core and runner helpers are reused.** The core's state encoding is
  re-exported (a two-line core change) instead of copied, along with its
  `Sender`, `Message` and `MsgType`, and runner's MQTT login. The test
  faucet is gone.

It was retested on a fresh local stack, with the mixer charging senders
for real after `scripts/fund-dev.sh` funded the owner:

- **Key exchange:** the agent started at 0 sats and answered. **Corrected
  2026-10-17 (PR 4): that was timing.** The mixer forwards the owner's
  ContactKey to the agent before it credits the 5 sats the exchange
  carries, so the agent's paid answer (3 sats and a 1-sat ping) can reach
  the mixer while the agent still has 0 and is refused "not enough
  balance". Nothing retries it, and a restart does not replay it. In PR
  4's journey with real accounting it failed every time. The agent now
  registers with an invite from its owner and starts with sats
  (stakwork/sphinx#385).
- **Echo:** worked as a threaded reply.
- **Allowlist:** a message sent while the owner was off the allowlist was
  ignored, then answered by the next catch-up once they were back on it.
- **Offline:** a message sent while runner was down was answered on
  restart.
- **Restarts:** a second restart answered nothing twice.
- **CLTV:** no failures.

Still open: the outbox is in memory and publishes are QoS 0, so a crash
or a drop mid-publish can still lose a reply. `mqtt_client` also reuses
its first login on every reconnect.

## Left behind

- The draft PR stakwork/sphinx#382 and its branch `spike/runner-reply`, to
  close and delete once Evan has read it.
- The sphinx worktree `~/Documents/sphinx-runner-spike`. Remove it with `git
  -C ~/Documents/sphinx worktree remove ../sphinx-runner-spike` and `git -C
  ~/Documents/sphinx branch -D spike/runner-reply` once it is no longer
  needed.
- The development profiles `spike-runner-human` and `spike-bridge-owner`
  under `Peel/dev`. Their stacks no longer exist.
- The stack is stopped, its ports are free, and the 1.4 GB build directory
  is deleted. An older stack from 2026-10-15 (ports 62618 to 62622) was
  already running and was left alone.
