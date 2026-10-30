# Phase 7 — iPhone

Last updated 2026-10-26. **A proposal for Tom's review.** Built so far: I1
(`PeelUI`, on `ios/peelui`), I2 (the first iPhone app, on `ios/app`;
status under "I2: the first iPhone app" below) and I6 (calls; see "I6:
calls" below).
Resumed 2026-10-13 (paused since 2026-10-08). It builds on
[../agent-brain.md](../agent-brain.md) (the Mac is the brain, the phone is a
remote), [../jobs-architecture.md](../jobs-architecture.md) (jobs run in
Strut) and [12-automations.md](12-automations.md) (Strut owns the schedule).
The research behind it was read on 2026-10-13 from Peel's `main` (6da14aa),
`~/Documents/strut`, `~/Documents/hive`, `~/Documents/sphinx` and
`~/Documents/sphinx-ios-v2`.

> **Superseded in part (2026-10-19).** The client track (I1, I2, F1 to F2c,
> G1) stands. The remote track is replaced by Phase 1 of the end state: the
> agent's account is held by the bridge (`sphinx/runner`, bundled in
> Peel.app), not a second PeelCore engine; its seed is `agent_seed(seed, n)`
> from the core (info `agent seed <n>`), not `peel agent <n>`; control is a
> JSON envelope under `metadata.peel` on ordinary messages, not `BotCmd` /
> `BotRes`; the loop is strut's `orchestrator`, not the brain's Peel; and
> brain mode is strut and the bridge on a home server with no Peel (Phase
> 2). The phone's agent DM is built (Phase 1 PR 9). See [../agent-architecture.md](../agent-architecture.md) and
> [../agent-on-strut.md](../agent-on-strut.md).

## The big picture

**The brain** is one machine that runs the agents, Strut and memory: Tom's
Mac today, then a home server (an old Mac or a Mac mini), and later perhaps a
brain Sphinx hosts. **Every other device is a remote.** The iPhone, and the
laptop once the brain moves off it, reach the brain by sending Sphinx
messages to the agent, as to any contact. Nothing on a remote runs the agent.

Making each agent a **real Sphinx contact** gives four things for free: an
address any device or Sphinx app can reach, encryption, a queue when the
brain is asleep or down, and push for its replies.

**What an agent is.** Five parts, each with one owner:

| Part | What it is | Owned by |
|---|---|---|
| Identity | A real Sphinx key: name, photo, an address people can message | Sphinx |
| Persona | Its system prompt ("Peel", "Chief of staff") | The brain (the `Agent` record) |
| Budget | What it may spend on models | Bifrost or Mothership virtual keys |
| Tools | Which connectors and workflows it may use | Strut (its grants) |
| Memory | What it knows | Strut's graph |

Budgets are model spend, not Sphinx sats: messages between Tom and an agent
are free. The contact gives an agent an address; the virtual key gives it a
budget. The first agent is agent 1 of this model, and more agents are more
rows.

**The path:**

1. **Today.** The agent is not a contact. It lives inside the Mac app, and
   only that Mac can talk to it.
2. **v1: one agent as its own account.** Its words are derived from Tom's,
   so the backup is still one set of twelve words. No server change. The
   cost is a second connection on the brain.
3. **Later: agents as children of one account.** One account, one
   connection, one set of words, each agent an identity under Tom's root,
   perhaps with its own balance. The server has some of the pieces (balances
   per scid, routing to yourself); the core and every Sphinx app would need
   "an identity that is not a contact". A protocol change for the Sphinx
   team ("Later, and considered" below).
4. **Hosted.** The brain runs in Sphinx's cloud. Devices talk to the agents
   exactly as before, because they are contacts either way.

Separate accounts do not mean more backups, because they are derived. They
mean one connection, registration and balance per agent, which step 3
removes. And an agent that reads Tom's Sphinx chats needs his keys: on a
home server they stay on hardware he owns. A hosted brain's first version
should see only its own conversations and connectors, not Tom's inbox, unless
he chooses otherwise.

## In one paragraph

Peel on iPhone is two things in one app. It is a full Sphinx client, built
from the same PeelCore with its own views in iOS 26's Liquid Glass. It is
also the remote for the brain: the Peel on a Mac that runs the agent, Strut
and the graph. The phone never talks to Strut. It talks to **the agent's own
Sphinx identity**, which the brain runs beside Tom's account. Talk is
ordinary Markdown messages. Control (jobs, automations, approvals, status)
is a small JSON protocol in Sphinx's bot message types. Sphinx is the
transport, the encryption and the queue: if the brain is asleep, the phone's
messages wait on the broker and the brain works through them in order when
it wakes. A home server is the same Peel in "brain mode" on a Mac mini that
never sleeps. Later the same code runs headless on Linux.

## Proposed decisions

1. **iOS 26 is the minimum.** It is the Liquid Glass release and matches the
   Mac app's macOS 26. `Package.swift` says iOS 26 since I2.
2. **The phone is a remote, not a second brain.** No agent loop, no API key,
   no graph and no Strut on the phone in v1. One brain, one memory, one set of
   jobs.
3. **The agent gets its own Sphinx identity.** The brain runs a second
   PeelCore engine for it. It sits in Tom's Direct messages like a person,
   from the phone, the Mac and the official apps alike.
4. **Strut stays on loopback.** Most of Strut's routes have no auth
   (`strut/src/auth.ts`; `POST /workflows/:name/run` is open), and the phone
   has no business reaching it. Every remote action goes through the brain's
   Peel, which owns the approval gate.
5. **Phone actions are typed commands, not prompts.** Pausing an automation,
   answering a Needs you card or approving a write never costs a model turn.
   Only free text goes to the agent.
6. **The brain keeps the queue.** Strut has no durable queue, so the brain
   stores every remote command before acting on it, acks it, and works
   through what is waiting when it wakes.

> **Superseded (2026-10-19):** proposed decisions 3, 4 and 6 and the shape
> below. The bridge holds the agent's account and keeps the inbox; strut,
> not the brain's Peel, runs the agent; strut stays on loopback on the Mac,
> and a direct path is optional (foundation.md, decision 4). See
> [../agent-architecture.md](../agent-architecture.md).

> **Amended (2026-10-26):** the phone still never talks to the brain's
> strut, but it does talk to its **orgs'** struts: paired with Stadeum as a
> device of its own, it opens a deliverable or an app the agent's DM names
> on that org's own strut, with its own person token for the org. See
> "Org pages on the iPhone" below and strut's specs/DESKTOP.md, "A device
> with no strut of its own".

## The shape

```
 iPhone (Peel, iOS 26)                       Brain: Peel on a Mac (laptop now, Mac mini later)
┌──────────────────────────────┐            ┌───────────────────────────────────────────────┐
│ Tom's account (PeelCore)     │            │ Tom's account engine     Agent's account engine│
│  chats · payments · calls    │            │  (as today)               (new, headless)      │
│                              │            │                               │                │
│ Agent DM in Chats, with its  │  Sphinx    │  RemoteInbox (agent.sqlite) ◄─┘                │
│  cards (approvals, results)  │◄─────────► │   ack · dedupe by uuid · expiry · order        │
│ Automations screen, pushed   │  broker    │        │                                       │
│  from Chats (cached state)   │  holds     │  AgentLoop + ApprovalGate (as today)           │
│                              │  messages  │   tools: Sphinx · memory · automations · jobs  │
│ Push via hub → NSE           │  while     │        │ loopback only                         │
└──────────────────────────────┘  asleep    │  Strut (bundled) ── Ladybug graph              │
                                            └───────────────────────────────────────────────┘
```

## 1. The phone as a Sphinx client

Most of the work is here, and none of it is new design: parity on a new
platform.

### What builds today and what does not

| Layer | State for iOS | Work |
|---|---|---|
| Rust core (`sphinxrsFFI.xcframework`) | Mac slice only (`scripts/build-ffi.sh`) | Add `ios-arm64` and `ios-arm64-simulator` slices. The official iOS library has no arm64 simulator slice, so build from `sphinx-rs` for `aarch64-apple-ios` and `aarch64-apple-ios-sim`, pinned in `Vendor/sphinxrs.lock` like the Mac slice. Do it together with the core upgrade (bug hunt N1), not twice |
| PeelCore | Close: no AppKit, UIKit or `Process`; quarantine is behind `#if os(macOS)`; NIOTransportServices, GRDB and ImageIO all work on iOS | Compile it, fix what breaks; a Keychain access group for the extension |
| AgentKit | Already says it builds for iOS | None. The phone does not run it in v1 |
| PeelAgent | Not portable: `BundledStrut` runs `Process()` (`BundledStrut.swift:89`); `AutomationServer` is a NIO server | Stays Mac-only. The phone does not link it |
| PeelApp | About 23k lines; 16 files import AppKit; `AppModel` imports AppKit (`NSApp.keyWindow`, `NSApplication.isActive`) | Batch 17 below: `AppModel` and its logic now in `PeelUI`, which builds for the iOS Simulator |
| LiveKit | 2.10.2 pin; any target importing PeelCore and LiveKit inherits the `RustBuffer` header clash | Calls stay behind `CallProvider`, as on the Mac |

### Batch 17: the iPhone seams

Planned in [../reviews/2026-10-08-second-review.md](../reviews/2026-10-08-second-review.md)
§9. It goes first, alone, because it touches every `AppModel` file. Built
on `ios/peelui` (2026-10-13) and in review; what moved and what stayed is
in the review's batch 17 status. The plan:

- A **`PeelUI`** library target (PeelCore, SwiftUI, Observation; no AppKit,
  UIKit or LiveKit): `AppModel` and its extensions, `ChatRow`,
  `PaymentAttempt`, `Formatting`, `MoneyArrivals`, the notification
  decisions and the image caches over `CGImage`.
- Platform services as small protocols each app injects: `FilePicking`
  (exists, `#if os(macOS)` inside), `AppPresence` (frontmost, activate,
  badge), `CallProvider`, `WebPresenting`, `Playback`, `Pasteboard`.
- The Mac app becomes `PeelMac` over `PeelUI`. Views stay per platform. The
  big views (`MessageViews`, `Sidebar`, `AttachmentViews`) are mostly plain
  SwiftUI and can be shared file by file where they fit. The composer
  (`ComposerField`, an `NSTextView`) cannot be shared, and neither can
  menus, floating windows or the web pane.

Review findings not applied (2026-10-14), for a later batch:

- The Mac reaches its own services through casts on the model
  (`agentHost as! MacAgent`, `webPresenter as! WebPane`). `Platform.mac()`
  is the only place the model is made, so they hold; type-safe access
  needs `AppModel` generic over its platform, or the agent's methods moved
  onto `MacAgent` (which would also drop the seven forwarders in
  `AppModel+Agent`).
- `FilePicking` is synchronous, shaped by `NSOpenPanel`; the phone's
  pickers are async, so it changes when the phone attaches files (I3).
- Mac-only state still in `PeelUI`: `agentRowsOpened`, `agentConnectFrom`,
  `MenuHosting` and `takesCommands`, the `-profile` launch argument and the
  old `pinTimeoutHours` default.
- `PeelTestSupport` imports PeelCore `@testable`, so a release build of
  every target fails; nothing builds release today.

### I2: the first iPhone app (built 2026-10-13, `ios/app`)

**Built.** `iOS/Peel.xcodeproj`, written by hand (no xcodegen): one app
target over the package's `PeelUI` and `PeelCore`, its sources a
synchronized folder (`iOS/Peel/`), iOS 26, iPhone only, bundle ID
`dev.peel.ios` with the team in an ignored `iOS/Local.xcconfig`. It builds
for the iOS 27 simulator and, unsigned, for a device. The app opens to
the same onboarding the Mac's model drives (invite, name, PIN, the words
and the check of three; or the words, name, PIN and restore progress),
each step pushed so Back is the system's; the PIN at launch with Forget in
place; then a tab bar with **Chats** (Unread, tribes, direct messages from
`sidebarSections`, Show all, search, the connection bolt and a subtitle
while not connected; a chat pushes in as the model's `destination`, so it
is read as on the Mac) and **Account** (name, balance, server, Change PIN,
show or check the twelve words, Forget). The conversation is read only:
the newest page of `chatRows`, runs with photo, name and time, day lines,
"New messages", payments and requests, tribe notes. Both appearances
follow the system, on the Sphinx tokens in `Theme`.

**Shared, not copied.** `Theme`, `Avatar` and `Clipboard` from
`Sources/PeelApp` compile into the phone too (they already had UIKit
branches); `WordCheck`, a tribe's membership notes
(`Message.membershipNote`) and `PIN.problem` moved into `PeelUI` for both
apps. `CallProvider.join` now throws: the phone's says calls are not on
iPhone yet, in the chat, rather than faking a call.

**Not yet, and why.**
- Message text shows without its marks (`MessageMarkup.blocks` and
  `plainText`): the styled renderer (`MessageText`, `LinkText`) lives in
  the Mac's views. F1 moved it where both can use it (done).
- No composer, attachments (a row says what it is), threads (the count
  shows), older pages, chat previews in the list (the stored last content
  is raw: a GIF's JSON, a call link) or pull to refresh.
- No notifications: `postsNotifications` is false until push (I5), so
  nothing asks for permission; the badge is set but shows only once
  allowed. No PIN timeout on the phone (the PIN is asked at launch only).
- Files, playback and the web pane do nothing and are never offered.
- Not verified past the restore screen in the simulator: no account was
  restored or created by the agent that built it. Tom restores the
  throwaway himself to check Chats, the conversation and Account.

Review findings not applied (2026-10-14):

- Keychain items outlive the app on iOS, so after a delete and reinstall
  the lock screen asks for the PIN of an account with no database. A
  first-launch check that clears them is Tom's call (it erases words).
- `ITSAppUsesNonExemptEncryption` is NO in the project; the export answer
  for an end-to-end encrypted client is Tom's before TestFlight.
- Clearing the clipboard after twelve words are entered cannot tell a
  paste from dictation or autofill without reading it, which on the phone
  asks the person; it stays as it is.
- `CallProvider.join` throws rather than `Platform.calls` being optional,
  so the phone refuses after fetching the ticket; and the Avatar file names
  the phone's `Logo` asset. Both wait for calls on the phone (I6).
- The PIN prompts (lock screen, the words, Change PIN) could share one view,
  and `WordsScreen`'s flags could be one mode; left for F2c.
- Nothing covers the chats in the app switcher's snapshot: with no PIN
  timeout on the phone there is nothing it would be hiding from.

### F1: the phone foundation (built 2026-10-14, `ios/f1-foundation`)

**Done means:** the shared pieces F2a, F2b and F2c build on, to
[../design/iphone.md](../design/iphone.md), with the Mac unchanged.

**Built.**
- **The tab shell** (`MainTabs`): Chats, Payments, You and the system's
  search tab (`role: .search`), each its own `NavigationStack` with large
  titles. The Chats badge is the unread count in Sphinx blue. You's icon
  is your 30 pt photo (your initial on your colour without one), larger
  than a glyph (Tom); selected, a 2 pt accent ring and a thin gap sit
  inside its edge, since a ring outside it ran into the tab's label. It
  is rendered to an image, since a tab bar draws only images. A conversation hides the
  tab bar. Payments is a placeholder with the balance until F2c; I2's
  Account moved into You as it was. Search filters the chat list by name
  (`searchQuery`, cleared on leaving the tab).
- **Navigation** (`PhoneRouter`): the tab and a typed path per tab
  (`ChatsRoute`, `PaymentsRoute`, `YouRoute`), with `openChat`,
  `open(_ message:inThread:)`, `openThread`, `openPayment`,
  `openFromNotification` and the thread sheet's binding over
  `AppModel.openThread`. `AppModel.destination` stays what is open (it
  marks chats read, closes another chat's thread, keeps money
  notifications off Payments): the router writes it from what is on
  screen and follows it when the model moves it (`focus(on:)`,
  `openThread`, a notification, a chat removed). A chat opened from
  Threads or Mentions goes on top of that list. A thread open when Chats
  is left comes back with it.
- **Surfaces**: `.phoneList(.plain / .grouped)` on every list or form
  (Peel's page behind it and its navigation bar, never the system's black
  or grey) and `.phoneRows(…)` on its sections (`background` rows, or
  `quote` cells grouped, `divider` hairlines).
- **Theme** (`PhoneTheme`): `PhoneFont`, the Mac's sizes on Dynamic Type
  text styles (`.phoneFont(.row)`, `.message`, `.name`, `.time`, …);
  `Surface` and `Theme.quietText(on:)`, `tertiaryText` on the background
  and `secondaryText` on a raised surface. No phone colours.
- **Glass** (`Glass.swift`): `GlassCapsule` with `GlassCapsuleButton`s
  (one capsule in a `GlassEffectContainer`, 44 tall, 46 wide slots),
  `GlassButton` (round, 44), `.floatingBar(edge)` (`safeAreaBar`: content
  scrolls under it with the system's scroll-edge effect) and
  `.scrollEdges()`. In a navigation bar the system draws the glass: put
  neighbours in one `ToolbarItemGroup`.
- **Components** (`PhoneComponents`): `CountBadge` (min 22, blue, gold
  `.mention`, orange `.attention`), `PhoneSectionHeader` (collapsible, a
  44 pt full-width button, a heading), `NavRow` (Automations, Threads,
  Mentions), `ChatListRow` (tribe square, person round, AGENT, the
  counts, VoiceOver's "3 unread, mentions you" or "waiting on you"; the
  count goes under the name at accessibility sizes), `PhoneCard`
  (`Card(.inset)` at radius 12, telling its content it is raised).
  `PeelButton` has a `.touch` size (44 pt at least, 16 pt on Dynamic
  Type) and `Badge` an `.attention` style, both shared with the Mac;
  `Badge`, `Card`/`Callout`, `IconButton` and `PeelButton` compile into
  the phone. `AgentTag` moved into `Badge.swift`.
- **Markdown**: `MessageText`, `LinkText` and the search highlight moved
  to `Sources/PeelApp/MessageText.swift`, which the phone compiles. Its
  size is a parameter (14 on the Mac, unchanged; 15 on the phone, scaled
  with `@ScaledMetric`); text is selectable on the Mac only, since on the
  phone a long press is the message's menu. `AgentMessageLink` moved from
  PeelAgent to AgentKit so the shared file can read it. The read-only
  conversation now renders Markdown through it.
- `ThreadRef` is `Identifiable`, for `.sheet(item:)`.

**For F2.** F2a replaces Chats' list with the design (the top rows,
`PhoneSectionHeader`s, swipe actions) and fills `ChatsRoute`'s Threads,
Mentions and Automations (`ComingScreen` now). F2b builds the
conversation, the composer on `.floatingBar(.bottom)` and the thread
sheet on `router.thread`; a link in message text opens the system
browser until it routes (the agent's message links among them). F2c
builds Payments, You's groups and `YouRoute`'s screens.

**Review findings applied:** the router holds publishing while `follow`
changes a tab and a stack together, so focus and a thread set by the
model survive the hop; it follows the model from `RootView`, locked or
not; the first chat no longer opens by itself on the phone
(`Platform.opensFirstChat`, true on the Mac); a thread left on Chats or
Search is kept per tab; the You icon renders once per change.

**Not applied, and why:** the new pieces have no callers yet (they are
F2's foundation); the AGENT row and orange count are not wired into
Chats (no agent DM on the phone until the remote track; F2a); message
text is not selectable on the phone until F2b's long-press menu brings
Copy; `CountBadge` stays beside `Badge` so the Mac's badge keeps its size.

**Not verified** past the lock screen with an account: the throwaway on
the simulator is locked and no PIN was entered by the agent. The shell
and the components were checked with made-up rows in a scratch screen,
not committed.

### F2a: Chats (built 2026-10-14, `ios/f2a-chats`)

**Built.** Chats to [../design/iphone.md](../design/iphone.md), screens 1
and 9: the large title with New message in the bar's glass (the orange
bolt joins it only when not connected); Automations, Threads (blue count
of `unreadThreads`) and Mentions (`unreadMentions`) as `NavRow`s; Unread,
Tribes and Direct messages over `sidebarSections`, so the Mac's order,
trimming, "Show all N" / "Show fewer" and open chat rule hold, the
collapsible headers writing `sidebarLayout`. A section's header is its
first row, not a sticky header, which sat see-through over the rows
under the glass bar. Swipe right: Mark read (with unread) or Mark
unread; swipe left: Mute or Unmute; a long press has the same and the
notification level. Pull to refresh is `AppModel.refresh()`: reconnect
and wait up to 5 s when not connected, otherwise catch up unless history
is already running. Not connected: the Mac's countdown, "Offline,
retrying in 8s" (Tom, 2026-10-14: one wording on both apps, over the
board's "Reconnecting in 8 s"), in the bolt's popover beside it
(Tom, 2026-10-19: no line under the large title, which shifted the list at
launch), the Mac's `ConnectionCard` on an opaque `menu` panel with Reconnect now. Threads
and Mentions push lists from the Mac's model (`threads`,
`mentionUpdates`); a tap opens the chat at the message or with the
thread sheet over it, on top of the list. Automations says plainly they
are on the Mac for now. New message opens a `ComingScreen` sheet. No
chats: "No chats yet", or "Restoring your chats" while a restore runs.

**Not built, and why:** Pin (the model pins messages, not chats); the
agent row's AGENT label and orange count (no agent DM on the phone
until the remote track; `ChatListRow` is ready for it); "Join a tribe",
"Add contact", "Invite someone" and pending invites at the sections'
ends (their forms are the Mac's).

**Shared with the Mac** (moved out of `Sidebar.swift`, the Mac
unchanged): `MuteLevel.choices(isTribe:)` with `title` and `short`;
`ReadToggle` and `AppModel.readToggle(for:)`, Mark as read or unread;
`ConnectionState.label(retryAt:now:)`, the countdown (tested,
`ChatMenuRulesTests`). The tab badge is blue through the tab bar's
`UITabBarAppearance` (iOS 26 ignores `UITabBarItem.badgeColor`).

**Not verified** with an account: checked with made-up chats and
mentions in a scratch launch mode, removed before the commit; the
Threads list's rows were not drawn (`ThreadSummary` has no public init).

### F2b: Conversation, Thread sheet and composer (built 2026-10-14, `ios/f2b-conversation`)

**Done means:** a chat, its threads and the composer on the phone, to
[../design/iphone.md](../design/iphone.md) screens 2, 3 and 10.

**Built.**
- **Conversation** (`ConversationScreen`, `MessageList`, `MessageRows`,
  `MessageMedia`): the header (name, a tribe's member count or a
  person's local time, Call and More in one capsule), the Mac's flat rows
  over `chatRows` (runs, sender colours, day badges, New messages, quotes,
  boosts, thread summaries opening the sheet, payments and requests,
  deleted, Retry and Discard by the Mac's rules), images and a GIF's first
  frame. It opens at New messages, follows the newest only at the bottom,
  and counts what comes below on the "N new messages" pill (`ListBottom`).
  Older pages load near the top (`AppModel.loadOlder`, a page more of the
  newest, back to one page at the bottom).
- **Long press** (`MessageMenu`): Reply in thread, Boost (a light
  haptic), Copy, Copy link, Delete; Retry and Discard when undelivered.
  Swipe right replies in the thread. One VoiceOver element per message
  with the same entries as actions.
- **Thread sheet** (`ThreadSheet`): large detent, grabber, its own
  composer; the draft is the model's per thread.
- **Composer** (`Composer`): a glass capsule over a `UITextView`, six
  lines then scrolling; attach (+) from Photos (redrawn as JPEG, no
  metadata), the camera or Files through `addFiles`; `@` mentions from
  `MentionQuery` (shared with the Mac's composer, tested); Send once
  typed.
- **Calls** ask `CallProvider.unavailable` first, so the phone says calls
  aren't here yet before posting a call message.

**Later (video and files):** received video plays in its row
(`VideoTile`, `VideoPlayback`: auto-download up to `Engine.autoDownloadLimit`,
a tap loads a larger one), PDFs and other files are a `FileCard` that
previews in Quick Look and shares through the share sheet (`FileCopy` names
the cached file). `AttachmentFormat` moved to PeelUI for both apps. Not
built: paid attachments still say "Buy it on the Mac"; Photos does not
offer video; not built or run on a device yet.

**Not built, and why:** voice messages (the mic says they are coming);
the send-sats bolt in a DM says sending from a chat is coming (no phone
send sheet yet, F2c); link cards (the Mac's are AppKit forms; the link
stays in the text); members and details under More; buying attachments, the full-size viewer (video and files: see Later above); GIFs do not
animate; the agent DM has `isAgent` (AGENT, "Ask Peel", no bolt) but
nothing passes it until the model knows the agent's chat.

**Not verified:** with an account. Checked in the simulator with made-up
rows in a scratch screen, not committed. The list does not yet hold its
bottom when the keyboard rises; the long-press menu was not driven.

### F2c: Payments, You and Lock (built 2026-10-14, `ios/f2c-payments-you`)

**Done means:** screens 6, 7 and 8 of [../design/iphone.md](../design/iphone.md),
Send and Receive, and Face ID, with every money rule the Mac's model's.

**Built.**
- **Payments** (`PaymentsTab`): the large title, the balance (tabular) and
  what waits on people offline, Receive (outline) and Send (filled), the
  history by calendar day (`Formatting.dayHeading`) with the Mac's paging
  (`PaymentPaging`), refresh triggers and lighting of payments received
  since it was last shown; pull to refresh; a success haptic when sats land
  while it is open; the tab's "+350" badge for sats not yet seen (the
  Mac's Payments row). A row: the bolt on `attention` at 14% (a clock on
  grey while it waits), the name, the note, the signed amount over the
  time. `PaymentDetail` is the Mac's detail pane as a pushed list.
- **Send** (`SendSheet`): paste or scan (VisionKit's
  `DataScannerViewController`, QR only, only an invoice taken) an invoice,
  read by `Invoice`, checked by `invoiceProblem`, its blocker's words now
  `AppModel.invoiceBlocker` (shared with the Mac's Pay pane); or send to a
  contact (amount and note, `sendPayment`). **Receive** (`ReceiveSheet`):
  amount and note, `createInvoice`, the QR (`QRCodeTile`, now compiled
  into the phone), Copy, Share, the expiry, Paid with a haptic.
- **The touch-safe confirm** (`TouchPayButton` over `PaymentAttempt`): over
  the threshold the first tap gives way to Cancel and an orange "Pay 2,000
  sats" that takes taps only after 0.7 s, so a double tap is never the
  confirmation; the second tap sends exactly that amount.
- **You** (`YouTab`): the 64 pt photo, the name (tap to change), the
  balance; Agent (Peel, "Set up on your Mac" until the remote track brings
  the brain's status, or the model when one is connected); Account: Twelve
  words, Change PIN, Face ID, Ask for the PIN (the PIN timeout), Boost
  amount (pushed: presets, or another amount through the touch-safe
  confirm), Confirm payments (the threshold), Server; Forget this account
  in red, confirmed in place (the spec's rule, not a sheet).
- **Lock** (`LockScreen`, `PinPad`): the board's keypad (78 pt keys, six
  dots that VoiceOver reads "2 of 6 digits entered"), Face ID bottom left
  when on (asked once as the screen appears), Delete bottom right,
  "Forgot your PIN?" confirming Forget in place. Change PIN, the words'
  PIN and Face ID's switch use the same pad (`PinPrompt`), which folds
  I2's three PIN prompts into one.
- **The PIN timeout on the phone**: `noteActivity` on going to the
  background and on coming back, so the timeout counts time away and
  `becameActive` locks when it is due.
- `SignedAmount`, `BigAmount` and `UntilExpiry` moved to
  `Sources/PeelApp/UI/PaymentKit.swift`, which the phone compiles; a
  payment's detail words (`context`, `quoted`, `statusFact`,
  `timeWithStatus`, `notSettled`) moved to `PaymentItem+Display`.

**Face ID** (`PeelCore/BiometricUnlock.swift`). Opt-in per device. Turned
on with the PIN, once the PIN opens the words, it keeps that PIN in a
data-protection Keychain item (`dev.peel.biometric`) with
`.biometryCurrentSet` access control and
`WhenPasscodeSetThisDeviceOnly`, never synchronised. Face ID releases
exactly what typing would: the words stay sealed under the PIN in
`PINBox`, and the released PIN goes through `unlock(pin:)` or
`revealWords(pin:)` as a typed one. A face added or removed or the
passcode turned off makes the item unreadable; a PIN changed elsewhere
makes it wrong; either way it is removed and the PIN is asked for. Change
PIN keeps the new PIN (or removes the item if that fails); Forget, a
restore and a new account remove it. The keeper is a protocol so the rules
are tested (`BiometricUnlockTests`); the Keychain item itself needs a
device (or a simulator with an account) to exercise.

**Not verified:** no account on the simulator (agents never make one), so
Payments, Send, Receive, You and Face ID were seen only with made-up rows
in a scratch screen, not committed; Face ID was never turned on with a real
PIN, and the scanner never saw a camera.

**Not done, and why:**
- The tab badge "+350" is the tab bar's one badge colour (blue), not the
  Mac's green: a tab item's badge colour is global.
- No cover over the app switcher's snapshot of chats when a PIN timeout is
  set; the words still cover themselves (I2). A scene-wide cover flashes
  under Face ID's sheet; left for Tom.
- Payment requests (type 2) are not in Payments' list, as on the Mac.
- `Callout` keeps the Mac's fixed 13 and 12 pt; it does not scale with
  Dynamic Type yet.

**Review findings not applied (2026-10-14):** the history grouped by day
in each screen's body rather than once in `PaymentsFeed` (the Mac groups
by `PaymentSection`, the phone by day); the Pay screens' payment found in
the paged history rather than by hash in storage (as on the Mac); the
receive countdown redrawing each second also when an hour or more is left
(as the Mac's); Face ID's outcome as an enum rather than a Keychain look
before and after; `SheetPage` beside `StepPage`; the Mac's and the
phone's preset lists and the countdown's words still written twice. Each
is a cleanup across both apps, left for a pass of its own.

### Simplify sweep of S1, batch 17 and I2 (2026-10-14, `ios/simplify-sweep`)

A /simplify pass over what #242, #247 and #249 left on main. Done: one
`ClipboardPasteboard` for both apps (was `MacPasteboard` and
`PhonePasteboard`, the same two lines); `PIN.digits` for both PIN fields
and `PIN.length` for the Mac's literal sixes; the Mac's Change PIN worded
by `PIN.problem`; the restore screen's lines (`RestoreProgress.lines`)
in PeelUI, drawn by both, the phone's failure line now `paused` like the
Mac's (the same condition); spreading pasted words (`WordBoxes.fill`)
once; Forget's warning (`AppModel.forgetWarning`) once.

Not applied, proposals for a later pass:
- The force casts `agentHost as! MacAgent` and `webPresenter as! WebPane`:
  sound (the Mac makes its one model with `.mac()`), but removing them
  needs a typed handle the Mac keeps or a generic `Platform`.
- Onboarding's flow (steps, numbering, `confirmPin`, `checkWords`) written
  twice: an `@Observable` flow in PeelUI both views draw. The two have
  drifted (a PIN mismatch, where typed words are forgotten), so each
  drift needs a decision first.
- The word check's submit (`confirmWords`, its guard, catch and problem)
  four times (onboarding and Account or You, on each app); unlock and
  forget likewise twice: model operations that return their problem.
- The Mac's `PinField` completes again on a seventh key (the phone's
  `PinBoxes` checks the old value); a fix, not a cleanup.
- `Platform.opensFirstChat`, a navigation choice among services: the
  Mac could ask for the first chat itself.
- `scripts/build-ffi.sh` stages and rebuilds the xcframework on every run
  even when nothing changed: a stamp of its inputs would skip it.

### G1: the bolt, contacts, invites and tribes (2026-10-14, `ios/g1-people`)

**Built** (Tom's decisions, 2026-10-14; [../design/iphone.md](../design/iphone.md)
decisions 4, 13 and 17, screens 1, 9 and 11): the connection bolt always
in Chats' title capsule, green when connected and orange when not, always
opening its panel (connected, it says so; Reconnect now only offline); New
message and its `ComingScreen` gone. Tribes ends in Join a tribe and
Create a tribe, Direct messages in the pending invites, Add contact and
Invite someone, each a sheet, as the Mac's sidebar ends them; the sections
show with nothing in them, for their actions. Codes come typed, pasted,
scanned with the camera (`CodeScanner`, which `InvoiceScanner` is now) or
read from a photo of a QR code (`QRImage`). Money goes through
`TouchPayButton`: the key exchange, an invite (always confirmed) and a
join. A chat's details are pushed over it (`ChatsRoute.details`,
`PhoneRouter.openDetails(_:)`, for the conversation's More menu):
a contact's key with its QR to copy and share, their local time, the time
zone switch and Remove contact; a tribe's facts, link, members (with the
owner's Approve, Decline and Remove), how you appear in it, Edit tribe and
Leave. Removing a contact on the phone goes back to Chats rather than to
the next chat (`deleteContact(_:movesSelection:)`).

**Shared with the Mac** (moved out of its views, the Mac unchanged):
`TribeSettingsDraft`, `TribeLookup`, `TribeIdentityDraft` and
`TimeZoneSharingSwitch` (`PeelUI/TribeForms.swift`), `InviteIcon`
(`Avatar.swift`), `AppModel.readContactCode` and `addedName`, an
invite's status words, a tribe's subtitle, escrow line and alias note,
`TribeInfo.priceLine`, `ContactCode.previewDetail` and `addRefusal`,
`Conversation.offersTimeZoneSwitch`, `AppModel.contactSince`,
`timeZoneSharing(in:)` and `setTimeZoneSharing`.

**Not built, and why:** a tribe's app and second brain (no web pane on
the phone); pinned messages and mute in the details (G2's More menu).

### Message lists, Layer 1 (2026-10-14, `fix/iphone-list-structure`)

**Built** ([../reviews/2026-10-14-message-lists.md](../reviews/2026-10-14-message-lists.md),
PR 3, rules 6 to 8). The thread sheet comes up on `openThread` with a
spinner where its rows go until they load, and dismissed it stays open in
the model until it has gone (`PhoneRouter.thread`, `threadDismissed`), so
it never slides down blank. A chat's screen keeps the rows it last showed
(`HeldRows`) and its list stays made, with its place, while the model
clears them: through the pop, under another tab and while a jump's window
reloads. The list is made once per chat, when `AppModel.loadedChat` says
its messages are in, and where it opens is worked out then, once. It
opens at a message asked for, else at "New messages"
(`opensAtNewMessages`), else where it last stood (`ListAnchor`, kept with
`keep(_:of:)` each time it comes to rest), else at the newest, and is
hidden until that row is laid out where it belongs: no 80 ms timer, no
jump to the divider after it shows. Back from another tab, "New messages"
that came meanwhile wins; left at the newest, it goes to the newest past
what came meanwhile. Rows report where they are in the content as they
lay out, not on every scroll frame. `ListAnchor`, `loadedChat`,
`anchor(of:)`, `keep(_:of:)` and `opensAtNewMessages(in:)` are PeelUI's,
from the Mac's list PRs (2 and 4); the iPhone does not use
`ChatListController` yet.

**Interim:** `MessageList.place` is a timed retry (a frame at a time, at
most a dozen) against the lazy stack's estimates. The shared list engine
(the review's PR 6) deletes it.

**Checked** in the simulator on a seeded local stack, frame by frame:
thread close kept its rows (about 20 blank frames before, none after),
Back kept the chat's rows (about 12 blank before, none), Back then the
chat again and a tab switch and back came back to the row being read
(before: the newest), and a chat with unread showed once, at "New
messages", without the jump.

**Not yet, and why:**
- A chat pushed in is blank until its rows load (about 15 frames on a
  warm database): nothing is held for a chat not yet open.
- The keyboard keeps the old re-pin: the bottom snaps after the keyboard
  rises, with a few frames of overlapping rows. `.sizeChanges` anchoring
  rode the keyboard but blanked the top of the list (the Mac's F8), so it
  waits for PR 6's engine.
- With the keyboard up, a message arriving at the bottom lands a few
  points short and shows "1 new message", as before.
- Anchors live while Peel runs. Older pages are dropped when a chat is
  left, so a place in them is not restored. Not checked: a jump from a
  notification.

### Org pages on the iPhone (2026-10-26, `feature/phone-org-pages`)

**Built.** A deliverable the agent's DM names now opens on the phone. The
Mac opens one through its own strut's read-through (`/peers/<org>/…`), on
loopback, which the phone cannot reach; the org's strut faces the internet
behind its own gate, so the phone reads it directly, as strut's
specs/DESKTOP.md ("A device with no strut of its own", stakwork/strut#339)
describes:

- **Pairing.** Hive's device flow moved from PeelAgent to PeelCore
  (`Hive.swift`: `HiveClient`, `HiveLink`, `HivePeer`, and `answer(to:)`,
  the poll loop the Mac and the phone now share), with the two helpers it
  needed (`TextLine.clean`, ChatData's cleaner; `Date(iso8601:)`). The
  phone pairs as a device of its own (`PhoneStadeum`): You › Stadeum,
  Connect Stadeum, the code, Open Stadeum to approve it in Safari; the
  credential and each org's token in `Profile.hive`; renewed when Peel
  comes to the front and the link is due; a revoke clears it and says to
  connect again; Disconnect. Locking or forgetting the account lets all of
  it go (`close`, on `phase` leaving `.ready`; the phone's profile is always
  `default`, so a pairing or renewal from before is told apart by a
  generation count and keeps nothing). A development profile pairs with
  `-hiveURL`, as on the Mac (`HiveClient(for:)`).
- **The cards.** An agent reply's `metadata.peel.artifacts` are lines under
  it (`AgentArtifactLines`), as on the Mac: label and title, then the
  workspace and Open; "On your Mac" for one on the brain's own strut;
  "Connect Stadeum in You to open" before pairing; else its https link, if
  it has one, opens in Safari.
- **The page.** `AgentArtifact.Handle.onOrg` takes the brain's
  `/peers/<org>` hop off (a second hop stays, for the org's own
  read-through) and `StrutUI.page` builds the org's UI address alone
  (`/lab/?artifact=…&solo=1`, `?app=<name>&solo=1`), the address
  `MemoryServer.page` now builds through too. `OrgPageSheet` shows it in a
  `WKWebView` whose store keeps nothing: the token as the first request's
  bearer (a swarm's gate wants a credential for the page itself) and set
  as `sessionStorage["strut/apiKey"]` by a script before the page's own,
  in strut's UI's folder on the org's origin only (a swarm's `/lab/`
  shares its host), never in an address. Navigation keeps to that folder,
  its `srcdoc` and blob frames; strut's "open in a new tab" loads in place,
  Back returning; a link elsewhere goes to Safari only from strut's own
  page (never a frame, which holds the org's or an agent's content) and on
  the person's own tap (`TouchWebView`); nothing downloads.

**Checked.** `swift test`: all pass but `BundledBridgeTests.theStagedRunnerExitsWhenPeelsPipeCloses`,
which needs a bridge staged after the runner pin moved to sphinx#396
(10-25; this Mac's stage is from 10-23). `OrgPageTests` cover the mapping
and the address. The iPhone app builds for the simulator (an arm64
simulator slice of the core built from v0.8.39 for it) and the Mac app
builds. `OrgPageSheet` itself, compiled into a throwaway simulator app
against a local strut with only a person token: an app's page rendered
and its `step_run` call went through, a job's markdown file rendered with
its image, and its "Open in new tab" loaded the file in place (WebKit shows no
markdown page, so the viewer stays). Not seen on screen: You › Stadeum
and the cards in the real app (no account on the simulator), and a real
Stadeum pairing.

**Review.** An independent review (an agent that did not write it) found
no way for the token to reach an address, a log, another origin or
Safari. Applied from it: Stadeum let go with the account (the sheet with
the previous person's token could have come back after Forget, and a
pairing in flight could have written the next account's item); links out
only from strut's own page; "open in a new tab" loads in place; the https
fallback; renewal races (a cancelled or superseded renewal keeps and says
nothing); a failed Keychain read clears the link; the folder scoping; the
revoke said once. Not applied: the iPhone's `PhoneStadeum` and the Mac's
`HiveState` are two copies of one pairing machine (status, connect,
cancel, renew, revoke), against "one owner". The Mac's is tied to its
strut and runner (peers synced, rooms' tokens handed to the bridge, a
revoked link kept to show), and folding them needs a Mac check run; it
goes with the Apps list PR, which needs the shared state anyway (done
there: "Apps on the iPhone, one Stadeum" below). Shared
now: the client and the poll loop (`answer(to:)`), and the choice of Hive
(`HiveClient(for:)`).

**Not done.** The Apps list (each workspace's pinned apps on the phone)
is the next PR. A deliverable on the brain's own strut stays words on the
phone.

### Apps on the iPhone, one Stadeum (2026-10-26, `feature/phone-apps-list`)

**Built.** The review's open finding above, and the Apps list.

- **One Stadeum.** The iPhone's `PhoneStadeum` and the Mac's `HiveState`
  are now one model in PeelUI, `Stadeum` (`AppModel.stadeum`): open with
  the account, Connect (`answer(to:)`), renew hourly (and on the iPhone
  when it comes to the front, `renewIfDue`), the revoke rule (the Mac's:
  orgs kept and listed, none `live`, Connect again), close, Disconnect,
  and a generation count so nothing begun before a close or a Disconnect
  keeps or says anything. What only the Mac does around it is its
  `StadeumHost` (`MacStadeumHost`): the "Always allow" rules per workspace
  before a link is kept, strut started again for another person or the
  peers synced and the bridge handed the tokens when the orgs change, the
  same on a revoke, and on Disconnect runner told to let go and strut
  started again. The Mac's behaviour is unchanged.
- **The apps.** `WorkspaceApp` moved to PeelCore with its listing
  (`listing`, one reader for strut's `GET /apps`), A–Z, search and
  source; its icon table to `Apps/Shared` (`WorkspaceAppIcon`). One read
  for both, `Stadeum.readApps`: the Mac's own and the workspaces' through
  its strut, the iPhone's workspaces' each on its own strut with the
  person's token (`WorkspaceApp.pinned(on:)`). On the phone, Chats gets an
  Apps row once Stadeum is connected (`AppsScreen`): the pinned apps, A–Z,
  with their icon, what they are for, where they come from when there are
  several workspaces, and their version; a tap opens one in the org page
  sheet (`Stadeum.opening(_ app:)`, `?app=<name>&solo=1` on the org);
  pulling reads them again.
- **The page.** `OrgPageRequest` (PeelUI) is the page and its token for
  both openings, with its origin, folder, first request and hand-over
  script, now unit tested; `PhoneRouter.orgPage` is the sheet, closed when
  its workspace stops being live and when the account locks.

**Checked.** `StadeumTests` (pairing against a stand-in Hive, the host
told, kept with the account; a revoke keeping the orgs but using none,
still revoked when opened again, Hive not asked again; close; openings;
the apps read and an unreadable workspace; the page's folder and
hand-over), `WorkspaceAppTests` (a workspace's pinned apps read on its
own strut with the bearer), with `HiveTests` and `OrgPageTests`; both
apps build; a person token's `GET /apps` on a local strut gives the
fields the reader takes. Not seen on screen: the Apps screen in the real
app (no account on the simulator).

**Review.** An independent review found the Mac step for step the same
and no token leak. Applied from it: the revoke kept with the link
(`HiveLink.revokedAt`): the iPhone opens Stadeum at every unlock, which
had forgotten it and used the revoked tokens until the next renewal's
401 (and for up to a week offline); no renewal is tried while revoked; a
revoke found mid-pairing leaves the code on the screen (coming back from
Safari had replaced it); `readingApps` observed (the screen showed "No
apps yet" while reading, and could stay on the spinner); unreadable
workspaces said (`unreadApps`) instead of "No apps yet"; only workspaces
still live listed; the iPhone renews when due, not at every unlock; the
Mac's Connect opens Stadeum itself when its agent did not open (it had
done nothing); the router follows `.apps` to Chats' Apps; an app's words
for the person moved from PeelCore to PeelUI. Two Mac differences kept,
both harmless: on a revoke the strut and bridge sync runs in its own
task, and Disconnect revokes the "Always allow" rules even when the
Keychain delete fails.

### Pairing that survives the trip to Safari (2026-10-27, `fix/iphone-stadeum-pairing`)

**Found.** A developer paired an iPhone: Stadeum said "Approved, it
finishes pairing on its own", and the iPhone never did. On the Mac the
browser sits beside Peel, which keeps polling; on the iPhone, approving
takes Peel off the screen, and three things could end the pairing after
Hive's yes. The first poll back in Peel often went out on a connection
the system dropped while Peel was away, and one error ended the pairing
(`answer(to:)` threw it). Hive's 500 for a moment did the same. And a
code approved but collected after its 10 minutes (signing in to Hive
counts) said "The code ran out before it was approved", which Stadeum had
just contradicted.

**Built.** `answer(to:until:wait:)` polls again after a poll that reached
no one (a dropped or refused connection, a timeout, no network:
`unreached`; a certificate Peel will not trust still fails at once) or a
5xx (`Unanswered`), until
the code's end by this device's clock (`deadline`: `expiresIn` from when
the code was asked for, never later than Hive's); past it, the last error
is said. A refusal still ends it at once. `Stadeum.cameToFront` (from
`AppModel.becameActive`, both apps, while unlocked) cuts the wait before
the next poll short, so coming back from Safari collects at once; it also
renews when due, which the iPhone's scene did itself before. A code Hive
no longer has is said for what it is: past the deadline, "ran out before
pairing finished", with the minutes to come back in; sooner, "Stadeum no
longer has this code".

**Checked.** `HiveTests` (a 5xx tried again and then said; a refusal not
tried again; a port no one listens on tried again until the deadline) and
`StadeumTests` (coming to the front polls a 600-second interval at once;
the two expired messages), each failing with its fix taken out; the full
`swift test`; the iPhone app built for the simulator. `scripts/risk.sh`:
medium. Not seen: a real iPhone paired against Hive, nor You › Stadeum on
screen (no account on the simulator).

**Review.** `/code-review`, `/simplify` and `/security-review` (no
findings). Applied: a certificate Peel will not trust fails at once
rather than being retried for ten minutes (`unreached`); the wait holds
`self` strongly (a released model would have polled with no wait); the
front's shortcut is one flag only while a poll is in flight, so it never
leaks into the next pairing; 429 counts as busy, as `Web.retryLater`
judges it; `expiresIn` is range-checked like `interval`; `renewIfDue`
internal; the tests share the stand-in Hive and no longer sleep. Not
applied: an `AsyncStream` as the wake signal (cancelling the race with
the sleep ends the stream, so a later wake would be lost); one shared
transient-error helper (`PeelError.diagnosticKind` counts any unlisted
code as network, `.badURL` included, which would be retried for ten
minutes); the Mac now renews on coming to the front when due, and a
renewal already in flight then runs beside a second (seconds' window,
as the iPhone already had); a lost reply leaves a device in Stadeum's
list that nothing holds (Hive's to say; it answers `expired_token` for
expired, unknown and collected alike); a persistent 5xx re-mints the
orgs' tokens each poll (Hive mints before it spends the code).

### The project

- An Xcode project for the iOS app, an extension and signing. SwiftPM
  stays the source of truth for the libraries; the project only hosts the
  app targets. The Mac app can keep `scripts/bundle-app.sh`.
- **A paid Apple developer team is needed** for the push capability and
  TestFlight. A Personal Team installs on Tom's own phone for 7 days but
  cannot receive push.
- Bundle ID per team, as on the Mac (#225).

### Same account on two devices

The phone holds Tom's words like the Mac (Keychain, under the PIN). Peel
already follows tribes joined or left on another device (#207) and catches
up history from what it has handled (#204). The restore matrix in
[../finding-bugs.md](../finding-bugs.md) §6 has to include "Peel Mac and
Peel iPhone on one account" before Tom moves his real account.

## 2. The remote

> **Superseded (2026-10-19):** sections 2 and 4 and the remote track of
> the build order (S2, B1 to B4, H1). Option A, the agent's own identity,
> stands, held by the bridge. The rest is in
> [../agent-on-strut.md](../agent-on-strut.md): the envelope, the request
> types, approvals on the Mac, "Waiting for your approval on your Mac" on
> the phone. B5 to B7 (jobs, cards and notification actions on the phone)
> are Phase 2, on the DM's job messages and device requests rather than
> jobs-architecture.md's P2 and P3.

### Who the phone talks to

| Option | How | Verdict |
|---|---|---|
| **A. The agent's own identity** | The brain runs a second account for the agent. The phone sends it Sphinx messages like any contact | **Chosen.** End-to-end encrypted, queued by the broker, works from the official apps too, and push already exists for DMs |
| B. Tom's account messaging itself | Phone and Mac share one identity and send to it | No such channel in the core: `sendself` is the async-payment path (`sphinx/src/topics.rs:12`), contacts are per child key, and whether you can add your own key as a contact is unverified |
| C. Direct HTTPS to Strut (Tailscale, a tunnel) | The phone calls Strut's API | Strut's routes are mostly unauthenticated; nothing is queued while the Mac sleeps; it bypasses the approval gate. Kept as a possible live-stream optimisation later, never as the control path |
| D. A relay through the memes server | Write commands into a file the brain polls | A second encrypted channel to build and secure, for what Sphinx already does |

The 2026-10-08 design had an agent account on a separate host
([../design/agents.md](../design/agents.md), "Setting up the agent") and it
was dropped as too much too early. This is a smaller version: the identity,
but no separate host. It runs inside the brain's Peel.

**Setting it up.** In Account › Agent on the Mac: "Give your agent a Sphinx
account". Peel derives the agent's words from Tom's (below), signs the
agent's account up with an invite (Peel already makes invites, `invite`
table), keeps its words in the Keychain as a second profile, and adds it to
Tom's contacts.

**One set of words: the agent's are derived from Tom's.** The server knows an
account by its root key: the core makes it from the seed as `m/42'/42'` over
`hkdf(seed, "bip32 seed")` (`sphinx/src/signer/my_keys_manager.rs:130-137`),
and every contact already gets its own child key under that root
(`auth_secret_from_idx`). Those children are still Tom's account to the
mixer, which routes and pushes by root, so a child key cannot be the agent's
address. What can be done is to derive a whole second seed from Tom's,
one way:

- `agent seed n = HKDF-SHA256(Tom's seed, info: "peel agent <n>")`, cut to
  16 bytes of entropy and turned into words with the core's
  `mnemonicFromEntropy`. CryptoKit only, no core change. BIP85 (child
  mnemonics from a master key) is the standard form of the same idea, and
  worth using instead if the core exposes BIP32 derivation to Swift.
- To the server the agent is a separate account with an unrelated key; it
  cannot be linked back to Tom's.
- **Backup is Tom's twelve words.** A restore derives agent 1, 2, … and
  restores each one the server knows, stopping at the first it does not.
- One way only: the agent's words do not reveal Tom's.
- If the agent's words leak, the agent moves to the next index; the old
  index is retired in the `Agent` record.
- Only Peel knows to derive them. The official apps restore Tom's account
  and never see the agent's words, which is fine: they reach the agent as a
  contact.

This is the "Create from my seed … until child derivation lands" step that
[../design/agents.md](../design/agents.md) left greyed in 2026-10-08. That costs a few sats once: the key
exchange is 5 sats (`Engine+Messages.swift:8`). After that, **messages
between Tom and the agent are free**: a direct message is sent with 0 msat
unless it carries a payment (`Engine+Messages.swift:300`). The agent needs no
running balance. Its only budget is model spend, which is the agent's API
key or, later, a Bifrost or Mothership virtual key, not Sphinx sats.

**Why its own account, even on an always-on server.** The brain runs Tom's
account too, because the agent reads Tom's chats and sends as Tom behind the
card. So why a second identity? The phone and the laptop need an address
for the brain, and Tom's account cannot address itself: the core has no
channel from one of an account's devices to another. The other way to give
the brain an address is the network: a gateway on the server in front of
Strut and the agent, reached over Tailscale or a tunnel. On an always-on
box that would work, but it means:

- its own auth, because Strut's routes are mostly open;
- Tailscale or a tunnel on every phone and laptop;
- its own push: APNs keys on the server and a push service, because Sphinx's
  push only fires for Sphinx messages;
- nothing waits if the box is down, rebooting or moving house.

A Sphinx identity gets all four from what Sphinx already does, for a few
sats once. The agent can also speak as itself later (a tribe member that
is clearly Tom's agent, not Tom). The network path stays an option to add
for live streaming of a job's steps, on top of this, not instead of it.

**Ready for more than one.** v1 has one agent, but the data has room for
more, so a second one is setup and not a migration. The agent store already
keeps graph-shaped `record`s (`SQLiteAgentStore+Migrations.swift`). B1 adds:

- An `Agent` record: id, name (today's `AgentSession.defaultName`, "Peel"),
  photo, its system prompt, its Sphinx profile and pubkey, and which model
  credential it uses.
- The `Conversation` record links to its `Agent`. Approval rules,
  automations and the `RemoteInbox` rows carry the agent's id. Automations
  pass it in `peel-automation`'s input, so each run knows whose it is.
- Everything that reads "the agent" today reads "agent 1". No UI to add a
  second one in v1.

**What making it a real contact costs.** Nothing that blocks it, but the
work is real:

- **Two engines on the brain.** Peel runs one account today. The agent's
  engine is a second PeelCore engine with its own MQTT session, profile lock
  and storage. It is headless, but it still has to start, reconnect and catch
  up like Tom's.
- **One agent on the Mac, not two.** The agent will show up in Tom's direct
  messages as a contact, beside today's Agent chat. On the Mac its row
  opens the Agent chat, as [../design/agents.md](../design/agents.md)
  decided ("one agent contact"). The two must not show as separate chats.
- **The agent's key lives on the brain.** It is derived from Tom's words, so
  there is nothing new to back up, but the brain's Keychain holds it, and a
  home server needs it (or Tom's words, to derive it). Whoever holds it can
  read the agent's side of the conversation. It cannot command the brain,
  because the brain takes commands only from Tom's key.
- **Round trips, not streaming.** A reply goes through the broker: about a
  second, and the phone sees whole messages, not tokens arriving.
- **It is visible everywhere Tom is.** The official apps show the agent's
  chat too: talk as normal text, control messages as bot responses or
  nothing. Its notifications follow Tom's mute settings like any contact's.

**Trust.** The agent's engine takes commands only from its owner's pubkey,
and the sender comes from the signature, as for every message today. Anyone
else who messages the agent gets nothing back in v1.

### Two kinds of message

The core's `Message` struct is a closed serde struct
(`sphinx/src/msg/mod.rs:167`): unknown fields are dropped. A structured
payload therefore has to be a message's `content` under its own type.

| Kind | Type | Content | Shown |
|---|---|---|---|
| **Talk** | `Message` (0) | Markdown, both ways | As a normal chat, in Peel and the official apps |
| **Control** | `BotCmd` (24), phone to brain; `BotRes` (25), brain to phone | One JSON envelope | Peel renders cards; the official apps show nothing for 24 and a bot response for 25 |

Types 24 and 25 exist in the core (`msg/mod.rs:227-262`), but nothing sends
`BotCmd` today, so spike S2 checks that both go through the core, the broker
and history catch-up between two Peel accounts. The fallback is type 0 with
a fenced `peel` block that Peel hides and other apps show as code.

The envelope:

```json
{ "v": 1, "op": "automation.pause", "id": "<uuid, the command's id>",
  "args": { "automation_id": "…" }, "not_after": 1760400000 }
```

Replies carry `re` (the command's id) and a `state` snapshot where it helps,
so the phone can redraw without asking again.

### What the phone can do

| On the phone | Command (`op`) | On the brain |
|---|---|---|
| Ask the agent anything | Talk message | An agent turn in the agent conversation, then a Talk reply |
| See what is going on | `status` | Brain awake, Strut up, last seen, counts of running jobs and open asks |
| Needs you: answer a job's question | `job.answer {job_id, text}` | `continue_job` (or queued until the job is not busy) |
| Approve or deny a write | `approval.decide {approval_id, decision: once\|always\|deny}` | The same `ApprovalGate` as the Mac card, then the exact step it showed |
| Jobs | `jobs.list`, `job.get`, `job.cancel` | Peel's `Job` records, `GET /jobs/:id`, `POST …/cancel` |
| Automations | `automations.list`, `automation.pause\|resume\|run_now\|delete` | `AutomationsClient`, as the sidebar does today |
| Create an automation | Talk ("every Friday at 5…") | The agent's `create_automation`; its card comes to the phone as an approval |
| Memory | Talk ("what do you know about Kate?") | The agent's `recall`. No graph browser on the phone in v1 |

Brain to phone, unprompted, always as `BotRes` (with a short Talk line where a
person should read it):

| Event | Envelope |
|---|---|
| An automation delivered | `automation.delivered {name, text}` (and the text as Talk) |
| A job finished, failed or asks | `job.update {job_id, status, text, ask?}` |
| A write needs approval | `approval.request {approval_id, intent: {action, content, details, target}, expires}` |
| State changed while the phone was away | `state {jobs, automations, asks}` on the phone's `status` |

**Approvals from the phone are the same gate.** The phone shows the intent
exactly as the brain will run it (`ToolIntent`); the decision names the
approval's id; the brain checks the id is open and unexpired, runs exactly
what it showed, and closes it. A replayed or late decision does nothing.
"Always allow" on the phone writes the same `ApprovalRule` as on the Mac.

### One conversation

The agent DM is where everything the phone sees lives: phone turns,
automation deliveries, job updates, approvals. The Mac's agent chat shows
the same deliveries and the phone's turns (each turn in `AgentSession` keeps
its origin). In v1 the Mac's own typed turns stay on the Mac and are not
copied into the DM, to keep the DM to what the phone needs; open question 3.

## 3. Queues: where things wait

There are three places work can wait, and each has one owner.

| Queue | Holds | Owner | When the brain is asleep |
|---|---|---|---|
| **Phone → brain** | Talk and `BotCmd` messages | The Sphinx broker, then the brain's `RemoteInbox` | Messages wait on the broker; the brain catches up on wake (#204's history catch-up) |
| **Inside the brain** | Commands not yet done, and `job.answer` for a busy job | `RemoteInbox` in `agent.sqlite` | Survives restarts; worked through in order |
| **Brain → phone** | Replies and events | The Sphinx broker, then push | The phone gets them when it connects or a push wakes it |

**What the person sees.** The agent runs on the brain, so when the brain is
off nothing answers, not even the Sphinx tools. The phone says so itself,
from the missing ack:

| The brain is | You send "what did Kate say?" (Sphinx tools) | You send "research flights for Friday" (a job) |
|---|---|---|
| Asleep or off | *Queued. Your Mac picks this up when it wakes* (the phone, no ack) | The same |
| Awake, Strut down | Answered at once | The agent answers: "Strut isn't running. I've kept this and will start it when Strut is back." The inbox holds the `start_job` |
| Awake, Strut up | Answered at once | The job starts; its result or question arrives later as a message |

The front agent decides between its own tools and a job, as in
agent-brain.md ("Routing"). Nothing on the phone decides that.

**`RemoteInbox`** is one table in `agent.sqlite`: the message uuid
(the key; duplicates from catch-up do nothing), the `op`, its arguments,
received and `not_after` times, and a status (`received`, `acked`, `running`,
`done`, `failed`, `expired`). The rules:

- **Store, then ack.** The brain writes the row and replies `ack {re}` at
  once, before any model or Strut work. The phone shows each command as
  *Sent*, then *Received by your Mac*, then the result. No ack within a few
  seconds means *Your Mac will pick this up when it wakes*. That is the
  whole presence model: no heartbeat messages to keep up.
- **In order, one at a time** per conversation. Typed commands that do not
  touch the agent (pause, list, decide) can run beside a turn.
- **Stale work asks first.** Talk messages and commands carry `not_after`
  (default 12 hours for Talk, 1 hour for an approval). A message older than
  that, found on wake, is not acted on blindly: the agent replies "This came
  in at 08:00 while I was asleep; still want it?" An approval past its
  `expires` is never run.
- **Busy jobs queue, not fail.** Strut refuses a second turn on a job
  (`job_busy`); the inbox keeps the answer and sends it when the turn ends.

**What Strut does not do.** Strut's scheduler keeps `nextRunAt` in memory and
skips a fire missed while it was down or asleep (`strut/src/scheduler.ts`).
A callback that fails three times is lost, and an interrupted run is marked
stale. So:

- On a laptop brain, the Automations list already shows a missed one-off
  (`Automation.isMissed`). Add **Run missed on wake**, per automation, off by
  default: on launch the brain compares each automation's last run with its
  schedule and fires each one it missed once.
- On launch, the brain reconciles every job still marked running with `GET
  …/runs/:id`, as jobs-architecture.md already plans.
- On a home server none of this happens in practice, which is the point of
  one.

**Not yet known:** how long the broker keeps messages for a recipient that is
offline. Spike S3 measures it, and the answer sets how long a brain can sleep
before the phone's messages are lost.

## 4. The home server

> **Superseded (2026-10-19):** brain mode is strut and the bridge on a home
> server, one Docker bundle, with no Peel on the box ([../end-state.md](../end-state.md),
> Phase 2). Stage 3's `peel serve` is not needed.

The brain is a role, not a machine. Three stages, the same code:

| Stage | Where | What changes |
|---|---|---|
| **1. The Mac you use** | Tom's laptop | Nothing new. Sleep is handled by the queues above. Optional: "Keep this Mac awake while it is charging" in Account › Agent (`IOPMAssertion`, only while plugged in) |
| **2. A Mac mini at home** | Always on | **Brain mode**: the same Peel.app, launched at login, running the agent's engine and Strut. Tom's own account is optional there. The laptop's Peel then becomes a client like the phone: its agent chat speaks the same remote protocol to the agent. Moving the brain = moving the Strut data folder, `agent.sqlite` and the agent's words, with an export and import in Account › Agent |
| **3. Linux or cloud** | A server | PeelCore and AgentKit headless (`peel serve`), Strut as it is. Needs a Linux build of the core, a file or KMS secret store instead of the Keychain, and Calendar dropped (EventKit is Apple-only). Only worth doing if a Mac mini is not good enough |

Stage 2 is the one worth aiming at. It is why the remote protocol is the
single way to reach the agent from anywhere other than the brain itself:
once the brain moves off the laptop, the Mac app needs exactly what the phone
needs, and nothing has to be built twice.

## 5. Push notifications

How Sphinx does it today (from `sphinx/mixer/src/push.rs` and
`sphinx-ios-v2`):

- The app registers its APNs token with the core's `setPushToken`, which
  publishes it on the MQTT `pushtoken` topic. The mixer keeps **one token per
  account root**.
- On a new message, the mixer posts to `hub.sphinx.chat/api/v1/nodes/notify`
  with the encrypted child index and "you have new messages". The hub signs
  for the official app's bundle ID only.
- The official app's Notification Service Extension decrypts the child index
  with a `push_key` from a shared Keychain group and looks up the chat's name
  in an encrypted map in app-group defaults. No message text is in the push.
- The official app disconnects MQTT in the background. Push is the only way it
  is woken.

What that means for Peel:

- **Peel needs the hub to accept a second app** (Peel's bundle ID and APNs
  key). Tom is finding out (2026-10-13). The plan assumes it can: I5 is built
  as if the hub says yes, and if it says no, I5 is dropped and the phone stays
  foreground-only plus background refresh. Spike S4.
- **One token per account** means that whichever app registered last gets the
  pushes. Fine for Tom once he moves to Peel; worth a note for anyone who runs
  both apps on one phone.
- **The agent's messages push like any DM**, because they are DMs. No extra
  server.
- Peel's extension does what the official one does: decrypt the child index,
  show the chat's name. For the agent's chat it shows "Your agent" and, where
  the brain sends an `approval.request`, a notification category with
  **Allow once** and **Deny** actions. A tap runs in the background, connects
  briefly, sends `approval.decide` and disconnects.
- Until the hub accepts Peel: foreground only, plus opportunistic
  `BGAppRefreshTask` catch-up. Never call `setPushToken` from Peel on a real
  account before then, since it would take the official app's pushes away.

### Push: what is built (I5 groundwork, 2026-10-27)

Built, mirroring `sphinx-ios-v2` (`AppDelegate`, `SphinxOnionManager.pushKey`,
`registerDeviceID`, its notification extension), and **registering nothing**:

- **Targets and ids.** The iPhone app and a new `PeelNotificationService`
  extension (`<bundle ID>.NotificationService`, `Apps/iOS/NotificationService/`)
  share `Apps/iOS/Peel.entitlements`: `aps-environment`
  (`PEEL_APS_ENVIRONMENT`: development, production in Release), the app group
  `PEEL_APP_GROUP` (`group.com.sphinx.peel`) and the Keychain group
  `$(AppIdentifierPrefix)$(PEEL_KEYCHAIN_GROUP)` (`com.sphinx.peel.shared`).
  All three come from `Apps/Config/Peel.xcconfig`, follow `PEEL_BUNDLE_ID`, and
  reach Swift as Info.plist keys (`PeelAppID`, `PeelAppGroup`,
  `PeelKeychainGroup`, `PeelPushEnvironment`; `PeelPush.PushConfig`). The
  project is hand-written, so `project.pbxproj` was edited (no XcodeGen).
- **`Sources/PeelPush`** (no dependencies, tests run anywhere:
  `swift test --filter PeelPushTests`): `PushToken.hex`, `PushKey` (32 random
  bytes as hex, made once by the app in the shared Keychain group; the
  extension only reads it), `PushConfig`, `PeelPushFlags`,
  `PushRegistration` (token, app ID, environment) and its
  `coreArguments` (what the core is given beside the token), and `PushNotificationResolver` (child
  from `aps.custom_data.child`, a Hive link left as the server sent it,
  decrypt through `ChildIndexDecrypting`, a name from `PushNameDirectory`,
  generic "Peel" / "You have new messages" on any failure).
  `Sources/PeelPushCrypto` is the core's `decryptChildIndex` behind that
  protocol, the only part the extension links besides PeelPush (not PeelCore).
- **The app.** `PeelAppDelegate` (via `@UIApplicationDelegateAdaptor`) calls
  `registerForRemoteNotifications` and hands the token to `PushCoordinator`,
  which makes the push key and calls `Engine.registerPushToken`
  (`Engine+Push.swift`: the core's `setPushTokenForApp`, sphinx-rs 0.8.40,
  with `app_id` = `com.sphinx.peel` and `push_environment`; the older
  `setPushToken` carries neither and is never used). The
  notification permission is asked for only when the flag is on, since
  nothing would come otherwise. `Notifier` is unchanged.
- **The flag.** `PeelPushFlags.registerWithHub` (Info.plist
  `PeelPushRegisterWithHub`, a UserDefaults value wins), **off by default**.
  `registerPushToken` sends nothing while it is off, when not connected, with
  an empty token, or with a key that is not a push key
  (`PushRegistrationTests`, which also asserts the app ID and environment the
  core is given).
- **The environment** is one build setting, `PEEL_APS_ENVIRONMENT`
  (`Apps/Config/Peel.xcconfig`: development, production for Release). The
  entitlement's `aps-environment` and Info.plist's `PeelPushEnvironment` (what
  is reported as `push_environment`) both read it; no `#if DEBUG` decides it.
  The mixer deletes a registration whose environment is not the token's, so
  they must stay equal: any Release build, archive or Ad Hoc, is signed
  production and reports production.

Reading the token while debugging: a Debug build prints `[Peel push] APNs
device token (<environment>, app <id>): <hex>` to Xcode's console and asks for
notification permission at launch, without turning the hub flag on. Release
builds print and ask nothing. The push key is never printed.

Not verified here (a Linux pod with no Swift or Xcode): none of this was
compiled. In particular `decryptChildIndex(encryptedChild:pushKey:)` follows
sphinx-ios-v2's call site and `setPushTokenForApp(... appId:pushEnvironment:)`
follows sphinx-rs 0.8.40's UDL, and `project.pbxproj` was only checked for
balanced syntax and that every id it uses is defined. Build `Peel iOS` once
in Xcode and run `swift test`.

Done since: sphinx-rs carries `app_id` and `push_environment` on the
registration (0.8.40); the mixer keeps one registration per app; the hub's
routing is a Strut workflow (the mixer's `PUSH_WORKFLOW_URL` and
`PUSH_WORKFLOW_KEY`), not AWS SNS platform apps.

### The names map (what a push shows)

A push carries no text, only `aps.custom_data.child`, the child index encrypted
under the push key; the extension decrypts it (`decryptChildIndex`) and names
the chat from a map the app keeps, as sphinx-ios-v2 does.

- **Format, as Sphinx's** (`SphinxOnionManager.swift:1060-1099`,
  `saveContactsToSharedUserDefaults`; `SymmetricEncryptionManager.swift:21-27`):
  a JSON object `{"contact-<n>": name, "tribe-<n>": name}`, sealed with
  RNCryptor v3 under the push key as the password, base64, in the app group's
  UserDefaults under `childIndexesStorageKey` (Peel's own group,
  `group.com.sphinx.peel`). Sphinx's extension reads it the same way
  (`NotificationService.swift:102-129`) and words the body "You have new
  messages from <contact>" / "in <tribe>", title "Sphinx"; Peel's title is "Peel".
  Peel does not copy Sphinx's sound key, and nothing mutes or hides a push
  there. The decrypted child is only the index: no sender, no text.
- **Peel:** `PeelPush` has `PushNameDirectory` (the reader and the map),
  `PushNameDirectoryWriter` (seal and keep, skipping a write when the names
  have not changed; `clear`), `RNCryptorSealer` (the same scheme as PeelCore's
  `MediaCrypto`, Apple platforms only) and `UserDefaultsPushNameStore`; the
  extension reads with the same `PushNameDirectory.read`. Names are cleaned to
  one line of at most 100 characters; a blob that does not open under the
  push key, a missing key or map, or any failure gives the generic line.
- **When:** `PushCoordinator.refreshNames` runs when an account opens (phase
  ready), when the app comes to the front, and when a chat appears or goes or
  a name changes (`PushNames.signature`, not on every message). It is
  cleared (`accountClosed`) when the phase leaves ready: locked, forgotten.
  A locked phone-app therefore shows the generic line until unlocked. It
  needs the push key and the app group and does not depend on the hub flag
  and never registers anything.
- **The id mapping.** Sphinx: `my_idx` of the core's `listContacts` JSON is
  the index, its `pubkey` is matched to a contact's key or a tribe's owner key
  (`SphinxOnionManager.swift:1055-1085`). Peel: `Engine.Contact.childIndex` is
  that same `my_idx` from the same call (`EngineTypes.swift:391-399`,
  `Engine+Account.swift:54-57`), and its `pubkey` is the `chat` of a stored
  `Conversation`, whose `isTribe` tells a tribe from a contact
  (`PushNames.entries`). *Verified in code:* that Peel reads the same field
  from the same core call and that `chat` equals the core contact's key
  (tests use tribe keys in `c/<pubkey>` core entries). *Inferred, not
  verified:* that the child in a push decrypts to this `my_idx` (it does in
  Sphinx, which uses the same core and push key); to be confirmed on a device.
- Tests: `PushNamesTests` in PeelPushTests (round trip with a fake sealer, a
  contact and a tribe with one index, wrong or missing key, a corrupt blob,
  clearing, cleaning, the real cipher against an independent RNCryptor
  vector) and PeelCoreTests (the mapping from contacts and chats).

Device check, with the hub registration on (a development stack):

1. Add a contact (with a name) and join a tribe; open Peel once so the map is
   written; background the app.
2. Receive a direct message: the notification reads "You have new messages
   from <contact>". Receive a tribe message: "... in <tribe>".
3. Rename the contact (or have them change their alias), come to the front,
   background, receive again: the new name.
4. Forget the account (or let the PIN lock the app) and receive a message: the
   generic "You have new messages". Reopen: names are back.
5. A message from someone not yet a contact, or any push that fails to
   decrypt, shows the generic line and never crashes the extension.

### Turning registration on

The flag stays off until all of these are in place, in this order:

1. The mixer is deployed with `PUSH_WORKFLOW_URL` and `PUSH_WORKFLOW_KEY` set.
2. Strut secrets: `APNS_BUNDLE_ID=com.sphinx.peel`, `APNS_TEAM_ID=8297M44YTW`,
   and the APNs key id `VF3D2FPXST` (its key file secret is already configured).
3. Apple portal: the Push Notifications capability on `com.sphinx.peel` and
   on `com.sphinx.peel.NotificationService`, and the app group on both.
4. Build `Peel iOS`.
5. Turn it on: Info.plist `PeelPushRegisterWithHub` to true, or for a
   development run the UserDefaults key `PeelPushRegisterWithHub` (a launch
   argument `-PeelPushRegisterWithHub YES`, or `defaults write` for the
   simulator). A UserDefaults value wins. The default stays off.

The environment reported is development for a Debug build and production for
a Release one, and must equal the token's real environment.

Left to do:

1. **Apple portal and Strut setup** as above (nothing here can do it).
2. **Device check of the names map** (below).
3. The extension's `CURRENT_PROJECT_VERSION` is a copy of the app's (13): move
   them together. The project's `DEVELOPMENT_TEAM` is `8297M44YTW` (shared
   with Sphinx); the Personal Team is only for the Mac's local signing.

### I6: calls

Status (built, not yet run: written without an Xcode build): the phone joins
and starts LiveKit calls with the Mac's scope, through the same seam. Shared
unchanged: `CallLink`, `CallServer`, `Engine+Calls`, `CallStore` and
`AppModel.avatar(of:)`; `PhoneCalls`, which refused, is now `LiveKitCalls`
making an `IOSCallSession` (Apps/iOS/Peel). The target links the `LiveKit`
package product the Mac target uses (the same remote package reference).

- **Built:** join and start (audio from the chat's Call menu, or video, the
  camera on for the one who starts it), Join or Open on the call card,
  mute, camera and flip camera, Leave, a tile per person with speaking and
  muted marks, the focus layout (a tap; a screen someone shares takes it),
  the running time and connection state, Rejoin, microphone and camera
  permission asked on first use with Open Settings when refused, and a bar
  over the tabs while the call screen is down. The audio session is
  `playAndRecord` / `voiceChat` on joining and released on leaving.
  `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` and
  `UIBackgroundModes` = audio are `INFOPLIST_KEY_` build settings of the
  iOS target (the project generates its Info.plist).
- **Not built, as on the Mac or by choice:** screen sharing from the phone
  (the Mac shares; the phone needs a broadcast extension; viewing another's
  share works), the device menus (the system routes audio; flip replaces
  the camera menu), keep on top, the header's live-call pill, CallKit and
  VoIP push (the Mac has neither).
- **To check by hand:** a call between the phone and a Mac, with video;
  audio carrying on with the phone locked; permissions refused; leave and
  rejoin; a Bluetooth headset.

## 6. The app (Liquid Glass)

The design is [../design/iphone.md](../design/iphone.md), agreed by Tom on
2026-10-14 from the board
(https://claude.ai/artifact/PWonJ4bK6FXiCr7dpmrLBm). In short: tabs Chats,
Payments and You, plus search (Tom, 2026-10-14); the agent is a DM in
Chats, not a tab, and Automations is a screen pushed from Chats; glass only
on floating chrome; the Mac's colours and their meanings.

- **Calls** use LiveKit's iOS SDK behind `CallProvider` (built, I6; see
  "I6: calls"). CallKit and the official app's VoIP push are later.
- **Quick capture** (the Mac's planned ⌃⌥Space) is an App Intent on the
  phone: "Ask Peel" from the Action button, Siri, a Control Center control
  and the share sheet, each sending a Talk message to the agent.
- **Later:** a widget with the Needs you count; a Live Activity for a running
  job (needs push from the brain).

## 7. Build order

> **Superseded in part (2026-10-19):** the R track (S2, B1 to B4, H1) is
> replaced by Phase 1's PRs; see section 2's note.

Spikes first, because three of them can change the plan.

| # | What | Size |
|---|---|---|
| **S1** | The core for iOS: device and simulator slices from `sphinx-rs`, with the upgraded core (bug hunt N1); PeelCore compiles and connects in the simulator | M |
| **S2** | `BotCmd` and `BotRes` between two throwaway accounts through the core, the broker and catch-up | S |
| **S3** | How long the broker keeps messages for an offline recipient | S |
| **S4** | Ask the Sphinx team: can the hub accept Peel's bundle ID and APNs key? | a question |

Then three tracks. **C** (the client) and **R** (the remote) can run side by
side once I1 and B1 are in.

**The remote pays off before the iPhone app exists.** Because the agent is
a contact, B1 and B2 alone let Tom message his agent from the official
Sphinx app on his phone today, as plain text. Peel on iPhone then adds the
cards (approvals, Needs you, Activity) and push. So R can start first if the
client track is held up by S1.

| PR | Track | What | Depends on |
|---|---|---|---|
| **I1** | C | Batch 17: `PeelUI`, the platform protocols, `PeelMac`. Runs alone. Built on `ios/peelui` (2026-10-13), in review: `PeelUI` builds for the iOS Simulator; the Mac target keeps the name `PeelApp`; `PeelUITests` still to come | — |
| **I2** | C | The iOS project and target, signing, iOS 26 in `Package.swift`; the app opens, unlocks with the PIN, restores from words, connects. Built on `ios/app` (2026-10-13), with Chats and a read-only conversation; restore with a real account still to check | I1, S1 |
| **F1** | C | Phone foundation: the theme and glass helpers, the tab shell, navigation, the shared rows, a cross-platform Markdown renderer (the Mac's `MessageText` off AppKit) | I2 |
| **F2a** | C | Chats: the list, its top rows, Unread, Tribes, Direct messages, swipe actions, the not-connected state | F1 |
| **F2b** | C | Conversation, the Thread sheet and the composer | F1 |
| **F2c** | C | Payments, You and Lock | F1 |
| **I5** | C | Push: the extension, the shared Keychain group, `setPushToken` once the hub agrees | F2b, S4 |
| **I6** | C | Calls (built; see "I6: calls") | F2b |
| **B1** | R | The agent as a real contact: the `Agent` record (ready for more than one), its identity as a second engine on the brain, setup in Account › Agent, its contact row opening the Agent chat on the Mac | S2 |
| **B2** | R | `RemoteInbox`, the envelope, ack, expiry and order; Talk turns from the DM into `AgentSession` | B1 |
| **B3** | R | Commands for automations and status; deliveries to the DM | B2 |
| **B4** | R | Approvals over the remote (`approval.request` / `decide`), with the replay and expiry checks | B2 |
| **B5** | R | Jobs over the remote, once jobs-architecture.md's P2 and P3 land | B2, P2, P3 |
| **B6** | both | The agent DM's cards and the Automations screen on the phone, over B2 to B4 | F2b, B3, B4 |
| **B7** | both | Notification actions for approvals; the App Intents and share sheet | I5, B6 |
| **H1** | R | Brain mode for a Mac mini; brain export and import; the laptop as a client; Run missed on wake | B3 |

```
now      S1  S2  S3  S4        I1 (alone)
then     I2  B1
then     F1  B2
then     F2a F2b F2c  B3  B4
then     I5  I6  B6  H1
last     B7  B5 (when jobs land)
```

F2a, F2b and F2c run in parallel once F1 is in. The agent's cards (the
brain's status, queued messages, approvals, job results) and the
Automations screen on the phone wait for the remote track (B1 to B4);
until then the agent DM is a plain DM.

### Done means, for v1

- Tom uses Peel on his iPhone with his real account for a week instead of
  the official app, after the restore matrix covers Peel Mac plus Peel
  iPhone on one account.
- From the phone, with the Mac asleep: send the agent a message, see it
  queued, see it answered when the Mac wakes, with nothing done twice.
- An automation's result and a job's question arrive on the phone as a push
  (once the hub allows it), and an approval decided on the phone runs
  exactly what it showed, once.

## Later, and considered

- **Several agents** (Tom, 2026-10-13: a future idea, not v1). Each agent
  is a contact, so more than one is the same setup run again, on the
  `Agent` record B1 adds:
  - Its own identity, name, photo, system prompt and automations; later its
    own model budget through a Bifrost or Mothership virtual key on the
    home server.
  - Peel comes with a few to start from: Peel (the general one), a chief of
    staff, and others, each a different prompt.
  - Adding a contact gets two tabs, People and Agents. Agents lists those
    defaults and lets you describe a new one.
  - Probably its own memory each. How is not decided: one graph with a
    space per agent, or one graph each.
- **An agent on the phone, for when the brain is off** (considered, not in
  v1). AgentKit already builds for iOS, and the phone has Tom's chats and
  calendar, so a small local agent could answer "what did Kate say?" with
  the brain asleep. It could not reach memory, jobs, connectors or
  automations, which all live in Strut, and it would split the
  conversation and memory in two. A home server fixes the same problem
  without the split, so H1 is the better spend. Revisit only if a brain
  that sleeps turns out to be common.
- **Sub-identities on one account** (Tom, 2026-10-13). Instead of a derived
  second account, the agent would be an identity under Tom's own root: one
  account, one connection, its own key, maybe its own balance. Read in
  `~/Documents/sphinx` on 2026-10-13, not tried:
  - The mixer already keeps **balances per scid**, and every child index
    gets its own scid (`mixer/src/db/balances.rs:19`,
    `get_scid_for_child_idx`). Today a client uses one; a second could hold
    the agent's budget.
  - It already routes an onion from an account to itself: `sendself`
    (`mixer/src/handler.rs:192-227`), used for async payments, with push
    skipped.
  - Missing: in the core, an identity that is not a contact. A message from
    Tom's root to his own child key reads as "ours" today (#207), so it
    would need to read as inbound to that identity. Every client of the
    account (the official apps too) would also have to know an identity
    from a contact, or show the agent's chat as messages to yourself. Push
    is per root and skipped for self-sends, so the phone would need it back
    for the agent's replies.
  - This is a protocol change for the Sphinx team, not Peel's alone. v1
    uses the derived account, which needs no server change. The `Agent`
    record and the remote protocol do not change either way: only how the
    agent's identity is made, and which engine receives its messages. A
    spike on the local stack (a message from an account to its own second
    scid) would show how far the existing pieces go.
- **Where the brain can live.** The same protocol serves every option, so
  people can choose later:
  - A Mac kept awake: Tom's own, set to stay on. The phone reaches it from
    anywhere, because Sphinx is the transport.
  - A home server: an old Mac or a Mac mini (H1).
  - A cloud brain that Sphinx hosts for people who want neither, such as a
    Swarm's Strut. The agent reads Tom's chats with Tom's words, so this
    needs its own answer on where those keys live. Home first, cloud as an
    offer later.

## Open questions for Tom

1. **The agent's own account.** Agreed that the agent gets a Sphinx identity
   (see "Why its own account, even on an always-on server")? It is the
   decision the rest depends on.
2. **Push.** Tom is checking whether the hub can take a second app. Built as
   if yes; dropped without fuss if no.
3. **One conversation or two?** Should the Mac's own typed agent turns be
   copied into the DM so the phone sees all of it, or stay
   local in v1, as proposed?
4. **The home server.** Is a Mac mini at home the target (stage 2), so that
   brain mode can be planned now instead of after the phone ships?
5. **Order against the hardening.** The bug hunt's "before the team" gates
   (the core upgrade, CI, the belief reviews) and this phase share S1. Should
   I1 and S1 to S4 start now, with B1 onward after the core is upgraded?

## Kept from the earlier notes

- The connection status lives in the Mac window's subtitle; on the phone it
  moves into the Agent and Chats headers (above).
- The official iOS app also registers a PushKit VoIP token for calls
  (`sphinx-ios-v2/sphinx/AppDelegate.swift:351`). Out of scope for v1.
