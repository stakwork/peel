# Peel and the sovereign agent

Last updated 2026-10-08. How Peel relates to the two Hive pages "Sphinx Personal
Agent vs. the Market" and "Sovereign Sphinx Agent: build plan and decisions",
and the rules that keep Peel's engine ready for an agent.

The agent's design (one agent contact, the agent host, Strut, the graph,
workers over ACP, the permission gate) is now in
[agent-architecture.md](agent-architecture.md), agreed with Tom on
2026-10-08. Where the two overlap, that file wins; this one keeps the
engine rules, the corrections to the Hive pages and the spikes.

## Where Peel sits

The two pages describe a product: you hold one identity, you chat to a chief of
staff, and it runs always-on agents that each have their own key, wallet,
budget and memory. Peel narrows that to one agent contact, the chief of
staff, with workers behind it that are not contacts
([agent-architecture.md](agent-architecture.md)). The build plan assumes those features land in the official
Sphinx apps. Peel replaces that assumption: Peel is the interface, and its
engine is the Sphinx client that the agents run on.

So Peel has two jobs:

1. **v1: a cleaner Sphinx client** with the capabilities in the v1 scope, and
   nothing else from the official apps.
2. **The base for the agent.** Every decision in v1 should keep the agent
   work possible without a rewrite.

## The shape

```
 You (master seed, on your devices only)
 ┌──────────────────────┐   ┌──────────────────────┐
 │ Peel on Mac          │   │ Peel on iPhone       │   your account,
 │ UI + engine          │   │ UI + engine          │   one device each
 └──────────┬───────────┘   └──────────┬───────────┘
            │      Sphinx messages     │
            ▼  (onion-routed, via mixer)  ▼
 ┌─────────────────────────────────────────────────┐
 │ Agent host (desktop now, home server or cloud)  │
 │  engine: the agent's own account                │
 │  agent loop · Strut jobs · ACP workers · tools  │
 │  LadybugDB graph (host is the only writer)      │
 │  budget and permission gate, outside the model  │
 └─────────────────────────────────────────────────┘
```

- **The agent is a Sphinx account.** It has its own seed (from an invite
  now, a child seed later), its own balance at the mixer, and it is one
  contact in your list. You talk to it by DM, in threads. Workers such as
  Claude Code run behind it and are not contacts.
- **No private API between the app and the host.** Instructions, approvals,
  reports and receipts travel as Sphinx messages. The host can move between
  desktop, home server and cloud without the app changing. During the
  transition agents also work with the official apps, as plain text.
- **The phone is not the runtime.** Your account does not need to be always on:
  the server queues messages. Only the agent accounts need an always-on host.
- **One engine, two hosts.** The app and the agent host run the same engine:
  the core contract, the transport, storage and the message conventions.
  This is the main architectural constraint on Peel today. The host is
  phase 9.

## What this changes in Peel now

These are rules for v1 work, not new features.

1. **The engine is headless and multi-account.** No UI types, no global
   state, no single-account assumption in `PeelCore`. The host runs one
   agent account now and may run more later in one process.
2. **Every user action is an engine operation.** The UI only calls typed
   operations (send, pay, add contact, join tribe). The same operations become
   the agent's tools, behind one permission and budget gate. If a capability
   lives only in a view, an agent cannot use it.
3. **Message conventions live in the engine.** Attachments, threads, boosts,
   paid messages: phases 2 to 5 are mostly protocol work. Write it once, where
   both the app and the host can use it.
4. **Agent message types need a convention.** Choice cards, approval requests
   and receipts become new message JSON that falls back to readable text in
   the official apps. Decided: versioned JSON under a `peel` key of the
   message `metadata` object (phase 9, "Message shapes").
5. **Contacts have a kind:** person, your agent, someone else's agent. Your
   agent is one contact in Direct messages, with the AGENT label.
6. **Fix child-seed derivation before any child exists.** Changing it later
   breaks restore for every agent.

## Engine language: Swift (decided 2026-10-07)

The engine stays Swift. Peel is first Tom's own client and a place to
experiment with agents; it may replace the official apps for his team later,
if it is clean, bug-free and secure. Swift keeps one language while we learn
what the agent needs.

Later, the always-on part may move to a separate engine, possibly in Rust on
`sphinx-rs`, in its own repo. The rules above keep that move cheap: the engine
has no UI types and every action is an engine operation, so a different engine
can sit behind the same interface.

## Corrections to the two pages

Checked against the code on 2026-10-07.

- **The signer policy does not cover chat accounts.** The `glyph` policy
  (`msat_per_interval`, `htlc_limit_msat`) belongs to the VLS signer for a node
  the user runs (`sphinx-rs/signer`). A chat account's balance is a ledger
  entry at the mixer (`sphinx/mixer/src/db/balances.rs`), and payments go
  through the mixer's node. Decisions 3 and 10 need rewriting: the hard cap is
  the child's balance (enforced by the mixer ledger, funded by top-up), and
  any rate limit is enforced by the agent host's code, outside the model, or
  by a mixer change.
- **"No operator in the middle" is too strong.** Message content is
  onion-routed, but the mixer operator holds every account's balance and sees
  timing and amounts. The custody risk in the build plan applies to every
  funded agent.
- **Master agent or chief of staff.** The build plan makes the master agent
  "you" with the master seed; the market page makes the chief of staff a
  contact with its own key. Peel takes the second: the master seed never
  reaches a runtime, and the agent is its own account. How that account is
  made (an invite now; a child derived on your device, or a separate agents
  root, later) is decision 8 in
  [agent-architecture.md](agent-architecture.md).
- **The interface is Peel, not the official apps.** Phases 1 and 2 of the build
  plan land in Peel and the agent host.
- **An invite may not be needed for a child account.** `routes::register` in
  the mixer takes the invite code as optional. Read in the source on
  2026-10-07: a child of a registered root registers free with no invite
  (`research/acp-harnesses.md`, section 9). Check on production.

## Spikes before deciding

1. Derive a hardened child seed from the master (BIP-85 style), register it on
   the server without an invite, keysend from master to child.
2. Run two engines (two accounts) in one process against the local test server.
3. Find what one message costs an agent, in sats and latency, through the mixer.
4. Prototype one agent message type (a choice card) that reads as plain text in
   the official Mac app.

The chef story on the market page stays the acceptance test.
