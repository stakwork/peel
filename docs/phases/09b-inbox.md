# Phase 9b — The Inbox: a view of what your agent is keeping for you

This file predates the 2026-10-10 replan (`../agent-architecture.md`); it is kept for its research.

Status: planned. This is a late step of phase 9 (`09-agents.md`, Wave D),
built after graph memory. Nothing is built. Tom raised the idea on
2026-10-09 and turned it agent-first the same day. The design board
(one direction, based on I2) is kept outside the repo.

## Idea

Tell your agent what to remember, by text or voice: "add 'call the
garage' to my list", "remind me about this tomorrow at 2". The agent
keeps these as items in its graph and reminds you. It also tidies them
and answers questions about them.

Peel's **Inbox**, in the sidebar, shows those items: what is open, when
each will remind you, and where it came from. You can tick one or
snooze it with one click, and open the conversation that made it.

The Inbox is not a to-do app. It is the window onto the agent's
commitments to you.

Tom, 2026-10-09: in the end you just ping your agent ("add this to my
to-do list", "remind me about this note tomorrow at 2") and the agent
keeps it in LadybugDB. Messages to yourself can't be edited, ticked off
or assigned.

## The shape: a view, a cache, one writer

**The agent is the only writer.** Items live in the agent's LadybugDB
from day one, and the host process writes them. These all go through
the agent, by message:

- capture;
- questions ("what's on my list?", "what's due this week?");
- grouping;
- briefs;
- upkeep: merging duplicates, flagging stale items, and noticing
  "done" in a chat.

**Peel's table is a cache.** Each device keeps a copy of the items. The
Inbox draws from it, and reminders are scheduled from it. The cache is
filled and corrected by the host's typed messages.

**The Inbox is a read-mostly view.** It shows:

- the open items and when each reminds you;
- for each item, a link to the agent conversation it came from;
- one-click tick and snooze.

Anything more, such as rewording, merging or a question, is a message
to the agent.

```
 Tom ─ text or voice ─▶ agent DM ─▶ orchestrator (the only writer)
                                     ├─ inbox tools in the loop
                                     └─ Item nodes in LadybugDB
                                              │ item.state, item.snapshot
                                              ▼   (typed messages to Tom)
 Peel on each device: cache table ─▶ Inbox view · per-device reminders
        └─ tick · snooze ── item.put ──▶ orchestrator
```

### Why the view exists at all

If the agent does everything, why draw a list?

- **Trust.** You can see what the agent wrote down, in its words, and
  when it will remind you. Without that, a commitment to remind you is
  only a promise in a scroll of messages.
- **Speed for tiny actions.** Ticking or snoozing an item is one click,
  not a sentence and a model turn.
- **Offline.** The cache shows the list, and reminders still fire, while
  the host sleeps or the Mac is offline. A tick or snooze made then waits
  in the cache and syncs later.

## User stories

1. **Ask the agent to keep something.** By text or voice: "add 'call the
   garage about the MOT' to my list". The item appears in the Inbox on
   every device.
2. **Ask it to remind me.** "Remind me about this tomorrow at 2", in
   reply to a message in the agent DM. The item is about that message,
   and the reminder fires on my Mac and phone, also with Peel closed.
3. **Ask about my list.** "What's due this week?", "what did I finish
   on Monday?", "group the house stuff". The agent answers in the thread.
4. **See the list.** I open the Inbox and see the open items, their
   reminder times and where each came from.
5. **Tick or snooze.** I tick an item or snooze it with one click, in the
   Inbox or from the notification.
6. **Go back to where it came from.** A click opens the agent's thread
   for the item, in the right-hand panel.
7. **The agent keeps it tidy.** It merges duplicates and asks about stale
   items. When I say in a chat that a thing is done, it suggests ticking
   it, and I see the result.
8. **Everywhere.** The same items, ticks and reminders on every device.

## The item

### In the graph

The host owns the node. It reuses the agent schema's `Artifact` (a
pointer) and `Job` (with its `thread_uuid`), rather than adding Message
and Thread nodes:

```
NODE Item (id PK, text, created_ms, updated_ms, done_ms, remind_ms,
           deleted_ms, state: open | suggested, origin, thread_uuid, rev)

REL ABOUT     (Item → Artifact)   the message it is about: kind message,
                                  ref "<chat>/<uuid>", no text copied
REL HANDED_TO (Item → Job)        when the agent works the item
REL ABOUT     (Item → Concept)    later: grouping, instead of tags
```

```
            ┌──────────────────── Item ─────────────────────┐
            │ id · text · done_ms · remind_ms · thread_uuid  │
            └───┬──────────────────┬───────────────────┬─────┘
          ABOUT │        HANDED_TO │             ABOUT │ (later)
                ▼                  ▼                   ▼
   Artifact (kind: message,     Job (thread_uuid,    Concept
   ref: chat/uuid)              status) ─TURN▶ Run
```

- **`thread_uuid`** is the agent thread the item was made in. The
  Inbox's link goes there.
- **`origin`** is one of `asked` (Tom asked by text or voice), `capture`
  (quick capture, later), `inferred` (the agent noticed it) or `import`.
- **`state: suggested`** marks an item the agent inferred on its own,
  from a meeting, an email or a chat. Tom keeps it or drops it. The
  agent's own list tools don't count it until then. This follows the
  Glimmer rule that concept writes are proposals.
- **`rev`** goes up by one on every host write.
- **`deleted_ms`** is a tombstone, so a delete reaches every device.
- **Assigning to a person** waits for a Person node, which comes with
  Connections.
- **`ABOUT` gains two endpoint pairs:** `Item → Artifact` and
  `Item → Concept`. LadybugDB rel tables list their pairs. If multi-pair
  tables are awkward in the Swift bindings, the message edge is named
  `SAVED_FROM` instead.

### Write rules for items

These follow the agent architecture's write rules.

- **The host writes an item only on an event:**
  - Tom's `item.put` (a tick or a snooze);
  - an `inbox_*` tool call in a turn Tom started;
  - Tom keeping a suggestion;
  - upkeep that Tom approved with a card.
- **Upkeep proposes; it never deletes on its own.** Merging, dropping a
  stale item or ticking from a chat is an ask card ("Merge these two?",
  "Tick 'book the MOT'? You told Kate it's booked"). The agent may make
  a change that loses nothing (rewording on request, regrouping) and say
  so in the thread.

### Peel's cache

Peel adds one table in `peel.sqlite`, made by the next append-only
migration in `Storage+Migrations.swift`:

```
inboxItem (id TEXT PK, text TEXT, createdAt INT, updatedAt INT,
           doneAt INT, remindAt INT, deletedAt INT, state TEXT,
           origin TEXT, threadUUID TEXT, aboutChat TEXT,
           aboutMessage TEXT, rev INT, pending INT DEFAULT 0)
```

- **It is per account.** Forgetting the account removes it.
- **The host's messages fill it.** `Engine` applies each `item.state` and
  `item.snapshot` the typed codec decodes. The view reads it with a GRDB
  `ValueObservation`.
- **Tick and snooze write the row with `pending = 1`** and send an
  `item.put`. The host's echo replaces the row and clears `pending`.
- **The operations are typed engine operations** (`agent-native.md` rule
  2): `Engine.items()`, `tick(_:)` and `snooze(_:until:)`.

## Sync

```
 Peel Mac   ──item.put {id, base rev, doneAt | remindAt}──▶┐
 Peel phone ──item.put────────────────────────────────────▶│ orchestrator
                                                           │ applies in arrival
                                                           │ order, rev += 1
 Peel Mac   ◀──item.state {id, rev, fields}────────────────┤ sent to Tom's
 Peel phone ◀──item.state──────────────────────────────────┘ account
            ◀──item.snapshot (paged) ── on item.sync {since rev}
```

- **The messages are typed,** under the `peel` metadata key, in the agent
  DM and outside threads:
  - Peel to host: `item.put` and `item.sync`;
  - host to Tom: `item.state` and `item.snapshot`.
- **Every device converges.** The host's messages go to Tom's account,
  so every device gets them, live or from history. A new or restored
  device asks with `item.sync {since 0}`.
- **Conflicts are settled per field.** When a field changed after the
  sender's base `rev`, the host keeps its own value, and its echo corrects
  the sender. With one person and a few devices, conflicts are rare.
- **In the DM** these messages draw nothing in Peel. The official apps
  show the short fallback text, for example "Inbox: added 'Paul's timber
  quote'". That noise is accepted while they are the fallback.
- **Ticks are batched.** Changes made within two seconds go in one
  `item.put` list, since every message costs a trip through the mixer
  (`agent-native.md`, spike 3).

## Reminders, per device

```
 cache row with remindAt ─▶ UNCalendarNotificationTrigger, id "inbox.<id>"
   lock or quit  ─▶ pending requests rewritten: "A reminder is due"
   unlock        ─▶ rewritten with the item's text
   fires with Peel closed (macOS keeps scheduled requests)
   actions: Snooze 1 hour · Tomorrow 9:00 · Done ─▶ item.put
```

- **Each device schedules from its own cache.** Reminders then work
  offline and while the host sleeps (Strut skips missed schedules on a
  sleeping Mac, agent decision 12).
- **Done or snoozed on one device** reaches the others as an `item.state`.
  Peel there removes the delivered notification and reschedules.
- **The lock rule holds:** "while Peel is locked a notification names
  nobody and says nothing". A scheduled reminder fires whatever state
  Peel is in. So Peel rewrites its pending requests:
  - with no text, on lock, on quit and in `willTerminate`;
  - with the item's text, on unlock.

  A crash leaves the text until the next launch. The category's
  `hiddenPreviewsBodyPlaceholder` covers the system's own "hide
  previews".
- **An action taken before unlock.** If Peel was closed, an action
  launches it with no PIN entered and no database open.
  - Peel reschedules the notification at once, which needs no database.
  - It keeps `{item id, action, time}` in a small pending list in
    `UserDefaults`, with no text.
  - After unlock it applies the list as an `item.put`.
- **The pending limit.** Peel schedules the soonest 60 reminders and
  tops the list up on every change. Apple documents a limit of 64 on
  iOS; macOS is not documented.
- **A click** opens the Inbox at the item. `Notifier`'s delegate routes
  it by an `item` key in `userInfo`.
- **The host messages a reminder itself** only when the reminder belongs
  in the conversation ("you asked me to nudge you about Paul's quote").
  The devices still fire their own reminder. The host's message is then
  a quiet reply in the thread, without a second notification.

## The view

- **The sidebar row** is "Inbox", under Search and above Threads. Its
  count is the open items, in grey. When reminders are due, it shows the
  due count in orange instead ("waiting on you", as the agent's row
  does).
- **The Inbox** sits in the conversation column, under the H1 header:
  - Today first: overdue items, then the ones due today. Overdue is
    orange, never red.
  - Then Later.
  - Then Suggested, the agent's inferred items, each with Keep and Drop.
  - Done is folded at the bottom, collapsed.
  - Reminder times line up in a right-hand column.
  - An item about a message shows the message's sender and chat under
    its text.
- **A click on an item** opens its agent thread in the right-hand panel,
  where threads open. That is the conversation that made the item, so
  rewording or asking about it happens there.
- **The hover actions** are Tick, Snooze (a short menu next to it: 1
  hour, This evening, Tomorrow 9:00, Monday) and "Open thread".
- **The keyboard:** Space ticks the selected item, S snoozes it, Return
  opens its thread, and ⌘Z undoes a tick.
- **No edit screen, no tags, no projects, no add field.** Adding is a
  message to the agent. Until quick capture exists, the Inbox's empty
  state and header say so: "Ask your agent to add something", which opens the
  DM.

## Privacy

- **The host holds the items.** It runs on Tom's own machine, and items
  reach it as onion-routed message content. The mixer sees timing and
  size, not content.
- **A message an item is about** reaches the host as a pointer only: a
  chat id and a message uuid. The host is a different account and can't
  read Tom's other chats.
  - If Tom asks the agent about a message from another chat (by
    forwarding it, or quoting it in the DM), the agent sees only what Tom
    sent.
  - The Inbox shows that message's sender and text from Peel's own
    message store, on the device, never from the host.
- **The cache** is in `peel.sqlite`, protected like the messages:
  FileVault, and the PIN in front of the UI.
- **Reminder text** follows the lock rule above.

## Quick capture (later)

Tom wants this; it comes after the Inbox. Press ⌃⌥Space in any app,
type a line and press Return. The line goes to the agent as a message,
and you are back where you were.

```
 any app ─ ⌃⌥Space ─▶ Carbon RegisterEventHotKey (no permission)
                         ▼
   nonactivating NSPanel, floating, joins all Spaces
   ┌─────────────────────────────────────────────────┐
   │ ▢ Call the garage about the MOT                 │
   │ To your agent · ↩ send · ⇥ remind               │
   └─────────────────────────────────────────────────┘
      host reachable: sent as a DM to the agent (origin capture)
      host offline:   queued locally, shown greyed in the Inbox, sent later
```

- **`RegisterEventHotKey` (Carbon) needs no permission.** It registers
  one combination for the whole system. The `KeyboardShortcuts` package
  and most launchers use it.
  - Since macOS 15 it refuses a combination whose only modifiers are
    Option or Option-Shift. ⌃⌥Space is fine.
  - If another app holds the combination, registration fails. Account
    then says so and records another.
- **`NSEvent.addGlobalMonitorForEvents` needs Accessibility or Input
  Monitoring** to watch key presses. Peel does not use it.
- **A nonactivating `NSPanel` can take the keyboard** without bringing
  Peel to the front, as Spotlight does:
  - `styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]`;
  - `level = .floating`;
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.

  It is a new panel, not `FloatingWindow`, which is a child of Peel's
  window.
- **The shortcut works only while Peel runs.** Peel keeps running with
  its window closed. "Open Peel at login" (`SMAppService.mainApp`) sits
  beside the shortcut.
- **Offline.** The line is kept in the cache as a `pending` item with
  `origin: capture`, and sent when the agent DM can be reached. The host
  sleeping is not the same as offline: the mixer queues the message, so
  the line is sent and the agent files it when it wakes.
- **Locked.** If Peel locked itself after idle, the engine is attached,
  so the panel sends as usual and shows nothing else. After a cold
  launch with no PIN entered, the panel keeps the line and asks for the
  PIN under it.

## Scope

**In phase 9 Wave D** (`09-agents.md`):

1. **The host:**
   - the Item node and edges, by a migration of the graph schema;
   - the `inbox_add`, `inbox_update`, `inbox_done`, `inbox_list` and
     `inbox_snooze` loop tools;
   - the `item.*` messages in the typed codec;
   - upkeep as ask cards.
2. **Peel's cache:**
   - the table and migration;
   - applying `item.state` and `item.snapshot`;
   - `tick` and `snooze` with `item.put`;
   - `item.sync` on a new device.
3. **The view:**
   - the sidebar row and the Inbox list;
   - Suggested, with Keep and Drop;
   - the thread opening in the right-hand panel.
4. **Reminders:**
   - per-device scheduling;
   - the lock rewrite;
   - the actions and the pending list from before unlock.

Voice capture works as soon as the agent understands voice messages
(phase 10). Until then, voice in the board's future frame stands for
text.

**Later:**

- quick capture;
- grouping as Concept edges;
- assigning to people (with Connections);
- repeating reminders;
- Siri, Shortcuts and a Share extension;
- the iPhone view, with the iPhone phase.

**Not planned:**

- an edit screen;
- tags;
- projects;
- sub-tasks.

The agent rewords and groups on request.

## Open decisions for Tom

1. **Reminder text while Peel is locked or closed.**
   - (a) Follow the lock rule: "A reminder is due" until you unlock.
   - (b) Always show the text.
   - (c) A setting, off by default.

   **Recommend (a).** It keeps the promise the lock makes, and the click
   opens the item after the PIN.
2. **Items the agent infers on its own.**
   - (a) Added straight to the list.
   - (b) Suggestions that you keep or drop.

   **Recommend (b),** in line with concept writes being proposals.
   Anything you asked for is added directly.
3. **Upkeep that changes the list** (merge, drop a stale item, tick
   from a chat).
   - (a) Always an ask card.
   - (b) The agent acts and tells you, with Undo.

   **Recommend (a) to start.** Move a kind of upkeep to (b) once it has
   been right for a few weeks.
4. **Snooze in the Inbox.**
   - (a) A short menu of presets.
   - (b) The presets plus a date picker.

   **Recommend (a).** "Remind me on the 24th at 10" is a message to the
   agent.
5. **The quick capture shortcut, when it comes.**
   - (a) ⌃⌥Space.
   - (b) ⌥⌘N.

   **Recommend (a),** changeable in Account.
