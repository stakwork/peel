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

This was learning only. The code is on a local branch, `spike/runner-reply`,
in a separate worktree of `~/Documents/sphinx` (commit `0091640e`). It was
not pushed, and no PR was opened on stakwork/sphinx: Evan and Tomas own
that repo, and whether the bridge belongs in runner is Evan's call.

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
with `"echo: " + text`. With strut, following jobs-architecture.md:

```
Sphinx msg (owner -> agent)
  bridge.handle: owner only; store uuid -> run id once known
  POST {STRUT_URL}/workflows/job/run
       {job: <conversation id>, title, input: {prompt: text},
        callback: {url: http://<bridge>/jobs/done, token}}
    -> 202 {runId}      (job_busy: queue the message for the next turn)
  ... strut runs the turn ...
strut run.end callback -> POST /jobs/done  {status, output: {text, artifacts, ask}}
  bridge: look up runId -> (sender, uuid); reply(sender, text, uuid)
```

Runner already has the parts this needs: a Rocket server with a
constant-time admin token check (`AdminAuth`) for the `/jobs/done` route,
reqwest for the call out (`workflow.rs` already posts a Stakwork workflow),
and redb for the `runId -> (sender, uuid)` map. Which job a message belongs
to is decided by the front agent, which is a strut workflow (decision 1). So
the bridge passes every owner message to one job per conversation, and
strut does the routing. A "working on it" message, streaming and
`ask` as a Sphinx message shape are the next design question. They are not
bridge plumbing.

## What a real bridge still needs

Sizes: S is under a day, M a few days, L a week or more, for someone who
knows the core.

| Part | State after the spike | Missing | Size |
|---|---|---|---|
| Key exchange | Works both ways; the core answers a paid ContactKey on its own | **The agent pays to answer.** The core's answer to a ContactKey costs PRICE_TO_MEET (3,000 msat) plus a ping. Here the `fund` mixer hid that; on a real server an unfunded agent cannot accept its owner. Something must fund the agent account: the owner keysends it on pairing, or the bridge adds the owner itself, so the owner pays. | S (funding: "Who funds the agent" below) |
| Contact handling | Answers anyone who completes a key exchange | Only the owner (and later allowlisted people) start strut runs. `db/senders.rs` is the allowlist runner already has. The owner's key is known at pairing. The alias is from `RUNNER_ALIAS`; a photo goes through the same call (`my_img`). | S |
| Reconnect and catch-up | Catch-up by server index works across restarts | Retry and move the index only on success (finding 3); an outbox for publishes made while disconnected (finding 4); fresh broker credentials on reconnect: `mqtt_client` reuses the signed timestamp it was started with (not tested whether the broker rejects an old one). The last two are in the core's `mqtt_client`, which the mixer and tribes server share, or runner owns its own client loop. | M |
| Store | Whole state as one blob, rewritten on every call | One redb row per state key (the graph and hops entries grow); `runId -> message` for jobs; nothing else. The conversation itself lives in strut and on the owner's devices. The bridge keeps no chat history. | S |
| Attachments | Not tried | Strut artifacts out and files in: the memes server's signed token, upload, the media key in the message (official apps' JSON conventions, AGENTS.md "How the core works"). The core has `bindings::media` for the token. | M–L |
| Control messages | Echo only answers type 0; the rest are stored by the core and ignored | Read receipts (`bindings::read`), deletes, boosts and payments to the agent (refuse or keep?), tribe messages if the agent ever joins one, and the `ask` / approval shapes the agent-native rules need. Each is small once its shape is chosen. | S each |
| Account from the user's words | A random seed through `/seed` | The derived seed, set by Peel at pairing through the admin endpoint (decision 2's contract). `/seed` already refuses to replace a seed. | S, once the derivation is agreed |
| Sphinx tools for strut | None | Read, send and pay as bridge HTTP routes strut calls, behind the approval gate. | M |
| strut call and callback | Sketched above | The route, the map, `job_busy` queueing, strut's auth (`STRUT_API_KEY`). | S–M |

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
  the core by hash (`bd9e140` plus the sphinx-rs release in
  `scripts/build-ffi.sh`). Text, key exchange and catch-up worked between
  them today, but every core change would need checking against both.
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
3. The account pays the agent a starting balance the person picks (say
   1,000 sats). It shows as a payment in the chat with the agent.
4. The agent adds its owner as a contact, and Peel answers on its own.

Creating a Sphinx account does not change: the agent costs nothing until
it is set up. The starting balance covers the agent's side of the key
exchange (3,000 msat plus a ping) and what it pays for later (tribe
messages, the pay tool).

## Left behind

- The sphinx worktree `~/Documents/sphinx-runner-spike` on local branch
  `spike/runner-reply`. Delete it with `git -C ~/Documents/sphinx worktree
  remove ../sphinx-runner-spike` and `git -C ~/Documents/sphinx branch -D
  spike/runner-reply` once it is no longer needed. The patch is also in the
  session notes folder, `runner-bridge-spike.patch`.
- The development profile `spike-runner-human` under `Peel/dev`. It was on
  a stack that no longer exists.
- The stack is stopped, its ports are free, and the 1.4 GB build directory
  is deleted. An older stack from 2026-10-15 (ports 62618 to 62622) was
  already running and was left alone.
