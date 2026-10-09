# Second review, 2026-10-08

Scope: `origin/main` at `cd194a0` (#75, contacts). It covers the PRs since
the [first review](2026-10-08-architecture.md):

- calls (#44–#74)
- video and audio (#67)
- the web pane (#73)
- contacts (#75)
- the boost chip (#66, #71)
- the MainView/PeelMenu split (#69)
- the bottom-gap fixes (#68, #72)

I read the whole of PeelCore, PeelApp, the CLI and the tests, in six
read-only passes:

- core storage and notifications
- the engine and network
- calls, media and web
- the app model and shell
- the chat column
- payments, account and the CLI

I re-read every finding below against the code and dropped anything I
could not confirm. Line numbers are on `cd194a0`. No code was changed.

Tags:

- **Refactor**: no behaviour change.
- **Behaviour**: the change is visible or changes what happens, so Tom
  should look at it before it merges.

## Summary

The engine boundary still holds. PeelCore imports no UI framework. Every
core call goes through `run`/`commit`. The splits of rows 10–13 landed
cleanly. The new features mostly reuse what was there: `Web.session`, the
`Sats` formatter, `PeelError.readable`, and `MuteLevel.notifies`. The
app has no raw `"\(error)"` left.

Most of what this review found falls into four groups:

1. **Small real bugs from the day's speed.**
   - Return in Join a tribe looks the tribe up again instead of joining.
   - An invite that times out can be paid for twice.
   - A second ⌘N window steals the web view.
   - The history watchdog reports a failed restore after a plain
     disconnect.
   - A thread's send errors are invisible when the thread replaces the
     chat.
   - The Payments list stops at 50 rows offline.
   - A video keeps playing after the viewer steps to an image.
   - The previous account's player survives an account switch.
2. **#72's blank messages only go halfway.** The list hides them, but
   storage still counts them as unread, in threads and in sidebar
   previews, and Notifier posts "New message" for them. This is the
   biggest correctness item.
3. **Money sends are tracked by tag in three tables with three code
   paths.**
   - Messages, invoices and invites each have their own path.
   - They have already drifted: invites ignore UNSETTLED.
   - `pay()` has a dead "nothing was sent" branch.
4. **Parallel features copied the same small things again.** The main
   copies:
   - split-pane layout
   - menu anchors
   - attachment status views
   - QR tiles
   - the dashed unknown-person icon
   - hidden shortcut buttons
   - link-style buttons
   - sender fallbacks
   - the hex, JWT and "https or loopback" helpers

   `AppModel` has grown into about 1,830 lines across eight files. Seven
   of those files are views that carry an `extension AppModel`.

That last point is also what would block sharing models with an iPhone
app (section 9): the app model is half in view files and holds Mac-only
types. The iPhone work is paused, so this is a later item (batch 17), not
an early batch.

Out of the open rows of the first review:

- Row 9 (styles and confirm controls) moves to the polish pass, which is
  redesigning forms and popovers (section 10).
- Rows 6, 8, 12, 14, 15, 16 and 18 are folded into the batches below.

## Status of the first review's open rows

| Row | Item | State at `cd194a0` | Here |
|---|---|---|---|
| 6 | One sender resolution | Open. There are 5 resolvers and about 15 inline fallbacks. A member with no alias is "Unknown" in their own row (`MessageViews.swift:196,732`) and "Someone" in a quote (`ChatModel.swift:117`). | 5.6, batch 14a |
| 8 | Notification policy in PeelCore | Partly done: `MuteLevel.notifies` (`Models.swift:70`) and `CallLink.isAnnounced` (`Call.swift:69`) are in core and tested. The rest is still in `Notifier`. | 4.1, batch 8 |
| 9 | Styles and confirm controls | Open. Moved to polish. | section 10 |
| 12 | `JSON.decode` helper, decode the body once | Open. There are 23 inline decodes. A tribe body is decoded three times. | 5.1, batch 7 |
| 14 | Off-main reads | Open, and it has grown (new reads in Payments, time zones and contacts). | 3.1, batches 5 and 11 |
| 15 | Restore cursor and tests | Open. No test touches the history state machine. | 5.5, batch 13 |
| 16 | Engine sends many files | Open (`ChatModel.swift:257-282`). | 5.5, batch 13 |
| 17 | Docs refresh | Open. | batch 16 |
| 18 | Polling to continuations | Open, and it has grown from 5 to 11 call sites. | 3.4, batch 13 |

## 1. Bugs (ranked)

**1.1 Blank messages still count everywhere except the list (high; M; behaviour).**
- `Message.isBlank` (`Message.swift:173-177`) is only used by the list
  (`MessageViews.swift:122`). Everything else still includes blanks:
  - **Unread counts.** `countsAsUnreadSQL` (`Storage+Reads.swift:135-141`) feeds the Dock badge and the sidebar counts.
  - **Mark as unread.** `newestIncomingIndex` (`Storage+Writes.swift:426-436`) runs Mark as unread. When the newest incoming message is blank, the chat shows 1 unread with no row and no divider.
  - **First unread reply.** `firstUnreadReply` (`Storage+Threads.swift:69-83`) can open a thread at a row that is never drawn.
  - **Thread counts.** Thread count, thread unread and latest (`Storage+Threads.swift:50-54`), the `HAVING COUNT(*) >= 2` collapse (`:61`) and `threadCount()` (`:183-191`). The last one drives `isDeletable`.
  - **Sidebar.** The sidebar's last message and preview (`Storage+Reads.swift:101-102`).
  - **Notifications.** `Notifier.received` lets blank content through (`Notifier.swift:163`). It posts "New message", because the preview is "" and falls to the hidden-text body (`:295`).
- A quote of a blank parent goes nowhere:
  - `ChatRow.quote` returns `.message(parent)` for any content parent (`MessageViews.swift:210`), but that parent's row was dropped at `:122`.
  - The quote shows a sender over an empty line.
  - A click finds no row (`:497-500`).
- *Fix:*
  1. Add a stored `noWords` column in migration v17 (literal DDL), set in `Storage.store` from the status-independent half of `isBlank`. Our own pending or failed sends never count as unread, so the status part is not needed.
  2. Backfill it in Swift behind a versioned `Setting`, as `mentionScan` does. The migration stays literal-only.
  3. Add `AND NOT m.noWords` to `countsAsUnreadSQL`, the thread SQL, `threadCount` and `conversationsSQL`.
  4. `Notifier` skips `isBlank`.
  5. `quote()` returns nil for a blank parent (batch 4).

**1.2 An invite that times out can be paid for twice (med; S; behaviour; money).**
- When the server does not confirm within 30 s, `makeInvite` throws `.inviteNotConfirmed`. By then the record is stored as `.sending`, and the payment may already be published (`Engine+Contacts.swift:89-92`).
- `PaymentAttempt` treats that error as `.refused`: it clears `armed` and shows the text (`PaymentViews.swift:117-119`).
- `InviteForm` stays open with the amount still filled in, because `made` is nil (`ContactsViews.swift:434-441`).
- Confirm and Send then make a second invite. `checkPayment` may pass again because the balance may not have dropped yet.
- *Fix:* on timeout, return the `.sending` record instead of throwing. `InviteDetail` already shows "Waiting for the server to confirm". Adjust the CLI's print (`Commands+Contacts.swift:34-37`).

**1.3 `pay()`'s "nothing was sent" branch is dead (med; S; behaviour; money).**
- `pay` throws when `transport == nil` (`Engine+Payments.swift:366`).
- Nothing between there and `let unsent = transport == nil` (`:408`) suspends, so `unsent` is always false and the mark-failed branch (`:418-420`) never runs.
- If the connection drops inside `complete` before anything is published, the invoice payment stays PENDING. It is then refused as `invoicePending` for `unrecordedPaymentTimeout`, which is 30 minutes (`Message.swift:100`).
- *Fix:* catch `Failure.notConnected` from `complete`, as `makeInvite` does (`Engine+Contacts.swift:82-86`). The real fix is 5.3.

**1.4 Return in Join a tribe looks it up again instead of joining (med; S; behaviour).**
- The field's `.onSubmit { Task { await lookUp() } }` (`SidebarForms.swift:21`) runs whatever `info` holds.
- `lookUp()` (`:63-77`) does not check for an existing preview.
- The field's submit shadows Join's `.defaultAction` (`:54`).
- `join()` (`:79`) has no `!working` guard.
- *Fix:* submit joins when `info != nil` and looks up otherwise; add `guard !working` to `join()`.

**1.5 A second ⌘N window steals the web view (med; S; behaviour).**
- The main scene is a `WindowGroup` (`PeelApp.swift:20`), and nothing replaces `.newItem`, so ⌘N opens a second main window.
- There is one `WebPane` on `AppModel` (`AppModel.swift:191`).
- `WebViewHost.makeNSView` hands the same `PaneWebView` to both windows (`WebPane.swift:463`), so the first window goes blank.
- Each window's `.onDisappear { pane.close() }` (`WebPane.swift:431`) ends the page in the other window.
- `viewer`, `dropTarget` and the selection are also shared between the windows.
- *Fix:* `CommandGroup(replacing: .newItem) {}`, or make the main scene a single `Window`. Tom decides which (Q3).

**1.6 The history watchdog survives a disconnect (med; S; behaviour).**
- The watchdog is cancelled only in `finish` and `close` (`Engine+History.swift:94`, `Engine.swift:212`). `disconnect` and `teardown` leave it running (`Engine.swift:194-204,311-320`).
- 30 s after going offline mid-restore, `historyStalled` clears the run and emits `historyFailed` (`Engine+History.swift:129-134`).
- The app then marks the restore failed (`AppModel.swift:906-908`), although `cameOnline` would have resumed it (`Engine.swift:825-826`).
- *Fix:* cancel the watchdog in `teardown` and keep `history`.

**1.7 A thread's send errors are invisible when the thread takes the column (med; S; behaviour).**
- `send()` writes failures to `conversationNotices[chat]` (`ChatModel.swift:252,286`).
- `NoticeBar` exists only in `ChatColumn` (`ConversationView.swift:77-81`).
- `ChatColumn` is removed when the thread replaces it in the narrow layout (`:28-30`).
- `ThreadPanel` has no notice bar (`ThreadViews.swift:16-39`).
- *Fix:* one "notice, then composer or status bar" footer shared by both. This also removes the copied composer/`TribeStatusBar` switch (`ConversationView.swift:82-92` and `ThreadViews.swift:30-38`).

**1.8 Opening at "New messages" far up a long list lands at the end (med; M; behaviour).**
- The focus branch of `MessageList.onAppear` waits 100 ms, and its comment explains why: "After the list's initial bottom anchor, which would undo it" (`MessageViews.swift:333-339`).
- The divider branch right below it scrolls at once (`:340-343`), so `.defaultScrollAnchor(.bottom, for: .initialOffset)` (`:327`) can override it.
- The rows below the divider have only estimated heights, so even a scroll that lands is imprecise. Nothing re-tries it: `onChange(of: divider?.id)` (`:386-388`) only sets the flag.
- #68's re-pin is not the cause, because `onAppear` sets `following = false`. #68's notes record this as pre-existing.
- *Fix:* an initial `ScrollPosition(id: divider.id, anchor: .top)`, or the same deferred path `takeFocus` uses, plus one re-scroll after the first height settle while `!following && !userScrolling`.

**1.9 The Payments list cannot show stored rows past its limit (med; S; behaviour).**
- `paymentHistory(limit:)` shows the newest `limit` stored rows (`PaymentHistory.swift:124-129`).
- `limit` grows only inside `loadOlder`, after a network fetch made while connected and while `hasMore` is true (`PaymentsView.swift:284-295`).
- So:
  - offline, the list never shows more than 50 rows;
  - once a short page sets `hasMore = false`, stored rows beyond the limit are never shown.
- *Fix:* when the last row appears and `items.count == limit`, raise `limit` from storage first. Fetch from the server only when `items.count < limit`.
- *Batch 5, in review (#79):* this, 3.1's invoice check in a task, the expiry refresh (1.12) and the double refresh (3.3). The limit rises from storage at most a page ahead; while connected the server page is still fetched each time, since pings folded into payments make `items.count` an unreliable test.

**1.10 `MediaPlayback` and other state outlive an account switch (med; S; behaviour).**
- `resetAccountState` (`AppModel.swift:790-831`) never stops `MediaPlayback.shared` (`MediaViews.swift:14`).
- The player is keyed by message id, and ids are per-profile row ids. In the next account, a tile with the same id shows the previous account's player, and its decrypted file stays open.
- The reset also leaves these behind: `attachmentPrices`, `composerFocus`, `dropTarget`, `connectionError`, `reconnectAt`, `searchQuery`, `focus`, `joiningRoom` and `startingCallIn`.
- *Fix:* stop playback and reset these fields. Batch 15's `ComposerStore` and `CallState` would then reset as units.

**1.11 The image viewer (med; S; behaviour).**
- *Wrong image:* `image` is assigned after an await with no cancellation check (`ImageViewer.swift:98-99`); the video branch at `:96` has one. If you step from a slow uncached image to a cached one, the slow decode lands last and is shown under the other image's index.
- *Video keeps playing:* stepping from a playing video to an image never pauses it. Only `onDisappear` calls `closeFullScreen` (`:119`).
- *Keys from any window:* the `KeyMonitor` (`:104-115`) never checks `event.window`, unlike `MenuPresenter` (`MenuPresenter.swift:270-274`). Escape in the call window closes the viewer.
- *Fix:* check `Task.isCancelled` before assigning; close full screen when the item is not a video; ignore events from other windows.

**1.12 Smaller bugs (low; S each; behaviour).**
- **Copied words cleared early.** `Clipboard.copySecret` checks only the latest change count (`Clipboard.swift:26-36,46-51`). If the words are copied at t=0 and again at t=50, they are cleared at t=60. *Fix:* capture the change count inside each clear task.
- **Discard can fire twice, or with no confirm.** `UndeliveredActions`' confirmed Discard (`ConversationView.swift:474-481`) has no working state, so a second click calls `discard` twice. `CallCard` discards an unsent call with no confirm at all (`CallViews.swift:208`). *Fix:* both go through the shared confirm from the polish pass; until then, a `working` guard.
- **Thread quotes.** A quote whose parent sits in a collapsed thread opens the thread at its bottom with nothing lit (`MessageViews.swift:510-511`). *Fix:* `model.focus(on: parent, inThread: true)`.
- **Payment requests.** Jumping to a payment request never scrolls or lights it: `go(to:)` matches only `.message` and `.payment` (`MessageViews.swift:498`), so a notification for an invoice gives up (`:477-480`). *Fix:* include `.paymentRequest`.
- **Pinned message.** It is found only in the loaded timeline, and not when it is folded inside a collapsed thread (`ConversationView.swift:99-101`). This is first-review 3.5, still open. The doc comment calls it Mac-app parity (`TribeViews.swift:357-358`). *Fix:* read `storage.message(uuid:in:)` in the tribe observation (batch 11). Q5.
- **Fullwidth hex.** `isPubkey` accepts fullwidth hex digits (`Tribe.swift:434`), so such text passes Peel's check and then fails later with a vaguer error. *Fix:* `$0.isASCII && $0.isHexDigit`.
- **Expired invoices.** Expiry is checked only on redraw (`PaymentsView.swift:1105-1109,1128-1130,1301`), so Pay stays enabled after the invoice expires. The engine still refuses it. *Fix:* `TimelineView(.explicit([expiresAt]))`, as `WaitingForServer` does (`PaymentViews.swift:502`).
- **Day divider pill.** "Today" uses a continuous `Capsule()` stroke (`ConversationView.swift:432`). The boost chip's fix (`PaymentViews.swift:422-426`) switched to `Capsule(style: .circular)` because the continuous stroke "draws square stubs past its ends". Two more shapes have radius at or above half their height and should get an eye check:
  - the jump-to-newest button, `menuBoxed(cornerRadius: 18)` on 36 pt (`MessageViews.swift:557-558`);
  - the composer box, radius 18 on about 35 pt (`ComposerView.swift:132-133`).

  *Fix:* `.circular` for the pill, and a `style:` parameter on `menuBoxed`.

**1.13 About 100 pt of blank space under the last message (open; not reproduced).**
I did not find any code that adds about 100 pt on purpose. These are the
candidates, most likely first:

1. **The end marker sits on an estimated height.**
   - It is an overlay on the padded `LazyVStack` (`MessageViews.swift:321-322`), so its position follows the stack's estimated height rather than the last laid-out row.
   - Every "go to the end" scroll targets it (`:345,441,456`).
   - #68's notes logged "a list 197 pt past its end".
   - *Fix:* make the end a real last child (`Color.clear.frame(height: 12).id(bottomID)` in place of the bottom padding), or scroll to the last row with `.bottom`.
2. **Rows that survive #72's filter but draw little.**
   - Your own pending or failed blank text: `isBlank` excludes those (`Message.swift:174-175`), so the row is empty until Retry appears.
   - A blank message with boosts shows only the chip.
   - A blank reply to a missing parent shows only "Original message not available". `quote` returns `.missing`, not nil (`MessageViews.swift:209`).
3. **Empty children with spacing.**
   - A deleted message's `BoostLine` renders an empty VStack inside the row's `VStack(spacing: 3)` (`MessageViews.swift:664,679-681`).
   - `CallCard` keeps an empty 24 pt line while presence is unknown (`CallViews.swift:201`).
4. **Deliberate space.** The stack's bottom padding is 12 pt (`:321`) and the last run's `endsRun` padding is 4 pt (`:696`).

Outside the list, `NoticeBar`, the composer and `ReplyBar`, `TribeStatusBar`
and the app-level `NotificationOffer` inset (`PeelApp.swift:127-129`) move
the column but are not blank rows. The diagnostic build should say which of
these it is. Candidate 1 is in batch 4 regardless.

## 2. Money tracking and publishing

**2.1 Sends tracked by tag live in three places (med; M; refactor plus one behaviour decision).**
- The tags are in `message.tag`, `invoice.tag` and `invite.tag`.
- There are three readers, which `checkPendingSends` merges by hand (`Engine.swift:862-878`):
  - `pendingSends` (`Storage+Reads.swift:195-207`)
  - `pendingInvoicePayments` (`PaymentHistory.swift:167-177`)
  - `sendingInvites` (`Storage+Reads.swift:381-388`)
- Status is written two ways:
  - `setStatus` covers messages and invoices, with the same forward-only state machine written out twice (`Storage+Writes.swift:452-475`).
  - `setInviteStatus` maps onto a third vocabulary (`:590-601`) and never receives the server's failure reason.
- `chat(forTag:)` covers messages and invoices but not invites (`Storage+Reads.swift:209-221`).
- **They have drifted:**
  - A live PENDING becomes UNSETTLED (`Engine.swift:916`), and messages and invoices then stop being polled.
  - Invites ignore UNSETTLED (`Storage+Writes.swift:592-595`, `default: return`), so they stay `.sending` and are asked about again on every connect.
  - Only invoices have a test for this (`InvoiceTests.swift:190`).
- Invites store no payment hash, so the payment history cannot tie a funding payment to its invite.
- *Fix:*
  - one `pendingSendTags(textBefore:)` read;
  - one `applyStatus(tag:status:error:)` with one forward-only rule, applied to each table;
  - decide what UNSETTLED means for an invite (Q2).

**2.2 Three hand-written "commit, publish, mark failed if nothing went out" sequences (med; M; refactor that fixes 1.3).**
- The sequences are `Engine+Messages.swift:224-243`, `Engine+Payments.swift:407-421` and `Engine+Contacts.swift:79-86`.
- Each decides "unsent" differently: a transport snapshot, a dead snapshot (1.3), and `catch notConnected`.
- The "payment may have gone" sentence is written twice (`Engine+Messages.swift:232-233`, `Engine+Payments.swift:413-414`). The `deliver` copy prints a raw `\(error)` (`:233`).
- *Fix:* one `commitAndPublish(…) -> Published (.all | .none | .unknown)`. Each caller maps `.none` to failed.

**2.3 Adding a contact pays 5 sats with no check (low; S; behaviour; Q1).** `Engine+Messages.swift:16` hard-codes `amtMsat: 5000`. `addContact(code:)` (`Engine+Contacts.swift:16-25`), the new QR and paste flow, reaches it with no `checkPayment`. With the threshold at 0 ("ask for every payment"), it still pays without asking.

## 3. Inefficiency

**3.1 Main-actor storage reads (row 14; low–med; M; refactor).** These are all synchronous `pool.read`s from main-actor code:
- **Payments.** `blocker` (`PaymentsView.swift:1069` → `:1120`) calls `invoiceProblem` (`Engine+Payments.swift:346-359`, `nonisolated`). That is 3–4 reads on **every redraw** of the Pay pane. Add `paidAt` (`PaymentsView.swift:40-44`) and `oldestPaymentTimestamp` (`:19`).
- **Tribes.** `AppModel.tribe(_:)` fetches every tribe to find one (`ChatModel.swift:182`). It is used from `ConversationMenu` (`Sidebar.swift:312`), and `Notifier.flush` does the same (`Notifier.swift:186`).
- **Menus and threads.** `ConversationMenu`'s `newestIncomingIndex` (`Sidebar.swift:301`), `canDelete`'s COUNT (`ChatModel.swift:129`) and `firstUnreadReply` (`:166`). Each runs once per menu opening, not per redraw.
- **Time zones.** `withSenderZones` reads storage during every row rebuild until each sender is cached (`TimeZoneViews.swift:45`). Its cache is dropped on each chat switch (`:18`).
- **Settings in `attach`.** Some are read from storage (`AppModel.swift:841-848`) and others through the engine.
- **File copies on the main actor.** A finished web download is copied there (`WebPane.swift:322` → `Files.swift:63`), while the attachment path detaches the same call (`ChatModel.swift:440`). The "find Downloads, then save" code is written twice (`WebPane.swift:319-322`, `ChatModel.swift:435-440`).
- **Small ones.** `Clipboard.copyImage` reads the whole file (`Clipboard.swift:58`). `PendingFile.size` stats the file on every redraw (`AttachmentViews.swift:457,473`).
- **Views observing storage directly.** `PendingInviteRows` and `InviteDetail` (`ContactsViews.swift:76-86,471-480`).
- *Fix:*
  - Observe a `tribes: [String: Tribe]` map in AppModel; it replaces `tribe(_:)`, `selectedTribe` and Notifier's read.
  - Compute the invoice problem in `.task(id:)`.
  - Read settings in one engine call.
  - Add `UserFiles.saveToDownloads(_:named:) async` in PeelCore and use it from both places.

**3.2 `threads()` scans every message of yours on every write (med; S; refactor).**
- The live query filters with `threadUUID IN (SELECT … WHERE fromMe = 1 … UNION SELECT uuid … WHERE fromMe = 1)` (`Storage+Threads.swift:155-158`).
- No index leads with `fromMe` (`Storage+Migrations.swift`), so every message you have sent is read each time any write re-runs it.
- *Fix:* a correlated `EXISTS (… x.chat = t.chat AND x.fromMe = 1 AND (x.threadUUID = t.threadUUID OR x.uuid = t.threadUUID))`, which uses `message_thread` and the uuid index.

**3.3 Per-emission work (low; S–M; refactor).**
- **Payment requests.** `requests(in:)` runs 1–3 queries per payment request on every timeline emission (`PaymentHistory.swift:188-207`). `purchases(in:)` decodes every purchase body (`:275-293`). Batch both by payment hash, as `paymentItems` does.
- **Contact lookups.** `Engine.contact(_:in:)` encodes the whole core state for each lookup (`Engine+Tribes.swift:409-414`), and `isPerson` is on most send paths and in `commit`. Encode only the `c/` entry, or keep a pubkey map.
- **Row rebuilds.** Every `ChatRow.rows` rebuild decodes sender JSON, `AttachmentFields`, `CallLink` and time zones per message (`MessageViews.swift:122,156,194,220`). `ChatRow` is not `Equatable`, so every visible row re-evaluates on any change. `QuoteView` calls `model.sender(of:)` in `body`: a scan of the conversations plus a JSON decode (`MessageViews.swift:1014`, `ChatModel.swift:114-116`). *Fix:* resolve the quote's sender when the row is built, and make `ChatRow` `Equatable`.
- **Payments sections.** `PaymentsView` regroups with `Dictionary(grouping:)` on every redraw (`:307`). On connect it calls `refresh()` twice (`:236,237`).

**3.4 Polling (row 18; low–med; M).**
- `Engine.poll` (`Engine.swift:271-278`) now has 11 callers:
  - registration (`:267`);
  - payments (`Engine+Payments.swift:184,199,221,233`);
  - tribes (`Engine+Tribes.swift:189,265,290,317`);
  - invites (`Engine+Contacts.swift:89,129`), new in #75.
- `deleteTribe`'s check fetches the registry over HTTP **every 200 ms** for up to 15 s (`Engine+Tribes.swift:189-191`).
- *Fix:* give `poll` an interval now (1–2 s for network checks). Later, keyed continuations resumed in `commit`.

**3.5 Redraws (low; S; refactor).**
- **Connection card.** `ConnectionCard` ticks every second unconditionally (`Sidebar.swift:365`), but its label is constant when connected. It only runs while the popover is open. *Fix:* run the `TimelineView` only while offline with `reconnectAt`.
- **Sidebar filtering.** The sidebar filters the conversations twice per redraw (`Sidebar.swift:34,41` → `AppModel.swift:237-246`). Every `ConversationLink` also reads the whole `readStates` dictionary (`Sidebar.swift:253`), so one chat's unread tick redraws every row. *Fix:* one `sidebarSections` computation, and per-chat read state.
- **Menu anchors.** The "record the frame, then open a menu" pattern writes `@State` on every frame change in 6 places:
  - `Controls.swift:11-17` and `:60-84`;
  - `Sidebar.swift:69,75,100`;
  - `CallViews.swift:403,467,475`;
  - `CallWindow.swift:371,428`;
  - `PeelMenu.swift:217-226`.

  `PopoverModifier` on every boost chip in the scrolling list (`PaymentViews.swift:431`) is the costly one. Only `HoverCardModifier` (`PeelMenu.swift:197-206`) keeps the frame in a reference box. *Fix:* one `.menuAnchor` modifier with that box.

**3.6 Caches (low–med; S; mostly refactor).**
- **`PhotoCache`.** It is an unbounded dictionary plus a `failed` set (`Avatar.swift:101,106`), and it repeats `ImageCache`'s in-flight sharing (`ChatModel.swift:499-531`).
- **`MediaInfoCache`.** It is capped by count only (200, `MediaViews.swift:115`), and its posters are up to 640 px (`:119`). That can reach a few hundred MB, outside `ImageCache`'s 200 MB cost limit.
- **Never trimmed.** `attachmentHandles` (`AppModel.swift:101`) and `Notifier.posted` (`Notifier.swift:47`).
- *Fix:*
  - `NSCache` with a cost limit for photos and posters;
  - both image caches in one `ImageCaches.swift`;
  - prune handles to the open chat, keeping any transfer still running.

## 4. Architecture

**4.1 The notification policy is still in the app (row 8; med; M; mostly refactor).**
The pieces of the policy are spread out:
- In `Notifier`:
  - which types notify (`Notifier.swift:163-164`);
  - the read-marker gate (`:190-193`);
  - join requests only for owned tribes (`:185-186,194`);
  - restore gating (`:158-162`);
  - the money mute rule `== .all` (`:249`).
- The frontmost, selected and locked gate is written 3 times (`Notifier.swift:187-189,226-227,244-248`) and once more at `AppModel.swift:227`.
- In PeelCore:
  - money's read-marker rule is `isMoneyForMe` (`Storage+Writes.swift:325-332`);
  - invoice-paid detection is in `Engine.swift:606-615`.
- New contacts have no rule of their own.

There are concrete divergences:
- `unreadTypes` includes invoices and calls (`Message.swift:289`), so a payment request raises the badge but never notifies.
- `ChatReadState.shownUnread` (`Models.swift:97-103`) re-implements `MuteLevel.notifies`.
- `Receipt.Kind.purchase` (`MoneyArrivals.swift:22`, `Notifier.swift:283`) can never happen.
- `Engine.swift:609-610`'s "told by its `.moneyReceived`" comment is stale, and the filter under it is dead: `received` only holds types 5 and 29 (`Storage+Writes.swift:110`).

PeelApp has no test target, so none of this is tested.

*Fix:*
- A PeelCore `NotificationPolicy`: `notifies(_:readState:ownsTribe:callServer:) -> Kind?` for messages, money and new contacts, with one type set shared with `unreadTypes`.
- One "quiet here" predicate in the app.
- Drop the dead purchase case.
- Whether a payment request should notify is Q4.

**4.2 Network helpers are borrowed from the memes server (low–med; S–M; refactor plus a text change).**
- `Web.get` (`Web.swift:48`) and `CallServer.ticket` (`CallServer.swift:126-131`) use `MemesServer.Transfer`, so their refusals read "the memes server refused … (HTTP n)" (`MemesServer.swift:16`).
- A restore during a config outage therefore says "the memes server refused the config" (`ServerConfig.swift:20` via `Account.swift:93`).
- `tooLarge` prints "larger than 0 MB" for limits under 1 MB (`MemesServer.swift:18`). It is also borrowed for local files (`Files.swift:35`, `IncomingFiles.swift:83,123`, `Engine+Attachments.swift:35,37`).
- More copies:
  - JWT payload decoding, twice: `MemesServer.swift:36-42` and `CallServer.swift:214-219`.
  - "https, or http on loopback", three times: `MemesServer.swift:63`, `Web.swift:46`, `Tribe.swift:251`.
  - Hex encoding, four times: `Engine+Account.swift:9`, `MediaStore.swift:19`, `Call.swift:135`, `MediaCrypto.swift:30`.
  - "Setting, else default, none on loopback", for the memes server (`Engine+Attachments.swift:282-286`) and the call server (`Engine+Calls.swift:8-12`).
- *Fix:*
  - `Web.Transfer` with a neutral `Web.Failure`, mapped to memes or call wording at the two call sites, with sizes through `ByteCountFormatter`;
  - `JWT.payload<T>`;
  - `Web.isAllowed(_:)`;
  - `Sequence<UInt8>.hex`;
  - `configuredHost(_:default:)`.

These are the calls journals' deferred items. They are now worth it because
of the wrong error text. The `myAlias(in:)` helper is still not worth it:
its two sites differ on purpose.

**4.3 `Engine` (low; refactor).**
- About 91 public members and 56 stored properties (`Engine.swift:11-123`).
- These groups should become small structs on the actor:
  - the payment reply slots and in-flight sets (`:78-94`);
  - tribes (`:45-53,69-74`);
  - history (`:120-123`), which is the `HistoryCursor` of 5.5.
- `payingInvoices` also holds `"purchase <token>"` keys (`Engine+Attachments.swift:243-245`), so it is really "money sends in flight".
- `mentionScan` is never cancelled in `close()`.
- New ad-hoc `PeelError("…")` strings since #57: `Engine+Contacts.swift:72`, plus the older `Engine+Payments.swift:398` and `Engine+Attachments.swift:54`. One `Failure.coreReturnedNothing(String)` covers all three.

**4.4 `AppModel` (med; L; refactor).**
- `AppModel.swift` has 1,023 lines and 60 stored properties. Seven more files carry `extension AppModel`, about 811 lines between them:
  - `ChatModel` (411)
  - `CallViews` (139)
  - `TimeZoneViews` (89)
  - `PaymentViews` (74)
  - `PaymentsView` (60)
  - `ContactsViews` (32)
  - `PaidAttachmentViews` (7)
- **Composer state** is six dictionaries keyed by `ComposerID`, plus `dropTarget` (`AppModel.swift:72-85`).
- **Calls** take nine properties (`:111-139`).
- **The balance is held twice**: `AppModel.balanceMsat` (`:140`) and `MoneyArrivals.balanceMsat` (`MoneyArrivals.swift:73`).
- **Some settings are read once in `attach`** (`:839-852`) and refreshed only by this app's own setters: `pinTimeoutHours`, `paymentConfirmationMsat`, `boostAmountMsat`, `showsText`, `callServer`, `myServer` and `myContactInfo`. A CLI change on the same profile goes stale.
- *Fix:* `ComposerStore` and `CallState` as `@Observable` objects, as `Notifier` and `MoneyArrivals` already are. Keep the balance in one place.

**4.5 `PaymentsView.swift` is 1,327 lines (low; M; refactor, move-only).** Its seams:

| Lines | Content | Moves to |
|---|---|---|
| 9-68 | Model operations | `AppModel+Payments.swift` (batch 15) |
| 70-169 | `Formatting` helpers and display | `Formatting.swift`, `PaymentItem+Display.swift` |
| 370-419, 680-772 | Panes and shared pieces | `PaymentPanes.swift` |
| 421-678 | Rows and the detail pane | `PaymentRows.swift` |
| 774-998 | Receive | `ReceivePane.swift`, with the QR code in `QRCode.swift` |
| 1000-1193 | Pay an invoice | `PayInvoicePane.swift` |
| 1195-1327 | `PaymentRequestRow` | beside `PaymentRow` |

`PaymentViews.swift` splits the same way: payment controls (91-316), the
conversation's rows (318-610), and Account rows (612-698).

**4.6 Call logic in a views file (low; S; refactor, move-only).** The join, start, leave and presence logic of `AppModel` is in `CallViews.swift:16-154`. `openingCallWindow` takes an `OpenWindowAction` into the model (`:28-30`). It belongs in `AppModel+Calls.swift`, with the window opening passed in as a closure (batch 15).

## 5. Duplication

**5.1 JSON (row 12; low–med; S for the helper, M with the column; refactor).**
- There are 23 inline `JSONDecoder().decode(…, from: Data(x.utf8))` calls in PeelCore:
  - `Engine.swift:376,432,502,515,517,518,567,720,843`
  - `Engine+Account.swift:50`, `Engine+Tribes.swift:413`
  - `Invoice.swift:49,166`, `TimeZones.swift:66,183`
  - `Message.swift:131,346,357`, `Media.swift:224`, `Tribe.swift:446`
  - `Storage+Threads.swift:301`, `Storage+Reads.swift:22`, `Call.swift:83`
- `SenderInfo` is decoded in four separate places among them.
- A tribe body is decoded three times: `BodyFields.decode` at `Engine.swift:734`, again at `:486`, and again at `:763`, with `fields` still in scope.
- `json_extract(sender,'$.alias')` appears 7 times (`Storage+Reads.swift:30,32,261,265,286`; `TimeZones.swift:131,160`), with two different `json_valid` guards.
- *Fix:*
  - `enum JSON { static func decode<T>(_:) -> T? }`;
  - pass `fields` through;
  - optionally a generated `senderAlias` column with an index, as v14's `senderTZ`.

**5.2 `Storage.apply` (low; S; refactor).**
- There are four overloads (`Storage+Writes.swift:56,63,68,80`). The full one returns `[Message]` and takes three `inout` arrays.
- The 2- and 3-argument overloads exist only for tests.
- *Fix:* one `@discardableResult apply(_:) -> Applied { stored, purged, received, addedUs }`.

**5.3 Split panes and footers (low; S; refactor).**
- The web split (`WebPane.swift:410-432`) is line for line the thread split (`ConversationView.swift:19-40`).
- `WebToolbar` rebuilds `DetailHeader`'s 60 pt bar (`WebPane.swift:492-494`, `MainView.swift:227-229`).
- *Fix:* one `SidePanelSplit`, plus the shared footer from 1.7.

**5.4 Attachment and media views (low; M; refactor).**
- The failure reason is worked out four times: `AttachmentViews.swift:196-198,262`, `MediaViews.swift:339-341`, `ImageViewer.swift:39`.
- These are written twice:
  - the uploading, downloading and saved status chain (`AttachmentViews.swift:256-261`, `MediaViews.swift:421-427`);
  - the upload overlay (`:185-190`, `:272-276`);
  - the fitted tile frame (`:167-169`, `:244-246`);
  - the download task id (`:156`, `:202`).
- The "loaded, else cached" lookup is written three times (`AttachmentViews.swift:138-140`, `MediaViews.swift:240,403`).
- *Fix:*
  - `AttachmentHandle.failureReason`;
  - an `AttachmentStatus` view;
  - an `attachmentTile(fitted:)` modifier.

**5.5 App logic that belongs in the engine (rows 15, 16; M; refactor).**
- **Row 16.** Sending several files with one caption is still in `ChatModel.swift:257-282`, and the CLI sends only one file. *Fix:* `Engine.sendAttachments(…) -> [(URL, Result)]`.
- **Row 15.** The history machine (`Engine+History.swift:20-101,129-134`) is untested. *Fix:* extract a pure `HistoryCursor` that holds:
  - the active run, the queue and `awaitingCounts`;
  - `plan`, `start`, `advance(indices:total:)` and `stalled(at:)`.

  Test page advance, end by total, a page that does not advance, queueing, empty counts, and a stall that applies only to the matching cursor.
- Whether `msgsTotal` is an index or a count is worth checking against sphinx-ffi when the cursor is extracted.

**5.6 Sender resolution (row 6; low; M; behaviour, because labels change).**
- There are five resolvers:
  - `sender(of:)` (`ChatModel.swift:112-122`)
  - `avatar(fromMe:…)` (`AppModel.swift:757-761`)
  - `people(in:)` (`:354-360`)
  - `avatar(of: CallParticipant)` (`CallViews.swift:143`)
  - `Notifier.names` (`Notifier.swift:263-267`)
- Inline fallbacks bypass them at:
  - `MessageViews.swift:196,732`
  - `ConversationView.swift:398,404`
  - `TribeViews.swift:343,369,502,505`
  - `Notifier.swift:210,275,290`
  - `PaymentViews.swift:463,590`
  - `PaymentsView.swift:128,1238`
  - `TimeZoneViews.swift:156`
- "Me" fallbacks are repeated at `Sidebar.swift:78,81,118`, `AccountView.swift:98,100` and `ConversationView.swift:283`.
- *Fix:*
  - one `Sender.unnamed` ("Someone");
  - `ChatRow.row` and `sender(of:)` share one resolver;
  - an `AppModel.me`.

**5.7 Row chrome (low; M; refactor).**
- **Hover and "yours" tint** are written three times: `MessageViews.swift:697-705`, `PaymentViews.swift:575-583`, `PaymentsView.swift:1223-1227`. Only messages light while their menu is open.
- **Time tooltip.** `PaymentRow` copies `RunHeader`'s time and delivered bolt (`PaymentViews.swift:548-555`) instead of using `RunHeader`, as `PaymentRequestRow` does (`PaymentsView.swift:1213`).
- **Pending opacity** follows two different rules (`MessageViews.swift:678`, `PaymentViews.swift:570`).
- **Card box.** The call card and the request card are the same box: one continuous, one not (`CallViews.swift:235-237`, `PaymentsView.swift:1273-1275`).
- *Fix:* a `RowChrome` modifier, `PaymentRow` built on `RunHeader`, and `cardBoxed()`.

**5.8 Small shared pieces (low; S; refactor).**
- **QR codes.** `QRCode` and `QRCodeTile` are in `AccountView.swift:215-249`; Receive builds its own tile in `body` (`PaymentsView.swift:854-862`); `copyImage` is at `:977-998`. *Fix:* one `QRCode.swift` with a size.
- **Link buttons.** `PaneLink` (`PaymentsView.swift:762-773`) is repeated at `CallWindow.swift:409-411` and `AttachmentViews.swift:308-311`. *Fix:* `LinkButton`.
- **Hidden shortcut buttons**, three times: `CallWindow.swift:76-80`, `CallViews.swift:408-415`, `MessageViews.swift:570`. *Fix:* `.hiddenShortcut(_:action:)`.
- **`Formatting.shortKey`.** It is defined in `PaymentsView.swift:70-74` and re-implemented at `AccountView.swift:104` and `Sidebar.swift:109`.
- **Sats.**
  - The units 1000 and 3,600,000 are repeated: `TribeViews.swift:110-113,139-142`, `Commands+Tribes.swift:134-137`, `PaymentViews.swift:627,673`.
  - `TribeSettingsForm.text(_:unit:)` (`TribeViews.swift:123-128`), the inverse of `Sats.parse`, is private and untested.
  - `presets(_:including:)` is re-implemented for the PIN timeout (`AccountView.swift:412`).
- **The big amount block** is written four times in Payments (`PaymentsView.swift:546-556,893-899,1057-1062,1249-1254`).
- **CLI.**
  - Paging older payment history is written twice: `Commands+Money.swift:52-59` and `PaymentsView.swift:17-20`. *Fix:* `Engine.fetchOlderPaymentHistory()`.
  - `satsArgument` exists, but `pay`, `invoice` and `request` parse amounts by hand (`Commands+Money.swift:23,67,96`).
- **Error casing.** `Formatting.sentence` (capitalised, with a full stop) is used only in `ContactsViews`. Everywhere else shows lowercase `PeelError.readable`, sometimes both within one form (`ContactsViews.swift:277` vs `:290`). *Fix:* one rule, applied in `ProblemText`. This changes visible text.

## 7. Tests

| Path | Gap |
|---|---|
| Blank messages | No storage test for unread counts, threads or previews with blanks (1.1). |
| Restore | No test of the history machine (5.5). |
| Money publish | No test where the connection drops between commit and publish, for `pay`, `deliver` or `makeInvite` (1.3, 2.2). |
| Invites | Missing: UNSETTLED on an invite tag; `cancelInvite`'s balance-rise rule (`Engine+Contacts.swift:116-133`, extract a pure `refundSeen(before:now:amount:)`); the unrecorded-invite timeout. The "always confirms" check cannot be reached offline, because the connection check comes first (`Engine+Contacts.swift:57-58`). |
| Invoices | `invoiceProblem`'s balance plus `feeReserveMsat` rule (`Engine+Payments.swift:151-153,356-358`) is untested; `MoneyRefusalTests.swift:281-285` covers only expired and no-amount. |
| Parsing | `Sats.msat(_:)` (`Sats.swift:41-46`), behind every amount field and CLI amount, has no test: overflow, commas, zero and whitespace are all unchecked. |
| History gap-fill | `refreshPaymentHistory`'s loop (`Engine+Payments.swift:166-179`) needs a fake page source. |
| Migrations | `shippedSchema` is frozen at v13 (`MigrationTests.swift:5-39`). v15 (`Storage+Migrations.swift:246-252`) is never asserted. Move the snapshot to the latest version. |
| Notifications and app state | No PeelApp test target. Notifier, MoneyArrivals, `PaymentAttempt`, `ChatRow.rows` and the Payments paging are untested. The `PeelUI` target in section 9 makes them testable. |

## 8. Stale comments (low; S; docs only)

- `Storage+Reads.swift:125-134` has two doc blocks glued together; the first still says "text, attachments and direct payments".
- `Storage+Writes.swift:446-451` says only payments and boosts can be unsettled, and that "unsettled leaves it pending". The SQL disagrees on both (`:459`, and `InvoiceTests.swift:191` expects UNSETTLED).
- `Engine.swift:609` (see 4.1).

## 9. Sharing the app model with the iPhone

The iPhone foundation (iOS FFI slices, PeelCore building for iOS, a minimal
app using `Engine` and `Storage` directly) was started and is now paused, so
this section is a later item.
`AppModel` itself already compiles some platform code behind
`#if os(macOS)`, for example `isFrontmost` and `openFromNotification`
(`AppModel.swift:449-486`), and `Theme`/`Clipboard` have UIKit branches. These
things stop the iPhone from reusing the Mac app's models:

**AppKit and Mac-only types inside the model:**
- **Directly in `AppModel`:**
  - `NSApplication` (`AppModel.swift:453,482`, guarded).
  - `NSOpenPanel` and `NSSavePanel` in `ChatModel.swift:358,419`. They are guarded, but the iOS branch returns `[]`; it should be a picker the platform supplies.
  - `NSWorkspace` (`ChatModel.swift:448`).
- **Mac-only types that `AppModel` holds or calls:**
  - `Notifier` (`AppModel.swift:187`), which also sets `NSApp.dockTile` (`Notifier.swift:334`) and opens Settings through `NSWorkspace` (`:115`);
  - `WebPane`, an `NSObject` holding an `NSView` web view (`AppModel.swift:191`, `WebPane.swift:1-15`);
  - `CallSession`, which imports LiveKit (`AppModel.swift:125`);
  - `MediaPlayback.shared`, which imports AVKit (`ChatModel.swift:475`);
  - `PasteboardFiles.Item`, which imports AppKit (`ChatModel.swift:315`);
  - `Clipboard` (`AppModel.swift:398,412,793`).
- **`OpenWindowAction`** is passed into the model for calls (`CallViews.swift:28-30`).
- **The LiveKit constraint.** Any target that imports both PeelCore and LiveKit inherits the `RustBuffer` header clash and the 2.10.2 pin (`06-calls.md`, PR 3 journal). A shared model target must not import LiveKit; calls stay behind a protocol.

**Model logic that lives in view files:**
- Seven `extension AppModel` blocks sit in views (4.4).
- `ChatRow` and its `rows` builder, a pure view model, are in `MessageViews.swift:15-230`.
- `PaymentAttempt` (the confirm-then-pay state machine) is in `PaymentViews.swift:98-125`.
- The Payments paging and limit logic is in `PaymentsView.swift:284-295`.
- The time-zone sender cache is in `TimeZoneViews.swift:18-45`.
- `ImageCache` is in `ChatModel.swift:497-531`.
- `Formatting` helpers are in `PaymentsView.swift:70-97`.

**What a shared `PeelUI` library target would hold.** It depends on PeelCore
only, imports SwiftUI and Observation, and imports no AppKit, UIKit or
LiveKit:
- `AppModel` and its `+Chat`, `+Payments`, `+Calls`, `+Contacts` and `+TimeZones` extensions, moved out of the view files;
- `ChatRow`, `PaymentAttempt`, `Formatting`, `Sats` display helpers and `MoneyArrivals`;
- the notification decisions (via PeelCore's `NotificationPolicy`, 4.1);
- the image caches over `CGImage`.

Platform services become small protocols that each app injects at
`attach`:
- `FilePicking` (open, save, reveal);
- `AppPresence` (frontmost, activate, badge);
- `CallProvider` (wraps `CallSession`);
- `WebPresenting`;
- `Playback`;
- `Pasteboard`.

`Theme` can join once its colours are tokens; views stay per platform.

This also gives the app its first test target (section 7). The move is
mostly mechanical, but it touches every file that holds an `AppModel`
extension, so it runs alone when it runs (batch 17). Two of its pieces are
worth doing earlier for their own sake and are in batch 15: moving the
seven `AppModel` extensions out of view files into `AppModel+*.swift`
(4.4, 4.6), and moving the `NSOpenPanel`/`NSSavePanel`/`NSWorkspace` calls
behind one small `FilePicking` helper.

## 10. Polish: form system (not a cleanup batch)

Forms and popovers are being redesigned in the polish pass: fields,
popover containers, buttons, toggles, and the tribe header becoming Call
plus a More menu. First-review row 9 moves there. No cleanup agent should
restyle these before the design is picked. Here is the evidence the polish
work should absorb:

- **Confirms.** `InlineConfirm` lives in `TribeViews.swift:248-294` and belongs in `Controls.swift`. There are four hand-rolled variants:
  - `UndeliveredActions` (`ConversationView.swift:463,474-491`), whose double fire is in 1.12;
  - `ForgetAccountControl` (`LockView.swift:60-106`);
  - `WordsRow` (`AccountView.swift:457,523-545`);
  - `CallSwitchConfirm` (`CallViews.swift:507-547`).

  A no-confirm Discard sits in `CallViews.swift:208`.
- **Boxes.**
  - `OnboardingView.boxed()` (`OnboardingView.swift:527-530`, radius 8) is `fieldBoxed` (`Styles.swift:6-11`, radius 6) without the padding.
  - There are radius-7 input boxes (`PaymentViews.swift:313-314`, `PaymentsView.swift:1031-1032`).
  - Panel boxes outside `panelBoxed`: `SidebarForms.swift:43`, `ContactsViews.swift:320`, `OnboardingView.swift:248-249`.
  - `RoundedRectangle(cornerRadius:` appears 84 times with 9 literal radii (8 ×23, 10 ×18, 6 ×13, 7 ×10, 5 ×5, 9 ×4, 12 ×4, 18 ×2, 14 ×1).
  - `Styles.swift` has three `extension View` blocks (`:3,14,29`).
- **Fields.**
  - `.roundedBorder` is used in `SidebarForms.swift:20`, `ContactsViews.swift:199,215,420,423` and `TribeViews.swift:69,72,74,185`.
  - `fieldBoxed` is used in the payment panels.
  - `InviteForm` mixes both (`ContactsViews.swift:418` and `:420`).
- **Popover skeleton.** The title at 15 bold, `VStack(spacing: 12)`, padding 16 and a fixed width are written five times: `SidebarForms.swift:15-17`, `ContactsViews.swift:170-172,411-413,469-470`, `PaymentViews.swift:236-240`.
  - The code preview card (`ContactsViews.swift:302-321`) is the Join a tribe preview (`SidebarForms.swift:24-43`).
  - `InviteForm`'s footer hand-builds what `FormFooter` does (`ContactsViews.swift:428-442`).
- **Edit tribe fields have no labels.** Name, "What it is about" and the image link are placeholder-only `TextField`s (`TribeViews.swift:68-74`). Once filled, which is always the case when editing, nothing says what each field is.
- **Dashed unknown-person icon.**
  - `PaymentAvatar`'s nil branch (`PaymentsView.swift:468-473`, 1.5 pt, dash [3,2]) and `InviteIcon` (`ContactsViews.swift:129-143`, 1 pt, dash [2,2]) have drifted, though the comment says one copies the other.
  - The dashed drop zone is also repeated three times (`ContactsViews.swift:252-255`, `AttachmentViews.swift:406,558-560`).
- **Big amount block** (5.8) and **error casing** (5.8).

## Questions for Tom

1. **Adding a contact pays 5 sats with no check** (2.3). Should it ask when the threshold is 0, and fail early on a zero balance?
2. **UNSETTLED for an invite** (2.1). Should the invite stay "sending" and keep being asked about, or show as unconfirmed like a payment?
3. **⌘N** (1.5). Should Peel be single-window, or should each window get its own web pane and selection?
4. **Payment requests** (4.1). They count as unread but never notify. Should they notify?
5. **Pinned messages beyond the loaded 200** (1.12). Keep the Mac app's behaviour, or read the pin from storage?

## Cleanup plan

The batches are grouped by the files they touch, so a wave's batches can
run as parallel agents. "After" means rebase onto that batch once it has
merged. Batches marked **behaviour** need Tom's eye.

| # | Batch | Items | Files | Kind | Size | After |
|---|---|---|---|---|---|---|
| 1 | **Core money and restore fixes** | 1.2 invite timeout (with its form), 1.3 `pay` unsent, 1.6 watchdog, `isPubkey` (1.12); tests for each | `Engine+Contacts`, `Engine+Payments`, `Engine.swift` (teardown), `Tribe.swift` (`:434`), `ContactsViews` (`InviteForm` only), `Commands+Contacts`, Tests | behaviour | S–M | — |
| 2 | **App fixes** | 1.4 Join on Return, 1.5 ⌘N, 1.10 reset on account switch, 1.11 viewer, copy secret (1.12) | `SidebarForms`, `PeelApp.swift`, `AppModel` (`resetAccountState` only), `ImageViewer`, `Clipboard` | behaviour | S | — |
| 3 | **Blank messages** | 1.1 storage and Notifier, the v17 column and backfill, the schema snapshot moved to v17, tests | `Storage+Migrations`, `Storage+Writes`, `Storage+Reads`, `Storage+Threads`, `Message.swift`, `Notifier` (`received` only), `MigrationTests`, `StorageTests`/`ThreadTests` | behaviour | M | — |
| 4 | **Chat column fixes** | 1.7 thread notices and the shared footer, 1.8 "New messages", 1.13's end marker, the blank or missing quote (1.1), thread and payment-request jumps, the pill and capsule shapes (1.12), `SidePanelSplit` (5.3) | `MessageViews`, `ConversationView`, `ThreadViews`, `WebPane` (split only, `:410-432`), `ComposerView` (one line), `Styles` (`menuBoxed` style) | behaviour | M | — |
| 5 | **Payments screen fixes** | 1.9 limit, invoice problem out of `body` (3.1), expiry refresh, double refresh | `PaymentsView` | behaviour | S | — |
| 7 | **Core tidy** | 5.1 `JSON.decode` and the body decoded once, 5.2 `apply` result, 3.2 `threads()`, 3.3 request batching, section 8 comments | `Engine.swift`, `Engine+Account`, `Engine+Tribes`, `Engine+Attachments`, `Engine+Payments`, `Invoice`, `TimeZones`, `Message`, `Media`, `Tribe`, `Call`, `Storage+Reads`, `Storage+Threads`, `Storage+Writes`, `PaymentHistory`, Tests | refactor | M | 1, 3 |
| 8 | **Notification policy** | 4.1 `NotificationPolicy` in PeelCore with tests; one "quiet here" predicate; dead purchase case | new `PeelCore/NotificationPolicy.swift`, `Models.swift`, `Notifier`, `MoneyArrivals`, Tests | refactor (Q4 would add behaviour) | M | 3 |
| 9 | **Money sends in one place** | 2.1 one tag read and one status rule, 2.2 `commitAndPublish`, a `Failure` for "core returned nothing" (4.3), invite UNSETTLED per Q2; tests for dropped publishes | `Engine.swift` (`checkPendingSends`), `Engine+Messages`, `Engine+Payments`, `Engine+Contacts`, `EngineTypes`, `Storage+Reads`, `Storage+Writes`, `PaymentHistory`, Tests | refactor plus Q2 behaviour | M | 7 |
| 10 | **Network helpers** | 4.2 `Web.Transfer`/`Web.Failure`, `JWT.payload`, `Web.isAllowed`, `.hex`, `configuredHost`; `UserFiles.saveToDownloads` (3.1) | `Web`, `MemesServer`, `CallServer`, `ServerConfig`, `Files`, `IncomingFiles`, `Engine+Attachments` (`tooLarge` only), `MediaStore`, `MediaCrypto`, `Call.swift` (`:135`), `Engine+Account` (`:9`), `Engine+Calls`, `Tribe.swift` (`:251`), Tests | refactor plus error text | S–M | 7 |
| 11 | **App reads and redraws** | 3.1 tribes map (replaces `tribe(_:)`, `selectedTribe`, Notifier's read), the pin from storage (Q5), settings in one engine call, sender zones off main, invites observed in the model; 3.5 connection card, sidebar sections, per-chat read state | `AppModel`, `ChatModel`, `TimeZoneViews`, `Sidebar`, `ConversationView` (pin), `TribeViews` (pin bar), `ContactsViews`, `Notifier` (one line), `Engine+Account` (settings read) | refactor (pin is behaviour) | M | 2, 4, 8 |
| 12 | **Media, caches and web download** | 3.6 caches; 5.4 attachment views; the web download off main through batch 10's helper | `Avatar`, `MediaViews`, `AttachmentViews`, `PaidAttachmentViews`, `ImageViewer`, `WebPane` (download), `ChatModel` (save and `ImageCache` out to `ImageCaches.swift`) | refactor | M | 2, 4, 10 |
| 13 | **Engine structure** | 5.5 `HistoryCursor` with tests (row 15), `sendAttachments` (row 16), 3.4 `poll` interval then continuations (row 18), engine sub-state structs and `contact()` encoding (4.3, 3.3) | `Engine.swift`, `Engine+History`, `Engine+Tribes`, `Engine+Payments`, `Engine+Contacts`, `Engine+Attachments`, `ChatModel` (send), `Commands+Chat`, Tests | refactor | L | 9, 10, 12 |
| 14a | **One sender and row chrome** | 5.6 sender resolution, 5.7 `RowChrome`, `RunHeader` for payments, `cardBoxed`, quote sender at build time (3.3), `ChatRow` `Equatable` | `MessageViews`, `PaymentViews`, `PaymentsView` (rows), `CallViews`, `ConversationView`, `TribeViews`, `TimeZoneViews`, `Sidebar`, `AccountView`, `Notifier`, `ChatModel` | behaviour (labels) | M | 4, 8, 11, 12 |
| 14b | **Payments split and helpers** | 4.5 move-only split; `QRCode.swift`, `shortKey`, the big amount block, the Sats units and `text(_:unit:)` with tests, `presets`; the CLI's `satsArgument` and `fetchOlderPaymentHistory`; `Sats.msat` tests | `PaymentsView` → new files, `PaymentViews`, `AccountView`, `Formatting`, `TribeViews` (Sats only), `Sats.swift`, `Engine+Payments` (one function), `Commands+Money`, `Commands+Tribes`, Tests | refactor | M | 14a, 13 |
| 14c | **Menus and small controls** | 3.5 `.menuAnchor`; `LinkButton`, `.hiddenShortcut` (5.8) | `Controls`, `Sidebar`, `CallViews`, `CallWindow`, `PeelMenu`, `PaymentViews`, `MessageViews`, `AttachmentViews` | refactor | S | 14b |
| 15 | **AppModel decomposition** | 4.4 and 4.6: the seven `AppModel` extensions move out of view files into `AppModel+Chat`, `+Calls`, `+Payments`, `+Contacts`, `+TimeZones`; `ComposerStore`, `CallState`, one balance, settings kept fresh from the engine; file pickers behind one `FilePicking` helper | `AppModel`, `ChatModel` → `AppModel+Chat`, `CallViews`, `PaymentViews`, `PaymentsView`, `ContactsViews`, `TimeZoneViews`, `PaidAttachmentViews`, `ComposerView`, `ComposerField`, `CallWindow`, `MoneyArrivals` | refactor | L | 11–14 |
| 16 | **Docs refresh** | First-review row 17, plus AGENTS.md for every move above | `docs/*`, `AGENTS.md` | docs | S | 15 |
| 17 | **Later: iPhone seams, a `PeelUI` target** | Section 9: `ChatRow`, `PaymentAttempt`, `Formatting`, `MoneyArrivals`, the image caches and `AppModel` into a `PeelUI` library target; platform protocols for pickers, presence, calls, web, playback and pasteboard; a `PeelUITests` target with first tests for `ChatRow.rows` and `PaymentAttempt`. Paused with the iPhone work | `Package.swift`, every `AppModel*` file, `MessageViews` (`ChatRow`), `PaymentViews`, `Notifier`, `PeelApp.swift`, new `Sources/PeelUI/`, new tests | refactor (move plus protocols) | L | 15; when the iPhone work resumes |
| P | **Polish: form system** | Section 10; done by the polish work, not a cleanup agent | the form and popover views | design | — | the polish design; after wave 1 |

**Status.**
- **Batch 1:** in review, #80 (2026-10-08). It also touches `Transport.swift`, `Engine+History` (`request`) and `AddContactForm`, which Q1 needed. Left for batch 9: `deliver`'s `transport == nil` snapshot, the three "may have gone" sentences, and `inviteNotConfirmed`'s unused text.
- **Batch 4:** in review (2026-10-08). 1.13's end marker left as it is: since #84 the list ends flush on its last row (checked on a copy of `og-div2`), so no scrolling changed for it.
- **Batch 7:** in review (2026-10-08). Left as they are: the decodes that throw or read `Data` (their errors are what the caller reports), the `json_extract(sender,'$.alias')` copies and the `senderAlias` column (5.1, optional), and 3.3's contact lookups (batch 13). `threads()` now finds a reply of ours in the thread's own chat only, which every reply of ours is.
- **Batch 9:** in review (2026-10-08). Q2 applied: an invite whose funding payment is unsettled stays sending. Left as they are: `inviteNotConfirmed` (only `confirmedInvite`'s poll timeout, caught there), invites storing no payment hash, `chat(forTag:)` without invites (an invite has no chat), and "the attachment was not stored" (`Engine+Attachments`, a storage refusal, not the core's).
- **Batch 10:** in review (2026-10-08). `UserFiles.saveToDownloads` is added but not yet used: `ChatModel` and `WebPane` move to it in batch 12. A memes token's `exp` is now read only from a three-part JWT of at most 8 KB, as a call token's is; any other token is used for one call, as one with no `exp` was.
- **Batch 11:** in review (2026-10-08). The pinned message is now read from storage however old (Q5), the one behaviour change; it follows the pin and the message's edits and deletes. Sender zones are read off the main thread and the rows rebuilt when they come back, a moment after the chat draws. An invite's detail now follows the model's observation of every invite made here; an observation error shows as the window's notice rather than in the detail. Left as they are: 3.1's menu and thread reads (once per menu opening), Payments (batch 5), and `Notifier`'s `storage`, now only a sign that it is attached.
- **Batch 12:** in review (2026-10-08). Photos now share `ImageCache`'s code in its own 64 MB instance, so the viewer's full-size images never push them out; posters count towards a 64 MB limit. Left as they are: 3.6's never-trimmed `attachmentHandles` and `Notifier.posted` (`AppModel` and `Notifier` were not this batch's files). Saving to Downloads with no Downloads folder now says so, where it silently did nothing.
- **Batch 13:** in review (2026-10-09). `HistoryCursor` (the run, the queue, `awaitingCounts`; `plan`, `start`, `advance(indices:total:)`, `stalled(at:)`) with its own tests; `Engine.sendAttachments` sends a composer's files and the caption, used by `ChatModel` and the CLI (`send-file` now takes several paths and, as the app, sends the caption alone when its file is refused); `TribeWork` and `MoneyWork` group the session bookkeeping (`payingInvoices` is `money.sendsInFlight`); `contact(_:in:)` encodes only the `c/` entry, all `get_contact` reads. `poll` waits are woken by each commit instead of every 200 ms, and the registry check of `deleteTribe` runs once a second. Because a woken wait returns at once, `connect` now also waits for `cameOnline` to ask for history, which the 200 ms tick had covered (a restore otherwise read as not syncing). Left as it is: `msgsTotal` is the server's eighth topic segment as sphinx-rs passes it on, so whether it is an index or a count is the mixer's to say; taken as an end index, a count costs at most one empty page. `mentionScan` is still not cancelled in `close()`.
- **Batch 14a:** in review (2026-10-08). One `Sender` (`ChatRow.People.sender(of:inTribe:)`), used by the rows, `sender(of:)`, quotes (now resolved when the rows are built), boosts, threads and calls, and `AppModel.me`; one fallback word, `Sender.unnamed` ("Someone"). Labels that change: a tribe member with no alias is "Someone" (was "Unknown") in their run header, time tooltips, person card and a paid attachment's footer, with "?" initials (was "U"); in the moment before your alias (or a DM's conversation) is known, your (its) row initials are "?" (were "Y", "S"); a call participant's tooltip for you without an alias is "You" (was "?"). Payment rows now light while their menu is open, as messages do. `MessageRow` is `Equatable`; quotes reach the list through `goToMessage` in the environment. Also touched: `AppModel` (`me`, `people`, `avatar`), `Styles` (`cardBoxed`), `CallWindow`, `ImageViewer`, `ThreadViews`, `PaidAttachmentViews`. Left as they are: `Notifier.names` (a chat's name, not a sender's) beyond its fallback word.
- **Batch 14b:** in review (2026-10-09). `PaymentsView` split, moved verbatim: the screen stays, with `PaymentItem+Display`, `PaymentPanes` (`PaneFrame`, `KeyValues`, `AttentionNote`, `PaneLink`, `UntilExpiry`, and the new `BigAmount` for the four big amounts), `PaymentRows`, `ReceivePane`, `PayInvoicePane`; `PaymentRequestRow` joins the chat's payment rows in `PaymentChatRows`, out of `PaymentViews`. `QRCode.swift` holds `QRCode` (with `copyImage`) and `QRCodeTile`, which now takes a size and Receive uses (its corners 8 pt, were 10). `Formatting` takes the payment times and `shortKey` (now also the Account header's). `Sats.msatPerSat`, `Sats.millisecondsPerHour` and `Sats.text(_:unit:)` (was `TribeSettingsForm`'s), tested with `Sats.msat`. `presets` is shared with the PIN timeout, which now sorts an off-list value among the choices (it went last). `Engine.fetchOlderPaymentHistory()` for the app and the CLI's `history`; `pay`, `invoice` and `request` read amounts with `satsArgument`, so a bad amount says "the amount must be a whole number of sats above zero". Left as they are: `Sidebar`'s short key and `Commands+Chat`'s `--price` (not this batch's files); `PaymentViews`' controls and Account rows stay in it, unmoved, as the form rework touches them.

### Waves

1. **Wave 1, parallel:** 1, 2, 3, 4 and 5.
   - Their files do not overlap.
   - 1's `ContactsViews` hunk is only `InviteForm`, which nothing else in the wave touches.
   - 4's `WebPane` hunk is only the split.
   - All five are behaviour changes, so Tom reviews each.
2. **Wave 2, parallel:** 7 (core tidy) and 8 (notification policy).
   - 7 is PeelCore only. 8 touches `Notifier`, `MoneyArrivals`, `Models.swift` and a new core file, none of which 7 touches.
3. **Wave 3, parallel:** 9 (money sends), 10 (network helpers) and 11 (app reads).
   - 9 and 10 are PeelCore only and share no file. 11 is app only, apart from one engine accessor in `Engine+Account`, which 10 touches at `:9` only.
4. **Wave 4:** 12 (media), then 13 (engine structure).
   - 12 waits for 10's helper and shares `ChatModel` with 11, in different functions.
   - 13 touches most `Engine+*` files and `ChatModel`'s send, so it runs alone.
5. **Wave 5, in order:** 14a, then 14b, then 14c, then 15. They share view files throughout. 16 comes after them.
6. **Later:** 17, the iPhone seams, when the iPhone work resumes. It touches every `AppModel` file, so nothing else in the app should be in flight while it runs.

**Must be sequenced:**

| Pair | Shared files |
|---|---|
| 3 → 7 → 9 | Storage files |
| 1 → 9 | `Engine+Contacts`, `Engine+Payments` |
| 3 → 8 | `Notifier` |
| 8 → 11 | `Notifier` |
| 10 → 12 | `Files` |
| 9, 10, 12 → 13 | `Engine` files, `ChatModel` |
| 4 → 14a | `MessageViews`, `ConversationView` |
| 14a → 14b → 14c → 15 | `PaymentViews`, `PaymentsView`, `Sidebar`, `AppModel` files |
| 15 → 17 | every `AppModel` file |

Any batch that adds a migration takes the next free number, and only batch
3 adds one here (v17). A `senderAlias` column (5.1) would be a later
migration, and it is optional.
