# Peel agents design

Last updated 2026-10-07. The agent screens for phase 9, drawn on top of the
approved layout in `README.md`. Nothing here is built. The mock lives on the
canvas "Peel agents": https://claude.ai/artifact/766M5wfBmXvc39fPyRrZBf.
Six artboards, each a full Mac window at 1280 by 800 so placement in the real
layout is obvious; the phone fallback is 390 by 844.

## Decision

The contact is the identity; the harness is a setting. An agent is a Sphinx
account that sits in Direct messages beside people, with the rounded-square
avatar and the AGENT label the layout already gives it. Everything you keep
with an agent (the conversation, the grants, the activity, the trust) hangs
off that contact. What answers behind it, Claude Code, Codex, goose,
buzz-agent or a custom harness, is one row in the agent's settings and can
change without the contact changing. So there is no agents section, no agents
home, and no harness in the sidebar beyond a small mark on the avatar. The
only new surfaces are the add-agent flow, a status line and ask cards in the
conversation, a settings panel, and a Harnesses group on the Account page.

Colour is state, as in `README.md`: green for confirmed (running, allowed,
done), orange for waiting on you (an open ask card), red only for Remove this
agent. Rejecting an ask is quiet, not red: nothing is destroyed.

## 1. Sidebar with agents

- Direct messages holds Kate, Evan and Paul, then Claude Code and Reviewer.
  Same row style; the agents differ by their rounded-square initials avatar
  and a small mark on its corner, a letter for the harness (C for Claude
  Code). Both agents here run Claude Code with different grants: Reviewer is
  read only. That is the point of the decision, so the mock shows it.
- An agent waiting on an answer shows an orange count where unread would show
  a blue one. Orange is "waiting on you", as the connection bolt uses it.
- The "+" row at the end of the section is now "Add contact or agent". It
  opens a popover at the row's trailing edge (the `SidebarActionLink`
  pattern) with two rows: Add contact, "Paste their contact info", and Add
  agent, "A harness on this Mac, behind its own account". Add contact keeps
  today's form in the popover; Add agent opens the sheet in artboard 2. One
  row with a chooser rather than two rows like Tribes: the chooser explains
  the difference in one line each, which two bare rows cannot, and Add
  contact stays where it is.
- The detail column shows Reviewer's conversation, idle: the header line
  reads harness, folder, Read only, Idle (a hollow dot); Stop is disabled.

## 2. Add agent

- A sheet dropping from the top of the detail column, over the conversation
  dimmed; the sidebar stays. Four steps. In the app one step shows at a time
  with Continue; the artboard shows all four side by side so the flow reads
  at once.
- **Name and avatar.** Initials preview, name field, Add photo (a link to an
  https image, as the Account page does until uploads land). A note says the
  agent shows in Direct messages like any contact, with the AGENT label.
- **Harness.** A radio list from the harness registry. Each row carries its
  state under the name: a green check for installed and logged in, an orange
  dot for installed but not logged in, "Not installed · Install" with the
  registry's install hint, and Custom with "Add a harness · one JSON file".
  A note says the harness starts in its conservative mode and Peel never
  passes skip-permissions.
- **Folders and mode.** Mode first: Read only is the default, Edits allowed
  is a choice; the note says read only lets Peel answer reads itself and
  edits always ask. Then the folder list with remove per row and Add folder,
  which opens the folder picker that gives the signed app its macOS grant.
- **Account.** Paste an invite link (selected) or Create from my seed, greyed
  with LATER until child-seed derivation lands. Ends with Create agent, the
  only filled button in the sheet.
- Why four small steps: each is one decision, the harness list is too tall
  for a popover, and the sheet keeps the conversation and sidebar in place.

## 3. Agent conversation

- **Header.** Rounded-square avatar with the harness mark, the name, AGENT,
  then one line: harness · folder · mode · Running (green dot) or Idle
  (hollow dot). On the right, Stop, New session, and an icon button that
  opens the settings panel (artboard 4).
- **Messages** are the same bubbles as any DM, with three new kinds of
  content between them:
  - Progress lines: quiet 13 pt secondary rows with a chevron and a duration
    ("Read 4 files · 3 s", "Ran swift build · 41 s"). They come from
    `session/update`, collapse by default and expand on click.
  - A result card inside the answer bubble: the diff summary (files, +86 −4)
    and Open. It opens Peel's own diff view, never a raw file.
  - An ask card for each `session/request_permission`: an orange "Waiting
    for you" line, the question with the path in mono, one line of context
    (what the grant allows, how long an answer lasts), and the four ACP
    answers: Allow once and Allow for this session filled, Reject and Reject
    always as quiet text. Once answered the card collapses to one line with a
    green check ("Allowed once · Edit Sources/PeelApp/AccountView.swift ·
    14:04"), so the history stays readable and is its own audit log.
- **Thread panel.** A second session running in a thread, one session per
  Sphinx thread as the host loop says. The header carries "second session ·
  Running"; then the original message, the reply divider, replies and
  progress; the reply composer with "Also send to Claude Code".
- The sidebar row keeps its orange count while the ask card is open.

## 4. Agent settings

- Opened from the header icon. A 360 pt panel on the right, in place of the
  thread panel, so the conversation stays in view while you change grants.
  Rows are stacked (label, value, control) because 360 pt is too narrow for
  the Account page's label column.
- **Grants.** Harness with Change; Folders with remove per row and Add
  folder; Mode (Read only / Edits allowed); Allowed senders (Owner only /
  Allowlist) with the note that only messages signed by your key reach the
  harness.
- **Session.** Idle timeout and Max turn as pickers, one note under the
  group.
- **Activity.** The last five tasks: time in a tabular column, a state mark
  (green check done, green dot running, orange dot waiting, hollow stopped),
  the task text, and Open, which scrolls the conversation to that message.
- **Remove this agent.** The one red text, confirmed in place next to the
  trigger, never a native dialog. The note says it stops sessions, drops the
  queue and removes the contact from this Mac; the account itself stays on
  the server.

## 5. Profile, Harnesses group

- The Account page scrolled to a new Harnesses group under Security. Rows:
  Claude Code (Installed, logged in; used by Claude Code, Reviewer), Codex
  (Installed, not logged in; the hint "Run codex login in a terminal" and
  Check again), goose and buzz-agent (Not installed; Install opens the
  harness's own page in the browser), and Custom (Add a harness; one JSON
  file: id, label, command, args, env, install hint).
- A note under the group says Peel looks for each harness on PATH when the
  page opens.
- Why here and not per agent: harnesses belong to this Mac, like the server
  and the devices, not to a contact.

## 6. Phone fallback

- The official Sphinx app renders the ask card's text fallback: "Allow Edit
  Engine.swift? Reply yes or no." A reply of yes or no, signed by the owner's
  key, counts as the answer, and the agent confirms in words ("Allowed once.
  Editing Engine.swift."). Nothing else: no buttons, no AGENT label, a round
  avatar, because the official app knows nothing about agents. The artboard
  is plain by design.
- yes maps to Allow once. Allow for this session and Reject always are only
  reachable from Peel.

## What the engine needs

| UI part | Needs | Where it comes from |
|---|---|---|
| Agent rows, harness mark, AGENT label | A kind on the contact (person, agent) and the harness id | Agent record (phase 9); `agent-native.md` rule 5 |
| Orange count, Activity states | Open asks and task state per agent | Peel's query over stored ask and task messages |
| Add agent | Harness registry with an availability probe; folder grants; registration of a child account from an invite | Registry (built in plus custom JSON files); `Engine.addContact` for the invite; phase 9 task 2 for the account |
| Status line, Stop, New session | Session state per agent (harness, folder, mode, running or idle), cancel and new session | Session table (thread to session) and the ACP client: `session/new`, `session/cancel` |
| Progress lines | `session/update` events kept against the task message | ACP client; Peel stores updates as children of the task |
| Result card | A typed result message with a diff reference, and a diff view in Peel | Typed message JSON with a version field (phase 9 message shapes) |
| Ask card and its answer | A typed ask message from `session/request_permission` with the four options; an answer message whose signature recovers the owner's pubkey; the message uuid as the idempotency key; a text fallback | Phase 9 message shapes; the core's sender recovery (phase 2) |
| Thread sessions | One session per Sphinx thread | `threadUuid` on messages; the session table |
| Settings panel | Read and write of the agent record; revocation drops the queue and cancels sessions | Agent record; the host loop |
| Harnesses group | The registry's install hint per harness; a logged-in probe per harness | Registry; how each harness reports login is not checked yet |

## Open design questions

- The orange count in the sidebar for an agent waiting on you: keep it, or
  stay with blue unread only and let the ask card carry the colour.
- One "Add contact or agent" row with a chooser, or two rows like Tribes.
- The settings panel on the right, or a full page in the detail column like
  Account.
- The harness mark is a letter for now. Harness logos belong to their owners;
  and the header already names the harness, so the mark may not be needed.
- Progress lines are one row each; a run of many steps may read better as a
  single "12 steps" row that expands.
- Where Allow for this session ends when a thread session and the main
  session share a folder.
- Whether the phone fallback should parse "yes always" as Allow for this
  session, or stay with yes and no.
- Light appearance is not drawn; the app is dark only for now.
