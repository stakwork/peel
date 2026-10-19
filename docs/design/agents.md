# Peel agent design

Last updated 2026-10-08. The agent screens for phase 9, on top of the
approved layout in `README.md`. Nothing here is built. The architecture is
in `../agent-architecture.md`; this file is what Tom sees.

The canvas "Peel agents" (https://claude.ai/artifact/766M5wfBmXvc39fPyRrZBf,
six artboards at 1280 by 800, phone at 390 by 844) was drawn on 2026-10-07
for the earlier model, one contact per harness. Artboards 3 (the
conversation, ask cards, thread panel) and 6 (phone fallback) still hold.
Artboards 1 (sidebar), 2 (Add agent), 4 (settings panel) and 5 (Harnesses
group) need redrawing to the sections below.

> **Superseded in part (2026-10-19):** the agent host, its workers and the
> "Create from my seed" account sheet. The agent is strut's `orchestrator`
> behind the bridge, its account from `agent_seed(seed, n)`, set up by Peel
> with one invite. See [../agent-architecture.md](../agent-architecture.md).

## Decision

One agent contact. Tom's agent sits in Direct messages beside people, with
the rounded-square avatar and the AGENT label the layout already gives it.
The conversation, the memory, the grants, the mandates and the activity
all hang off that one contact.

Workers (Claude Code, Codex, goose, a custom worker) are not contacts. They
appear only inside a thread that is bound to one, and in the Workers group
of Account › Agent. There is no agents section, no agents home, and no
worker in the sidebar.

Colour is state, as in `README.md`: green for confirmed (running, allowed,
done), orange for waiting on you (an open ask card), red only for Remove.
Rejecting an ask is quiet, not red: nothing is destroyed.

## 1. Sidebar

- Direct messages holds Kate, Evan and Paul, and the agent. Same row style;
  the agent differs by its rounded-square avatar. No worker marks.
- When the agent waits on an answer, its row shows an orange count where
  unread would show a blue one. Orange is "waiting on you", as the
  connection bolt uses it.
- The "+" row stays "Add contact". Setting up the agent is a one-time step
  in Account › Agent, not a sidebar action.

## 2. Setting up the agent

On Account › Agent, before an agent exists, one card: "Set up your agent".
A sheet with three steps, one at a time with Continue:

- **Account.** Paste an invite (selected) or "Create from my seed", greyed
  with LATER until child derivation lands. The account is created on the
  host, not in the app: the sheet shows the one command to run on the host
  (`peel-agent serve` with the owner filled in) and waits for the agent's
  first message, which adds it as a contact.
- **Name and avatar.** Initials preview, name field, photo by link.
- **First grant.** Optional: a worker and a folder, read only by default.
  It can be skipped; the agent works without workers.

## 3. The agent conversation

- **Header.** Rounded-square avatar, name, AGENT, then one line from the
  agent's `status` messages: Idle (hollow dot), Working (green dot) or
  Waiting on you (orange dot). On the right, an icon that opens Account ›
  Agent.
- **Threads.** Each topic is a thread, as in tribes: the agent replies in a
  thread rooted at Tom's message, and a thread of two or more collapses
  into a thread row in the main conversation. The thread panel on the right
  holds the conversation.
- **Plain thread.** Bubbles in Markdown. A job the agent started shows as a
  quiet line ("Started a job · Weekly plan") and its result arrives later
  in the same thread.
- **Bound thread.** The thread panel's header names the worker, folder and
  mode, with Running or Idle, Stop and Unbind. "Hand to a worker" in a
  thread's menu binds it: a popover at the trigger with the granted workers
  and folders. The agent can also propose a binding with a card
  ("Hand this to Claude Code in ~/hive?"), answered Bind or Not now.
- **New content between bubbles:**
  - Progress lines: quiet 13 pt secondary rows with a chevron and a
    duration ("Read 4 files · 3 s", "Ran swift build · 41 s"), collapsed by
    default, expand on click.
  - A result card inside the answer bubble: the diff summary (files, +86
    −4) and Open, which opens Peel's own diff view, never a raw file.
  - An ask card for each permission the rules do not cover: an orange
    "Waiting for you" line, the question with the path in mono, one line of
    context (what the grant allows, how long an answer lasts), and the
    options the worker offered: Allow once and Allow for this session
    filled, Reject as quiet text. Once answered the card collapses to one
    line with a green check ("Allowed once · Edit
    Sources/PeelApp/AccountView.swift · 14:04"), so the history stays
    readable and is its own audit log.
  - A payment ask: the amount, the payee and the reason, Pay or Reject,
    for a payment outside every mandate.
  - A proposal card for a change to Tom's concept tree: the seed file and
    the change, Approve or Reject.
- The sidebar row keeps its orange count while any card is open.

## 4. Account › Agent

A page in the detail column like Account, reached from the Account page and
from the agent's header. Each control sends a typed message to the agent and
shows the host's answer; while it waits, the row shows a spinner in place.

- **Agent.** Name, avatar, the host it runs on and when it was last seen,
  the balance with Top up.
- **Workers.** One row per worker the host can start: Claude Code
  (Installed, logged in), Codex (Installed, not logged in; the hint "Run
  codex login on the host" and Check again), goose (Not installed; the
  install hint), Custom (one JSON file on the host). The host probes each
  when the page opens.
- **Grants.** Per worker: folders with remove per row and Add folder, mode
  (Read only / Edits allowed). A note says only messages signed by your key
  reach a worker.
- **Mandates.** Each signed spending approval: scope, cap per payment and
  per period, expiry, Revoke. New mandate opens a form in a popover.
- **Activity.** The last tasks: time in a tabular column, a state mark
  (green check done, green dot running, orange dot waiting, hollow
  stopped), the task text, and Open, which scrolls to that message.
- **Connections** (later phase): one row per service with Connect, scope,
  access level and Disconnect. See `../agent-architecture.md`,
  "Connectors".
- **Remove the agent.** The one red text, confirmed in place next to the
  trigger, never a native dialog. It stops the host's sessions and removes
  the contact from this Mac; the account stays on the server.

## 5. Phone fallback

- The official Sphinx app renders the card's text fallback: "Allow Edit
  Engine.swift? 1 Allow once, 2 Allow for this session, 3 Reject." A reply
  of `1`, `2`, `3`, `yes` or `no`, signed by the owner's key, counts as the
  answer, and the agent confirms in words ("Allowed once. Editing
  Engine.swift."). No buttons, no AGENT label, a round avatar, and threads
  shown as replies inline, because the official app knows nothing about
  agents and groups threads only in tribes. The artboard is plain by design.

## What the engine needs

| UI part | Needs | Where it comes from |
|---|---|---|
| Agent row, AGENT label | A kind on the contact | Phase 9 task 12; `agent-native.md` rule 5 |
| Orange count, status line | Open cards and the agent's state | `status` and `ask` typed messages; Peel's query over them |
| Threads in the DM | The tribe thread rule in 1:1 chats | Phase 9 task 11; `threadUuid` is already stored |
| Bind, Stop, Unbind | `bind` and `unbind` typed messages; the host's binding table | Phase 9 tasks 7, 8, 14 |
| Progress lines | `progress` messages kept against the task message | ACP `session/update`, sent by the host |
| Result card | A typed `result` with a diff reference, and a diff view in Peel | Phase 9 message shapes |
| Ask card and its answer | A typed `ask` with the worker's options; an answer whose signature recovers the owner's pubkey; the uuid as the idempotency key; a text fallback | Phase 9 message shapes; the core's sender recovery (phase 2) |
| Payment ask, Mandates | `mandate` and `revoke`; the gate on top of `checkPayment` | Phase 9 task 20 |
| Account › Agent | The host's answers to typed requests: workers, grants, mandates, activity | The host loop and `agent.sqlite` |

## Open design questions

- The orange count in the sidebar for the agent waiting on you: keep it, or
  stay with blue unread only and let the card carry the colour.
- Whether Account › Agent is a page or a panel beside the conversation.
- Progress lines are one row each; a run of many steps may read better as a
  single "12 steps" row that expands.
- Where "Allow for this session" ends when two bound threads share a folder.
- Whether the phone fallback should parse "yes always" as Allow for this
  session, or stay with numbers and yes or no.
- Light appearance is not drawn; the app is dark only for now.
