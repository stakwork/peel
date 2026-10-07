# Phase 9 — Local runtimes: Peel dispatches work to Claude Code, Goose or Codex

Status: planned. Comes after the agent host in `docs/agent-native.md` exists
and after the real account has moved over.

## Idea

Acting on a machine is a solved problem: Claude Code, Codex and Goose already
have the tools, the file edits, the shell, the sandboxing, the permission
prompts and the agent loop, each with its own safety model. Peel should not
write a worse copy. What Peel uniquely has is the identity, the encrypted
transport, and the place where you say yes or no.

So Peel becomes a dispatcher. A task arrives, from you or from an agent account
you have designated; Peel starts a session in the runtime you chose, in a
folder you granted; it streams progress back as Sphinx messages; and it turns
the runtime's permission prompts into approvals, in the app or on your phone
over Sphinx. Peel is the remote control for any local agent, over your own
network rather than a vendor's relay. Nothing in `docs/agent-native.md`
changes: no private API between the app and the agent host, requests queue on
the server while the Mac is asleep, and the host can live anywhere.

## Shape

One small interface in the Mac app, one adapter per runtime:

```
LocalRuntime
  start(task, in folder, with grants)   → session
  session.events                        → text, tool use, permission request, result
  session.answer(permission, allowed)
  session.cancel()
```

- **Claude Code** — through the Agent SDK: a structured event stream and a
  `canUseTool` hook that maps straight onto approvals. First, because Tom
  lives in it and the hook is the cleanest.
- **Goose** — `goose run`, MCP-native; second, and the one Stakwork already
  leans on.
- **Codex** — `codex exec`, with the strongest OS-level sandbox of the three;
  third.

API keys and subscriptions stay with the runtimes on the Mac; Peel never holds
or forwards them. The task request and the result travel as typed JSON in a DM
(Sphinx already carries structured commands: `BotInstall`, `BotCmd`, `BotRes`,
types 23–25); large inputs and outputs go as encrypted attachments (phase 3).

## What it rests on

- The core recovers each message's sender from its signature, so a request is
  bound to exactly one agent account (verified during phase 2).
- The app has a stable signed identity, which macOS requires before it grants
  folder access, Automation or Accessibility to a bundle.
- Replay protection already exists: the unique time on every core call and the
  message uuid the store deduplicates on.

## The gate lives in Peel, outside the model and outside the runtime

Outsourcing the execution does not outsource the decision. This is remote
execution of your machine by a chat identity, so the permission model is the
design; the adapters are the easy part.

- An explicit allowlist of agent accounts, each with its own key. Never "any
  contact", never your root identity.
- Grants per agent: which runtime, which folders, which permission mode the
  runtime is launched in. Runtimes start in their conservative mode; Peel
  never passes "skip permissions".
- Permission requests from the runtime are shown next to the task and
  answered in the app or from the phone; destructive ones always wait for a
  person. No native dialogs.
- Every task, permission answer and result logged locally and visible in the
  conversation.
- Grants revocable in one place; a revoked agent's queued tasks are dropped and
  its running sessions cancelled.
- Idempotency keys on tasks, so one replayed by a reconnect runs once.

## Tasks, roughly in order

1. Task and result shapes (JSON in a DM message), with a version field.
2. `LocalRuntime` and the Claude Code adapter via the Agent SDK, including the
   permission hook.
3. The allowlist and grants UI: designate an agent, pick a runtime, folders
   and permission mode.
4. Approvals in the app, then over Sphinx to the phone (phase 7).
5. The local audit log, shown in the conversation.
6. Goose adapter, then Codex adapter.

## Risk to keep in view

A compromised agent account is remote execution on the Mac. The mitigations
are the allowlist, per-agent keys with narrow grants, conservative runtime
modes and a person answering anything destructive; if those are not in place,
the phase does not ship.
