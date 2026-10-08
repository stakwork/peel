# Architecture review, 2026-10-08

Scope: `origin/main` at `5b7afb8` (#24, one-tap boost). I also skimmed the open
branches: `phase3/unread` (#23), `fix/boost-status` (#26), and the docs-only
`docs/audit-phase` (#12) and `docs/phase9-acp` (#15). `phase4/boosts-payments`
(#16) and `chore/ignore-claude-dir` (#14) are already merged. Line numbers are
on `origin/main` unless a branch is named. No code was changed.

`phase4/payments` has not been pushed, but it exists locally at `3454c5b`.
It is +3,783 lines over 21 files:

- a new migration **v13**, which assumes #23's v12 lands first
- `Engine.swift` +467
- new `PaymentHistory.swift` (585), `Invoice.swift` (184) and `PaymentsView.swift` (1,245, born oversized)
- `PaymentViews`, `MessageViews` and `PeelCommand` edits

It is the biggest thing in flight. Every Engine, Storage, PaymentViews or
PeelCommand refactor below should also wait for it. Before it opens, it should
split `PaymentsView.swift` and reuse the shared sats and sender helpers.

## Verdict

The engine boundary held through the day's 25 PRs.

- PeelCore imports no UI framework and has no globals or singletons.
- Every core call goes through one commit path (`Engine.run`/`commit`; `deliver` is the one documented second entry).
- Almost every user action is a typed engine operation.
- Storage has good offline tests.

The debt is in two places. The first is the app layer, where each PR wrote its
own copy of the same small things:

- sender name and photo resolution, 7 copies, with three different fallbacks
- sats formatting, 3 copies in the app and about 9 truncating copies in the CLI
- in-place confirm controls, 4 hand-rolled
- row chrome
- error-to-text conversion, 3 patterns

The second is four oversized files: `Engine.swift` (2,325 lines),
`Storage.swift` (1,404), `MainView.swift` (1,092) and `PeelMenu.swift` (798).

Three findings matter beyond tidiness:

- Engine and observation errors reach `AppModel.notice`, which only the onboarding screen shows. Once the app is open they are silently dropped.
- Forgetting the account leaves the old engine, its storage and four observation tasks running.
- Migrations and partial indexes are built from live Swift constants.

I found no money-correctness bug on main. The riskiest paths (payment refusals,
tribe membership transitions, history restore, read markers) have no tests.
Read markers get tests in #23.

**Merge order for in-flight work:** land #26 first, then rebase #23. They
conflict for certain in `PaymentViews.swift` L28: #23 edits
`AppModel.boost(_:tipMsat:confirmedMsat:)` and #26 deletes it. They also
conflict in `Storage.swift` at `BoostSummary.Boost` and its initializer
(~L327/L940). Every refactor PR below waits for both unless it says otherwise.

**Question for #26 before it merges:** `pendingSends` selects only
`status = 'PENDING'` (`Storage.swift:624`), and so does the `message_pending`
index (`Storage.swift:191`). An UNSETTLED payment is therefore never asked
about again with `getTags` after a restart. The new docs say "a later COMPLETE
or FAILED still lands", but that is only true while the app stays connected.
Confirm this is intended or add UNSETTLED to the query.

## File sizes

| File | Lines | Natural seams |
|---|---|---|
| `PeelCore/Engine.swift` | 2,325 | types and `Failure` (1–260) · account and settings (344–473) · connection (475–625) · messages, delete, resend, deliver (625–1035) · payments (763–930) · attachments and memes (1036–1241) · tribes (1243–1700) · core contract (1709–2093) · history and restore (2095–2302) |
| `PeelCore/Storage.swift` | 1,404 | init/lock (1–44) · migrations (45–195) · public models `Setting`, `Conversation`, `ChatReadState`, `Timeline`, `BoostSummary`, `ThreadSummary`, `ChatThread` (212–372) · reads and live queries (376–779) · threads (781–1008) · commit and writes (1012–1404) |
| `PeelApp/MainView.swift` | 1,092 | shell and `PaneDivider` (1–92) · sidebar (94–533) · popover forms (535–745) · detail (747–834) · `Avatar` and `PhotoCache` (836–940) · box styles, `Clipboard`, `Formatting` (942–1092) |
| `PeelApp/PeelMenu.swift` | 798 | `MenuEntry` model (1–115) · `MenuPresenter` (116–360) · menu views (361–537) · controls `MenuButton`, `HoverIconButton`, `PeelDropdown` (538–630) · AppKit `KeyMonitor`, `RightClickCatcher`, `FloatingWindow` (630–798) |
| `PeelApp/AccountView.swift` | 753 | fine by section; `GhostButtonStyle` (732) belongs with the other styles |
| `PeelApp/AppModel.swift` + `ChatModel.swift` | 748 + 433 | `ChatModel.swift` is an `extension AppModel`, not a model, and also holds `AttachmentHandle` and `ImageCache`. `PaymentViews.swift:16–101` is also an `AppModel` extension. |
| `PeelCore/Media.swift` | 744 | `MediaCrypto` · `MediaToken` · `MemesServer` (HTTP) · `MediaStore` cache · `AttachmentFields` · `ImageDecoding`/`ProfilePhoto`/`UserFiles` |
| `PeelApp/PaymentViews.swift` | 691 | #26 removes ~120 lines (`BoostPanel`, `AmountLine`, `boostCost`) |
| `PeelApp/MessageViews.swift` | 690 | `ChatRow` builder (1–163) is a pure view-model; #23 adds about 230 lines |
| `peel/PeelCommand.swift` | 656 | one 330-line `switch` in `run()` (90–458); output helpers (459–560) |

## 1. Duplication

**1.1 Sender name and photo resolution, 7 copies (med).**
- `ChatModel.swift:103` `sender(of:)`: fallback "Someone", avatar "?"
- `AppModel.swift:262` `people(in:)`: "You"/"Someone"
- `MessageViews.swift:125` `ChatRow.row`: tribe member fallback "Unknown"
- `MessageViews.swift:423` `RunHeader`: "Unknown"
- `PaymentViews.swift:416,470–473`: BoostChip and BoostersPanel redo `fromMe ? myAlias : alias`
- `Notifier.swift:196,204,214`, `ConversationView.swift:369,375`, `TribeViews.swift:325,351,483`: "Someone"

The same person shows as "Unknown" in a row and "Someone" in its quote.

*Fix:* add one `AppModel.sender(of:)`, or a `SenderNames` struct built per chat, returning `(name, avatarName, photoURL)` with a single fallback. `ChatRow.rows` takes it instead of `People`, and BoostChip, BoostersPanel, Notifier and the notes call it.

**1.2 Sats formatting and parsing (med; money is shown wrong in the CLI).**
- App: `Formatting.sats(msat: UInt64)` `MainView.swift:1085`; the `Int64` overload and `satsNumber` `PaymentViews.swift:103–113`; `TribeSettingsForm.text` `TribeViews.swift:116`.
- Engine: `Failure.needsConfirmation` description divides by 1000 (`Engine.swift:126`), so 1,999 msat reads "1 sats".
- CLI: 9 truncating `/ 1000` at `PeelCommand.swift:161,235,315,435,500,522,547,548,616`. A tribe price of 1.5 sats prints "1 sats/msg".
- Two parsers: `Sats.msat` (`Message.swift:172`, whole sats, commas allowed) and the free public function `amount(_:unit:of:)` (`Tribe.swift:339`, decimals).
- `SatsField` filters input itself (`PaymentViews.swift:233`). `BoostPanel` does `tip * 1000` by hand (`:259`).
- Preset lists differ: `[10,50,100,500]` sats (`:252`) and `[10…1000]*1000` msat (`:620`).

*Fix:* move `Formatting.sats` into PeelCore as `Sats.format(msat:)`; it is Foundation-only. Use it in the CLI and in `Failure.description`. Rename `amount(...)` to `Sats.parse(_:unit:)` so it is not a module-level free function.

**1.3 In-place confirm controls, 4 hand-rolled (low-med).**
- `InlineConfirm` (`TribeViews.swift:239`) exists. The others are:
  - `UndeliveredActions.confirmingDiscard` (`ConversationView.swift:419–453`)
  - `ForgetAccountControl` (`LockView.swift:60–106`)
  - `WordsRow.confirmingCopy` (`AccountView.swift:439,505–520`)
- They disagree on order and words: InlineConfirm shows Cancel then the action; UndeliveredActions shows Discard then "Keep".
- Two other confirm mechanisms are deliberately different: the menu's `destructive(confirm:)` and the money `PayButton`/`ConfirmHint`.

*Fix:* give `InlineConfirm` an optional explanation and a cancel title, use it in the three places, and fix one order.

**1.4 Row chrome (low).**
- The hover/fromMe tint is duplicated in `MessageRow` `MessageViews.swift:371–379` and `PaymentRow` `PaymentViews.swift:568–574`.
- The time plus full-date help is in `MessageViews.swift:427–431` and `PaymentViews.swift:539–543`.
- The green "Delivered" bolt is in `MessageViews.swift:432–437` and `PaymentViews.swift:544–549`.
- The pending opacity rule is in `:354` and `:563`.
- "deleted" wording: "This message has been deleted" (`MessageViews.swift:556`), "Message deleted" (`Message.swift:159`), "This payment has been deleted" (`PaymentViews.swift:585`).

*Fix:* add a `RowChrome` modifier and a `SentTime` view.

**1.5 Box and button styles spread over four files (low).**
- Box helpers: `fieldBoxed` (radius 6, `MainView.swift:262`), `boxed` (radius 8, `OnboardingView.swift:561`), `panelBoxed`/`menuBoxed` (`MainView.swift:944–954`).
- Button styles: `GhostButtonStyle` (`AccountView.swift:732`), `Primary`/`SecondaryButtonStyle` (`OnboardingView.swift:522–548`).
- Forms use `.roundedBorder` in places (`MainView.swift:551,660`, TribeSettingsForm) where the payment panels use `fieldBoxed`.
- There are 51 ad-hoc `RoundedRectangle(cornerRadius:)`.

*Fix:* move all of them into `Styles.swift` beside `Theme`, with two radii as tokens.

**1.6 JSON decoding of bodies and senders (low).**
- Decoders: `BodyFields` (`Message.swift:250`), `DeclaredAmount` (`:267`), `AttachmentFields` (`Media.swift:634`), `SenderInfo` (`Message.swift:234`).
- About 12 inline `JSONDecoder().decode(…, from: Data(x.utf8))`: `Engine.swift:337,1641,1745,1834,1847,1849,1856,1897,2026,2134`, `Storage.swift:415,996`.
- A tribe message's body is decoded twice (`Engine.swift:2040` and again at `:1818`).
- `Message.senderInfo` decodes on every access.
- SQL repeats `json_extract(sender, '$.alias')` at `Storage.swift:84,423,425,677,681,702`.

*Fix:* add a `JSON.decode<T>(_ string: String?) -> T?` helper. Return `BodyFields` from `message(from:)` so `commit` reuses it.

**1.7 SQL fragments (low).**
- "Is this chat a tribe" is written 9 ways: `Storage.swift:185,410,424,450,481,553,735,792,1222`.
- Status literals are inline: `'PENDING'`/`'FAILED'`/`'COMPLETE'` at `:191,624,1331`. #26 adds `'UNSETTLED'` in more places.

*Fix:* add `static let tribeChats = "SELECT pubkey FROM tribe"` and bind `Message.Delivery` raw values as arguments.
*Done 2026-10-08 (#60), in part:* `tribeChats` replaces the four copies of that exact subquery. The status literals stay inline: `status = ?` would stop `pendingSends` using the partial index `message_pending`, and `setStatus` compares `?1` with them throughout.

**1.8 Image caches, 2 (low).** `PhotoCache` (`MainView.swift:901`, remote URLs) and `ImageCache` (`ChatModel.swift:401`, local files) both wrap `ImageDecoding.thumbnail` with in-flight dedupe. *Fix:* one `ImageLoader` with a URL key and two fetchers, in its own file.

**1.9 Three money double-click guards (low).** They are `AppModel.moneyInFlight` (`PaymentViews.swift:85`), `PaymentAttempt.working` (`:130`) and `Engine.quickBoostGap` (`Engine.swift:840`). #26 replaces the gap with "once per message". After #26, decide whether `moneyInFlight` is still needed beside `PaymentAttempt`.

## 2. Inconsistent patterns

**2.1 Errors are surfaced three ways, and engine errors are dropped once the app is open (high).**
- `AppModel.notice` gets `.coreError` events (`AppModel.swift:623`) and every observation failure (`:668,681,701,710,728,739`). It is shown only in `OnboardingView.swift:25`.
- So these failures are never seen in the main window: "coming online: …", "checking mentions", "saving tribes", a dead `timeline` observation.
- Elsewhere there are three styles:
  - `attempt` writes to `conversationNotices` through `PeelError.readable` (`AppModel.swift:413`).
  - `PaymentOutcome` (`PaymentViews.swift:7`).
  - 19 view-local `problem = "\(error)"` raw strings (`AccountView.swift:170,289,402,648`, `MainView.swift:604,616,680`, `TribeViews.swift:152,463`, `ConversationView.swift:295,307,320,330`, `LockView.swift:54,90`, `OnboardingView.swift:210`), which print NSError dumps for network errors.
- `markSelectedChatRead` uses `"\(error)"` (`AppModel.swift:447`) while `markRead` uses `readable`.

*Fix:* show `notice` in the main window as a quiet dismissible bar (tom-ui: not red). Use `PeelError.readable` in every `catch`.

**2.2 Settings are read two ways (low).** `attach` reads some settings through engine accessors (`pinTimeoutHours`, `paymentConfirmationMsat`, `boostAmountMsat`) and others straight from storage (`contactInfo`, `server`, `balanceMsat`, `AppModel.swift:586–590`). `Storage.set(_:for:)` is `public` (`Storage.swift:396`), so nothing stops a client writing `.clock` or `.needsRestore`. *Fix:* make `set` internal and read settings through the engine.
*Done 2026-10-08 (#60), in part:* `set` is internal; reading settings through the engine is still open.

**2.3 Naming (low).**
- `ChatModel.swift` holds `extension AppModel`; it should be `AppModel+Chat.swift`, as should `PaymentViews`' extension (`AppModel+Payments.swift`).
- `TribeHeader` and `TribeMembersPanel` live in `ConversationView.swift:125–333` but belong in `TribeViews.swift`.
- AGENTS.md describes "ChatModel" as if it were a type.

**2.4 Typed failures and string failures mixed in Engine (med, agent-native).** `Engine.Failure` has 28 cases, but 19 refusals are ad-hoc `PeelError("…")`: `Engine.swift:358,404,456,713,742,757,884,1059,1079,1279,1281,1312,1356,1380,1388,1398,1416,1476,1496`. An agent tool or the UI cannot match "tribe price rose" or "already answered". Also, `noMemesServer`'s text tells the user to pass `--memes-host` (`:146`), which is a CLI flag inside an engine message. *Fix:* add `Failure` cases and keep the words in `description`.

## 3. Boundary violations

**3.1 The notification policy lives in the app (med, agent-native).**
- `Notifier.flush` decides what notifies: past the read marker, by mute level, mentions-only, and join requests only for owned tribes (`Notifier.swift:172–210`).
- It repeats `ChatReadState.shownUnread` (`Storage.swift:285`).
- The engine already has a third rule set for `.moneyReceived` (`Engine.swift:35–40`, `Storage.swift:1251`).
- An agent host needs the same "is this news to me" decision.

*Fix:* put `ChatReadState.notifies(_ message:, ownsTribe:)` (or a `Message` helper) in PeelCore, and have Notifier and the unread count use it.

**3.2 Sending several files with one caption is app logic (low-med).** `ChatModel.send` (`ChatModel.swift:212–257`) orders files, puts the caption on the last one, sends the caption alone if that file is refused, and requeues refused files. An agent sending three files gets none of this. *Fix:* add `Engine.sendAttachments(_ files:, caption:, to:, replyTo:, inThread:) -> [Result]`; the app keeps only tray and requeue.

**3.3 UI strings in PeelCore (low).** `ConnectionState.label` (`Engine.swift:79`) is reimplemented with a live countdown in `MainView.swift:497–501`. `Message.preview` returns "Message deleted"/"Image" (`Message.swift:158`). Acceptable for the CLI, but the UI should own its wording. *Fix:* leave as is; stop the app from adding second copies.

**3.4 Contact info parsed twice (low).** `AppModel.myPubkey` splits `myContactInfo` on `_` (`AppModel.swift:529`); `Engine.addContact` parses the same format (`Engine.swift:629`). *Fix:* add a `ContactInfo` type in PeelCore.

**3.5 Pinned message limited to the newest 200 (low, a bug).** `ChatColumn.pinned` (`ConversationView.swift:85–88`) finds the pin only in the loaded timeline, so an older pin is never shown. *Fix:* read it with `storage.message(uuid:in:)` in the tribe observation.

**Held well:** PeelCore has no SwiftUI, AppKit or UIKit imports, no `static var`, no singletons and no `UserDefaults`. `Profile` is name-keyed, so many accounts can run in one process. Message conventions are all in Engine.

## 4. Oversized files

See the table above. The proposed splits are all move-only and none change behaviour:

- **Engine:**
  - `Engine.swift` keeps types, init, connection, `run`/`commit`/`complete`/`receive`.
  - `Engine+Account.swift`, `Engine+Messages.swift`, `Engine+Payments.swift`, `Engine+Attachments.swift`, `Engine+Tribes.swift` (with `membership`/`discoveredTribe`), `Engine+History.swift`.
  - `EngineTypes.swift` for `Event`, `Failure`, `Contact`, `Invite`, `JoinRequest`.
  - Cost: extensions in other files cannot see `private` stored properties, so those become internal. That is acceptable inside the module.
- **Storage:** `Storage.swift` (init, lock), `Storage+Migrations.swift`, `Models.swift` (public value types), `Storage+Reads.swift`, `Storage+Threads.swift`, `Storage+Commit.swift`.
- **MainView:** `MainView.swift` (shell, PaneDivider, Detail), `Sidebar.swift`, `SidebarForms.swift` (Join, Add contact, FormFooter, ProblemText), `Avatar.swift` (Avatar, TribeIcon, ConversationIcon, image loader), `Clipboard.swift` (or into `CopyFeedback.swift`), `Formatting.swift`, `Styles.swift`.
- **PeelMenu:** `PeelMenu.swift` (entries, presenter), `PeelMenuViews.swift`, `FloatingWindow.swift` (AppKit), `Controls.swift` (MenuButton, HoverIconButton, PeelDropdown).
- **Media:** `MediaCrypto.swift`, `MemesServer.swift`, `MediaStore.swift`, `Files.swift` (`ImageDecoding`, `ProfilePhoto`, `UserFiles`).
- **PeelCommand:** `PeelCommand.swift` (usage, dispatch), `Commands+Account|Chat|Tribes|Money.swift`, `Output.swift`, plus a `readOnlyStorage()` helper for the 9 copies of `Storage(directory:readOnly:true)`.

## 5. Dead code, unused API, stale docs

**Dead or test-only API (low).**
- `Storage.messages(in:)` (`Storage.swift:773`) is used only by tests, since `timeline(in:)` replaced it; #23 still edits it.
- `Storage.replyCounts(in:)` (`:858`) is tests only.
- `Engine.Event.moneyReceived` is ignored by the app (`AppModel.swift:647`); only the CLI prints it. Keep it if the Payments screen (04 plan) will use it, and say so in the doc comment. *Done 2026-10-08:* the app uses it and `.invoicePaid` (`04-money.md`, "Sats received").
- `Detail` `.payments` is a placeholder (`MainView.swift:765`), while `Storage.payments()` exists.

*Fix:* delete the first two and rewrite their tests against `timeline`. *Done 2026-10-08 (#60).*

**Stale docs (low-med).**
- `docs/PLAN.md:107`, phase 3 row: "attachments on `phase3/attachments`, UI to come". The UI shipped.
- `docs/PLAN.md` Storage section lists 4 tables. There are 6 (`chatState` and `tribe` are missing) and 11 migrations.
- `docs/design/README.md:4`: "Nothing here is built yet beyond the current shell", and "Peel logo stays in the sidebar header". The header is now your avatar and menu.
- `docs/phases/03-chat.md` (1,649 lines) opens with a status naming six branches, all merged. `04-money.md:170` says "main is at v8".
- The phase files have become build journals. Each needs a 10-line current-status header, with the journal below.
- #12 and #15 rename `08-local-tools.md` to `09-*`, so any docs PR waits for them.

## 6. Migrations and tests

**6.1 Migrations use live constants (med).**
- v11 builds its backfill and two partial indexes from `MessageType.boost`, `MessageType.sqlList(MessageType.payments)` and the literal `'PENDING'` (`Storage.swift:183–191`).
- v7 uses `Tribe.Status.active.rawValue` (`:131`).
- If `payments` ever gains a type, old databases keep the old index predicate and new ones get the new one. SQLite then stops using `message_payment`/`message_pending` on old databases, or the backfill differs.
- The closures are inline in one 150-line `migrator` (`:45–195`). v12 arrives with #23 (`chatState.readPending`).

*Fix:*
1. Freeze literal values inside migrations.
2. Move the migrator to `Storage+Migrations.swift` with a header rule: append-only; never edit a shipped migration; literals only; one test per data backfill.
3. Add one test that migrates a v1-shaped database through every step. Only v8, v9 and v11 have one today: `ThreadTests:54`, `MediaTests:285`, `PaymentTests:179`.

No consolidation (squashing v1–v11) is needed: Tom's real account has already run them.

**6.2 Coverage gaps on the riskiest paths (med-high).**

| Path | Covered | Missing |
|---|---|---|
| Money | threshold maths, retryability, `wouldBeSplit`, upsert of amounts, `isMoneyForMe` | Engine refusals are testable offline but untested: balance unknown/insufficient, `paymentToTribe`, `notBoostable`, `noteTooLong`, `setBoostAmount` threshold. `checkPayment` runs before any core call, so an `Engine` on a temp profile with `.balanceMsat` set is enough. `deliver`'s rule that a half-published payment stays pending (`Engine.swift:994–999`) is untested: `Transport` is a final class with no seam. The synthesised FAILED for unrecorded payments (`:1858–1862`) is untested. #26 extracts `recordedStatuses` and adds `SendStatusTests`. |
| Tribe membership | `canPost` | `Engine.membership(after:in:replaying:)` (`:1605`) is pure, static and private, and decides who removed, approved or deleted us, including the role-0 owner check. Make it internal and table-test it. Same for `discoveredTribe`'s host trust rule (`:1575`). |
| Restore | nothing | The history state machine is untested: `startRestore`, `advanceHistory`, `finish`, the stall watchdog, `historyEnded` clearing `needsRestore` (`:2178–2292`). Extract a pure `HistoryCursor` (next/end/queue) and test page advance, an empty page, stall and queueing. |
| Read markers | `setRead` forward-only, indirectly | #23 adds `ReadMarkerTests.swift` (+124). Nothing until it lands. |
| App | none (no PeelApp test target) | `ChatRow.rows`, `Formatting.relative`, `LinkText`, `MessageBlocks` are pure. Moving them to a small `PeelUI` library target would make them testable. Not urgent. |

## 7. Concurrency and actors

**7.1 Account lifecycle leaks (med).**
- `attach` starts `observeConversations`, `observeReadStates`, `observeThreads` and `consumeEvents` as unowned `Task`s (`AppModel.swift:597–600`).
- `forgetAccount`/`resetAccountState` (`:209,552`) never cancel them.
- `Engine.events` is never finished: no `emit.finish()` anywhere. So `consumeEvents` keeps the old `Engine`, its `Storage` (the `DatabasePool` and the profile `flock` fd) and its observations alive after forget.
- A stray write could then push old rows into the new session.

*Fix:* keep the four tasks and cancel them in `resetAccountState`. Add `Engine.close()`, which disconnects and calls `emit.finish()`.

**7.2 Synchronous DB reads on the main actor (low-med).**
- `AppModel.tribe(_:)` reads every tribe on each call (`ChatModel.swift:161`). It runs on every sidebar menu open (`MainView.swift:408`) and, through `boostCost`, on every BoostPanel redraw (`PaymentViews.swift:20`).
- `canDelete` runs a `COUNT(*)` per menu open (`ChatModel.swift:119`).
- `Notifier.flush` reads all tribes (`Notifier.swift:179`).
- `attach` makes three reads (`AppModel.swift:586–590`).
- Each read is small, but they are on the main thread.

*Fix:* observe a `tribes` dictionary in AppModel from a live query, and add `threadCount` to `ThreadSummary`/`Timeline` rows.

**7.3 Polling instead of continuations (low).** `Engine.poll` checks actor state every 200 ms (`Engine.swift:568`). It is used for registration (`:564`), tribe create, update and delete, and member lists (`:1434,1510,1535,1562`). It works and is bounded, but it is latency plus wakeups. *Fix, later:* keyed `CheckedContinuation`s resumed in `commit`.

**7.4 Unowned tasks in Engine (low).**
- `refreshTribes` (`:2003`) and `recordConfiguredTribeHost`/`refreshTribes` in `cameOnline` (`:2101`) are not cancelled by `disconnect()`.
- The cache file deletion is fire-and-forget (`:1875`), which is fine.
- `mentionScan` is detached but tracked, which is good.

*Fix:* keep the background refresh task handle and cancel it in `teardown`.

**7.5 Clock (low, note).** `clock.next()` feeds signatures outside `run` (`:521–523,1136,1235,1237`) and is only persisted on the next commit. That is harmless while wall-clock milliseconds lead. Note it beside `UniqueClock`.

## Refactor plan

These are small, independent PRs in priority order. "Waits for" means rebase after
that PR merges. Recommended merge order for what is in flight: **#26, then #23,
then phase4/payments**. phase4/payments is not listed in the table but applies
to every row that touches Engine, Storage, PaymentViews, MessageViews,
PeelCommand or AppModel.
After that, PRs 1–3 and 9–10 can run in parallel sessions, since they touch
different files.

| # | PR | Scope | Files | Risk | Waits for |
|---|---|---|---|---|---|
| 1 | **Show engine errors in the main window** | A quiet `notice` bar in `MainView`; `PeelError.readable` in every `catch`; no raw `"\(error)"` | AppModel, MainView, AccountView, TribeViews, ConversationView, LockView, OnboardingView | low | #23 (AppModel) |
| 2 | **Account lifecycle** | Keep and cancel the observer and event tasks; add `Engine.close()` that finishes `events`; cancel the tribe refresh in `teardown` | AppModel, Engine (small) | low-med | #23, #26 |
| 3 | **Tests: money refusals and tribe membership** | Offline Engine tests for `checkPayment`/boost/sendPayment refusals; make `membership` and `discoveredTribe` internal and table-test them | Tests (new files), Engine (two `private` keywords) | low | none for membership; #26 for payment tests |
| 4 | **Migration hygiene** | Literal values in v7 and v11; move to `Storage+Migrations.swift` with the append-only rule; full-chain test from v1 | Storage, Tests | low (no schema change) | #23 (v12), #26 |
| 5 | **Sats in PeelCore** | `Sats.format(msat:)` and `Sats.parse(_:unit:)`; CLI and `Failure` use them; one preset list | Message, Tribe, MainView/Formatting, PaymentViews, TribeViews, PeelCommand, Engine | low | #26, #23 |
| 6 | **One sender resolution** | `sender(of:)` with one fallback used by ChatRow, Boost views, Notifier and notes | ChatModel, AppModel, MessageViews, PaymentViews, Notifier, ConversationView, TribeViews | low | #26, #23 |
| 7 | **Typed engine failures** | Replace 19 `PeelError` strings in Engine with `Failure` cases; drop the CLI flag from the engine text | Engine | low | #26, #23 |
| 8 | **Notification policy in PeelCore** | `ChatReadState.notifies(...)` used by Notifier and unread counts | Storage (model), Notifier | low-med | #23 (Notifier, readStates) |
| 9 | **Styles and confirm controls** | `Styles.swift` (boxes, button styles, radii); `InlineConfirm` used by UndeliveredActions, ForgetAccountControl, WordsRow | MainView (box helpers only), OnboardingView, AccountView, TribeViews, LockView, ConversationView | low | none (#23 touches other hunks) |
| 10 | **Split MainView, PeelMenu and Media** | Move-only, as in section 4 | MainView, PeelMenu, Media | low | after PR 9; MainView after #23 (`ConversationMenu`) |
| 11 | **Split Storage** | Move-only: Models, Reads, Threads, Commit; delete `messages(in:)` and `replyCounts`; make `set` internal; shared tribe and status SQL fragments | Storage, Tests | low | #23, #26, PR 4 |
| 12 | **Split Engine** | Move-only into extensions; `private` becomes internal for stored state; one `JSON.decode` helper; decode the body once | Engine | low-med (large diff, no logic) | #23, #26, PRs 2 and 7 |
| 13 | **Split PeelCommand** | Commands by area, `Output.swift`, `readOnlyStorage()` | PeelCommand | low | #23, #26, PR 5 |
| 14 | **Off-main reads** | Observed `tribes` map in AppModel; `threadCount` in summaries; pinned message from storage (fixes 3.5) | AppModel, ChatModel, Storage, ConversationView, Notifier | low-med | #23, PR 11 |
| 15 | **Restore cursor and tests** | Extract `HistoryCursor` from Engine; tests for page advance, stall and queue | Engine+History, Tests | med (restore path) | PR 12 |
| 16 | **Engine sends many files** | `sendAttachments(...)`; ChatModel keeps only the tray | Engine, ChatModel | med | PR 12 |
| 17 | **Docs refresh** | PLAN storage section and phase table; design README header; a 10-line status header on each phase file; AGENTS layout after the splits | docs/*, AGENTS.md | none | #12, #15, #23, #26; then after PRs 10–13 |
| 18 | **Polling to continuations** | Replace `poll` with keyed continuations | Engine+Tribes | med | PR 12; optional |
