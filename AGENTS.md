# Agent Guide

Peel is a native Sphinx chat client written from scratch in Swift on the shared
Rust core. Read `docs/PLAN.md` first (architecture and phase index), then the
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
    - `Engine+Tribes.swift` — join, leave, create, edit, members, approvals,
      a tribe's details, how you appear in one, the tribes registry and its
      background refresh
    - `Engine+Preferences.swift` — `set`, every change to a user setting
      through `Preferences`; the sync with the official apps' encrypted
      `/preferences` file (`syncPreferences`, one at a time; on connect, 2 s
      after a change, `refreshPreferences` when the app comes to the
      front), `.preferencesChanged`
    - `Engine+History.swift` — restore and catch-up: asks for the pages
      `HistoryCursor` names, the stall watchdog, recovering the account's
      own photo
    - `HistoryCursor.swift` — the history machine without the network: the
      run in flight, the queue, a restore's plan, paging and stalls (tested)
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
  - `Storage+Reads.swift` — reads and live queries: conversations, read
    states, tribes and their senders, mentions, payments, the shared SQL
    (`tribeChats`, `chatsSQL`, `countsAsUnreadSQL`)
  - `Storage+Threads.swift` — replies and threads: `timeline(in:)` (tribe
    threads collapsed), `thread(_:in:)`, `threads()`, parents, boosts and
    thread summaries
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
  - `PeelError.swift` — `PeelError`, a failure worded for the person
  - `Tribe.swift` — tribe records, tribe links, the tribes server's
    registry, and `TribePrice`: what a member pays to join or per message
    (the amount the engine sends, and why it is more than the owner's
    price), the only price shown to someone who will pay it
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
    pings and takes or refuses each write
  - `StateCodec.swift` — the MessagePack shape the core uses for its state,
    and the amounts beside the onions of a history page
    (`paymentAmounts`, what really arrived)
  - `JSON.swift` — `JSON.decode`, the one way a JSON string (a body, a
    sender, a core reply) is read into a type; `JWT.payload` (a token's
    claims, unchecked) and `.hex` for bytes
  - `Profile.swift`, `SecretStore.swift` — a local account: `.app` profiles keep
    the words in the data-protection Keychain sealed under a six-digit PIN
    (moved there from the login Keychain on first unlock), `.development`
    profiles in a plain file with no PIN (CLI only)
  - `ServerConfig.swift` — the public config endpoint a restore reads
  - `Web.swift` — every request outside the memes server (photos, the tribes
    registry, the config): ephemeral sessions (also the memes server's), the
    size-limited `Transfer` (also the memes and call servers') and its
    neutral `Failure`, `get`, the public-https host check (`isPublic`) and
    "public https, or http to this machine" (`isAllowed`, `isThisMac`)
  - `WebPage.swift` — what the app's web pane may open
    (`WebPage.address`), what an address typed into it opens
    (`WebPage.typed`: http or https, or a search), which attachments it
    shows as pages (`WebPage.isHTML`) and each profile's website data
    store identifier
- `Sources/PeelApp/` — the SwiftUI Mac app (`AppModel`, with its extensions
  by area in `AppModel+Chat` (replies, threads, sending, attachments, and
  the chat's small types: `ComposerID`, `ThreadRef`, `AttachmentHandle`),
  `AppModel+Calls` (join, start, leave, presence and the watches of recent
  calls; the view passes the call window's opening in), `AppModel+Payments`
  (`PaymentOutcome`, boosts, sends, history, invoices, buying an
  attachment), `AppModel+Contacts` (adding by code, invites) and
  `AppModel+TimeZones` (sender zones, local times, the zone setting);
  `ChatSearch` (⌘F: the search bar under a chat's header and its results
  list, its header button, stepping through matches with
  `focus(on:inThread:)`, the highlight in message text);
  `FilePicking` (the open and save panels and Show in Finder, the only
  callers of `NSOpenPanel`, `NSSavePanel` and the Finder reveal), `MainView` (the
  shell, `PaneDivider`, `Detail`), `Sidebar` (the Unread, Tribes and Direct messages sections over `ChatSections`, rows, header, connection bolt, arrow keys and Return while it has focus,
  `ConversationMenu`, whose pieces the chat header's More shares), `SidebarForms` (join a tribe), `ContactsViews` (add
  a contact by code or QR picture, invites with sats, the sidebar's pending
  invites and "New" contacts),
  `Avatar` (people's and tribes' icons, `AppIcon`), `ImageCaches`
  (`ImageCache`, bounded: attachments, and photos apart, and `animations`: GIFs' frames and sizes, Giphy's bytes; `MediaInfoCache`),
  `AnimatedPicture` (a GIF played by Core Animation, paused off the screen; `.gifPlayback`, Reduce Motion's play button over a tile), `Styles` (the `…Boxed` helpers), `Clipboard`,
  `Formatting`, `ConversationView` (with the tribe header and
  `HeaderMoreButton`, the chat header's More), `TribeViews`, `TribeDetails` (a tribe's details, `TagChips`, how you appear in a tribe), `OnboardingView`, `LockView`, `AccountView`;
  for the chat: `MessageViews`, `LinkCards` (the tribe and contact link
  cards under a message, through the Join and Add forms), `ThreadViews`, `AttachmentViews`,
  `PaidAttachmentViews` (buying and pricing a paid attachment), `ComposerView`,
  `ComposerField` (the message field: Return sends, `@` mentions),
  `ImageViewer` (images, and videos full size), `MediaViews` (the video
  tile, the audio card, `PlayerSurface` over AVKit's player view and
  `MediaPlayback`, the one player at a time), `PasteboardFiles` (drop and paste into the tray), `PaymentViews` (paying: `PaymentAttempt`, `PayButton`, send sats with `TemplatePicker`, and `TemplateImage`, a payment template's picture; the Account's boost and confirmation rows, `presets`), `PaymentChatRows` (boosts, payment rows and requests in a chat), the Payments screen (`PaymentsView`, with `PaymentRows` for the list and a payment's detail, `ReceivePane`, `PayInvoicePane`, the shared `PaymentPanes` and `PaymentItem+Display`), `QRCode` (the tile, the code, copying it as an image), and `PeelMenu`, the one menu used instead of native ones (entries, the
  view modifiers with `.menuAnchor` and its `MenuAnchor`, `KeyMonitor`, `RightClickCatcher`, `WindowReader`), with
  `MenuPresenter` (the presenter and the menu's own views, `MenuPanel` and
  `MenuRow`), `Controls` (`MenuButton`, `PeelDropdown`,
  `UnreadBadge`, `.hiddenShortcut`, and the forms' `ProblemText` and `FormFooter`) and `FloatingWindow` (the borderless window menus and panels open in);
  `CopyFeedback` (`CopyButton` and the menu's "Copied" pill, for every copy);
  `CallViews` (the call card, the header's call button and presence
  watching, the in-place switch confirm, the sidebar's on-a-call bar),
  `CallSession` (the call you are on: the LiveKit room, microphone, camera
  and devices), `CallWindow` (the grid, the focus layout with its strip,
  keep on top and the control bar) and `CallScreenShare` (the system picker,
  the capture into a LiveKit buffer track, Peel's windows left out of display
  shares);
  `UI/`, the component library over `Theme` (`docs/design/README.md`,
  "Component library"): `PeelButton`, shadcn's button (variants primary,
  secondary, outline, ghost, destructive, link; sizes sm, md, lg;
  `.buttonStyle(.peel(...))`; every text button but the small ones inside
  rows), with `buttonProgress`, the spinner inside a running button;
  `IconButton`, shadcn's icon button (ghost or outline, 28 or 24 square,
  `lit`, `working`; every icon button but the call window's control bar,
  controls over media and the composer's);
  `Panel`, shadcn's card in a popover (title, close, body, footer; 372 or
  320 `compact`; draws its own box, so the presenter adds none; every
  form's panel);
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
  https links, Browser and a tribe's second brain and app as More menu
  items);
  `Notifier` for local notifications and the Dock badge; `MoneyArrivals` for
  sats received: the header's count-up, the Payments row's "+350", one
  notification per arrival; `CallTestRoom`, the development-only LiveKit
  test room (phase 6, PR 3); `Offscreen` (the `-offscreen` check mode) and
  `OffscreenDriver` (its `-drive` script), see "Checking the app". PeelApp is the only target that links LiveKit
  and WebRTC)
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
  `ReadMarkerTests`, `ChatSectionsTests`, `RowIdTests`, `ThreadTests`, `SearchTests`, `MessageTests`,
  `MessageMarkupTests`, `MembershipTests`, `TribeTests`, `ContactsTests`,
  `EngineTests`, `EngineFailureTests`, `ConnectionDropTests`, `AutoResendTests`,
  `PublishPlanTests`, `HistoryCursorTests`, `PaymentTests`, `InvoiceTests`,
  `MoneyRefusalTests`, `PaymentTemplateTests`, `SatsTests`, `MediaTests`, `MediaInfoTests`,
  `IncomingFilesTests`, `CallTests`, `CallServerTests`, `CallWatchTests`,
  `NotificationPolicyTests`, `PersonHueTests`, `TimeZoneTests`, `PreferencesTests`, `PreferencesFileTests` (with a port of the official reader),
  `ServerAddressTests`, `WebTests`, `WebPageTests`, `GiphyTests`; the audits'
  `AuditInputTests`, `AuditMoneyTests`, `AuditNetworkTests` and
  `AuditSecretsTests`; `TestSupport` (shared fixtures)
- `Tests/PeelIntegrationTests/` — journeys through the real core against the
  local stack (opt-in, see Tests below): `Stack` (finds or starts
  `scripts/test-stack.sh`), `Person` (one account), `Bank` (where the sats
  come from), `Journeys` (runs them one at a time) and the journeys by area,
  `AccountJourneys`, `ContactJourneys`, `InviteJourneys`, `MessageJourneys`,
  `TribeJourneys`, `AttachmentJourneys`, `PaymentJourneys`, `HistoryJourneys`,
  `ReconnectJourneys`, `PreferencesJourneys`
- `scripts/test-stack.sh` (with `test-stack-helpers.py`) — starts the local
  stack the integration journeys use, on random ports; `tap` takes the
  wire tap down, up, or freezes it (a dead connection that looks open)
- `scripts/risk.sh` — ranks a branch's risk (low, medium, high) from the
  files it touches and its size; see "How a change ships"
- `scripts/build-ffi.sh` — assembles the bindings from sibling `sphinx-rs` and
  `sphinx-mac-v2` checkouts
- `scripts/bundle-app.sh` — builds the Mac app and wraps it as a signed bundle
  (default `.build/Peel.app`, or the path given), without installing it;
  embeds the frameworks the app loads through `@rpath` (LiveKit's
  `LiveKitWebRTC.framework`) in `Contents/Frameworks`
- `scripts/check-app.sh` — `bundle-app.sh` into `.build/PeelCheck.app`
  (bundle ID `dev.peel.mac.check`), then runs a drive file offscreen on a
  development profile (see "Checking the app")
- `scripts/run-app.sh` — `bundle-app.sh`, then installs to
  `~/Applications/Peel.app` and opens it from there (so a Dock pin survives rebuilds)
- `scripts/signing-identity.sh` — the identity both signing scripts use
- `scripts/sign-app.sh` — signs a bundle with the Apple Development identity,
  embeds a provisioning profile and the stub's entitlements (Keychain,
  microphone, camera), frameworks first (see Signing)
- `scripts/provision/` — an empty Xcode app whose only job is to make Xcode
  fetch a provisioning profile for Peel's bundle ID; `sign-app.sh` builds it
- `scripts/build-icon.sh` — compiles `Assets/AppIcon.icon` (edit it in Icon
  Composer) into `Assets/Assets.car` and `Assets/AppIcon.icns`; rerun after
  changing the icon. `Assets/peel.svg` is the flat logo for docs and pages

## Build and run

```sh
./scripts/build-ffi.sh      # once, and after the core changes
swift build
scripts/check-app.sh <dev> <drive file> <out dir>   # app: offscreen, see below
.build/debug/peel --profile <dev> listen             # CLI
```

`scripts/build-ffi.sh` checks the static library against `Vendor/sphinxrs.lock`
(sha256 plus the `sphinx-rs` commit); pass `--update` after deliberately taking a
new build of the core.

The app bundle is assembled by hand in `scripts/bundle-app.sh`; there is no
Xcode project for the app itself. To check a build without replacing the
installed app, `./scripts/bundle-app.sh /some/dir/Peel.app`.

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
  {"open": "account"}                     // the Account screen, as Account… (⌘,) opens it
  {"open": "payments"}                    // the Payments screen, as its sidebar row opens it
  {"key": "f", "mods": ["cmd"]}           // also return, escape, tab, space, delete, up, down, left, right
  {"type": "green"}
  {"wait": 0.5}
  {"snapshot": "search"}                  // search.png; open menus and panels as search-1.png, …
  ```

  Each step waits 300 ms for the UI to settle. Keys go into Peel's own
  event queue, so key monitors and shortcuts see them as typed; `keyCode`
  is real only for the US-layout letters, digits, punctuation and named
  keys above (other characters are sent with code 0). There is
  no mouse step: posted clicks do not reach SwiftUI's buttons in an app
  that is never active, so reach a control by its shortcut or add a
  named step like `select`.

## Signing and the weekly re-sign

The app keeps the words in the data-protection Keychain, which needs the
`keychain-access-groups` entitlement, which needs a provisioning profile. Tom
has a free Personal Team (team `T3M78XC3UV`, bundle ID `dev.peel.mac`, access
group `T3M78XC3UV.dev.peel.mac`), so:

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
- The entitlements are `scripts/provision/Provision.entitlements`: the access
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

## Tests

```sh
swift test      # needs the generated bindings, like swift build
```

`Tests/PeelCoreTests` uses Swift Testing and runs offline, each storage test in
its own temporary profile directory. It covers `StateCodec` round-trips and
malformed input; `Storage` commits (atomic state and settings), message upsert
(uuid dedupe, server fields from the later copy, cross-chat uuid rejection),
status by tag, read markers (server truth, pending, mark unread), contact alias/photo rules, the `conversations()` and
`timeline(in:)` first emission, and the profile lock; `Message` helpers;
`ServerAddress` parsing; and the `Engine` helpers that need no server
(mnemonics, invites, a fresh account); attachment encryption against an
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
names it, new contacts, the invite and add refusals, the price to join
held to the balance and the threshold); money when the connection goes
(`ConnectionDropTests`: a send that never left fails and may go again, one
cut short or dropped after a write stays pending, two Retries at once pay
once, and only a payment over half an hour old that the server never
recorded fails); refusals as typed
`Engine.Failure` cases with their words; and the whole migration chain from a v1
database, with the literals frozen into shipped migrations; and the audit's
adversarial inputs (`Audit*.swift`: seeded random and huge input to the
parsers, markup in linear time against a reference, link labels, names,
hosts, codes and the attachment cipher). Nothing talks to
a broker: anything protocol-level is still verified against the local test
server.

`Tests/PeelIntegrationTests` runs journeys through the real core against a
local stack that `scripts/test-stack.sh` starts on random ports (never 1883
or 8000); opt-in, see `docs/testing.md`:

```sh
PEEL_INTEGRATION=1 SPHINX_BIN_DIR=<cargo target>/debug swift test --filter PeelIntegrationTests
```

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

For the development test room (`Sources/PeelApp/CallTestRoom.swift`;
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
  records (type 33) are honoured only when signed by this account in newer
  cores; the one Peel links (`bd9e140`) honours a live one from anyone.
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
- Swift 6 language mode with strict concurrency in `PeelCore` and `PeelApp`.
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
  FormKit, `PeelButton`, `IconButton`, `Panel`, `MenuPresenter`, `PictureField`, `.menuAnchor`,
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
