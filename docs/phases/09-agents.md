# Phase 9 — Agents as contacts: any ACP harness behind a Sphinx identity

Status: planned. Decided 2026-10-07 after reading Block's Buzz. Comes after
the audit (phase 8) and after the real account has moved over. Tasks 1 and 2
can run earlier as spikes on the throwaway account.

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
Block's Buzz (`block/buzz`, July 2026) connects agents the same way; its
harness in `crates/buzz-acp` is the reference for the host loop below.

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
  buzz-agent. A custom harness is one JSON file: id, label, command, args,
  env, install hint. Peel probes PATH for availability and shows the install
  hint when a harness is missing.
- **ACP client, in Swift.** Spawns the harness; `initialize`; `session/new`
  with the working directory and the MCP servers the grant allows;
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
  card for each permission request, with the four ACP answer kinds; result
  cards. The header shows folder, mode, harness, running or idle, Stop and
  New session.

## Message shapes

- A task is plain text in the DM. A reply inside a Sphinx thread goes to that
  thread's session.
- Ask cards and their answers are typed JSON in a text message with a readable
  fallback, so the official phone app can still answer during the transition.
  An answer counts only when its signature recovers the owner's pubkey. The
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
- Grants per agent: harness, folders, mode. Harnesses start in their
  conservative mode. Automatic approval is allowed only for a read-only
  configuration, and Peel never passes "skip permissions".
- Permission requests reach a person, in the app or on the phone. "Allow
  always" lasts for the session, never beyond the grant.
- Every task, answer and result is visible in the conversation and logged.
- Revoking a grant drops the agent's queue and cancels its sessions.

## Open questions

- **Subscription or API key.** Buzz's docs run the Claude adapter with an API
  key and say the Codex adapter needs an OpenAI key, not a ChatGPT login.
  Check whether `claude-agent-acp` accepts the Claude subscription login. If
  not, keep a print-mode CLI fallback for Claude Code only.
- **ACP versions.** Version 2 adds resume and list. Pin the version in the
  client and test it against goose and buzz-agent, which are the two
  independent implementations easiest to run locally.
- **The always-on host.** `buzz-acp` is Rust, like `sphinx-rs`. A fork with a
  Sphinx transport may be the separate engine `docs/agent-native.md` leaves
  open. Evaluate it before writing a second host.
- **Cost per turn** through the mixer, in sats and latency (agent-native
  spike 3).

## Tasks, roughly in order

1. The ACP client in Swift, tested against `buzz-agent` or `goose acp` with no
   Peel UI: a prompt in, updates out, one permission request answered.
2. The agent profile: a second engine in the app, unlocked by the same PIN,
   owner-only gate, the thread-to-session table.
3. The Claude Code contact on one read-only folder, through the ACP adapter,
   or the print-mode CLI if the subscription login fails.
4. Ask cards: permission requests answered in the app, then from the phone
   over Sphinx.
5. The grants screen, the harness registry and the add-agent flow: name,
   harness, folders and mode, then the account.
6. Codex, goose and custom harnesses; the heartbeat for ongoing agents.
7. The audit log in the conversation, and revocation.

## Risk to keep in view

A compromised agent account is remote execution on the Mac. The mitigations
are the allowlist, per-agent keys with narrow grants, conservative harness
modes and a person answering anything destructive; if those are not in place,
the phase does not ship.
