# Phase 8 — Local tools: an agent acting on your Mac

Status: planned. Comes after the agent host in `docs/agent-native.md` exists
and after the real account has moved over.

## Idea

Peel on the Mac is one device on your account with a signed, end-to-end
encrypted channel to every contact, and an agent is a contact. So an agent can
act on the Mac the same way you talk to it: it sends a tool request as a Sphinx
message, the Mac app carries out what it is allowed to, and replies with the
result as a message. The Mac app becomes a small tool server whose transport is
Sphinx, much like an MCP server. Nothing in `docs/agent-native.md` changes: no
private API between the app and the host, requests queue on the server while
the Mac is asleep, and the agent can live on the desktop, a home server or the
cloud without the Mac side knowing.

## What it rests on

- The core recovers each message's sender from its signature, so a request is
  bound to exactly one agent account (verified during phase 2).
- The app has a stable signed identity, which macOS requires before it grants
  folder access, Automation or Accessibility to a bundle.
- Replay protection already exists: the unique time on every core call and the
  message uuid the store deduplicates on.
- Sphinx already carries structured commands in conversations
  (`BotInstall`, `BotCmd`, `BotRes`, types 23–25); a typed JSON request in the
  message body follows that precedent. Large inputs and outputs travel as
  encrypted attachments (phase 3), not as message text.

## The gate lives in the app, outside the model

This is remote execution of your machine by a chat identity. The design is the
permission model; the tools are the easy part.

- An explicit allowlist of agent accounts, each with its own key. Never "any
  contact", never your root identity.
- Capabilities granted per agent: which folders (read, write), which named
  scripts or actions, nothing like an open shell by default.
- Destructive or irreversible actions confirmed in the app, next to the
  request, before they run. No native dialogs.
- Every request and result logged locally and visible in the conversation.
- Grants revocable in one place; a revoked agent's queued requests are dropped.
- Idempotency keys on requests, so a request replayed by a reconnect runs once.

## Tasks, roughly in order

1. Request and reply shapes (JSON in a DM message), with a version field.
2. The allowlist and grants UI: designate an agent, pick folders and actions.
3. First tools: list, read and write files in granted folders; open a path.
4. Named scripts the user registered themselves.
5. Confirmation flow and the local audit log.
6. Later, if wanted: screen and app control along the lines of computer use,
   which needs Accessibility and Screen Recording permissions and a much
   stricter gate.

## Risk to keep in view

A compromised agent account is remote execution on the Mac. The mitigations
are the allowlist, per-agent keys with narrow grants, and confirmation for
anything destructive; if those are not in place, the phase does not ship.
