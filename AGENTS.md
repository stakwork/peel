# Agent Guide

Read `docs/VISION.md` before anything else: Peel's guiding principles and
the experience it must give. Every change serves it.

Peel is a native Sphinx chat client written from scratch in Swift on the shared
Rust core. Read `docs/PLAN.md` next (architecture and phase index), then the
phase you are working on under `docs/phases/`. A phase with work done opens
with a short status (built, open, decided) above its journal; a planned one
is a short plan. Update the status and the journal when you finish something.

## Project layout

- `Sources/PeelCore/` — the client engine, no UI
  - `Engine.swift` — the actor that drives one account: its stored state and
    init, the connection and reconnect loop (with the keep-alive's pings
    and the network watch, `connectionAnswers`), and the core contract (`run`,
    `commit`, `complete`, `receive`, and `commitAndPublish` for every money
    send, whose `.none` alone may mark it failed): runs core calls, commits
    the state they return in one transaction, performs the subscribes and
    publishes they ask for. The rest of the engine is extensions by area. Stored state, helpers
    and nested types the extensions share are internal rather than private,
    so the module, not the file, is the boundary (`seed` among them: never
    read it, or call `run`/`commit`, from outside the engine files). What
    only `Engine.swift` writes keeps `private(set)`, `state` above all: it
    changes only in `init` and `commit`. Session bookkeeping is grouped in
    `TribeWork`, `MoneyWork` and `HistoryCursor`. A `poll` waiting for a
    server reply is woken by each commit (`wakeWaiters`, also called where
    a waited-for flag clears outside one); only a network check polls on
    an interval.
    - `EngineTypes.swift` — `Event`, `Failure` (refusals and their words),
      `ConnectionState`, `Contact`, `Invite`, `JoinRequest` and the other
      public nested types
    - `Engine+Account.swift` — mnemonics, invites, the contact and
      registration helpers, the account's name and photo, mention re-scans,
      settings and server hosts
    - `Engine+AgentAccount.swift` — the agent's own account
      (`docs/agent-on-strut.md`, section 4): `agentAccount(n)`, its seed
      `agent_seed(seed, n)` and what the bridge needs beside it (owner,
      device, broker); never printed, dumped or reflected with its seed
    - `Engine+Contacts.swift` — adding by a scanned or pasted code
      (`addContact(code:)`), removing a contact (`deleteContact`: the
      server's copy, then `forgetContact` in `Engine.swift`), invites with
      sats (`makeInvite`, `cancelInvite`), new contacts seen
    - `Engine+Messages.swift` — contacts, text, deletes, resends (Retry, and
      a reconnect's own of recent sends that move no money, `resendRecent`), discards,
      `deliver` (every message through the core), the `openTribe`,
      `isContact` and `knownTribe` lookups, read markers and mutes
    - `Engine+Payments.swift` — payments, boosts, confirmation thresholds,
      invoices (made, requested, paid), payment history and the
      reconciliation against it (`reconcileInBackground`)
    - `Engine+Attachments.swift` — sending, downloading and buying
      attachments; payment templates (the list, their pictures, the
      token a payment carries); the memes server sign-in
    - `Engine+Calls.swift` — the call server, call links, tickets, presence
    - `Engine+DeviceRequests.swift` — the device side of the device channel
      (`docs/agent-on-strut.md`): the agent contact's requests to this
      device (`Setting.deviceAgent`, off unless set) are stored, acked,
      done once through the handler the host gives
      (`answerDeviceRequests`) and answered with a `result`; a repeat gets
      the stored answer; anyone else's, or one for another device, gets
      nothing. Answered after the commit that stored them, and again once
      online for those a stop cut short (`answerOwedDeviceRequests`). A
      send (`sendText(for:)`) is marked `sending`, with its uuid, in the
      commit that stores its message, so it goes at most once; one cut
      short there, or whose publish failed, answers `unknown`
    - `Engine+Tribes.swift` — join, leave, create, edit, members, approvals,
      a tribe's details, how you appear in one, the tribes registry and its
      background refresh
    - `Engine+Preferences.swift` — `set`, every change to a user setting
      through `Preferences`; the sync with the official apps' encrypted
      `/preferences` file (`syncPreferences`, one at a time; on connect, 2 s
      after a change, `refreshPreferences` when the app comes to the
      front), `.preferencesChanged`
    - `Engine+History.swift` — restore and catch-up: asks for the pages
      `HistoryCursor` names, `resumeHistory` (the one way history picks up
      again: on coming online and from Resume after a stall),
      the stall watchdog, a page the core refuses
      whole read again without what it cannot read (`readablePart`, found
      by halves in `readable`), recovering the account's own photo
    - `HistoryCursor.swift` — the history machine without the network: the
      run in flight, the queue, a restore's plan, paging and stalls, and
      where history stands, every message below it handled by a page or
      live (`from`, kept as `Setting.historyFrom`), where every catch-up
      starts (tested)
  - `Account.swift` — load, signup, create and restore: the one place that
    decides where the mnemonic, the server and the tribes host come from
  - `Storage.swift` — SQLite via GRDB for one profile: init, the profile lock,
    core state and settings
  - `Models.swift` — the public value types Storage returns: `Setting`,
    `Conversation`, `MuteLevel`, `ChatReadState`, `Timeline`, `BoostSummary`,
    `ThreadSummary`, `ChatThread`
  - `ChatSections.swift` — the sidebar's chats in order: Unread (direct
    messages, then tribes that mention you, then other tribes), the five
    most recent tribes and direct messages with "Show all", the open chat
    always shown, the search, and the next unread chat (tested)
  - `ListBottom.swift` — a message list against its bottom, for its jump
    button's "N new messages": what counts as seen at the bottom and when
    the list leaves it, crossings judged against the last one taken (tested)
  - `MentionQuery.swift` — the `@word` before a composer's cursor (or a
    `/` command opening the agent DM's message) and what it matches, by
    any of an item's names, for the Mac's composer and the iPhone's (tested)
  - `Storage+Reads.swift` — reads and live queries: conversations, read
    states and the unread messages behind them, tribes and their senders,
    mentions, payments, the shared SQL
    (`tribeChats`, `chatsSQL`, `countsAsUnreadSQL`)
  - `Storage+Threads.swift` — replies and threads: `timeline(in:)` (tribe
    threads collapsed), `thread(_:in:)`, `threads()`, `threads(in:limit:)`
    (one chat's, whoever wrote), parents, boosts and
    thread summaries
  - `Storage+Dictation.swift` — Dictation History on the Mac
    (`DictationRecord`, `dictation`, v28): kept with a keep time that
    drops older ones, watched newest first, cleared. Tested in
    `DictationHistoryTests`
  - `Storage+DeviceRequests.swift` — the device requests' ledger
    (`deviceRequest`, a request's id within its agent): `admit` (the
    stored row wins; a message seen before is not a new copy), `claim` and
    `finish` (only one run does it; a send's `sending` mark is in
    `Storage.apply`), the owed ones, forgetting expired ones
  - `Storage+Writes.swift` — writes: `Commit` and `apply` (one core call's
    changes in one transaction), message upsert and deletes, read markers,
    mutes, send status, invoices, uploads, contacts and tribes
  - `Storage+Search.swift` — message search over the `messageText`
    FTS5 index (v19): `MessageQuery` (words, "phrases", `from:`, the
    only FTS5 syntax built), `searchMessages` (one chat or all), snippets
  - `Storage+Migrations.swift` — the schema migrations: append-only, never edit a
    shipped one, literal values only (no live `MessageType` or `Tribe.Status`)
  - `Message.swift` — `Message` (one stored message, the core's sender and
    body JSON kept whole), `MessageType` and the fields read from a body
  - `Invoice.swift` — `Invoice` (an invoice as the core reads it) and the
    money tables' records, `InvoiceRecord` and `PaymentRecord`
  - `PaymentHistory.swift` — `PaymentItem`, `PaymentRequest`,
    `PurchaseState` and the Storage reads that join the money tables
  - `Sats.swift` — amounts as people see and type them (display and input
    only; money is kept in msat): `format` drops the rest of a sat as the
    official apps do, `exact` keeps it for a tribe's prices
  - `PeelError.swift` — `PeelError`, a failure worded for the person:
    `readable` (an error's words, mid-sentence) and `problem` (the one
    way the app shows a failure, as a sentence, after "Could not …"
    when needed; tested)
  - `Tribe.swift` — tribe records, tribe links, the tribes server's
    registry, and `TribePrice`: what a member pays to join or per message
    (the amount the engine sends, and why it is more than the owner's
    price), the only price shown to someone who will pay it; `Tribe.exit`
    (leave, remove from Peel, or neither) and `Tribe.pages` (its app and
    second brain, in their one order)
  - `NotificationPolicy.swift` — what notifies (messages, payment
    requests, announced calls, join requests to owned tribes) and the one
    "quiet here" rule (the chat in view, its mute level) that messages,
    calls, money and new contacts share
  - `PersonHue.swift` — a person's colour (direction D): the official apps'
    colour key and its hue, FNV-1a mod 8
  - `Call.swift` — `CallLink`: reads and validates call links against the
    account's call server, and makes new rooms (phase 6); `WatchedCall`,
    the recent calls across chats whose presence the app keeps, and their
    live query (`Storage.recentCallMessages`, beside them as
    `PaymentHistory.swift` keeps its own)
  - `CallServer.swift` — the call server: `CallTicket` (`GET
    /api/connection-details`, the media server allowlist, the token's claims;
    never stored or logged) and the `/ws` presence feed (`CallPresence`), one
    per engine
  - `Media.swift` — what an attachment is: `AttachmentKind` (by its bytes),
    `OutgoingFile`, media tokens, `AttachmentFields`, `DownloadedAttachment`,
    `MediaInfo` (a cached video's or recording's duration, picture size and
    poster frame, read in place with the container type from its bytes)
  - `MediaCrypto.swift` — the official apps' attachment encryption
    (RNCryptor v3)
  - `MemesServer.swift` — the memes server: sign-in, upload, download,
    payment templates (`/templates`, `/template/<muid>`), `Web.Transfer`'s
    failures in its own words
  - `PaymentTemplate.swift` — a payment template, the server's list of
    them, the token a type 5 carries for one (the official apps' format)
    and `Message.paymentTemplateMUID`
  - `MediaStore.swift` — the profile's `media/` cache and outbox
  - `Contacts.swift` — `ContactCode` (what a scanned or pasted code is:
    contact info, a `share_contact` link, an invite, a tribe link; strict),
    `MessageLink` (the first tribe or contact link in a message's text, for
    its card) and `InviteRecord` (invites made here; the core keeps none)
  - `QRImage.swift` — QR codes in a picture (Vision), size- and
    pixel-limited
  - `Giphy.swift` — a received GIF from Giphy (`giphy::` and base64 JSON,
    as `GiphyHelper` reads it), Giphy's media hosts (the only ones fetched
    for one) and the fetch
  - `Files.swift` — `ImageDecoding` (with `animation`: every frame of a GIF
    and its delay, as `AnimationFrames`), `ProfilePhoto`, `TooLarge` (bytes over
    a limit, local or downloaded) and `UserFiles` (files saved for the
    person, quarantined; `saveToDownloads` off the caller's actor)
  - `IncomingFiles.swift` — attachments that arrive by drag or paste: which
    pasteboard items attach, image bytes and promised files written to Peel's
    own temp folder and checked
  - `MessageMarkup.swift` — how message text reads: paragraphs, list and
    numbered items, headings, quotes, fenced code, and inline code, https
    and `[text](url)` links, mentions and emphasis; `plainText`, the one
    line that previews show
  - `TimeZones.swift` — time zones: the offset in a message's `metadata`
    (sent unless the chat's switch is off, never to a public tribe; read
    with Peel's own parser), the per-chat switch (a `timezone`
    preference), `localTime(of:)`
  - `ControlEnvelope.swift` — the device channel's control messages
    (`docs/agent-on-strut.md`): `MessageMetadata` (a body's metadata
    string, read bounded, and keys set beside each other, `tz` among them),
    `ControlEnvelope` (`metadata.peel`), `ControlMessage.read` and
    `Message.control`, which take an unknown version, `op` or field shape
    for `unsupported`, never a guess; `Message.agentTools` (a reply's tool
    rows, `metadata.peel.tools`, as `AgentToolLine`), `Message.agentJob`
    and `agentArtifacts` (a job's message: `metadata.peel.job`, `AgentJob`,
    and what it points to, `AgentArtifact`: an https link, or the handle
    the bridge adds, `AgentArtifact.Handle`, a file strut serves or an app,
    only in those shapes, with strut's peer id and app name rules that
    `Hive` and `WorkspaceApp` use too) and `AgentDM` (your
    message the agent is still answering in its DM)
  - `Preferences.swift` — the one owner of every user setting: the
    registry (`Preference`: the preferences file's key, account or device
    scope, the official encoding), `JSONValue`, the official reader's
    rewrite rules (`isOfficialFixedPoint`), the `preference` table's
    reads and dated writes (phase 11)
  - `PreferencesFile.swift` — the preferences file without the network:
    read as the official apps read it (refused whole if they could not),
    the merge per item by date, everything else copied through untouched,
    and the conditional apply
  - `Transport.swift` — one MQTT connection (mqtt-nio); `ServerAddress`;
    in debug builds `init(publishing:)`, the tests' broker that answers
    pings, takes every connect and subscribe, and takes or refuses each
    write (`Engine.connectingForTesting` puts it under a connect)
  - `StateCodec.swift` — the MessagePack shape the core uses for its state,
    and a history page's onions (`onions`, `batch` to frame some again)
    with each one's index and, for a payment, what really arrived
    (`paymentAmounts`)
  - `JSON.swift` — `JSON.decode`, the one way a JSON string (a body, a
    sender, a core reply) is read into a type; `JWT.payload` (a token's
    claims, unchecked), `.hex` for bytes and `Date(iso8601:)`, the one
    reader of strut's and Hive's dates
  - `Hive.swift` — Hive's device flow (the person knows it as Stadeum),
    for the Mac and the iPhone alike (`HiveClient`: start, poll, `answer`
    (polled until the person answers), renew), what is kept of a pairing
    (`HiveLink`, its peers and credential, never in a database; `HivePeer`,
    one org's strut and the person's token for it), and the Hive a profile
    pairs with (`HiveClient(for:)`: a development profile's `-hiveURL`)
  - `WorkspaceApps.swift` — `WorkspaceApp`, an app a Stadeum workspace
    pinned as a tab or one of the person's own: read from strut's `GET
    /apps` (`listing`, `init(peer:entry:)`), on a workspace's own strut
    with the person's token for the iPhone (`pinned(on:)`), and A–Z
    (`byTitle`); its words for the person are PeelUI's
  - `OrgPage.swift` — a deliverable from the agent's DM on its org's own
    strut, as the iPhone opens it (`AgentArtifact.Handle.onOrg`: the brain's
    `/peers/<org>` hop taken off; none for the brain's own), and
    `StrutUI.page`, the one address of strut's UI showing one thing alone
    (`?artifact=` or `?app=`, `&solo=1`, the UI's folder with its `/`), with
    strut's key in it only for Peel's own strut
  - `TextLine.swift` — `TextLine.clean`, words someone else wrote as one
    safe line (control and direction characters out, no `<<<` marker,
    capped): the one cleaner the agent's chat data, Stadeum and strut's
    listings share
  - `BiometricUnlock.swift` — Face ID in place of the PIN, opt-in: the
    PIN kept in a Keychain item behind `.biometryCurrentSet` (this device,
    a passcode set), released by a face and then used as a typed PIN;
    removed when it is unreadable or wrong, followed by Change PIN, gone
    with the profile (`Profile.biometrics`; tested with a fake keeper)
  - `Profile.swift`, `SecretStore.swift` — a local account: `.app` profiles keep
    the words in the data-protection Keychain sealed under a six-digit PIN
    (moved there from the login Keychain on first unlock), `.development`
    profiles in a plain file with no PIN (CLI only); `KeychainItem` (one
    data-protection Keychain item, which the words and the agent's key
    share; readable only while the Mac is unlocked but for the agent's key,
    `AfterFirstUnlockThisDeviceOnly` for runs on a locked Mac; an item
    moves to its class on the next read or write, a failed move logged
    once; a locked read is `KeychainLocked`, never none kept) and `FileItem` (an owner-only file)
    behind `SecretItem`; the
    profile's `agentCredential` (the agent's provider, model and API key),
    `strutKey` (its strut's `STRUT_SECRET_KEY`: Keychain `dev.peel.strut`,
    or `strut-key` on a development profile; gone with the profile),
    `brain` (where Peel Home is, `Brain`: Keychain
    `dev.peel.brain`, or `brain` on a development profile) and
    `agentDatabase` (`agent.sqlite`)
  - `ServerConfig.swift` — the public config endpoint a restore reads
  - `Web.swift` — every request outside the memes server (photos, the tribes
    registry, the config): ephemeral sessions (also the memes server's), the
    size-limited `Transfer` (also the memes and call servers') and its
    neutral `Failure`, `get`, the public-https host check (`isPublic`) and
    "public https, or http to this machine" (`isAllowed`, `isThisMac`);
    `postToStrut` and `requestStrut`, a request with an optional bearer
    key to a strut only (`isStrut`: http to this Mac, https anywhere),
    following no redirect, through the system's proxy only over https
    (Peel's own strut, or a Stadeum workspace's)
  - `WebPage.swift` — what the app's web pane may open
    (`WebPage.address`), what an address typed into it opens
    (`WebPage.typed`: http or https, or a search), which attachments it
    shows as pages (`WebPage.isHTML`) and each profile's website data
    store identifier
- `Sources/PeelUI/` — the app's model, shared by the Mac and the iPhone
  (phase 7, batch 17): PeelCore and AgentKit, SwiftUI and Observation, no
  AppKit, UIKit, LiveKit or PeelAgent; builds for the iOS Simulator
  (`xcodebuild -scheme PeelUI -destination 'generic/platform=iOS Simulator'`,
  after `scripts/build-ffi.sh` with the iOS slices). Public, for the apps.
  `AppModel` (with `agentContact`, `agentChat`, `agentDestination` and
  `agentUnanswered`: the agent's DM as the agent's one row while the strut
  preview runs, where `.agent` opens, its rows `ChatRow.rows(agentDM:)`),
  with its extensions by area in `AppModel+Chat` (replies,
  threads, sending, attachments, and the chat's small types: `ComposerID`,
  `ThreadRef`, `AttachmentHandle`, `ListAnchor`), `AppModel+Calls` (a call's
  avatars and its chat's title), `AppModel+Payments` (`PaymentOutcome`, boosts,
  sends, history, invoices and `invoiceBlocker`, buying an attachment),
  `AppModel+Biometrics` (Face ID: on, off, unlock and the words), `AppModel+Contacts`
  (adding by code, invites, removing a contact, since when), `AppModel+TimeZones` (sender zones, local
  times, the zone setting, sharing it per chat) and `AppModel+Search` (`ChatSearch`, ⌘F's
  matches, stepping through them with `focus(on:inThread:)`);
  `Stadeum` (`AppModel.stadeum`, the Mac's and the iPhone's one Stadeum
  pairing: open with the account (renewed at once on the Mac, when due on
  the iPhone), Connect (Hive's device flow), renew hourly and when due,
  the revoke rule (orgs kept and listed, none `live`, kept with the link
  as `HiveLink.revokedAt` so an unlock or a restart does not use them
  again, no renewal tried), close, Disconnect; the apps listed,
  `readApps` (the Mac through its strut, the iPhone on each org's own;
  `readingApps`, `unreadApps`); `source`, `caption` and `matches`, an
  app's words for the person; `opening`, how a deliverable or a workspace's
  app opens on its org's own strut; `StadeumHost`, what a device does
  beyond it (the Mac's `MacStadeumHost`); and `OrgPageRequest`, such a page
  with its token: its origin and folder, the token's hand-over script and
  the first request, never described with the token);
  `CallStore` (`AppModel.calls`: presence by room, the counts per chat,
  the recent calls across chats watched while unlocked and the open chat's,
  the call you are on, join, start, leave; the view passes the call
  window's opening in; `AppModel` attaches it with the account, says when
  it locks and hands it the open chat's rows and its chats' notices);
  `Platform` (what the app supplies at init: `AppPresence` (in front,
  activate, the badge, notification settings), `MenuHosting` (for
  `takesCommands`), `FilePicking`, `Pasteboard`, `Playback`,
  `WebPresenting`, `CallProvider` and `OngoingCall`, and `AgentHost`, the
  agent's PeelAgent side); `ChatRow` (`Sender`, `Quote`, the rows built
  once per change); `PaymentAttempt`; `PaymentPaging` (Payments' limit and
  whether the server has more); `PaymentItem+Display`; `Formatting`
  (counts and their nouns, times and dates, offsets); `Labels` (a chat's
  title, Leave and Remove's words, a tribe's membership notes, a refused
  PIN's words and a PIN field's digits, Forget's warning, an invite's
  status, a tribe's details lines and price to join, what a contact code
  adds); `TribeForms` (`TribeSettingsDraft`, Create and Edit tribe's
  fields and their problems; `TribeLookup`, Join a tribe's link and
  lookup; `TribeIdentityDraft`, how you appear in a tribe; `TimeZoneSharingSwitch`, a chat's time zone switch; the Mac's forms and the phone's share them); `WordCheck` (three of the twelve words asked back, and `WordBoxes`, the twelve boxes a paste spreads into); `MoneyArrivals` (`Receipt`, the
  balance's roll, what Payments has not shown); `Notifier` (local
  notifications by PeelCore's `NotificationPolicy`, the badge through
  `AppPresence`); `ImageCaches` (`ImageCache`, bounded: attachments, and
  photos apart, and `animations`: GIFs' frames and sizes, Giphy's bytes;
  `MediaInfoCache`; `tileSide`, the chat's image size); `TimelineLog` (the
  opt-in log of the message list's placement, `defaults write dev.peel.mac
  PeelTimelineLog -bool YES`; `docs/testing.md`, "Timeline log");
  `CopyFeedback` (the hold, the animations and VoiceOver's "Copied");
  `ChatList/`, where a message list goes on any engine:
  `ChatListController` (the anchor, the following latch, "New messages",
  the pill over `ListBottom`, jumps, older pages and where a list opens,
  T1–T27 of `docs/reviews/2026-10-14-message-lists.md`; no SwiftUI, AppKit
  or UIKit) and `ChatListTypes` (`ChatListRow`, `ListContent`,
  `ListPlacement`, `ListViewport`, `ListDiff`, `ListPill`, and the
  `ChatListEngine` and `ListAnchorStore` protocols it takes; `AppModel` is
  the store)
- `Apps/Mac/Peel/` — the SwiftUI Mac app over `PeelUI` (the target "Peel macOS" of `Apps/Peel.xcodeproj`, see `Apps/`): `MacPlatform`
  (`Platform.mac()`: `MacPresence`, `LiveKitCalls`, and
  `MenuPresenter`, `MediaPlayback`, `WebPane` and `CallSession` conforming;
  `CallStore.session` and `AppModel.web`, the Mac's own types), `AppModel+Agent`
  (`MacAgent`, the `AgentHost` that holds the memory, Peel's strut and the
  automations, which `AppModel` reaches as `macAgent`; opening the
  account's `AgentSession` (the connected model, the name, the rules and
  the earlier local chat), the key kept through `Profile.agentCredential` and
  handed to strut (`modelChanged`), the earlier tool rows' titles, and the
  memory once its strut is running: Peel's
  own (`BundledStrut`), started with the agent and started again by Set
  up or Try again if it stopped; a development profile's only with `-strut YES`,
  its data in the profile's folder (`BundledStrut.dataFolder(for:)`): an
  experiment, `docs/agent-brain.md`; none while Peel Home has moved to a
  home server (`Brain.moved`, `AppModel+Home`), whose `peel://home-setup`
  links `openPeelLink` takes from `AppDelegate`),
  `AppModel+Connections` and `ConnectionsSection` (Account › Connections:
  Add MCP server, Test, Remove, the Assistant and Jobs switches, which
  restart Peel's strut with the new grants; below them
  `StadeumSection`, the Stadeum workspaces paired as peers),
  `AppModel+Automations` and `AppModel+Bridge` (`AgentBridge`: the
  agent's bridge beside Peel's own strut, in every build; `agentSetUp`,
  what the agent chat and Account › Assistant show of its own account,
  and `setUpAgent`, the person's Set up or Try again, the only start that
  pays to pair it, `BundledBridge.setUp`; and the agent chat as its DM:
  `agentAnswering`, `agentWaiting`, Stop's `cancel` in `stopAgentTurn`),
  `AppModel+Hive` (`MacStadeumHost`, the Mac's side of PeelUI's
  `Stadeum` (the user-facing name of Hive): the orgs put on strut as
  peers and their tokens handed to the bridge when they change, strut
  started again for another person, the workspaces' "Always allow" rules,
  Pair again after a revoke, Unpair; and the apps, the person's own on
  Peel's strut and those the workspaces pinned read through it,
  `refreshApps`, `appSources`; the person's pins under the
  sidebar's Apps row, `isPinned`, `setPinned`: none until the person
  pins one, `ChatSections.Layout.pinnedApps`), `AppsView` (the sidebar's Apps row: every listed app
  as a card, A–Z, its icon, version and status (`AppStatus`), with a
  search and the source to show, Yours or a workspace;
  `docs/apps-browser.md`), `WorkspaceAppView` (one of
  those apps alone in the detail column, opened from Apps or its pinned
  row: Peel's own strut's UI showing its page, in a `WKWebView` whose store
  keeps nothing and which goes nowhere but that strut, and `AppPinButton`,
  its pin in the header and on its card; `docs/agent-on-strut.md`, "Built:
  a workspace's apps"), `StrutPage` (a page of Peel's own strut's UI shown
  alone with strut's key in its address, and the rules the app view and the
  web pane's deliverable both keep to: only that strut, its `srcdoc` and
  blob frames, a link out only on the person's own click, which
  `InputWebView` knows of; "Built: a deliverable opens beside the chat");
  `ChatSearch` (⌘F: the search bar under a chat's header and its results
  list, its header button, the highlight in message text);
  `FilePanels` (`FilePicking`: the open and save panels and Show in Finder, the only
  callers of `NSOpenPanel`, `NSSavePanel` and the Finder reveal), `MainView` (the
  shell, `PaneDivider`, `Detail`), `Sidebar` (the rows at its top A–Z, Apps with the pinned apps under it, then the Unread, Tribes and Direct messages sections over `ChatSections`, rows, header, connection bolt (one status row and a check/reconnect action), arrow keys and Return while it has focus, `RestoreBar` at its foot (a restore's progress, or history paused and Resume),
  and `ConversationMenu`, whose pieces the chat header's More shares), `SidebarForms` (join a tribe), `ContactsViews` (add
  a contact by code or QR picture, invites with sats, the sidebar's pending
  invites and "New" contacts),
  `Avatar` (people's and tribes' icons, `InviteIcon`, `AppIcon`),
  `AnimatedPicture` (a GIF played by Core Animation, paused off the screen; `.gifPlayback`, Reduce Motion's play button over a tile), `Styles` (the `…Boxed` helpers and `.muted()`, the muted line), `Clipboard` (with `ClipboardPasteboard`, the model's `Pasteboard` on the Mac and the iPhone),
  `ConversationView` (with the tribe header and
  `HeaderMoreButton`, the chat header's More), `TribeViews`, `TribeDetails` (a tribe's details, `TagChips`, how you appear in a tribe), `OnboardingView`, `LockView`, `AccountView` (Account's categories, `AppModel.AccountPage`, one page each; `AccountCategories` stands in the chats' place, in `Sidebar`'s `SidebarColumn`, while it is open, under the sidebar's search, which then searches them);
  for the chat: `MessageViews` (`MessageList` with its pill and Page
  keys, `ListRowContent`, the rows), `MessageTable` (the Mac's list
  engine for the chat, a thread and the agent chat, over any `TableRow`: a non-flipped `NSTableView` of reused hosting
  cells, heights cached per row, width and version, the controller's
  placement applied in the same pass, idle measuring, its own animated
  moves), `ListProbe` (the frame probe
  over each list's `ListGeometry`), `MessageText` (message text over
  `MessageMarkup`: `MessageText`, `LinkText` and the search highlight;
  plain SwiftUI that the iPhone compiles too, its size a parameter, 14
  here), `LinkCards` (the tribe and contact link
  cards under a message, through the Join and Add forms), `ThreadViews`, `AttachmentViews`,
  `PaidAttachmentViews` (buying and pricing a paid attachment), `ComposerView`,
  `ComposerField` (the message field: Return sends, `@` mentions; in the
  agent's DM `@` offers the Stadeum workspaces and `/` its commands),
  `ImageViewer` (images, and videos full size), `MediaViews` (the video
  tile, the audio card, `PlayerSurface` over AVKit's player view and
  `MediaPlayback`, the one player at a time), `PasteboardFiles` (drop and paste into the tray), `PaymentViews` (paying: `PayButton`, send sats with `TemplatePicker`, and `TemplateImage`, a payment template's picture; the Account's boost and confirmation rows, `presets`), `PaymentChatRows` (boosts, payment rows and requests in a chat), the Payments screen (`PaymentsView`, with `PaymentRows` for the list and a payment's detail, `ReceivePane`, `PayInvoicePane`, and the shared `PaymentPanes`), `QRCode` (the tile, the code, copying it as an image), and `PeelMenu`, the one menu used instead of native ones (entries, the
  view modifiers with `.menuAnchor` and its `MenuAnchor`, `KeyMonitor` with the written Escape order and `KeyCode`, the named key codes, `RightClickCatcher`, `WindowReader`), with
  `MenuPresenter` (the presenter and the menu's own views, `MenuPanel` and
  `MenuRow`), `Controls` (`MenuButton`, `PeelDropdown`,
  `.hiddenShortcut`, `SettingDropdown`, and the forms' `ProblemText` and `FormFooter`) and `FloatingWindow` (the borderless window menus and panels open in);
  `CopyButton` (`CopyButton`, `CopyLabel` and the menu's "Copied" pill, for every copy, over `CopyFeedback`);
  the agent chat: `AgentViews` (`PeelLogo`, the sidebar's
  `AgentLink`, `AgentChatView` with Peel's first message and its Connect
  card, its list and pill, the turn rows, tool rows (an acting tool's outcome and View) and
  the failure row, `AgentApprovalCard` (a send waiting on you, where its
  row will be; the agent's device requests draw it too), `AgentConnectButton`),
  `DeviceCards` (the cards for the agent's `send` and `approve` device
  requests, each on its request's line in the agent's DM via
  `DeviceRequestLine` and `ChatRow.approval`; in any DM a request's
  one row, `ChatRow.agentRequest`, which opens to what it read or did,
  `DeviceRequestDetail`; and the send grants), `AgentTable` (the agent chat's
  rows for `MessageTable`, `AgentListRow`, `AgentDMRows` (the agent's DM
  as the chat draws it: its rows as a chat's with tool rows above a reply,
  "writing…", the earlier local turns above under "Old assistant chats (this Mac only)", read
  only) and `AgentOpenRows`, which tool rows are open), `OffscreenAgent` (the
  offscreen driver's agent: an earlier chat in memory for the list journeys),
  `AgentMemoryViews` (an earlier memory
  tool's opened row in sentences, and `MemoryPanelView`, one memory beside
  the chat; its state `MemoryPanel` in `AppModel+Agent`), `AgentConnectPanel` (provider, key
  and model, kept and handed to strut) and `AgentSettings` (Account › Assistant, with
  the "Always allowed" rules and Revoke, and the send grants ("May post
  as you") and Revoke; Account › Peel Home, `BrainSection`:
  where Peel Home is, its move out and back, and a link waiting for a yes);
  `CallViews` (the call card, the header's call button and presence
  watching, the in-place switch confirm, the sidebar's on-a-call bar),
  `CallSession` (the call you are on: the LiveKit room, microphone, camera
  and devices), `CallWindow` (the grid, the focus layout with its strip,
  keep on top, the recording indicator and the control bar) and `CallScreenShare` (the system picker,
  the capture into a LiveKit buffer track, Peel's windows left out of display
  shares);
  `UI/`, the component library over `Theme` and its tokens (`Theme.Radius`, `Space`, `AvatarSize`; `docs/design/README.md`,
  "Component library"): `PeelButton`, shadcn's button (variants primary,
  secondary, outline, ghost, destructive, link; sizes sm, md, lg, and
  `touch`, the iPhone's 44 pt one that grows with Dynamic Type;
  `.buttonStyle(.peel(...))`; every text button but the small ones inside
  rows), with `buttonProgress`, the spinner inside a running button;
  `IconButton`, shadcn's icon button (ghost or outline, 28 or 24 square,
  `lit`, `working`; every icon button but the call window's control bar,
  controls over media and the composer's);
  `Panel`, shadcn's card in a popover (title, actions top right, close,
  body, footer; 372 or 320 `compact`; the only box a popover has; every
  popover), and `PanelHero`, the top of a details panel;
  `Section` (`SectionHeader`, every heading over a group but the
  sidebar's) and `Card` (`Card`, raised or inset, every card and the
  boxes in a chat; `Callout`, shadcn's alert: a chat's and the window's
  notices, a tribe you cannot post in, an amber note, a download, the
  words reminder);
  `Badge` (`Badge`, a word or count in a capsule: unread counts, gold
  when it mentions you, orange `.attention` for waiting on you, "New",
  Payments' "+350", the day divider; `AgentTag`, AGENT beside an
  agent's name; `Chip`, a tag on and off, and a message's boosts);
  `Rows` (`ListRow`, shadcn's item: hover and the one selected fill,
  `Theme.selection`; search results, time zones, members, boosters,
  Payments' rows, mentions; `FactList` and `Fact`, a description list on
  a card: tribe details, a payment, an invoice, the Account's sections);
  `EmptyState` (shadcn's empty: the words a screen, pane or list shows
  with nothing in it, an optional title and actions: the start screen,
  Threads, Mentions, Payments, the web pane's failed page; `.sm` in a
  panel's list: no time zone matches);
  `FormKit` (the form system, shadcn's conventions: `FormSection`,
  `FormItem`, `FormTextField`, `FormNumberField`, `FormSwitchRow`,
  `FormDestructiveSection`, `FieldChrome`,
  `endsEditingOnClick` and `InlineConfirm`, the one in-place confirm, over
  the form tokens in `Theme`, its buttons `PeelButton`; used by every form, see `docs/design/README.md`, "Forms");
  `PictureField` (a picture picked or dropped, uploaded, never typed: the
  Account's photo, a tribe's image, your photo in a tribe);
  `TimeZoneViews` (the run header's "14:05 local", the DM header's local
  time, the hover card, a chat's details panel with the time zone switch,
  and for a contact their key, its QR code and Remove);
  `WebPane` (the web pane beside the chat: one `WKWebView` on the profile's
  own data store, its toolbar and address field, the routing of http and
  https links, Browser and a tribe's pages as More menu items, and
  `WebPane.open(_ page:)`, the one way a tribe's page opens; and, besides a
  page of the web and an HTML attachment, a deliverable from the agent's DM,
  `open(_:)` with a `StrutPage`: a web view of its own whose store keeps
  nothing, its name in the address field and never its address);
  `NotificationOffer` (the bar offering notifications);
  `Dictation/` (system-wide dictation, milestone 0, `docs/dictation.md`:
  `DictationController` the glue, `DictationHotkeyTap` the CGEventTap on
  its own thread, `DictationAudioCapture`, `DictationHUD`,
  `DictationTextInserter` (the focused element, Accessibility or ⌘V with
  the clipboard put back), `DictationSpeech` (speech-to-text on the open
  account's own strut, told of it by `AppModel.strutChanged`, and its
  model; `StrutTranscriber`), `DictationLingo` (a thin client of strut's
  dictation vocabulary, stakwork/strut#301: the lexicon for the window,
  `dictation/correction`, `add`, `remove`, `undo`; strut does the judging),
  `DictationEditWatch` (rereads the field after typing for the user's
  correction, sent once it settles: `DictationEdit`, PeelUI),
  `DictationModels` (the speech model and fixer picked on strut,
  `dictation/models`, `use`, `remove-model`, read every second while one
  downloads), `DictationVocabularyView` (the Vocabulary window),
  `DictationHistoryView` (the History window:
  each dictation by day, with Copy and Clear History),
  `DictationPermissions`, and the Account section (with the Speech model
  and Fixer pickers), offer and menu item in `DictationSettingsView`; its pure parts are in `Sources/PeelUI/Dictation/`);
  `MoneyArrivalViews` for sats received (`BalanceLabel`, the header's
  count-up; `PaymentsLink`, the Payments row's "+350"; the bolt's glow);
  `CallTestRoom`, the development-only LiveKit
  test room (phase 6, PR 3); `Offscreen` (the `-offscreen` check mode) and
  `OffscreenDriver` (its `-drive` script), see "Checking the app". The Mac app is the only target that links LiveKit
  and WebRTC)
- `Apps/` — the two apps and what they share, in one Xcode project,
  `Apps/Peel.xcodeproj` (hand-written; targets "Peel macOS" and "Peel iOS",
  schemes of the same names, over the package's libraries through a local
  package reference to the repo root, plus LiveKit for the Mac only. Its
  `Package.resolved`, under `project.xcworkspace/xcshareddata/swiftpm`, is
  a copy of the root's with LiveKit's pins added; copy again when the
  pins move). Both apps are `com.sphinx.peel`; `Config/Peel.xcconfig` holds
  that, the version and build number and the team, and an ignored
  `Config/Local.xcconfig` (see `Local.xcconfig.example`) puts your own
  team and bundle ID over them. `Assets/AppIcon.icon` is the icon Xcode
  compiles for both apps (edit it in Icon Composer); `Assets/peel.svg` is the
  flat logo for docs and pages. `Shared/` holds the files both apps
  compile: `Theme`, `Avatar`, `Clipboard`, `CopyButton`, `MessageText`,
  `QRCode` and `UI/`'s `Badge`, `Card`, `IconButton`, `PeelButton`,
  `RecordingIndicator` (the "this call is being recorded" dot and toast; its words are PeelUI's `RecordingNotice`) and
  `PaymentKit` (`SignedAmount`, `BigAmount`, `UntilExpiry`, `presets`) and
  `WorkspaceAppIcon` (an app's lucide icon as an SF Symbol);
  they must build for AppKit and UIKit. `Mac/` is the Mac app (below, as
  `Apps/Mac/Peel/`, a synchronized folder), `Mac/Peel.entitlements` (the
  Keychain access group, microphone and camera) and `Mac/Info.plist` (the
  `peel:` link). `Apps/iOS/Peel/` is the iPhone app (phase 7, I2; iOS 26, iPhone
  only), a synchronized folder (every file in it is in the target):
  `PeelPhoneApp` (the app, `RootView` by phase),
  `MainTabs` (the tab shell: Chats, Payments with its "+350" badge, You
  with your photo as its icon, and the system's search tab; Search),
  `PhoneRouter` (`PhoneTab`, `ChatsRoute`, `PaymentsRoute`, `YouRoute`:
  the selected tab and each tab's path, the org page over them (`orgPage`),
  `openChat`, `open(_ message:)`,
  `openThread`, `openDetails` (a chat's details over it), `openMembers`,
  `openPayment`, `openFromNotification`, the thread sheet's
  binding; it writes `AppModel.destination` from what is on screen and
  follows it when the model moves it), `PhoneTheme` (`PhoneFont`, the
  Mac's sizes on Dynamic Type styles, `.phoneFont`; `Surface` and
  `Theme.quietText(on:)`, the grey for a raised surface; the gutter and
  touch target; `.phoneList` and `.phoneRows`, Peel's surfaces under every
  list and its rows), `Glass` (`GlassCapsule`, `GlassCapsuleButton`,
  `GlassButton`, `.floatingBar`, `.scrollEdges`: Liquid Glass on chrome
  only), `PhoneComponents` (`CountBadge`, `PhoneSectionHeader`, `NavRow`,
  `ChatListRow`, `PhoneCard`), `PhonePlatform` (`Platform.phone()`:
  `UIApplication` presence and badge, `Clipboard`; files, playback and the
  web pane do nothing and are never offered; the web pane and calls throw
  their words), `Stadeum` (`StadeumSection`, You's Stadeum over
  `AppModel.stadeum`: connect, the workspaces, Connect again, Disconnect;
  `readWorkspaceApps`, each org's pinned apps on its own strut), `AppsScreen`
  (Chats' Apps row: the workspaces' pinned apps, A–Z, opened in
  `OrgPageSheet`, pulled to read again), `OrgPageSheet` (a
  deliverable or an app on its org's own strut, strut's UI showing it alone in a
  `WKWebView` whose store keeps nothing, over PeelUI's `OrgPageRequest`: the person's token as the first
  request's bearer and handed to the page's storage before its script
  runs, never in an address; only that strut's UI folder, its `srcdoc` and blob
  frames, a link out only from strut's own page on the person's own tap, `TouchWebView`; strut's
  specs/DESKTOP.md, "A device with no strut of its own"), `PhoneControls` (`StepPage`, `PinBoxes`, `NumberedWords`,
  `WordEntry`, `WordCheckBoxes`, the button styles),
  `LockScreen` (with `ForgetAccount`), `PinPad` (the keypad, `PinDots`,
  `PinPrompt`: every PIN asked for after onboarding), `PaymentsTab`
  (`BalanceHeader`, `PaymentRow`), `PaymentDetail` (`FactRow`),
  `SendSheet` (an invoice pasted or scanned, or a contact),
  `ReceiveSheet`, `InvoiceScanner` (`CodeScanner`, VisionKit, QR only), `PayControls`
  (`TouchPayButton`, the touch-safe confirm; `SatsInput`, `NoteInput`,
  `FieldLabel`, `BalanceLine`, `SheetPage`), `Onboarding` (invite or restore,
  pushed steps, `RestoreProgress`), `ChatsTab` (the top rows, Apps among
  them once Stadeum is connected, then
  Unread, Tribes and Direct messages over `AppModel.sidebarSections`,
  the swipe actions and long-press menu, pull to refresh, the sections'
  actions (Join and Create a tribe, pending invites, Add contact, Invite
  someone), `chatsDestinations`), `ChatsConnection` (`ConnectionBolt`,
  green or orange, the orange countdown under the title and the bolt's
  `ConnectionPanel`), `PeopleControls` (`PeopleSheet`, `SheetStack`,
  `ActionRow`, `PendingInviteRow`, `CodeEntry`: a code typed, pasted,
  scanned or read from a photo; `ConfirmInPlace`; `ShareableCode`, a QR
  code to copy and share), `ContactSheets` (`AddContactSheet`,
  `InviteSheet`, `InviteDetailScreen`), `TribeSheets` (`JoinTribeSheet`,
  `TribeSettingsSheet`: create and edit), `ChatDetails`
  (`ChatDetailsScreen`: a contact's or a tribe's, how you appear in a
  tribe, the time zone switch; `TribeMembersScreen`),
  `ChatsLists` (Threads, Mentions, and Automations' "on your Mac for
  now"),
  `ConversationScreen` (the header with Call and More in one capsule, the
  rows, the composer on `.floatingBar`, the thread sheet on
  `router.thread`), `MessageList` (opening at "New messages", following
  the newest at the bottom, the "N new messages" pill over `ListBottom`,
  older pages through `AppModel.loadOlder`), `MessageRows` (the flat rows:
  messages, payments, requests, notes, quotes, boosts, thread summaries,
  Retry and Discard; an agent reply's tool lines and its deliverables,
  `AgentArtifactLines`, each opening in `OrgPageSheet` or saying why it
  does not), `MessageMedia` (images, GIFs' first frame, files
  named), `MessageMenu` (`MessageActions`: the long-press menu, swipe
  right to reply in the thread, VoiceOver's actions), `ThreadSheet`,
  `Composer` (`PhoneComposer`: the glass capsule over a `UITextView`,
  attach from Photos, the camera or Files, `@` mentions, the mic and the
  bolt saying what is coming) and `YouTab` (photo, name and balance;
  Agent; Stadeum; the words, Change PIN, Face ID, the PIN timeout, boost amount,
  the confirmation threshold, server; Forget).
  `Peel/Assets.xcassets` holds `Logo`, a link to
  `Apps/Assets/peel.svg`, for the phone's own use
- `Sources/AgentKit/` — the agent's client side, GRDB and PeelDiagnostics only (no PeelCore,
  builds for macOS and iOS; `docs/agent-architecture.md`). The agent's loop
  is strut's (`docs/agent-on-strut.md`); Peel's own Swift loop, its model
  clients and its automation server were removed in Phase 1's PR 11
  - `JSONValue.swift` — any JSON value (props, event fields, tool schemas
    and arguments) and `StableJSON`, the one
    encoding AgentKit writes (keys sorted); `JSONValue+Access.swift` — its
    literals, `init(parsing:)`, `jsonString` and accessors
  - `MessageLink.swift` — `AgentMessageLink`, the agent's link to one
    message (`https://peel.invalid/message?chat=…&uuid=…`) and how the
    agent is told to write it, and the one at the end of a send row's
    line; the app opens it in place of the web. Here rather than in
    PeelAgent so the iPhone's message text (`MessageText`) can read it
  - `HLC.swift` — the hybrid logical clock: `tick` for a local event,
    `receive` for a remote one
  - `Event.swift` — `Event`, the only write: its JSON (the contract with
    the official apps, versioned by `v`) and what each op's fields mean
  - `AgentStore.swift` — `Record`, `Link`, the read results, the
    `AgentStore` protocol, and `add`/`update`/`link`/`unlink`/`forget`/
    `restore`, which build the events so callers never do
  - `SQLiteAgentStore.swift` — the event log and applying it: idempotent
    by event_id, last write wins per field (`field_clock`), `rebuild`
  - `SQLiteAgentStore+Reads.swift` — `read`, `search` (FTS5 over name and
    body), `walk` (depth at most 2), `ontology`, `records(type:)` (oldest first)
  - `SQLiteAgentStore+Migrations.swift` — its own schema, append-only
  - `Tool.swift` — `Tool` (with its read or send effect, whose `asks` is
    exhaustive so a new effect must decide; and `Plan`: a result at once
    or an action to approve), the shape the Sphinx tools take for the
    device requests
  - `Approval.swift` — the gate for every device request that acts:
    `ToolIntent`, what a card shows and `isShowable`; `ApprovalGate`, a
    rule or the person; `ApprovalRules`, the "always" rules as records,
    per tool and target, never for a cost; `SendGrants`, an automation's
    chats and sats cap, beside them
  - `Session/` — `AgentProvider` (Anthropic, OpenAI, OpenRouter: names,
    key pages, the picker's models), `AgentCredential` (prints without its
    key) and `AgentCredentialStore`; `AgentSession`, the agent on this Mac:
    the connected model (`connect`, `setModel`, `removeKey`, each handed on
    through `credentialChanged`), the agent's name, the rules
    (`approvalRules`, `revoke`), and the chat Peel's own loop kept before
    strut was the agent, read only: its `Conversation`, `Turn` and
    `ToolCall` records, and Clear (which forgets its `Summary` records
    too); `keep` writes turns in that shape for the offscreen driver
- `Sources/PeelDiagnostics/` — on-device crash and memory diagnostics, the
  record, uploaded nowhere; the agent reads it redacted when asked
  (`docs/diagnostics.md`, the guarantee). No UI. `CrashRecorder.install()` (first thing in each app's
  `init`: PLCrashReporter 1.12.2 inside `#if canImport(CrashReporter)`, in
  `PendingReport.swift` and `CrashRecorder.swift` alone, off under a
  debugger; its pending report moved into the private raw folder, the
  marker, the ring, the Mac's memory-pressure source), `Diagnostics` (the
  facade: `note(errorKind:)`, `setAction`, `setForeground`,
  `markCleanExit`, `memoryWarning`, `previousRun`, `recentEvents`,
  `snapshot`, `latestRedactedReport`, `deleteRecords`, debug-only
  `forceTestCrash`; `PeelCore` adds `note(error:)` and `PeelError.noted`,
  which every notice built from an error goes through, as do `AgentSession`'s,
  the tribe forms' and the refused-file notices, by kind only), `DiagnosticEvent`
  (enums and numbers only: no String field), `DiagnosticsRing`
  (bounded JSON-lines file, coalescing, rotation), `RunMarker`
  (`PreviousRun`, classified at launch), `CrashRecord` and `RedactedRecord`
  (the raw record never leaves the module), `Redactor`, `DiagnosticsStore`
  (`raw/`, `redacted/`, the strut's stderr tail; `StderrTail`),
  `MemoryProbe`. PeelUI re-exports it and adds `AppModel+Diagnostics` (the
  notice, `showDiagnosticRecord`, `deleteDiagnosticRecord`); the Mac's and
  the phone's `DiagnosticsViews` draw the notice and the sheet. Tested on
  Linux too: `swift test --filter PeelDiagnosticsTests`
- `Sources/PeelAgent/` — the device side of the agent in strut: the Sphinx
  tools over PeelCore's storage, the device requests, and the strut and
  bridge Peel ships (AgentKit and PeelCore; no AppKit or UIKit)
  - `SphinxTools.swift` — the read tools under the official Mac app's names
    (`get_contacts_and_tribes`, `read_recent_messages`,
    `read_unseen_messages`, `read_threads`) and Peel's `search_messages`,
    each through the reads the app's views use; what the orchestrator is
    told about them (`systemPrompt`)
  - `DeviceReads.swift` — the device requests the Mac answers for strut's
    agent, `chats.list`, `chats.read`, `chats.threads`, `chats.unseen` and
    `chats.search`, each through a `SphinxTools` read tool; any other kind
    refused in words
  - `DeviceActions.swift` — the device requests that act as you: `send`
    (the send tool's plan on its card through `ApprovalGate` and its
    rules, or an automation's send grant with `[Agent] ` first) and
    `approve` (the card alone, which may keep a send grant); a card past
    the request's time is `expired`; every other kind goes to `DeviceReads`
  - `ChatDirectory.swift` — a chat by the name the agent gives: chat id,
    exact, normalised, without spaces, part of a name, then typos;
    ambiguous rather than a guess
  - `ChatData.swift` — a tool's result: header, the chats' data between
    markers that say other people wrote it, one cleaned line per message in
    the official format (`[sender] date (uuid=… thread=… reply=…): text`)
    under a heading with the chat id, capped and cut by whole lines;
    `ChatDataReading`, a read's answer read back (its chats, each with the
    messages read and their uuids) for a device request's row
  - `SendTool.swift` — `send_sphinx_message`, effect send: the chat by
    the read tools' resolver, thread and reply by `Engine.checkLinks`, the
    card's words and a tribe's price, then `Engine.sendText` capped at
    that price; its row's line ends with the sent message's ids
  - `AgentStore+Profile.swift` — `SQLiteAgentStore.open(for:storage:)`,
    the account's `agent.sqlite` as the app opens it
  - `Connections.swift` — Account › Connections' MCP servers in strut's
    registry (`/mcp-servers`): add (the key put in strut's secret store
    first, the registration naming only the secret), test (strut's probe:
    the tools and which ask first), remove (with its key); and `MCPGrants`,
    which agents (the assistant, its jobs) reach each server, written into
    the host delta as `mcp/<server>/*`
  - `Hive.swift` — the Mac's side of a Hive pairing (PeelCore's
    `HiveClient`, `HiveLink`): strut's peers made Hive's (`syncPeers`), and
    the org call a `proposal:` card is for, read from strut's record
    (`peerRequest`)
  - `WorkspaceApps.swift` — the Mac's reads of PeelCore's `WorkspaceApp`:
    the apps a workspace pinned as tabs, read
    through Peel's strut (`pinnedApps(of:)`, `GET /peers/<id>/apps`), the
    person's own on it (`ownApps`, `GET /apps`, less what strut seeds), and
    the address of one shown alone (`MemoryServer.page(of:)`, through
    PeelCore's `StrutUI.page`: strut's UI
    with its key as `?key=`, `&app=@<id>/<name>&solo=1`, or `&app=<name>` for
    one of the person's own; Peel's own strut
    only), and of a deliverable from the agent's DM the same way
    (`page(showing:)`: `&artifact=<path>&solo=1` for a file, `&app=` for an app)
  - `BundledStrut.swift` — the strut Peel ships in `Contents/Strut` (or,
    for the tests and journeys, the one staged for this Mac, `staged`, through
    `init(folder:data:)`):
    started when an app account opens its agent (and again on Set up or
    Try again if it stopped), erased with the account (`erase`: what the agent
    remembered and its automations), its key made by Peel for
    this launch and kept only in memory, its secret store encrypted with
    `STRUT_SECRET_KEY` (the profile's `strutKey`, made on first start, read
    before strut starts, never logged), its port the OS's, read from its
    ready line (only `127.0.0.1` with Peel's key is trusted); the caller's
    `DYLD_*`, `NODE_*` (but `NODE_EXTRA_CA_CERTS`), `STRUT_*`, `OPENSSL_*` and
    `SSL_CERT_*` dropped, and
    its OpenSSL (Ladybug's, built for Homebrew's folders) given no
    configuration, engines or providers; its workspace (one Ladybug file,
    `workspace/graph/graph.lbug`; strut imports the old files once and
    moves them to `workspace/fs-workspace.imported-<time>/`) and memory
    graph in `~/Library/Application Support/Peel/Strut`, a development
    profile's in its own folder (`dataFolder(for:)`); its log read and
    dropped; stopped when Peel quits (stdin closed, SIGTERM, SIGKILL after
    two seconds), and gone by itself if Peel dies (`STRUT_EXIT_ON_STDIN_EOF`)
  - `BundledBridge.swift` — the agent's bridge Peel ships in `Contents/Bridge`
    (every build, in Release inside the app's sandbox; sphinx/runner,
    `docs/agent-on-strut.md` "Built: PR 4" and "Built: PR 10"):
    a port picked here and trusted once Rocket's launch line names it on
    runner's own output, the admin and strut-facing tokens per launch in
    memory only, the agent's seed (with an invite from the account on its
    first start) and owner over the admin routes, the contact info and
    balance from `GET /contact_info`; `setUp` pairs the agent (only from
    the person's Set up, which shows `setUpMsat`; an agent already a
    contact is used again), one invite per store, its sats asked back
    once the agent registered; its store, excluded from backups,
    owner-only beside the account's, erased with it; gone by itself if
    Peel dies (`RUNNER_EXIT_ON_STDIN_EOF`). Tested in `BundledBridgeTests`
    (the staged runner when there is one) and the journey `Journeys/Bridge`
  - `Orchestrator.swift` — Peel's half of strut's `orchestrator`
    (`docs/agent-on-strut.md` "Built: PR 5"): the host delta `BundledStrut`
    writes to `host-config.json` in strut's data folder at each launch
    (`STRUT_HOST_CONFIG`): Peel's tools and prompt section (who the agent
    is, the reads with `SphinxTools.systemPrompt`, sends, `memoryPrompt`
    and `automationsPrompt`),
    no pinned model (the connected one), and the `automation/*` steps on
    `peel-automation-run` behind `sphinx/approve`. `DeviceStep` is each
    `sphinx/*` step's source: a device request posted to the bridge on
    127.0.0.1 with `PEEL_BRIDGE_PORT` and `PEEL_BRIDGE_TOKEN` from strut's
    secret store, id `<run>/<path>`, `pending` wrapped in `withStop()`.
    `AutomationsClient.installOrchestrator` publishes the steps and
    `peel-automation-run` before the bridge starts (and drops any old
    secrets), `useBridge` stores the new ones once it runs. The steps and `peel-automation-run` are sealed. PR 7
    (`docs/agent-on-strut.md` "Built: PR 7"): `sphinx/post` posts from an automation's run
    with its send grant (kept by the automation's id, from strut's `ctx.automation`), `moveYours` moves the
    person's automations to `peel-automation-run` as the bridge starts (PR 10: never back),
    `pointRunEnds` points their run ends at the running bridge.
    Tested in `OrchestratorTests` (a staged strut with the automation steps, when there is
    one) and the journey `Journeys/Orchestrator`
  - `StrutSpeech.swift` — dictation's speech-to-text calls to a strut
    (`/audio/models`, the model's download, `/audio/transcribe` with the
    recording's WAV), on the slow strut session; its `Failure`s are the
    HUD's words, never strut's own. Tested in `StrutSpeechTests`
  - `AutomationsClient.swift` — strut's automation endpoints, for the
    Automations view: it lists every workflow's automations (a system one,
    `category: system`, with its workflow's description; the person's on
    `peel-automation-run`, and any left on the old `peel-automation`,
    whose step handed each run to Peel's own loop before PR 11, until a
    bridge start moves them), addresses each on its own workflow, reads
    their runs (`AutomationRunRecord`, `AutomationReply` and
    `AutomationFailure` in `Automation.swift`: a failure in plain words,
    anything shaped like a key masked) and turns each system automation on
    once (`turnOnSystem`, `docs/system-automations.md`).
    `setModel` puts the connected model as `STRUT_DEFAULT_MODEL` and its
    provider's key in strut's encrypted secret store, for the agent and
    the system automations, and takes them out on disconnect (and the old
    `peel-automation` step's token and port with any hand-over);
    `AppModel.modelChanged` calls it, one at a time, whenever strut starts
    or the model changes (a Keychain that cannot be read leaves the store alone)
  - `Brain.swift` — where Peel Home is: this Mac, or moved to a home
    server (`MovedHome`), kept in `Profile.brain` (one that cannot be read
    is never taken for this Mac; a home server kept the old way, by address
    and key, is read as this Mac and said once)
  - `PeelHome.swift` — Peel Home moving to a home server and back
    (`docs/always-on.md`, A4): `HomeLink` (`peel://home-setup?host=…&code=…`,
    read through `peelLink`, the code never printed), `HomeMover`, the one seam to strut's `move`
    (`StrutMove`: `node desktop.js move check|send|fetch` on the bundled
    strut, its env values in a 0600 file deleted after, the bridge's token by
    env), and `PeelHomeMove`, the state machine: `Brain.moved` kept before
    anything stops, this Mac's strut and bridge started again only when the
    box still waits for a move, folders set aside as `<name>.moved-<date>`
    once the agent answers from the box, back by `fetch`, and "Use this
    Mac's copy". `AppModel+Home` is the app's side (`PeelHomeLocal`, the
    ping in the agent's DM); Account › Peel Home shows it. Tested in `PeelHomeTests`
  - `MemoryServer.swift` — the agent's long-term memory, a Ladybug graph a
    strut owns (`docs/agent-brain.md`): its address and `STRUT_API_KEY`,
    from Peel's own strut's ready line, on this Mac only (`BundledStrut`;
    looked at again by `AppModel.lookForMemory` whenever strut starts or
    stops; the key never printed, dumped or reflected); one memory
    step run by
    `POST /steps/memory/<verb>/run` through `Web.postToStrut`, the
    arguments as the run's `input` under the config `{{ input }}` (strut
    templates any config, so memory text never goes as one), strut's reply
    read back, a step's own refusal as the failure, cleaned to one line
- `Sources/peel/` — command-line harness for PeelCore
  - `PeelCommand.swift` — usage and dispatch; `Invocation` (one run's
    options and remaining arguments, `load()`, `readOnlyStorage()`) and the
    argument helpers the areas share
  - `Commands+Account.swift`, `Commands+Contacts.swift`, `Commands+Chat.swift`, `Commands+Tribes.swift`,
    `Commands+Money.swift`, `Commands+Calls.swift` — the commands by area,
    each an `Invocation` method that returns false for a command not its own
  - `Output.swift` — `Session` (an engine with its events printed) and the
    row and payment lines every command prints
- `Sources/Sphinxrs/` and `Vendor/` — generated bindings and the core's static
  library, produced by `scripts/build-ffi.sh`; not checked in
- `Tests/PeelCoreTests/` — offline unit tests for PeelCore (see Tests below),
  a file per area: `StateCodecTests`, `StorageTests`, `MigrationTests`,
  `ReadMarkerTests`, `ChatSectionsTests`, `ListBottomTests`, `RowIdTests`, `ThreadTests`, `SearchTests`, `MessageTests`,
  `MessageMarkupTests`, `MembershipTests`, `TribeTests`, `ContactsTests`,
  `EngineTests`, `EngineFailureTests`, `ConnectionDropTests`, `AutoResendTests`,
  `PublishPlanTests`, `HistoryCursorTests`, `PaymentTests`, `InvoiceTests`,
  `MoneyRefusalTests`, `PaymentTemplateTests`, `SatsTests`, `MediaTests`, `MediaInfoTests`,
  `IncomingFilesTests`, `CallTests`, `CallServerTests`, `CallWatchTests`,
  `NotificationPolicyTests`, `PersonHueTests`, `TimeZoneTests`, `PreferencesTests`, `PreferencesFileTests` (with a port of the official reader),
  `ServerAddressTests`, `BiometricUnlockTests`, `PeelErrorTests`, `WebTests`, `WebPageTests`, `GiphyTests`;
  the audits' `AuditInputTests`, `AuditMoneyTests`, `AuditNetworkTests` and
  `AuditSecretsTests`; `TestSupport` (fixtures only these use). No PeelAgent,
  so they also run on iOS
- `Tests/PeelUITests/` — offline tests for PeelUI's model on a real
  engine and profile, no window or server: `CallStoreTests` (each chat's
  busiest watched call, the call you are on, locking stops the watches),
  `ChatListControllerTests` (the list controller's 25 cases on a fake
  engine and store) and `ChatSearchTests` (Return before a search's
  matches waits for the first of them) and `DictationTests` (the hotkey's
  state machine, the hotkey's encoding, the WAV writer,
  where dictated text goes) and `LingoTests` (reading strut's lexicon, what a
  correction learned and the dictation models; `DictationEditTests`, when
  an edit to dictated text is done)
- `Tests/PeelTestSupport/` — `Fixtures.swift`, the fixtures PeelCoreTests,
  PeelUITests and PeelAgentTests share (`TempProfile`, `rows`, `uuid`, `dm`,
  `Message.fixture`, `sender`, the keys, `registeredStorage`,
  `withTestEngine`) and `HTTPStub.swift` (a loopback HTTP server that
  records each whole request); a library target, since a test target
  cannot depend on another, imported `@testable`
- `Tests/PeelAgentTests/` — offline tests for PeelAgent, Mac-only like it:
  `AutomationsClientTests` (strut's lists and runs read back, failures in
  plain words with keys masked, system automations turned on once, the
  model handed to strut), `BundledStrutTests` (with a staged strut, a real
  start and stop, and no secret kept on disk as it is), `OrchestratorTests`
  (the host delta and prompt section; with a staged strut, the device
  steps and the move off `peel-automation`), `ConnectionsTests` (an MCP
  server added, tested, granted and removed on a staged strut against a
  stand-in server, `MCPStub`, its key held by name only), `StrutSpeechTests` (dictation's
  WAV and key sent, refusals, the model list and download), `HiveTests` (Hive's device
  flow against a stand-in answering as stakwork/hive#5602 documents:
  approve and collect once, deny, expiry, a page on another site or an
  account Peel cannot name refused, renewal and revoke; the org call's
  card worded from strut's record), `BundledBridgeTests`,
  `SphinxToolsTests` (name resolution, each tool on a seeded profile, caps, unseen grouping, message
  text that tries to end the data block, the device reads through the same tools), `SendToolTests` (the send
  tool over a real engine: the card's words, the price cap through the
  tool (a price raised while the card waits is refused in the engine's
  words), threads and replies, hidden characters), `DeviceActionsTests`
  (sends and approvals by device request: the card, once, deny, expiry,
  "Always allow", the price cap, send grants),
  `BrainTests` (what is kept, an old home server read as this Mac),
  `PeelHomeTests` (every point a move out or back can fail leaves at most
  one bridge able to run, and this Mac's runs only when nothing reached the
  box; the link; `StrutMove` on a stand-in Node: arguments, the env file,
  refusals),
  `AgentMessageLinkTests` (the agent's message links and a send row's
  link, only the one at the end) and
  `MemoryServerTests` (only Peel's own strut on this Mac, the POST
  included; the key never
  printed; strut's replies and refusals; the earlier chat's memory rows
  and the panel's nodes)
- `Tests/PeelDiagnosticsTests/` — offline, pure logic, also on Linux: `RingTests`
  (ring, run marker, small parts, the store) and `RedactorTests`
- `Tests/AgentKitTests/` — offline: `AgentStoreTests` (the event format,
  the clock, apply order, idempotency, per-field last write wins, forget
  and unlink, rebuild, search, walk and ontology), `AgentSessionTests` (the
  earlier chat read back from the records Peel's loop wrote, Clear, the
  connected model's key, the name) and `ApprovalTests` (the gate's rules:
  once, always per tool and target, a cost always asked, kept across a
  reopen, revoked, a card taken down); `TestSupport` (the in-memory
  credential). No test calls a model provider or uses a real key
- `Tests/PeelIntegrationTests/` — journeys through the real core against the
  local stack (opt-in, see Tests below): `Stack` (finds or starts
  `scripts/test-stack.sh`), `Person` (one account), `Bank` (where the sats
  come from), `Journeys` (runs them one at a time) and the journeys by area,
  `AccountJourneys`, `ContactJourneys`, `InviteJourneys`, `MessageJourneys`,
  `TribeJourneys`, `AttachmentJourneys`, `PaymentJourneys`, `HistoryJourneys`,
  `ReconnectJourneys`, `PreferencesJourneys`, `ReadJourneys`, `AgentJourneys`
  (the Sphinx tools the device requests use over a real account: the
  reads, a send only once allowed, a tribe send never paying more than its
  card), `DeviceRequestJourneys` (the Mac answers its agent's
  `chats.unseen` once, a repeat from the ledger, strangers nothing; sends
  as you once and only when allowed, `expired`, `unknown` after a stop
  mid-send); `FundDev` (the bank's half of
  `fund-dev.sh`, run only by it)
- `home/` — Peel Home, the always-on box's Compose bundle (its README,
  `docs/always-on.md`): `setup` runs strut's own `strut move serve` through
  `setup.sh` (receive a move on an empty box, send it back on request);
  `strut` and `bridge` run through `gate.sh`, which starts each only while
  Peel Home is on the box, with its own allow-listed keys from
  `data/env/<program>/` (read, never executed), and starts the bridge once
  strut answers `/health`; `peer` is Caddy in strut's network, the peer
  port where the Mac's strut calls `POST /home/pull` and `/home/push` and
  nothing else (TLS from its own CA, an allowlist in `Caddyfile`). Replaces
  `brain/` (A7)
- `scripts/test-stack.sh` (with `test-stack-helpers.py`) — starts the local
  stack the integration journeys use, on random ports; `tap` takes the
  wire tap down, up, or freezes it (a dead connection that looks open),
  or deafens it (the broker's replies lost after a register)
- `scripts/fund-dev.sh` — the only allowed way to give a development profile
  sats: a real payment from the bank on a local stack ("Checking the app")
- `scripts/risk.sh` — ranks a branch's risk (low, medium, high) from the
  files it touches and its size; see "How a change ships"
- `scripts/build-ffi.sh` — assembles the bindings: downloads the pinned
  `sphinx-rs` release's library, bindings and header from GitHub, or with
  `--update <tag>` another release's, recording it in the lock
- `scripts/bundle-app.sh` — builds the Mac app and wraps it as a signed bundle
  (default `.build/Peel.app`, or the path given), without installing it;
  embeds the frameworks the app loads through `@rpath` (LiveKit's
  `LiveKitWebRTC.framework`) in `Contents/Frameworks`, and the strut
  `stage-strut.sh` staged in `Contents/Strut` (without one it warns: that
  Peel's agent has no memory or automations; one without Ladybug it refuses)
- `scripts/stage-strut.sh <strut checkout>` — stages the strut Peel ships
  once per Mac, in `~/Library/Caches/dev.peel.build/strut` (or `$PEEL_STRUT_STAGE`),
  which every checkout's `bundle-app.sh` copies: strut's desktop package
  (`package-desktop.mjs`, with dictation's speech engine (sherpa) in
  `native/` and its fixer (node-llama-cpp with Metal, from strut's own
  `fixer/` install since strut#312) in
  `native/llama/mac-arm64-metal`, Ladybug, its `vector` and `fts`
  extensions, the `memory/*` steps, and the `orchestrator` with the
  `automation/*` steps, which Peel's delta needs), built from the strut
  commit `Vendor/strut.lock` pins (git archive of that commit only, so the
  checkout is left as it was), and Node, a pinned release checked against
  its SHA-256 (cached in `<stage>.node`). One run at a time
  (`<stage>.lock`). Apple silicon only. Run it once, after the pin moves,
  and again if macOS clears Caches
- `scripts/stage-bridge.sh <sphinx checkout>` — stages the agent's bridge
  (runner) once per Mac, in `~/Library/Caches/dev.peel.build/bridge` (or
  `$PEEL_BRIDGE_STAGE`): built from the sphinx commit `Vendor/runner.lock`
  names, from that commit's tree alone, with `Vendor/runner.Cargo.lock`
  (`--update-lock` after moving the commit). `embed-strut.sh` copies it
  into every build, and `run-app.sh` refuses without it
- `scripts/check-app.sh` — `bundle-app.sh` into `.build/PeelCheck.app`
  (bundle ID `dev.peel.mac.check`), then runs a drive file offscreen on a
  development profile (see "Checking the app")
- `scripts/run-app.sh` — refuses without a staged strut (`PEEL_ALLOW_NO_STRUT=1`
  to go on), `bundle-app.sh`, then installs to
  `~/Applications/Peel.app` and opens it from there (so a Dock pin survives rebuilds)
- `scripts/signing-identity.sh` — the identity both signing scripts use
- `scripts/sign-app.sh` — signs a bundle with the Apple Development identity,
  embeds a provisioning profile and the stub's entitlements (Keychain,
  microphone, camera), frameworks and the strut's Node and native
  libraries (every Mach-O in `native/` and its folders) first (Node with
  `scripts/strut-node.entitlements`: allow-jit only) (see Signing)
- `scripts/provision/` — an empty Xcode app whose only job is to make Xcode
  fetch a provisioning profile for Peel's bundle ID; `sign-app.sh` builds it
- `scripts/embed-strut.sh` — the Mac app's build phase that puts the staged
  strut in `Contents/Strut` (and signs its native code, when Xcode signs),
  and the staged bridge in `Contents/Bridge` (in Release with
  `scripts/bridge.sandbox.entitlements`)

## Build and run

```sh
./scripts/build-ffi.sh      # once, and after the core changes
swift build
scripts/check-app.sh <dev> <drive file> <out dir>   # app: offscreen, see below
.build/debug/peel --profile <dev> listen             # CLI
```

`Vendor/sphinxrs.lock` pins the core: the sha256 of each asset Peel links
(`universal-sphinxrs-mac.a`, `sphinxrs.swift`, `sphinxrsFFI.h`, in that
order) and the `sphinx-rs` release tag they come from. `scripts/build-ffi.sh`
downloads exactly those files (cached in `.build/sphinx-core`) and refuses,
and deletes, any with another hash. To move to a new core, run
`scripts/build-ffi.sh --update <tag>`, which records the release and its
three hashes. It then checks the core that release pins (`sphinx-ffi/Cargo.toml`
at the tag) for upstream's client security fixes through GitHub's compare
API. `stakwork/sphinx` is private, so set `GITHUB_TOKEN` to a token that can
read it (`GITHUB_TOKEN=$(gh auth token)`); without one every fix is
unchecked. A missing or unchecked fix warns, and fails the run with
`PEEL_REQUIRE_CORE_FIXES=1`, which any build that ships must set.

The Mac app is the "Peel macOS" target of `Apps/Peel.xcodeproj`; `scripts/bundle-app.sh`
builds it with `xcodebuild` (unsigned, into `.build/xcode`), then signs it for
the weekly re-sign below (`run-app.sh` installs the result). To check a build
without replacing the installed app, `./scripts/bundle-app.sh /some/dir/Peel.app`.
Or open `Apps/Peel.xcodeproj` in Xcode (after `build-ffi.sh`), pick "Peel macOS"
and Product > Archive for a build to distribute: the scheme's Release signs
with the team in `Apps/Config`, and `scripts/stage-strut.sh` must have run.

### The iPhone app

```sh
SPHINX_IOS_LIB=<sphinx-rs-ios>/out/ios-arm64/libsphinxrs.a \
SPHINX_IOS_SIM_LIB=<sphinx-rs-ios>/out/ios-arm64-simulator/libsphinxrs.a \
  ./scripts/build-ffi.sh                      # the core with its iOS slices
xcodebuild -project Apps/Peel.xcodeproj -scheme 'Peel iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .build/xcode build
xcrun simctl boot 'iPhone 18 Pro'
xcrun simctl install booted .build/xcode/Build/Products/Debug-iphonesimulator/Peel.app
xcrun simctl launch booted com.sphinx.peel
xcodebuild -project Apps/Peel.xcodeproj -scheme 'Peel iOS' -destination 'generic/platform=iOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build   # device, unsigned
```

Or open `Apps/Peel.xcodeproj` in Xcode (after `build-ffi.sh`), pick the
`Peel iOS` scheme and a simulator, and Run. A simulator needs no team; for a
phone, copy `Apps/Config/Local.xcconfig.example` to `Apps/Config/Local.xcconfig` and set
the team. The phone's profile is `default` in the app's own container,
its words in the app's Keychain; agents never put an account's words,
an invite or the throwaway account into it (Tom does that himself).

## Checking the app

Tom works on this Mac while agents run. Check the app only with
`scripts/check-app.sh <dev profile> <drive file> <out dir>`: it builds
`.build/PeelCheck.app` under its own bundle ID (its own preferences and
saved windows) and runs it with `-offscreen YES`, so it has no Dock icon,
never comes to the front, places every window beyond all screens (never
full screen or minimised), keeps its own clipboard (the general pasteboard,
by either route, is a private one), posts no notifications or beeps, and
opens no other app or system panel (links, the Finder and System Settings
stop at NSWorkspace; file panels, device prompts and Share are refused;
there is no Services menu). Media and call audio still play, so a drive
should not start them. It runs the drive file, writes the snapshots to the
out dir (`drive.log` beside them, with what each step did) and quits; it
fails after five minutes, and the script stops the app by its PID.

The mode and the driver refuse `default`, `throwaway` and the daily app's
bundle ID, and the check bundle refuses to run without the mode, each
quitting before any window opens.

- Never launch a visible build (`open` of a bundle without the mode,
  `run-app.sh`), never post system events (`CGEventPost`, AppleScript, the
  Accessibility API on any app) and never capture the screen; look only at
  the snapshots, which are drawn from Peel's own windows.
- A drive file is JSON lines, one step each; `//` lines are comments:

  ```
  {"select": "Offscreen Check"}           // sets the destination its sidebar row sets
  {"open": "send-sats"}                   // the open chat's Send sats panel, as its bolt opens it
  {"open": "connection"}                  // the sidebar bolt’s status panel
  {"open": "connection-check"}            // its check/reconnect action
  {"open": "account"}                     // the Account screen, as Account… (⌘,) opens it
  {"open": "account-dictation"}           // Account at one category, as its row opens it
  {"notification": "Offscreen Check"}     // a click on the notification for its newest message from someone else
  {"open": "payments"}                    // the Payments screen, as its sidebar row opens it
  {"open": "message-menu"}                // the open chat's newest row from someone else: its ••• menu
  {"key": "f", "mods": ["cmd"]}           // also return, escape, tab, space, delete, up, down, left, right
  {"link": "peel://home-setup?host=…&code=…"}  // a link macOS hands Peel, through its app delegate
  {"type": "green"}
  {"wait": 0.5}
  {"snapshot": "search"}                  // search.png; open menus and panels as search-1.png, …
  ```

  The message list journeys add a frame probe and the steps they need
  (`probe`, `thread`, `close`, `scroll`, `scrollTo`, `width`, `jump`,
  `expect`, `signal`, `unread`; `OffscreenDriver`'s header): `docs/testing.md`,
  "List journeys".

  Each step waits 300 ms for the UI to settle. Keys go into Peel's own
  event queue, so key monitors and shortcuts see them as typed (a key
  with ⌘ is offered to the window's views first, as AppKit does for a key
  window, which an app never active has none of); `keyCode`
  is real only for the US-layout letters, digits, punctuation and named
  keys above (other characters are sent with code 0). There is
  no click step: posted clicks do not reach SwiftUI's buttons in an app
  that is never active, so reach a control by its shortcut or add a
  named step like `select`. `{"hover": 0}` puts the pointer on a message
  list's row (the list's tracking area, moved over as AppKit reports it).
- A new development profile on the local stack starts with 0 sats, and
  adding a contact needs 6. **The only allowed way to fund one** is
  `scripts/fund-dev.sh <stack dir> <dev profile> <sats>`: the
  integration tests' bank adds the profile as a contact (named "bank")
  and pays it, a real payment on that stack (`docs/testing.md`, "Funding a
  development profile"). It refuses `default`, `throwaway`, and any server
  that is not the named stack's loopback broker. Never write a balance,
  setting or any other value into a profile's database, and never write a
  throwaway test that calls `Bank` to do this instead.

## Signing and the weekly re-sign

The app keeps the words in the data-protection Keychain, which needs the
`keychain-access-groups` entitlement, which needs a provisioning profile. Tom
has a free Personal Team (team `T3M78XC3UV`, bundle ID `dev.peel.mac`, access
group `T3M78XC3UV.dev.peel.mac`). A bundle ID belongs to one team, so a build
signed by any other team is `dev.peel.mac.<team>` instead (`PEEL_BUNDLE_ID`
overrides it), with its own, empty Keychain. So:

- `scripts/sign-app.sh` builds `scripts/provision` (an empty app, same bundle
  ID) with `xcodebuild -allowProvisioningUpdates` into `.build/provision`,
  then copies that stub's profile into Peel as
  `Contents/embedded.provisionprofile` and signs Peel with the stub's
  entitlements. The stub is rebuilt only when its profile has under two days
  left or was made for another app ID or certificate; the old profile is set
  aside in Xcode's folder first so Xcode asks Apple for a new one. Xcode must
  be signed in to the Apple ID (Settings > Accounts); nothing else is
  interactive.
- A Personal Team profile lasts **7 days**. Once the embedded profile has
  expired macOS refuses to launch the app. The Keychain item is not lost: it
  belongs to the access group, not the profile, and a build signed with a
  fresh profile reads it (checked by re-signing with a second profile).
- So: **run `./scripts/run-app.sh` at least once a week** (it prints the
  expiry). If the installed app has already stopped launching, the same
  command fixes it.
- The entitlements are `Apps/Mac/Peel.entitlements`: the access
  group, plus `com.apple.security.device.audio-input` and `.camera` for
  calls (hardened runtime blocks the devices without them). Adding a key
  there makes `sign-app.sh` build the stub again once, keeping a profile
  that is still good. Microphone and camera grants follow the signature, so they
  survive rebuilds and the weekly re-sign.
- Frameworks in `Contents/Frameworks` (LiveKit's WebRTC) are signed with the
  same identity before the app, so library validation loads them.
- Without an Apple Development identity `sign-app.sh` refuses: an ad-hoc
  app could not load LiveKit's framework under library validation, nor use
  the Keychain. (Before calls, an ad-hoc bundle ran without the Keychain.)
- A free team may register at most 10 App IDs in 7 days; do not change the
  bundle ID casually.
- The Mac app is sandboxed in Release builds only (archives for TestFlight
  and the Mac App Store need it): `Apps/Mac/Peel.AppStore.entitlements`, and
  `scripts/strut-node.sandbox.entitlements` for the strut's Node and
  `scripts/bridge.sandbox.entitlements` for the bridge (runner), which
  inherit the sandbox: Peel's network (runner's broker connection and its
  loopback server) and its container (runner's store). Debug builds, `run-app.sh` and the checks use
  `Peel.entitlements` and run unsandboxed, as before. Checked in a signed
  Release build: it launches, and Node starts, listens and writes its graph
  in the container. Not yet checked against a real account: calls, attach
  and save, the Keychain with the App Store profile.
- Both apps are `com.sphinx.peel` (`Apps/Config/Peel.xcconfig`) under the
  App Store team, for TestFlight. A build under any other team needs a
  bundle ID of its own in the ignored `Apps/Config/Local.xcconfig`
  (`PEEL_BUNDLE_ID = dev.peel.ios` for Tom's phone, whose Keychain stays in
  that ID; `dev.peel.ios.<team>` for any team but Peel's). The scripts build
  the Mac app as `dev.peel.mac` (above), so they never touch that file. The
  iPhone app keeps the words in its own Keychain, with no access group
  until the notification extension needs one (I5). A Personal Team build
  on a phone also lasts 7 days.

## Tests

```sh
swift test      # needs the generated bindings, like swift build
```

Before writing, changing, reviewing or auditing a test, read
`.claude/skills/test-audit/SKILL.md` (Claude loads it as the `test-audit`
skill): the four questions every new test must answer, the patterns that
fail them, the contracts never to drop, and how to sweep for gaps and
low-value tests.

`Tests/PeelCoreTests` uses Swift Testing and runs offline, each storage test in
its own temporary profile directory. It covers `StateCodec` round-trips and
malformed input; `Storage` commits (atomic state and settings), message upsert
(uuid dedupe, server fields from the later copy, cross-chat uuid rejection,
a deleted message kept empty when its copy comes again), status by tag, read markers (server truth, pending, mark unread), contact alias/photo rules, the `conversations()` and
`timeline(in:)` first emission, and the profile lock; `Message` helpers;
`ServerAddress` parsing; and the `Engine` helpers that need no server
(mnemonics, invites, a fresh account, the words check: which
accounts start checked, wrong words named by place, nothing kept on a mismatch); who a message from the core is
from (`SenderTests`: a live sender believed only when the topic agrees,
history from strangers dropped, our own copy in the chat it went to and a
tribe's copy of it taking over its row, a member's replay of our tag dropped, a request's amount from its invoice); attachment encryption against an
independent RNCryptor vector, media tokens, file kinds and names, the media
cache, and the attachment columns; dropped and pasted files (`IncomingFiles`); person colours (`PersonHue`: the key
format and a stable hash) and the gold chip's mention of you or @all; mention matching, the aliases that name
this account in a tribe, and the mention re-scan; message markup (inline
code, fences, links, mentions, plain-text previews); call links (both forms, hosts, room names,
query keys) and the call server setting; which calls notify (someone
else's, recent, valid) and the chat's notification level; call tickets (strict query encoding,
the media server allowlist, token claims, the token never described, and a
fetch from an in-process loopback stub that leaves no cookie or URL cache) and
the presence feed (each message, names, photos, joins and leaves); the
calls watched across chats (the newest valid per chat, the cap of eight,
ageing out, chats left or not ready, a closed account); the network and calls audit's regressions (`Audit*`: plaintext refusal, host allowlists, redirects, no push token, no offset to a tribe not known to be private); time zones (the offset's format and
parser, malformed metadata, the per-chat switch and public tribes, the
stored tribe record and its background recheck, local
times, a sender's zone at a moment for a page of runs, the v14 column on stored history); what opens in the web pane, what a typed address opens (a page, a
search, or refused), the per-profile store identifier and a tribe's app and second brain addresses; contacts
(`ContactCode` parsing and its refusals, tribe and contact links found
in message text (`MessageLink`), QR codes read from a picture,
invite statuses by tag, an invite marked used by the key exchange that
names it, new contacts, live contact records (type 33) kept only when
this account signed them, the invite and add refusals, the price to join
held to the balance and the threshold); money when the connection goes
(`ConnectionDropTests`: a send that never left fails and may go again, one
cut short or dropped after a write stays pending, a tribe text (which pays
the tribe's price) waits like a payment and is never sent again while the
server may have it, a tribe file's first send takes over its draft and one
that never left may go again, a send whose row went meanwhile is never
published, two Retries at once pay once, only a payment over half an hour
old that the server never recorded fails, a signup cut short after its
register keeps its words and registers again with the invite while one
whose register never left leaves nothing, and a new account's inviter is
added at most once);
refusals as typed
`Engine.Failure` cases with their words; and the whole migration chain from a v1
database, with the schema frozen after v17 and after v23 and the literals
frozen into shipped migrations; and the audit's
adversarial inputs (`Audit*.swift`: seeded random and huge input to the
parsers, markup in linear time against a reference, link labels, names,
hosts, codes and the attachment cipher). Nothing talks to
a broker: anything protocol-level is still verified against the local test
server.

`Tests/PeelUITests` tests `AppModel`'s stores through their public API,
offline, on a real engine and a temporary profile (a call server on
127.0.0.1:9 that never answers, so a test says who is on a call):
`CallStore`'s counts per chat, the call you are on, and its watches
stopping on lock; `ChatListController`'s state machine against a fake
engine and anchor store; and `ChatSearch`'s Return before its matches.

`Tests/PeelIntegrationTests` runs journeys through the real core against a
local stack that `scripts/test-stack.sh` starts on random ports (never 1883
or 8000); opt-in, see `docs/testing.md`:

```sh
PEEL_INTEGRATION=1 SPHINX_BIN_DIR=<cargo target>/debug swift test --filter PeelIntegrationTests
```

No test calls a model provider or uses a real API key, opt-in or not:
the agent's journeys run strut on a stand-in model endpoint.

`Tests/PeelBenchmarks` times the hot paths on a synthetic account (50
chats, 100k messages): the reads every write re-runs, markup, per-row
fields, commits. Opt-in; `-O` rather than `-c release`, which drops the
`#if DEBUG` hooks the other test targets need. Medians land in
`PEEL_BENCH_OUT` (default `.build/bench/latest.json`); compare a run
before and after a change:

```sh
PEEL_BENCH=1 PEEL_BENCH_OUT=.build/bench/before.json swift test -Xswiftc -O --filter PeelBenchmarks
```

### Local LiveKit server

For the development test room (`Apps/Mac/Peel/CallTestRoom.swift`;
details in `docs/phases/06-calls.md`, PR 3 journal). It opens a visible
window and asks for the microphone, so only with Tom at the Mac, never
from an agent unasked:

```sh
brew install livekit livekit-cli
livekit-server --dev --bind 127.0.0.1        # ws://127.0.0.1:7880, devkey / secret
lk token create --api-key devkey --api-secret secret --join --room peel-test \
  --identity <id> --valid-for 2h
./scripts/bundle-app.sh .build/PeelCallsTest.app
open -n --stdout <file> .build/PeelCallsTest.app --args -profile <dev> -callTestToken <jwt>
```

The first join asks for the microphone; until it is answered WebRTC waits
and nothing is published. Never answer it "Don't Allow" by accident: the
grant belongs to `dev.peel.mac` and Tom's signature, so it is the daily
Peel's grant too.

### Local memes server

There is no memes server in `~/Documents/sphinx` (its `memes/` crate is an
S3 upload stub with none of the endpoints the apps use) or in
`sphinx-swarm` (which points at the hosted one). Local tests use the stub
in `scripts/test-stack-helpers.py` (the endpoints in `docs/phases/03-chat.md`,
"How attachments work", and three payment templates), on a free port; pass `--memes-host 127.0.0.1:<port>` to
`init` (or any later command). An account on a loopback server has no memes
server until one is named, so local tests cannot reach `memes.sphinx.chat`.

## How the core works

- The core (`stakwork/sphinx`, exposed through `sphinx-rs/sphinx-ffi`) is a
  library of pure functions. Every call takes the seed, a unique time and the
  whole state, and returns a `RunReturn` describing what the client must do:
  save or delete state entries, subscribe to topics, publish payloads, store
  messages, update balance, reads, mutes and payments.
- `Engine.run` is the whole contract: run the call, commit the state before
  anything else can run, then do the network work. Keep it that way; a core call
  against stale state corrupts the account.
- The reference client is `sphinx/wasm/test/auto` (TypeScript, written with the
  core). Start there for any new capability.
- Message JSON conventions (attachments, threads, boosts, calls, paid messages)
  live in the official apps, not in the core. The reference is
  `sphinx-mac-v2/.../SphinxOnionManager+ChatExtension.swift`. Match them exactly
  or colleagues see broken messages.
- `send` returns only a tag and a uuid; Peel writes its own outgoing row in the
  same transaction as the state. The server echoes sent messages to all of the
  account's devices.
- The core recovers a message's sender from its signature, so a sender can
  only ever name themself. "Ours" is weaker: the core also takes a message
  for ours by a replayed tag or a shared date, either of which a contact
  can arrange, so `Engine` keeps one only when signed by our own key
  (`accountKey`) or by a known tribe in its own chat. The core also files
  a signer as a contact at the index it wrote to, so a core contact
  without a contact key is no proof of a tribe. For a live message the child index in the topic
  names the contact as well and `Engine` requires the two to agree. History
  (`batch`) messages are accepted only from contacts the core knows. Contact
  records (type 33) in history are honoured by the core only when signed by
  this account; the core Peel links (`bd9e140`, before upstream's SR-017)
  takes a live one from anyone, so `Engine.run` keeps a live record only
  when this account signed it (`isForeignContactRecord`).
  `scripts/build-ffi.sh` warns while the linked core lacks upstream's client
  security fixes.
- Names and photos are not core state; they arrive with messages and invites.
  A contact is a conversation only once the core holds their key (`ready`).

## Rules

- The app's profile `default` (`~/Library/Application Support/Peel/default`,
  words in the data-protection Keychain) holds Tom's REAL account since
  2026-10-07. Never open, test against, migrate, copy or delete it, and never
  run `scripts/run-app.sh` (it replaces the Peel Tom uses every day); check
  the app with `scripts/check-app.sh` on a development profile.
  The CLI only opens development profiles under `Peel/dev` and requires an
  explicit `--profile` that is not `default`.
- Develop against development profiles on the local test server; use the
  throwaway account (profile `throwaway`) only for what the production server
  must see, one session at a time, never a real one. Do not call `setPushToken` for a real account: the server keeps one push
  token per account and it would take notifications away from the official app.
- One process per profile: `Storage` takes a lock, so a second app or CLI on the
  same profile fails with "another Peel process is using ...". Quit the other one.
- Only a writable `Storage` migrates. The read-only CLI commands (`whoami`,
  `contacts`, `messages`, `thread`, `threads`, `unread`, `tribes`, `payments`) fail with
  "no such table" or "no such column" on a
  profile last opened by an older build; run any connecting command (or the
  app) on it once first.
- TLS is on by default; `ServerAddress` only goes plaintext for an explicit
  `mqtt://` scheme or a loopback host, and the scheme is persisted. A
  server named by an invite or the public config goes through
  `ServerAddress.named`, which refuses plaintext off this machine; only the
  CLI's `--server` may ask for it. The `--insecure` flag (CLI only) disables
  certificate verification. A tribe link naming this machine is refused on
  an account whose server is elsewhere.
- Never log the seed, the mnemonic, or invite links.
- Never use `URLSession.shared` (its disk cache records what was fetched and
  its redirects go anywhere): fetch with `Web.get` (size-limited; a public
  https host, or loopback http for the local test stack), or through the memes
  server. A photo someone else chose goes through `Web.photo`.
- Swift 6 language mode with strict concurrency in `PeelCore`, `PeelUI` and the apps.
  Actors for shared state, `@MainActor` for UI. `Sources/Sphinxrs` is generated
  and compiles in Swift 5 mode; do not edit it.
- Tom works on this Mac while agents run. Run builds, tests and test
  servers at normal priority (`taskpolicy -b` keeps them on the efficiency
  cores and made builds several times slower), with at most three agents
  building at once. Iterate with `swift test --filter`; run the full suite
  once before the PR. Delete your worktree's `.build` when you finish.
- Work in your own worktree (`git worktree add .claude/worktrees/<name>
  <branch>`), never in a shared checkout. `~/Documents/peel` is where other
  sessions run: never switch its branch or edit files there.
  `~/Documents/peel-main` is Tom's build folder, kept at `origin/main` for
  `scripts/run-app.sh`: never commit, edit, check out or build anything there.
- Do not add a dependency for something under a hundred lines.
- Keep the engine agent-ready (`docs/agent-native.md`): no UI types, global
  state or single-account assumptions in `PeelCore`; every user action is an
  engine operation, never logic inside a view; message conventions live in the
  engine.
- UI follows `docs/design/README.md` (Slack-style layout, Sphinx colours and
  the system font) and Tom's `tom-ui` and `taste` skills: colour is state, not
  decoration; no red for ordinary failure; restraint in motion.
- **Reuse before you write.** Before adding a view, helper, label, shortcut or
  panel, search for the shared piece that already does it (`Controls.swift`,
  FormKit, `PeelButton`, `IconButton`, `Panel`, `SectionHeader`, `Card`, `Callout`, `Badge`, `Chip`, `ListRow`, `FactList`, `EmptyState`, `MenuPresenter`, `PictureField`, `.menuAnchor`,
  `.hiddenShortcut`, `Formatting`) and use it. If two places need the same
  thing and no shared piece exists, make one and move both onto it; never
  write a second copy. Each behaviour has one owner: one place that handles
  a keyboard shortcut, one way a panel opens, one function that formats a
  given label. If your change would add a second, stop and fold them.
- Keep this file, `docs/PLAN.md` and the phase files current when you change
  the layout or finish a step.

## How a change ships

Every change, however small, goes through this chain. The reviews are not
optional here: a bug in this code can lose money or leak a key.

1. **Plan.** Read the phase file. Agree what is being built and what "done"
   looks like, and write that into the phase file before writing code.
2. **Build.** Engine and storage first, UI second. Reuse what the core and the
   reference client already do.
3. **Verify in the real medium.** `swift build`; the local test server for
   anything protocol-level; the throwaway account on production for anything
   the server sees. Never a real account. For UI, drive the real path at least
   once (the actual key press, in the app beside the features it sits next
   to) with `scripts/check-app.sh`, not only a hook that calls the code
   directly. Anything with a timer, animation, observation or scroll
   watcher also gets an idle check: leave the app on the screen it touches
   for a minute and confirm its CPU stays near 0% (`ps -o %cpu= -p <pid>`,
   `sample <pid> 10` on your own process). A `TimelineView` whose schedule
   goes back in time redrew every frame and cost 25-30% CPU at idle (#137).
4. **Review.** `/code-review` for correctness, `/simplify` for reuse,
   simplicity, efficiency and altitude (it applies its fixes), then
   `/security-review`. Fix what they find. Findings deliberately not applied go
   in the phase file with the reason.
5. **Rank the risk.** Run `scripts/risk.sh`. It reads what the branch touches
   and prints a tier with its reasons; the tier decides the extra review below.
   You may raise the tier, never lower it. Put its first line and the checks
   you ran at the top of the PR description (`Risk: high, touches
   Engine+Payments`).
6. **Record.** Update the phase file (done, learned, next) and this file if the
   layout or rules changed.
7. **Ship.** Commit with a plain message and push. Do not merge your own PR.

| Tier | What puts it there | Before merge |
|---|---|---|
| Low | Docs, tests only, copy, pure styling | The chain above. |
| Medium | Other engine, storage or app code, scripts, or a diff over 400 lines | The chain, plus one real key press or click check in the app, plus the reviewer's look at the diff and renders. |
| High | Money, keys and secrets, migrations and writes, untrusted input (web, markup, links, the core boundary), the message list, keyboard and focus | Medium, plus an independent review by an agent that did not write the change, briefed to find problems rather than approve (money and keys also get a separate security-only pass); the integration journeys that cover the area; and Tom's sign-off when it changes what he would notice. |

This chain reviews one diff. Before the repo goes to the team, phase 8
(`docs/phases/08-audit.md`) reviews the whole of it, features frozen.

## Local test server

No invite needed. From `~/Documents/sphinx` (set `CARGO_TARGET_DIR` outside the
checkout):

```sh
cargo build --manifest-path broker/Cargo.toml
cargo build --bin sphinx-mixer
SEED=1111111111111111111111111111111111111111111111111111111111111111 sphinx-broker
NO_LIGHTNING=true TESTING_ONLY_ADD_TO_SENDER=1 SEED=<same> sphinx-mixer
.build/debug/peel --profile alice --server 127.0.0.1:1883 init
```

### Local tribes server

The tribes server (`sphinx/tribes`) is an MQTT client of the broker plus an
HTTP registry. Build it with `cargo build --bin sphinx-tribes`. It refuses to
forward until it knows a blockheight, which a `NO_LIGHTNING` mixer has only
with `TESTING_ONLY_AUTO_MINE=1`. The mixer must name the tribe server's key
as the default, so start the tribes server first and read its key:

```sh
SEED=2222222222222222222222222222222222222222222222222222222222222222 \
  BROKER_URL=localhost:1883 ROCKET_PORT=8811 HOST=127.0.0.1:8811 DB_PATH=<dir>/tribes \
  sphinx-tribes
curl -s http://127.0.0.1:8811/info        # {"pubkey":"<tribe server key>"}
NO_LIGHTNING=true TESTING_ONLY_ADD_TO_SENDER=1 TESTING_ONLY_AUTO_MINE=1 \
  DEFAULT_TRIBE_PUBKEY=<tribe server key> SEED=<broker seed> sphinx-mixer

.build/debug/peel --profile alice --tribe-host 127.0.0.1:8811 tribe-create My Tribe   # prints the link
#   optional: --description <text> --image <https url> --price-per-message <sats> --price-to-join <sats>
#             --escrow <sats> --escrow-hours <hours> --private yes|no --unlisted yes|no
.build/debug/peel --profile bob tribe-join '<link>'
.build/debug/peel --profile bob send <tribe pubkey> hello
.build/debug/peel --profile alice tribe-members <tribe pubkey>   # owner: member keys, pending requests
.build/debug/peel --profile bob messages <tribe pubkey>          # row id, server index, uuid
.build/debug/peel --profile alice tribe-approve <tribe pubkey> <request uuid | member key [alias]>
.build/debug/peel --profile alice tribe-kick <tribe pubkey> <member key>
.build/debug/peel --profile alice tribe-edit <tribe pubkey> --name <name>   # same options as create
```

A command that only connects briefly may exit before what the tribe sends
has arrived (an approval, a kick); `listen` for a few seconds to catch up.

Accounts made before the mixer knew `DEFAULT_TRIBE_PUBKEY` have no tribes
server; make new ones. If tribe sends start failing with "Upstream node set CLTV
to less than the CLTV set by the sender" in the tribes server's log, restart
the tribes server: it reads the block height once, and the auto-mining mixer
keeps raising it. If another stack already holds 1883 and 8000, run a
second one on other ports (`BROKER_MQTT_PORT`, `BROKER_CONSOLE_PORT`,
`ROCKET_PORT`, `BROKER_URL`, separate `DB_PATH`s) and pass `--server
127.0.0.1:<port>`. Only `.development` profiles may be used; never post to a
production tribe.
