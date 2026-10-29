# Phase 6 — Calls

Status: **PRs 1 to 4 merged** (the call link and message, #44; the ticket
and presence, #54; LiveKit in the bundle, #55; the card and header, #59);
PR 5 (the window, #64), PR 6 (screen share, focus, keep on top, #70) and
PR 7 (notifications, #74) merged; PR 8 (docs only) closed 2026-10-09, later work covered it. Calls are done. Finishing calls is first in the order Tom set on the
evening of 2026-10-08 (`../PLAN.md`). Plan and boards
C1 to C6 approved by Tom on 2026-10-08. The five defaults PR 1 used are
decided (Tom, 2026-10-08; see "Decided" below).

- Built: `CallLink` (`Sources/PeelCore/Call.swift`) reads the bare and the
  `call::` forms and validates them against the account's call server;
  `MessageType.call`; the `callServer` setting; `Engine.startCall(in:audioOnly:)`
  and `Engine.callLink(in:)`; CLI `call-start` and `--call-server`; tests in
  `Tests/PeelCoreTests/CallTests.swift`.
- Built (PR 2): `CallServer` (`Sources/PeelCore/CallServer.swift`):
  `Engine.callTicket(for:in:)` returns a `CallTicket`, and
  `Engine.callPresence(of:)` returns an `AsyncStream<CallPresence>`
  (`.unknown`, `.live([CallParticipant])`, `.ended`); CLI `call-ticket` and
  `call-who`; tests in `Tests/PeelCoreTests/CallServerTests.swift`.
- Built (PR 3): LiveKit **2.10.2** in `PeelApp` only (not 2.17: see the PR 3
  journal), `LiveKitWebRTC.framework` embedded and signed by
  `scripts/bundle-app.sh` and `scripts/sign-app.sh`, the microphone and
  camera usage strings and entitlements, and a development-only test room
  (`Sources/PeelApp/CallTestRoom.swift`).
- Built (PR 4): the timeline card and the header's call button
  (`Sources/PeelApp/CallViews.swift`), calls in chats, unread and the
  sidebar order, and a placeholder join window
  (`Sources/PeelApp/CallPlaceholder.swift`) until PR 5; see the PR 4
  journal.
- Built (PR 5): `CallSession` and `CallWindow` replace the placeholder;
  the on-a-call bar and the in-place switch confirm; see the PR 5 journal.
- Built (PR 7): a call someone starts is an ordinary message notification
  ("Started a call" under who started it), never a ring; see the PR 7 journal.
- Built (live-call indicator): the model watches each chat's newest
  recent call (at most eight across chats), so the sidebar's green phone
  shows on any tribe or DM with people on its call and a card shows its
  count at once after switching chats; see its journal.
- Built (floating call bar): a small always-on-top control bar shows while
  the call window is not key; see its journal.
- Built (Hive calls, 2026-10-27, waiting for Hive's route): with Stadeum
  connected, the call menu can bring Jamie into a call from one of the
  person's workspaces; see the journal below and `../hive-calls.md`. It
  reopens decision 5 (Tom's call).
- Open: the production check of PR 2 (Tom, through the app once PR 4 ships;
  see the PR 2 journal), PR 8 (the record); one mic-allowed run of the test room (PR 3
  journal); and moving LiveKit to latest once the core's UniFFI is upgraded.
- Decided in PR 1, done in PR 4: calls joined `shownInChats`,
  `unreadTypes` and the preview with the card.

Why now: calls are core messaging, not parity. Tom's team starts calls from
chats every day, and Peel cannot be his daily client without them (Tom,
2026-10-08).

What the official apps do (Tom's description, confirmed in the code below):
the call button creates a LiveKit room and posts a call message in the chat
or tribe. The message is a small card in the timeline that shows how many
people are on the call. Clicking it opens a separate call window.

Peel copies only what others can observe: the call message on the wire, the
room and token flow, and the call server's presence feed. Everything else
(the card, the window, when to notify, what to subscribe to) is designed
here. LiveKit only; Jitsi links open in the browser.

Line numbers are from the checkouts on disk on 2026-10-08 (`sphinx-mac-v2`
and `sphinx-ios-v2` last fetched 2026-10-05; `~/Documents/sphinx`). Android
is not on disk; its files are read from `stakwork/sphinx-android-v2` on
GitHub (default branch). Mac paths are under
`sphinx-mac-v2/com.stakwork.sphinx.desktop/`.

## Conventions (verified against the code)

### The call message

- **Type 32.** `TransactionMessage+CoreDataClass.swift:117` (`case call =
  32`); the core has the same value, `sphinx/src/msg/mod.rs:260` (`Call =
  32`).
- **The body is the ordinary message JSON** with the link in `content`, as
  for text: `formatMsg` adds nothing for `.call`
  (`SphinxOnionManager+ChatExtension.swift:117-128`). `replyUuid` and
  `threadUuid` are added as usual (`:182-183`), so a call can be started in
  a thread.
- **Two forms of `content` are in use:**
  - The Mac app sends the bare link: `sendCallMessage` passes the link as
    the text, with the JSON form commented out
    (`NewChatViewModel+SendMessageExtension.swift:179-191`).
  - iOS and Android send `call::{"link":"…","recurring":false,"cron":""}`,
    still as type 32:
    - iOS: `sphinx-ios-v2/.../ViewModel/NewChatViewModel+SendMessageExtension.swift:222-235`,
      through `VoIPRequestMessage.getCallLinkMessage()`.
    - Android: `SphinxCallLink.kt`, `newCallLinkMessage`; `CallLinkMessage.kt`,
      `MESSAGE_PREFIX = "call::"`; `ChatViewModel.kt:2735-2741`,
      `setIsCall(true)`.
  - Mac and iOS read both forms: `VoIPRequestMessage.getFromString` strips
    `call::` and parses the JSON, returning nil otherwise
    (`VoIPRequestMessage.swift:22-28`), and its callers fall back to the bare
    string (`WindowsManager.swift:570`, `getFromString(link)?.link ?? link`). **Android
    reads only the `call::` form for type 32**: `MessageDboPresenterMapper.kt:67-74`
    parses `content` as that JSON and `Message.isSphinxCallLink` (`Message.kt:338-347`)
    needs the parse to succeed. A bare link is a call on Android only as type 0.
    So a bare link from the Mac app probably shows on Android as no call at
    all. This is not checked on a device.
- **A call is also any text message whose content is a call link.** Mac
  `isCallLink()` is `type == 32 || content.isCallLink`
  (`TransactionMessageInfoGetterExtension.swift:470-472`); the string test is
  "starts with http and contains `/sphinx.call`" (`Extensions/String.swift:813-817`).
  Android does the same for type 0 (`Message.kt:340`).

### The link

- **Shape:** `https://chat.sphinx.chat/rooms/sphinx.call.<stamp>`, plus
  `?startAudioOnly=true` for an audio call (`Helpers/VideoCallHelper.swift:50-59`).
  - Mac and iOS use `Date.timeIntervalSinceReferenceDate`: seconds since 2001
    with a fraction, e.g. `sphinx.call.781603422.512` (Mac `:33`, iOS
    `Helpers/VideoCallHelper.swift:67`).
  - Android uses Unix milliseconds (`SphinxCallLink.kt`).
  - A tribe with a Hive or second-brain app puts the host in the name:
    `sphinx.call.-<host>-.<stamp>` (`VideoCallHelper.swift:52-54`). With a Hive
    swarm, the Mac app asks Hive for the link instead
    (`NewChatViewController+BottomTopBarsExtension.swift:612-657`,
    `API+HiveExtension.swift:423-455`). Those links can carry `callKey` or
    `hiveToken` (`String.swift:799-811`), which the token request passes on:
    the Mac app sends `callKey`, iOS sends `hiveToken`
    (`sphinx-ios-v2/sphinx/API/API+LiveKitExtension.swift:17`, `:28-30`).
- **The room name** is the path after `rooms/`, up to `?` or `#`
  (`String.swift:789-797`; Android `callRoom` is the same).
- **Audio or video** is only the `startAudioOnly` query flag
  (`VideoCallHelper.swift:18-26`). It changes how the card looks and
  whether the camera starts. It is not a property of the room.
- **The call server** is `https://chat.sphinx.chat`, which a user setting can
  override (`API/API.swift:100-120`, `meetingServerURL`). The public config
  endpoint does not name it: `config.config.sphinx.chat/api/config/bitcoin`
  returns only `tribe_host`, `router`, `default_lsp` and `lsps` (fetched
  2026-10-08). A link counts as LiveKit only when it contains the hard-coded
  `https://chat.sphinx.chat` (`String.swift:783-787`), whatever the setting.

### Token, presence and money

- **The token** comes from `GET <callServer>/api/connection-details?roomName=<room>&participantName=<alias>`
  (`API+LiveKitExtension.swift:23`). Optional parameters:
  - `metadata={"profilePictureUrl":"<url>"}` (`:25-28`)
  - `callKey` (`:30-32`); iOS sends `hiveToken` instead
  - `isHost=true` (`:34-36`)

  The response is `{"serverUrl", "participantToken"}` (`:54-56`): a LiveKit
  URL and a LiveKit access token (a JWT). iOS (`API+LiveKitExtension.swift:21`)
  and Android (`NetworkQueryPeopleImpl.kt`, `ENDPOINT_CALL_TOKEN`) call the
  same endpoint.
- **The token request has no authentication.** `createRequest` adds a
  Bearer header only when given a token, and this call passes none
  (`API.swift:243-271`). The interceptor passes requests through unchanged
  (`API.swift:274-284`). Nothing is signed with the account key; the core
  and the FFI have no call API at all (see below). **It costs no sats.**
- **Presence (the participant count)** comes from the call server, not from
  LiveKit:
  - A WebSocket at `wss://<callServer>/ws` (`CallParticipantsSocketManager.swift:30-39`),
    also without authentication. The client sends
    `{"action":"subscribe"|"unsubscribe","roomName":…}` (`:88-100`).
  - The server sends `current_participants` (with `participants`),
    `participant_joined` (`participant`), `participant_left` (`identity`)
    and `room_finished`, each with `roomName` (`:116-145`).
  - A participant has `identity`, `nickname` and `avatarUrl` (`:166-177`).
  - There is also `GET /api/participants?roomName=` with
    `[{nickname, avatarUrl}]` (`API+LiveKitExtension.swift:118-151`).

  Inside a call, the LiveKit room itself lists the participants.
- **Host extras**, which Peel leaves out:
  - The sender joins their own call as host (`joinIfCallMessage`,
    `NewChatViewModel+SendMessageExtension.swift:121-134`; `isHost` is
    "outgoing message", `NewChatTableDataSource+CellDelegateExtension.swift:786-810`).
    The host's token is kept as `adminToken` (`WindowsManager.swift:603`)
    and used as a Bearer for `POST /api/remove-participant`
    (`API+LiveKitExtension.swift:153-174`).
  - Recording is `GET /api/record/<action>?roomName=` with no auth at all
    (`:66-116`). It starts by itself when the tribe has a second-brain or
    web app (`NewChatViewModel+SendMessageExtension.swift:129`).
- **The call server's source is not public.** It is not on disk, and a code
  search of the `stakwork` org finds only the clients. So what the token
  grants, whether `isHost` is checked, the token TTL and how `identity` is
  chosen can only be read from a token. PR 2 decodes one.
- **The tribes server** forwards type 32 to members (`tribes/src/forward.rs:895`).
  It does not replay it to members who join or reconnect later
  (`type_to_replay`, `:850-864`), and it does not charge the price per message
  for it (`type_that_need_ppm`, `:866-878`; the check is at `:180-186`). The
  official app still pays a tribe's price plus escrow on a call message, as
  on text (`SphinxOnionManager+ChatExtension.swift:255-261`). Peel pays
  only the 3-sat floor on a call (`Tribe.messageAmountMsat(type:)`,
  decided, question 3).

### The official call window (what not to copy)

- It is LiveKit's example app with Sphinx changes (`Scenes/Dashboard/Live Kit/`:
  `ExampleRoomMessage`, an E2EE key store, `adaptiveStream` and `dynacast`
  toggles, `RoomContext.swift:80-101`).
- The window takes the main window's full frame (`WindowsManager.swift:674-690`).
- Joining another call leaves the first without asking (`WindowsManager.swift:572-576`).
- The chat header's live-call banner subscribes to presence for **every**
  call message ever posted in an open tribe, with no age limit
  (`NewChatViewController+LiveCallBanner.swift:34-75`;
  `TransactionMessageQueriesExtension.swift:923-937`).
- A screen share includes the Sphinx app's own windows
  (`RoomContext.swift:403-421`, `includeCurrentApplication: true`), so other
  chats can show in a shared screen.
- Neither app rings. iOS VoIP push is commented out (`sphinx-ios-v2/sphinx/AppDelegate.swift:89`,
  `:704-719`), so an incoming call is an ordinary message notification.

### Jitsi leftovers (out of scope)

Peel treats all of these as an ordinary link that opens in the browser:

- Mac: `API.kJitsiCallServer` (`API/API.swift:100`), `isJitsiCallLink`
  (`String.swift:777-781`), and the `JitsiCallWebViewController` branch of
  `showCallWindow` (`WindowsManager.swift:639-668`).
- iOS: `JitsiIncomingCallManager.swift` and the CallKit and PushKit code
  around it in `AppDelegate.swift`.
- Android: `DEFAULT_CALL_SERVER_URL = "https://jitsi.sphinx.chat"` in
  `SphinxCallLink.kt`.

### The core

There is no call-specific API. `MsgType::Call = 32` is an enum value
(`sphinx/src/msg/mod.rs:260`), and `sphinx/src/bindings/` never matches on
it. `sphinx-rs/sphinx-ffi/src/sphinxrs.udl` has nothing for calls or
LiveKit. It does have `sign_ms`, `signed_timestamp`, `sign_bytes` and
`sign_base64` (`:162-172`). An authenticated token endpoint could check
those signatures if Stakwork ever adds one.

## UX

Boards to add to the design canvas (row "Calls"), before PR 4. Nothing is
built for them yet:

| Board | What it shows |
|---|---|
| C1 Call card | The card in a flat row: live with 3 people, empty, ended, an old call, your own call while you are on it |
| C2 Header | The call button's menu (Audio call / Video call), and the header when a call is live in this chat ("Join · 3") |
| C3 Call window | The grid with 2, 4 and 1-plus-screen-share layouts; the control bar; the device menu |
| C4 On a call | The bar in the main window's sidebar while you are on a call |
| C5 Switching calls | The in-place confirm when you join a second call |
| C6 Notification | A DM call notification, as a message's (no Join, no ring: PR 7) |

### The call card (in the timeline)

- **A call is a row in the run**, like any message: the sender's photo,
  name and time open the run as usual. Under them is a 320 pt card, the
  width of a payment request card:
  - Line 1: a phone or video glyph, then "Audio call" or "Video call"
    (14 semibold).
  - Line 2: who is on it, with up to three 24 pt avatars overlapping as on
    boost chips, then "+N". Initials when there is no photo.
  - On the right, **Join** (filled accent).
- **The count is state, so colour shows only live:**
  - Live (one or more people): a small green online dot (`#49C998`) before
    "3 on the call".
  - Empty: "No one on the call" in secondary text. Join stays, because a
    LiveKit room opens again when someone joins.
  - Ended (`room_finished`): "Call ended" in secondary text, with Join.
  - Not known (no connection to the call server, or an old call): no count
    line at all. Never "0", because that would be a guess. No red anywhere.
  - On it yourself: "You're on this call" and **Open** (it brings the call
    window forward) instead of Join.
- **Presence only for live-looking calls.** A card subscribes only when it
  is on screen and its message is less than 12 hours old. It unsubscribes
  when it scrolls away or the chat closes. Older cards show the plain card
  with Join and no count. This is the fix for the official banner's habit of
  subscribing to every call a tribe ever had.
- **Avatars come cheap from the presence feed.** It carries `avatarUrl`,
  and the photo cache loads it, but only over `https` to a public host (see
  Security: anyone who can name the room sets that URL). Names in the feed are self-declared
  (anyone can join as "Tom"). The card shows them as given and never matches
  a participant to a contact by name.
- **More menu**: "Copy call link" (through `CopyFeedback`, with the
  `startAudioOnly` flag as sent), "Join with video" or "Join audio only"
  (the other mode), and Reply and Thread as on any message.
- **Links Peel does not open itself** render as an ordinary link in the
  row, never as a call card. Clicking one asks before opening the browser,
  as other links do. This covers a Jitsi link, a call link on another host,
  and anything that fails validation (see Security).

### Starting a call

- The header's call button (already in the design, `design/README.md`
  "Conversation") opens Peel's menu with "Audio call" and "Video call"
  (shortcuts ⌥⌘A and ⌥⌘V, which nothing in Peel uses yet). There is no
  confirmation. The call is free in a DM, and costs 3 sats in a tribe
  whatever its price (decided, question 3).
- Starting a call sends the message and opens the call window at once, with
  the mic on. A video call also turns your camera on; an audio call does not.
- **When a call is live in this chat**, the call button becomes "Join · 3"
  with the green dot. Clicking it joins the newest live call instead of
  starting another. "Start a new call" stays in its menu. This replaces the
  official app's banner under the header.

### The call window

- **A separate window**, one call at a time. It opens at 960 × 640, then
  wherever you last left it. The title is the chat's name ("#tribe" or the
  contact) and a running time. Closing the window (⌘W) leaves the call.
- **The grid**: one tile per participant with their video or, without
  video, their photo on the conversation background. Name in the corner.
  The tile edge lights in the accent colour while that person speaks. A
  screen share takes the main tile and the people move to a strip.
- **Controls**, a bar at the bottom with padding all round, as SF Symbols
  with tooltips and shortcuts:
  - Mute (⌘⇧A) and Camera (⌘⇧V). Each has a chevron that opens the device
    menu (microphone, speaker, camera).
  - Share screen (⌘⇧S).
  - Leave, the only red control (it ends something). Leave needs no
    confirmation.
- **Starting state**: mic on and camera off when you join someone else's
  call, whatever the link says. A video call only puts the camera button
  first. Joining with your camera on unasked is the habit to avoid.
- **Permissions on first use**: macOS asks for the microphone on the first
  join and for the camera on the first camera turn-on. If access was
  refused, the control is disabled and a quiet line under the bar says "Peel
  can't use the microphone · Open System Settings".
- **Joining a second call** turns the Join button into an in-place confirm
  next to it: "Leave the call in #design and join?". It never leaves
  silently.
- **Recording indicator only**: tribe calls are recorded by the call
  server (egress), and everyone on the call must be told. The room's
  `isRecording` (from its metadata) shows a pulsing red "Recording" in the
  title bar and on the sidebar's bar, and a 5-second toast when it starts
  ("Recording in progress. Please be aware this call is being recorded.")
  and when it ends. Peel has no control to start or stop a recording. The
  words are `RecordingNotice` (`Sources/PeelUI`); the views are
  `RecordingIndicator` and `RecordingToast` in `Apps/Shared/UI/`, with no
  LiveKit, so the iPhone gets them once it can join calls.
- **Out of v1**: recording controls, removing participants, in-call chat, E2EE (the
  official apps would not be able to join), reactions, and background blur.

### On a call (the main window)

- While you are on a call, a bar at the bottom of the sidebar shows the
  chat's name, the time, Mute, and "Return to call", like a Slack huddle
  bar. The call stays visible even when its window is behind others.

### Incoming calls

- **A notification, not a ring** (Tom, 2026-10-08: "We definitely don't
  want a ring … It should just be like a Tribe message, and then you view
  it in the Tribe."). Neither official app rings. Someone else's type 32
  whose link passes `CallLink` validation, at most ten minutes old
  (`CallLink.notifyAge`; the card's 12-hour live window is separate, so a
  Mac waking hours later never announces a call long over), posts through
  `Notifier` like a message, on the same arrivals (live, or a catch-up
  after the first history; never a restore). A type 32 with any other
  link, and text that is only a call link, is never announced as a call.
  - The body is "Started a call". The title names who started it, and in
    a tribe the subtitle names the tribe ("#design"), as for a message.
  - Both follow the chat's notification level: a call mentions nobody, so
    muted and mentions-only chats stay quiet.
  - Clicking the notification opens the chat at the card, as a message
    notification opens its message. It never joins; you join from the card.
- No Join action, no ring, no sound beyond a message notification's, no
  call window or full-screen prompt, and no missed-call state. The card
  already says who is on the call.

## Engine and app split (agent-native)

```
┌───────────────────────────── PeelApp ─────────────────────────────┐
│ CallCard · header button · CallWindow · on-a-call bar · Notifier   │
│ CallSession (@MainActor): owns the LiveKit Room, tracks, devices, │
│ screen capture. The only code that imports LiveKit.                │
└──────────────▲───────────────────────────────▲────────────────────┘
               │ CallTicket (url + token)      │ presence stream
┌──────────────┴─────────── PeelCore ──────────┴────────────────────┐
│ Call.swift: CallLink (parse both forms, validate, make room names) │
│ Engine.startCall(in:audioOnly:) → sends type 32 via deliver        │
│ Engine.callTicket(for:in:) → GET /api/connection-details           │
│ Engine.callPresence(of:) → AsyncStream<CallPresence>               │
│ CallServer: one URLSessionWebSocketTask per engine, ref-counted    │
└───────────────────────────────────────────────────────────────────┘
```

- **The engine owns the call message, the link, the token and presence.**
  These are protocol: an agent can start a call in a DM, read who is on it,
  or hand a ticket to a media runtime. All of it stays in PeelCore with no
  UI types, no globals, and one `CallServer` per engine (multi-account).
  - Presence uses Foundation's `URLSessionWebSocketTask`, not Starscream:
    a WebSocket client is under a hundred lines on top of it.
  - Every call-server request (the ticket, `/api/participants` and the
    WebSocket) uses its own ephemeral `URLSession` with `urlCache = nil` and
    no cookies, and refuses redirects, as `MemesServer` does
    (`MemesServer.swift:54-69`). Never `URLSession.shared` (used today by
    `Tribe.swift:306`, `ServerConfig.swift:20`, `MainView.swift:925`), which
    would write the token response to `~/Library/Caches/dev.peel.mac/Cache.db`
    and keep the call server's cookies. PR 2 tests that `URLCache.shared`
    holds nothing after a ticket fetch.
  - The call server is an account setting (`callServer`, as `host[:port]`
    like the memes and tribes hosts, default `chat.sphinx.chat`), with a CLI
    `--call-server` flag for local tests. https always, except plain http
    for a loopback host (`TribeLink.baseURL`). An account on a local test
    server has no call server until one is named, as with the memes
    server, so local tests never make production links.
- **The app owns media.** The LiveKit SDK and WebRTC link into `PeelApp`
  only, never `PeelCore`, so the CLI and a future agent host do not carry
  WebRTC. `CallSession` takes a `CallTicket` and nothing else from the
  engine.
- **Storage.** Type 32 rows are already stored like any message (raw body,
  `content`). Nothing needs a new column:
  - `MessageType.call = 32` exists since PR 1. It joins `shownInChats`,
    `unreadTypes` and the preview ("Video call" or "Audio call") in PR 4,
    with the card: until then the app would draw a type 32 row as a
    membership note ("Alice joined").
  - No migration reads `shownInChats` or `unreadTypes` (v11 reads
    `payments`, v13 `moneySends`), so this needs no migration. Calls must
    not join `payments`, `content` or `resendable`. The first two feed
    migrations and partial indexes built from live constants (review,
    `2026-10-08-architecture.md:228-234`), and a call is never sent again
    blindly, because the room would be stale.
- **Tokens are never stored.** A `CallTicket` lives in memory for one join.
  It is never logged, never written to SQLite or the URL cache (the session
  above), and never shown in the app. Call-server errors are shown without
  their failing URL, because a `URLError`'s description includes the full
  query (`callKey`, `hiveToken`).
- **CLI** (development profiles only):
  - `call-start <chat> [--audio]` prints the link (PR 1). `listen` marks
    each incoming call message as a valid call (audio or video, and the
    room) or "not a call link on this account's call server".
  - `call-who <message id | link>` prints presence for a few seconds.
  - `call-ticket <message id | link>` prints the server URL, room, identity,
    expiry and admin grant from the token's claims, and whether a token
    came. It never prints the token itself.

## Token and auth flow

1. **Start**: `startCall` validates the configured call server, makes
   `sphinx.call.<32 hex chars>` (16 bytes from `SystemRandomNumberGenerator`,
   the system's secure generator, as for the words) and builds
   `https://<server>/rooms/<room>` (with `?startAudioOnly=true` for audio).
   It sends it as type 32 through `deliver`, in the `call::` JSON form or
   the bare form (open question 1). The `sphinx.call.` prefix stays because
   every client detects calls by it (`String.swift:813-817`; Android's
   `REGEX`).
2. **Join**: `callTicket(for:)` parses the stored link and checks it. Then
   it calls `GET <configured server>/api/connection-details` with:
   - `roomName` from the link
   - `participantName`: the alias this chat knows you by, so your tribe
     alias in a tribe
   - `metadata`: your photo URL
   - `callKey` and `hiveToken` if the link has them (Hive calls)

   Never `isHost`. The request goes to the configured server, never to a
   host taken from the message.
3. **Check the answer**: `serverUrl` must be `wss://` (`ws://` only on a
   loopback call server, for local tests) on an exact host from a short
   list kept with the call server setting (the call server's own host and
   the LiveKit host PR 2 records). Exact hosts, never a suffix match: a
   `*.livekit.cloud` rule would admit any LiveKit tenant. This catches a
   server bug or misconfiguration, not a hostile configured server, which
   picks the SFU anyway. The JWT is decoded without verifying its signature
   (Peel has no key; the SFU verifies it). Its `video.room` must equal the
   room asked for. `exp` and `sub` (identity) are read for
   the UI. A mismatch is an error and nothing connects.
4. **Connect**: the app gives `serverUrl` and the token to LiveKit. Media
   goes over DTLS-SRTP to LiveKit's SFU.
5. **Presence**: `callPresence(room:)` sends `subscribe` on the engine's one
   socket. It reconnects with backoff and subscribes again, and sends
   `unsubscribe` when the last listener goes.

### Security concerns

- **The room name is the only secret.** Anyone who knows it can get a token,
  join, and read presence: the endpoints above have no account
  authentication, and the call server cannot tell who is asking.
  - Official room names are timestamps (Mac to the microsecond, Android to
    the millisecond), so they are guessable from when a call started.
  - Peel's room names carry 128 random bits.
  - A call link is still a bearer capability: everyone who can read the
    message can join, which in a tribe means every member and the tribes
    server operator.
  - The card's More menu says "Anyone with the link can join" beside Copy.
- **Names on a call are self-declared** (`participantName` is whatever the
  client sends), so anyone can join as "Tom". Peel never treats a
  participant name as an identity. An open question asks whether to put the
  account's pubkey in `metadata`, which others could see but not verify
  without server support.
- **`isHost=true` is asked for by the client.** If the server honours it
  (PR 2 checks the token's grants), any client can get room-admin rights for
  any room it can name. Recording is open to anyone by room name. Both are
  server issues to report to Stakwork, not things Peel works around. Peel
  never asks for host.
- **What leaks to the call server**:
  - Your alias, photo URL and IP on every join, in a GET query string, so
    likely in its access logs.
  - Your IP, and which rooms you are watching, on every presence subscribe.
  - Keeping presence to on-screen cards under 12 hours old limits the second
    leak. Since the live-call indicator, each chat's newest recent call is
    watched too, at most eight, and none while locked (see its journal).
  - The SFU sees all media: calls are not end-to-end encrypted, here or in
    the official apps.
- **A hostile call message** cannot steer Peel elsewhere:
  - The link must be `https` (plain `http` only when the configured call
    server is itself loopback, exactly `127.0.0.1`, `localhost` or `::1`,
    `ServerAddress.isLoopback` in `Transport.swift:37-39`, as
    `MemesServer.redirect` uses it, `MemesServer.swift:62`). Its host,
    parsed from URL components rather than substring-matched (the official
    check is `contains`, `String.swift:783-787`), must equal the configured
    call server's host, with a room matching `^sphinx\.call\.[A-Za-z0-9._-]{1,128}$`.
  - Only known query keys are kept (`startAudioOnly`, `callKey`,
    `hiveToken`).
  - Anything else is a plain link that asks before opening the browser.
  - The token request is built from the parsed room, never by pasting the
    link, so a room cannot inject query parameters. `callKey` and
    `hiveToken` are percent-encoded strictly (`+` as `%2B`; `URLQueryItem`
    leaves `+` alone).
  - `serverUrl` is checked before any media connects (step 3 above).
- **Participant photos are attacker-chosen URLs.** `avatarUrl` in the
  presence feed and `profilePictureUrl` in LiveKit metadata are whatever the
  joiner sent in `metadata`, and joining needs only the room name. Today
  `PhotoCache` fetches any URL with `URLSession.shared` (`MainView.swift:917-929`),
  so a joiner could make every viewer of the card fetch
  `http://192.168.1.1/...` or a tracking URL. Call photos are fetched only
  over `https`, never from an IP literal, loopback or `.local` host, through
  an ephemeral session. (Sender photos on messages have the same gap; worth
  the same fix, outside this phase.)
- **The token is a bearer credential** until it expires. It stays in
  memory, out of logs (LiveKit's OSLog level is set to `warning` so the
  SDK never logs connect URLs), and out of the CLI.
- **Screen sharing can show other chats.** Peel leaves its own windows out
  of a display share, except the call window (the opposite of the official
  `includeCurrentApplication: true`). The system picker lets you choose a
  single window. Not yet proven: a filter the picker returns cannot be
  edited afterwards, and building one that excludes Peel's windows needs
  `SCShareableContent`, which needs the Screen Recording permission. PR 6
  names the mechanism (for example
  `SCContentSharingPickerConfiguration.excludedWindowIDs`) and tests it; if
  none works, display shares warn that Peel's windows are included.
- **Money**: a call message in a paid tribe pays only the 3-sat floor
  (decided, question 3). The official app pays the price plus escrow,
  which the tribes server does not ask for and probably never refunds the
  escrow part of, because the stake timer is only set for priced types
  (`forward.rs:187-211`).

## LiveKit on macOS

- **SDK** (PR 3 pins **2.10.2**, not 2.17; see the PR 3 journal):
  `livekit/client-sdk-swift`, latest **2.17.0** (2026-09-14). Its
  manifest is `swift-tools-version:6.1` with macOS 10.15 as the minimum,
  and the README says it is "compiled using Swift 6.1 with full support for
  strict concurrency" (no `@preconcurrency` needed). The local toolchain is
  Swift 6.4. The official Mac app is on 2.8.1 with WebRTC 137
  (`sphinx.xcworkspace/xcshareddata/swiftpm/Package.resolved:25-29`,
  `:293-299`), so 2.17 is a newer client against the same server. LiveKit
  keeps the protocol compatible, but PR 3 checks.
- **Its dependencies are binaries:**
  - `webrtc-xcframework` 150.7871.02, which its manifest calls the
    "LK-Prefixed Dynamic WebRTC XCFramework"
  - `livekit-uniffi-xcframework` 0.1.9 (`RustLiveKitUniFFI`, a Rust
    library)
  - a `PrivacyInfo.xcprivacy` resource
- **Effects on the hand-built bundle** (`scripts/bundle-app.sh` copies the
  executable, the icon and `Assets.car`, `:13-16`, and no frameworks or
  resource bundles):
  - `LiveKitWebRTC.framework` (and `RustLiveKitUniFFI` if it is dynamic) has
    to go into `Contents/Frameworks` with an
    `@executable_path/../Frameworks` rpath (`install_name_tool -add_rpath`).
    It is signed with Peel's identity before the app (inside out), because
    hardened runtime's library validation rejects a framework signed by
    another team. The alternative, the
    `com.apple.security.cs.disable-library-validation` entitlement, is not
    worth it.
  - SwiftPM's resource bundle (`LiveKit_LiveKit.bundle`) goes into
    `Contents/Resources`. A bundle at the app's root breaks `codesign
    --strict`. Check whether LiveKit reads it at run time at all (it holds
    only the privacy manifest).
  - Peel now links two Rust static libraries (`sphinxrs` and, if static,
    LiveKit's UniFFI). Check for duplicate Rust runtime symbols at link time.
  - Expect the app to grow by tens of MB, mostly WebRTC. Measure it in PR 3.
- **Permissions and entitlements.** Peel is signed with hardened runtime and
  the stub's entitlements (`scripts/sign-app.sh:91-96`), and it is not
  sandboxed. So:
  - `Info.plist` (the heredoc in `bundle-app.sh:17-35`) needs
    `NSMicrophoneUsageDescription` and `NSCameraUsageDescription`. macOS
    kills the app on first access without them.
  - The entitlements need `com.apple.security.device.audio-input` and
    `com.apple.security.device.camera`. Hardened runtime blocks the devices
    without them, even after the user allows access. These are not App ID
    capabilities, so the free Personal Team profile allows them and no new
    App ID is used (the 10-a-week limit is safe).
  - Add the two entitlements to `scripts/provision/Provision.entitlements`.
    `sign-app.sh` signs with what the stub was signed with (only with an
    identity: the ad-hoc path, `sign-app.sh:32-35`, signs the outer bundle
    with no entitlements and no nested frameworks, so `bundle-app.sh`
    refuses to bundle LiveKit ad hoc), and its
    freshness check (`stub_is_current`) looks only at the app ID,
    certificate and expiry. So the stub must be rebuilt once after the
    change: teach the check to compare the entitlement keys too.
  - Screen recording needs no entitlement, only the TCC permission "Screen
    & System Audio Recording". macOS 15 re-asks apps that use it
    periodically. LiveKit's macOS capturer (`MacOSScreenCapturer`) lists
    `SCShareableContent` sources, which needs that permission. Only its iOS
    capturer uses `SCContentSharingPicker`. The plan is the system picker
    (macOS 14+): its chosen filter feeds an `SCStream` whose frames go to
    LiveKit's `BufferCapturer` (`createBufferTrack`). Picker-chosen content
    needs no standing permission. If that turns out flaky, fall back to
    `MacOSScreenCapturer` and the permission.
  - TCC grants stick to the code signature's designated requirement. With
    the Apple Development identity and a fixed bundle ID they survive
    rebuilds and the weekly re-sign. An ad-hoc-signed build (no identity)
    is asked again on every build.
- **Testing without production calls**:
  - Run `livekit-server --dev` locally (devkey/secret).
  - Add a throwaway token stub for `/api/connection-details`, `/api/participants`
    and `/ws`, outside the repo, like the local memes stub (`AGENTS.md`,
    "Local memes server").
  - Use two development profiles and two Peel instances on
    `--call-server 127.0.0.1:<port>` (plaintext only for loopback,
    `ServerAddress.isLoopback`).
  - On production, only token and presence with the throwaway account on a
    fresh random room. No media and no real account, until Tom says
    otherwise (open question 6).

## PR breakdown

Each PR goes through the shipping chain in `AGENTS.md` (code-review,
simplify, security-review) and updates this file.

0. **First, the cleanup** (Tom's order): #30 and #31 and the review's
   other fixes. PR 1 does not depend on them technically: it touches no
   list a migration reads. (#30 and #31 merged. Since the evening of
   2026-10-08, calls come first and the rest of the cleanup later:
   `../PLAN.md`.)
1. **Engine: the call link and message.**
   - `Call.swift`: `CallLink` parses the bare form, the `call::` JSON form,
     Hive `-host-` rooms, `callKey`, `hiveToken` and `startAudioOnly`, validates, and
     makes random room names.
   - `MessageType.call`, the `callServer` setting, and `Engine.startCall`.
   - CLI `call-start`, and `listen` showing calls (`messages` shows them
     from PR 4, when they join `shownInChats`).
   - Tests: every form above, Jitsi links, foreign hosts, injection in room
     names, Android and Mac room stamps.
   - Verify: alice and bob on the local stack, in a DM and a tribe (forwarded,
     not replayed). Read the official Mac app's rendering of a Peel call
     only if Tom has a dev build against the local server.
2. **Engine: ticket and presence.**
   - `CallServer` (HTTP, and the WebSocket on `URLSessionWebSocketTask`),
     `Engine.callTicket(for:)`, `Engine.callPresence(room:)`, and the JWT
     claim checks.
   - CLI `call-ticket` and `call-who`.
   - One ephemeral, cache-less, cookie-less session that refuses
     redirects; a test that `URLCache.shared` stays empty; errors shown
     without their URL.
   - Verify against the local stub. Production (Tom, 2026-10-08): no
     production request from the build session; Tom checks the token and
     presence himself through the app once PR 4 ships, and records the
     token's grants (`roomAdmin`), TTL, identity scheme and the `serverUrl`
     host in this file.
3. **Build: LiveKit in the bundle.**
   - The dependency on `PeelApp` only. `bundle-app.sh` embeds and signs the
     frameworks. Add the Info.plist usage strings, the entitlements, and the
     stub freshness check.
   - A hidden development menu item, "Join test room", connects to the local
     `livekit-server`.
   - Check the duplicate Rust symbols, the bundle size, `codesign --verify
     --strict`, and a launch from `.build` with `-profile <dev>`. Never
     `run-app.sh`.
4. **App: the call card and header.**
   - `CallCard` with presence (the visible, under-12-hours rule), the
     header button and its menu, "Join · N", the More menu items, and the
     plain-link fallback. Participant photos only over `https` to public
     hosts, through an ephemeral session.
   - Boards C1 and C2 first.
5. **App: the call window.**
   - `CallSession` and `CallWindow`: the grid, speaking edge, mute, camera,
     device menus, leave, the shortcuts, one call at a time with its
     in-place confirm, the on-a-call sidebar bar, and the permission-refused
     lines.
   - Verify: two dev profiles on the local LiveKit.
6. **App: screen share.**
   - The system picker with `SCStream` and `BufferCapturer`, Peel's own
     windows left out of display shares, and the main-tile layout.
7. **Notifications.** No ring (Tom, 2026-10-08): see "Incoming calls".
   - A type 32 from someone else, at most ten minutes old, posts through
     `Notifier` like a message ("Started a call"), following the
     chat's level, only when its link passes `CallLink` validation. A click
     opens the chat at the card; no Join action.
8. **Record.** Update `AGENTS.md` (layout, the local LiveKit stack),
   `docs/design/README.md` (Calls section, status), `docs/PLAN.md`, and this
   file.

PRs 1 and 2 can be reviewed without any media. PR 3 is the risky one for
the build, so it lands before any UI depends on it.

## Reviews of this plan (2026-10-08)

- `/code-review` on the citations: iOS sends the `call::` form (not the
  bare link), iOS passes `hiveToken`, the migration freeze is not a
  technical blocker, the loopback rule was missing, and `bundle-app.sh` also
  copies the icon. All fixed above.
- `/security-review` of the token flow: call-server requests must use an
  ephemeral cache-less session (the token would otherwise land in
  `Cache.db`), and participant photo URLs are attacker-chosen. Both are now
  in the plan, with the `serverUrl` rule made exact, the ad-hoc signing
  path handled, and notifications gated on validation. Below the bar and
  left as PR 6 work: whether the system picker can exclude Peel's windows.
- `/simplify` skipped: the diff is docs only.

## PR 1 journal (2026-10-08)

- **Built** as planned, in the engine and the CLI only: no LiveKit, no
  token fetch, no UI, no migration (the setting is a new key in the
  `setting` table).
- **Validation** (`CallLink.init?(link:server:)`): the configured server's
  scheme, exact host (from URL components, never a substring) and port
  (443 written or not); no user, password or fragment; the path exactly
  `/rooms/<room>` read percent-encoded, so `%2F` and friends never pass;
  the room as in Security; only `startAudioOnly`, `callKey` and
  `hiveToken` kept, each at most once; `callKey` and `hiveToken` limited
  to base64, base64url and JWT characters, at most 2 KB; content at most
  4 KB. `url` and `message` are rebuilt from the parsed parts, with query
  values encoded to unreserved characters (`+` as `%2B`).
- **Reading**: `Engine.callLink(in:)` reads a type 32, or a text message
  whose whole content is a call link (the Mac app's rule). A deleted one
  is no call.
- **Price**: `Tribe.messageAmountMsat(type:)` gives a call the 3-sat floor,
  and `deliver` asks it for every type. `resend`'s price check and
  `sendToTribe` (joins and leaves) still use the full price; neither ever
  sends a call.
- **Starting** needs a connection (`notConnected` otherwise) and a contact
  or tribe (`notAChat`), because a call message is never sent again: a
  failed one stays a failed row, unseen until PR 4 decides what the card
  shows for it. `startCall` returns the tag so the app can follow its send
  status.
- **Verified on the local stack** (broker 1895, tribes 8825, mixer 8025,
  call server `127.0.0.1:7880`, which nothing listens on: PR 1 makes no
  requests), profiles `cl-alice`, `cl-bob`, `cl-carol`:
  - DM: alice starts a video and an audio call; both deliver and bob's
    `listen` shows each as a valid call with its room and mode.
  - Tribe priced at 10 sats plus 5 escrow: bob's call is stored with 3,000
    msat and delivered (the tribes server forwards it to alice), his text
    with 15,000 msat. Alice, the owner, starts an audio call; bob sees it.
  - Not replayed: carol joins afterwards and gets bob's text replayed but
    neither call.
- **Not checked**: how the official Mac, iOS and Android apps render a Peel
  call (needs a dev build on the local server, or production).
- **Reviews**: `/code-review` (high): `startCall` now needs a connection
  and a contact or tribe, and returns the tag; `callLink(in:)` returns nil
  rather than throwing with no call server; price wording fixed above.
  `/simplify`: the base URL is kept once in `CallLink`, the token check is
  folded into the query loop, the character set is built once.
  `/security-review` (link validation): no findings at confidence 8 or
  above. Not applied, with reasons:
  - `--call-server` is applied after `Account.load` rather than threaded
    through `Account` like `--memes-host`: no UI sets it before PR 4, and
    threading it touches every `Account` entry point.
  - No shared "setting, else default, none on loopback" helper for the
    memes and call servers, and no shared hex helper: small, and it would
    touch code outside this PR.
  - The call server is read from SQLite per `callLink(in:)`: one small read,
    and only the CLI calls it today; PR 2's `CallServer` value can cache it.
  - A `MessageType.priced` set mirroring the tribes server's
    `type_that_need_ppm`: only calls differ today.
  - `callKey` keeps a literal `+` (as `URLComponents` and the Mac app read
    it) and is sent as `%2B`; PR 2 checks this against a Hive link.

## PR 2 journal (2026-10-08)

- **Built** in the engine and the CLI only (no LiveKit, no UI, no
  migration). `CallServer` is an actor, one per engine, made again when the
  `callServer` setting changes (`setCallServer` closes the old one).
- **The ticket** (`callTicket(for:in:)`): `GET /api/connection-details` on
  the configured server only (a link on any other server is refused), with
  `roomName`, `participantName` (the tribe alias in a tribe, else the
  alias), `metadata` `{"profilePictureUrl":…}` when there is a photo (no
  pubkey), and `callKey` / `hiveToken` as the link carries them. Never
  `isHost`. Query items are built from parts, each value encoded to
  unreserved characters. A static ephemeral session with no URL cache and
  no cookies, which follows no redirect (a 3xx is a refusal), and a 64 KB
  limit. Errors are `CallServer.Failure` and never carry the URL.
- **The answer is checked** before anything connects:
  - `serverUrl` is `wss://` (or `ws://` only when the call server is
    loopback) on the call server's own host and port, or on one recorded
    for it in `CallServer.mediaHosts`; no user, password, query or fragment.
  - The JWT is decoded unverified: exactly three parts, at most 8 KB;
    `video.room` must be the room asked for, `exp` in the future, and `sub`
    1 to 256 bytes with no control characters. `video.roomAdmin` is read
    and reported.
  - `CallTicket` prints, dumps and reflects without its token.
- **`mediaHosts` was empty** until Tom's production check named the
  LiveKit host (`livekit.sphinx.chat`, recorded 2026-10-12). Until then a production ticket whose `serverUrl` is not on
  `chat.sphinx.chat:443` itself fails with `mediaHostNotAllowed(host)`,
  whose text is "the call server named a media server Peel does not know
  (`<host>:<port>`)". The host is shown only when it is plain letters,
  digits, dots, dashes and colons. In the app (PR 4) Join shows that text
  quietly beside the button (no red) and nothing connects; in the CLI,
  `call-ticket` prints it as the error. The fix is one line: add the host
  to `CallServer.mediaHosts["chat.sphinx.chat"]`.
- **Presence** (`callPresence(of:)`): one `URLSessionWebSocketTask` on
  `wss://<server>/ws` (`ws` on loopback), with its own session (no resource
  limit; a ping every 30 seconds keeps a quiet feed open and drops a dead
  one). The first listener for a room sends `subscribe`, the last one to
  stop sends `unsubscribe`, and the socket closes when no room is left. A
  drop sets every room to `.unknown` and reconnects after 1, 2, 4 … 30
  seconds, subscribing all rooms again.
  - Messages are read as the Mac app reads them (`current_participants`,
    `participant_joined` nested or flat, `participant_left`,
    `room_finished`), each for a valid room this socket asked for.
  - A join or leave before the first list is ignored; a list is
    de-duplicated by identity; a join after `room_finished` opens the room
    again; at most 500 participants.
  - Names lose control characters and are cut at 100 characters;
    identities with control characters are dropped (a leave matches them
    exactly); `avatarUrl` is kept only when `Web.isPublic` passes.
- **`+` and `%2B`, settled from the official apps' code.** The Mac app
  reads `callKey` with `URLComponents.queryItems` (`String.swift:806-811`)
  and sends it through `urlEncode()` (`API+LiveKitExtension.swift:30-32`),
  whose allowed set leaves out `+`
  (`Libraries/SocketIO/Util/SocketExtensions.swift:40-42`, `:127-129`); iOS
  does the same with `hiveToken` (`API+LiveKitExtension.swift:28-30`,
  `Extensions/String.swift:1309-1311`). So a `+` goes out as `%2B` and the
  server reads `+`, which is what Peel sends. A bare `+` would be read as a
  space by form decoding. In practice it never arises: Hive's
  `generate-link` makes `callKey` from 12 random bytes in hex
  (`hive/src/app/api/workspaces/[slug]/calls/generate-link/route.ts`), and
  `hiveToken` is a JWT (base64url).
- **Verified against a local stub** (HTTP and WebSocket, outside the repo,
  on a free loopback port; profile `ct-alice` on the local stack):
  - The stub received `participantName=Al%20ice%2B1`, the metadata JSON
    fully encoded and `callKey=ab%2Bc%2Fd%3D`, and decoded each exactly;
    no cookie came back although the stub set one on every reply.
  - By message id in a local tribe, the tribe alias was sent.
  - Refused with a clean error: a foreign media host, a token for another
    room, an expired token, and a 302 (not followed). With the server down
    the error is "the call server did not answer", without the key.
  - Presence: `.unknown`, the list, a join, a leave, then ended; an
    escape character stripped from a name; avatars on `192.168.1.1` and
    `127.0.0.1` dropped; another room's message ignored; `unsubscribe` and
    a 1000 close at the end. Killing and restarting the stub went to
    `.unknown`, then reconnected and subscribed again. A quiet feed stayed
    open 100 seconds with pings every 30.
  - The CLI's URL cache was not written.
  - Nothing contacted production.
- **Reviews**: `/code-review` (high): the socket got its own session and
  pings (a 30-second resource limit would have cut it); identities with
  control characters refused, in the feed and in `sub`; a list
  de-duplicated; the CLI's sleep before close removed; no call requests
  after `close`; a new room no longer skips the backoff. `/simplify`: the
  ticket takes the `CallLink`; `withoutControlCharacters` reused; static
  sessions; the ping task kept and cancelled; fewer lookups.
  `/security-review` (token, allowlist, logging): no findings at
  confidence 8 or above. Not applied, with reasons:
  - Moving `MemesServer.Transfer` and a neutral HTTP error into `Web`, and
    one JWT payload helper shared with `MemesServer.Token`: both touch the
    memes code outside this PR.
  - A `myAlias(in:)` helper shared with `deliver`: Engine is being edited
    by other sessions; small.
  - Caching the call server setting in memory: one small read per ticket
    or presence call.
  - A one-shot "who is on it now" engine op: PR 4's card uses the stream.
  - IPv6 loopback call servers compare brackets inconsistently and are
    refused; none is used.

## PR 3 journal (2026-10-08)

- **Why 2.10.2, not 2.17.0.** From 2.11.0 (2026-01-12, "Integrate UniFFI")
  LiveKit depends on `livekit-uniffi-xcframework`, a Rust library whose C
  header defines `struct RustBuffer` with `uint64_t capacity, len`. The
  core's `sphinxrsFFI.h`, from an older UniFFI, defines it with `int32_t`.
  Both sit behind the same guard (`UNIFFI_SHARED_HEADER_V4`; UniFFI never
  bumped it), so any Swift file that sees both clang modules fails to
  compile ("'RustBuffer::capacity' from module 'RustLiveKitUniFFI' is not
  present in definition of 'struct RustBuffer' in module 'sphinxrsFFI'").
  This is a header clash, not a link one: the library is dynamic and none
  of its 374 exported symbols is among the 996 that `libsphinxrs.a`
  defines.
  - `internal import Sphinxrs` in `Engine.swift` and `Invoice.swift` does
    not help: PeelCore builds, but clang still loads `sphinxrsFFI` into
    PeelApp.
  - 2.10.2 (2025-12-15) is the newest release without the UniFFI library.
    The official Mac app ships 2.8.1 with the same core, so the pairing is
    proven. It brings WebRTC 137.7151.10 (the official app's is 137) and,
    statically, `swift-protobuf`, `jwt-kit`, `swift-crypto` and
    `swift-asn1`, in PeelApp only.
  - Its manifest caps `swift-collections` below 1.3, and resolution is
    package-wide, so the whole package (NIO and mqtt-nio in PeelCore
    included) drops from 1.7.1 to 1.2.1. Nothing in Peel uses it directly;
    builds and tests pass. A later NIO that needs 1.3 would not resolve
    until LiveKit moves on, which the long-term fix below does.
  - What 2.10.2 lacks against 2.17: a `swift-tools-version:6.1` manifest
    and the README's "full support for strict concurrency" (2.10 is Swift
    5.9 tools; Peel's own code is unaffected, it is a MainActor caller),
    protocol v16 and "Room moved" handling, the reconnect and task
    cancellation fixes of 2.11, the WebRTC 144 and 150 updates, and the
    later agent and data-track features Peel does not use.
  - **Long-term fix**: upgrade the core bindings' UniFFI (sphinx-rs,
    `scripts/build-ffi.sh`, a new `Vendor/sphinxrs.lock`) so the
    `RustBuffer` layouts match, then move LiveKit to latest. Not in this PR.
- **Bundle** (`scripts/bundle-app.sh`): every framework the executable
  loads through `@rpath` (read from `otool -L`; today only
  `LiveKitWebRTC.framework`) goes into `Contents/Frameworks` with `ditto
  --arch` for this Mac's architecture, without `Headers` or `Modules`. The
  `@executable_path/../Frameworks` rpath is a linker flag on PeelApp in
  `Package.swift`, so the executable needs no patching. `LiveKit_LiveKit.bundle` holds only the privacy manifest and
  LiveKit never reads `Bundle.module`, so it is left out, as GRDB's and the
  NIO bundles already are.
- **Signing** (`scripts/sign-app.sh`): every framework in
  `Contents/Frameworks` is signed with Peel's identity and hardened runtime
  before the app (inside out); the closing check is now `codesign --verify
  --deep --strict`. Without an identity it now refuses outright: an ad-hoc
  app could not load the embedded framework under library validation, and
  could not use the Keychain anyway.
- **Permissions**: `NSMicrophoneUsageDescription` ("Peel uses the
  microphone so people on a call can hear you.") and
  `NSCameraUsageDescription` ("Peel uses the camera when you turn on video
  in a call."); `com.apple.security.device.audio-input` and `.camera` in
  `scripts/provision/Provision.entitlements`. The App ID is unchanged.
  - The stub check is split in two: `profile_is_current` (app ID,
    certificate, two days left, as before) and `stub_has_entitlements`
    (every key in `Provision.entitlements` is in the stub's signature).
    When only the second fails, the profile is kept and the stub is just
    built again with it, with no request to Apple (this machine's Xcode
    reported "No Accounts" when asked for a new profile).
- **The test room** (`CallTestRoom.swift`): only with a development profile
  and `-callTestToken <jwt>` (`-callTestURL` defaults to
  `ws://127.0.0.1:7880` and must be loopback `ws://`). The window opens at
  launch and joins; Window > Join Test Room opens it again; without the
  token nothing is listed (`.commandsRemoved()`, no restoration, and
  `defaultLaunchBehavior` presents it only when the test is on). It publishes the
  microphone and shows the connection and every audio track, polling once a
  second, and prints each change to stdout (never the URL or token).
  LiveKit's log level is `warning` app-wide.
  - Local stack: `brew install livekit livekit-cli`, `livekit-server --dev
    --bind 127.0.0.1`, `lk token create --api-key devkey --api-secret secret
    --join --room peel-test --identity <id> --valid-for 2h`, then
    `open -n --stdout <file> .build/PeelCallsTest.app --args -profile <dev>
    -callTestToken <jwt>`. `lk load-test --audio-publishers 1` adds a
    synthetic remote audio track.
- **Verified**:
  - `codesign --verify --deep --strict` passes; app and framework carry team
    `T3M78XC3UV` with hardened runtime; the app's entitlements have
    audio-input, camera and the access group. The second bundle reused the
    stub (no fetch), as the weekly re-sign will.
  - The CLI (`.build/debug/peel`) links nothing from LiveKit or WebRTC.
  - A fresh development profile launched from `.build`, connected to the
    local server (`.connected`, identity from the token), and saw a remote
    participant's microphone publication.
  - The microphone prompt shows the new wording ("Peel uses the microphone
    so people on a call can hear you."), titled with the bundle's file name.
- **Not verified**: publishing the microphone and subscribing to remote
  audio. The prompt cannot be clicked headlessly, and until it is answered
  WebRTC's worker thread waits on it (seen in a `sample`), so neither
  happens. One manual run with Allow clicked is open; the grant follows the
  signature, so it holds for later builds. Two Peel instances seeing each
  other's tracks waits on the same click.
- **Size** (debug bundle, as `run-app.sh` builds it): 47 MB (48,140 KB)
  before, 78 MB (79,760 KB) after. WebRTC thinned to arm64 is about 13 MB;
  the rest is the larger executable (LiveKit, protobuf, jwt-kit, crypto).
  WebRTC is linked, so dyld loads it at every launch; not measured.
- **Reviews**: `/code-review` (high): a join still in flight when the window
  closes now finishes before the room disconnects; the window is never
  restored and opens at launch only when the test is on (not again with a
  new main window); `-callTestURL` is read with `URL.host`, lowercased, so
  `[::1]` passes, and a rejected one says why; rows are keyed by index; the
  gate is the profile's kind, not a second read of `-profile`; the
  `swift-collections` downgrade is recorded above. `/simplify`: frameworks
  found from `otool -L` rather than named; the rpath moved to
  `Package.swift`; one `sign` helper; the stub check split in two;
  WebRTC thinned to this Mac's architecture; the launcher modifier
  replaced by `defaultLaunchBehavior`. `/security-review` (entitlements,
  framework signing, permissions, test room gating): no findings at
  confidence 8 or above. Not applied, with reasons:
  - Caching the signed framework between bundles: a 13 MB re-sign per
    build is small.
  - Plain `--verify --strict` instead of `--deep`: the brief asks for the
    deep check, and it costs one more hash of 13 MB.
  - Loading WebRTC lazily: it is a linked SwiftPM product and calls ship
    in PR 5; measure the launch cost once instead.

## PR 4 journal (2026-10-08)

- **Built** (boards C1 and C2): `CallCard` and `CallHeaderButton`
  (`Sources/PeelApp/CallViews.swift`), and a placeholder join
  (`Sources/PeelApp/CallPlaceholder.swift`) until PR 5's window.
  - Type 32 joins `shownInChats` and `unreadTypes`, and places a chat in
    the sidebar (`conversationsSQL`, not when deleted). It stays out of
    `content` and `resendable`. `Message.isSaid` (content or a call) picks
    the message row; `Message.shownText` is what a row shows (for a call
    message Peel cannot join, the link it carries, as plain text, which
    asks before opening like any link); `preview` reads "Audio call" or
    "Video call" (`CallLink.mode(ofLink:)`). `CallLink(in:server:)` holds
    the Mac app's rule (a call message, or text that is only a call link);
    `Engine.callLink(in:)` now wraps it. A failed call of yours is
    `isDiscardable` (never retried: its room would be stale) and the card
    offers Discard.
  - The card: the glyph and "Audio call"/"Video call"; live with up to
    three 24 pt avatars (presence feed photos only, through `Web.photo`;
    you are told apart by the ticket's identity) and "N on the call"
    after the green dot; "No one on the call"; "Call ended"; no line when
    unknown or older than 12 hours; "You're on this call" with Open. Join
    is filled; a failed ticket's reason (such as "the call server named a
    media server Peel does not know") shows quietly inside the card. More:
    "Copy call link" and "Anyone with the link can join"; Mark unread from
    here. Reply, Thread and Delete are not offered on a type 32 (they need
    `content`; deleting someone's call as a tribe owner needs the engine's
    incoming-delete rule widened, left for later).
  - Presence: a card watches only while it is drawn (its `.task`, so
    scrolling away or closing the chat unsubscribes) and only when its
    message is under 12 hours old. The header also watches the open chat's
    newest three calls under 12 hours, so "● Join · N" shows while the
    card is off screen; that is the only watch beyond on-screen cards.
  - The header: the phone with Peel's menu (Audio call ⌥⌘A, Video call
    ⌥⌘V, also live as shortcuts in the chat); while a recent call has
    someone on it, the bordered "● Join · N" pill (Open while you are on
    it) and a chevron with "Start a new call". Hidden on an account with
    no call server. Starting posts through `startCall` and joins; the
    spinner sits in the clicked button. While you are on a call, starting
    or joining another says "You're on the call in #x; leave it first"
    rather than leaving silently (PR 5 brings the in-place confirm).
  - The sidebar's green phone on tribe rows: a watched call with someone
    on it, or the call you are on. With watches limited as above, that is
    the open chat or your call's chat.
  - Placeholder: Join and Open fetch the ticket and open the "Call" window,
    which connects with the microphone and camera off and shows "Connected
    · N people" and Leave; closing it leaves. Not the test room's code
    (that stays development-only); the connect is the same two calls.
  - `Conversation.title` ("#tribe" or the name) replaces three inline copies;
    `MenuShortcut` gains ⌥; `HeaderButton` gains `working`.
- **Verified** on a local stack (broker 1977, tribes 8877, mixer 8077,
  `livekit-server --dev`, a throwaway call-server stub on 8879 that mints
  LiveKit tokens, proxies `/rtc` and reports presence from LiveKit's
  RoomService), profiles `cc-alice` and `cc-bob`:
  - Bob's `call-start` in a tribe: Alice's app shows the card, the chat
    unread 2 (text and call), the sidebar places it.
  - Presence (Bob in the room through `lk room join`, three made-up
    participants from the stub): the card with three avatars, "+1" and
    "4 on the call", the header's "● Join · 4", the sidebar phone. Bob
    leaving: "No one on the call", the header back to the phone, the
    sidebar phone gone. The room deleted: "Call ended". A stub restart:
    Peel reconnected and subscribed again.
  - Only the recent call subscribed; an 18-hour-old call (inserted into
    the dev profile's database) showed the plain card with Join and was
    never subscribed. A type 32 with a Jitsi link showed as a plain link.
  - **Not verified**: clicking Join, Open, Leave and the header menu, and
    the "media server" error in place. This session cannot send clicks or
    keys to the app (no accessibility grant), so the placeholder window's
    connection was not driven from the UI. The ticket path is the one the
    CLI's `call-ticket` exercises and the connect is the test room's.
    Tom: `.build/PeelCallCardTest.app`.
- **Reviews**: `/code-review` (high): no silent leave of a call you are on;
  no call message sent while a join runs; a failed call can be discarded;
  calls in collapsed threads keep their card; Mark unread on calls; the
  preview of a non-room `call::` shows its link; the header hidden without
  a call server; per-view watcher ids; the sidebar reads a derived set.
  `/simplify`: `isSaid` and `shownText` in PeelCore; presence apart from
  the (unobserved) watcher bookkeeping; recent calls worked out with the
  rows; `HeaderButton` and `avatar(fromMe:…)` reused; one window-opening
  helper; the window's title kept on the call. `/security-review`: no
  findings at confidence 8 or above. Not applied, with reasons:
  - Notifications for calls: PR 7 (calls count as unread but do not
    notify yet).
  - One presence task per room in the model instead of one stream per
    view: the engine already shares one subscription per room.
  - Caching parsed call links per message: text is skipped unless it holds
    `sphinx.call.`; a page holds few calls.
  - `AppModel.callServer` is read once per account: no UI changes it yet.
  - `MenuShortcut` as a modifier set: one flag is enough for now.
  - The placeholder's once-a-second count: PR 5 replaces the window.

## PR 5 journal (2026-10-08)

- **Built** (boards C3, C4, C5), in PeelApp, plus one PeelCore helper:
  - `CallSession` (`Sources/PeelApp/CallSession.swift`) owns the LiveKit
    `Room` for one call. Tiles, your mic and camera state and the
    connection state are worked out from the room's `objectWillChange`
    (throttled to ten a second; audio levels fire it constantly), with
    each person's name and metadata read once. Mic on at join; camera off
    except for the person who starts a video call (Tom's default). Access
    is asked from macOS (`AVCaptureDevice.requestAccess`) before LiveKit
    touches a device, so an unanswered prompt never holds the room, and
    nothing is published once you have left. Camera off unpublishes, so
    the camera chosen while off is the one that opens. Devices: LiveKit's
    `AudioManager` for microphones and speakers, `CameraCapturer` for
    cameras; a mic or speaker unplugged mid-call falls back to the default
    with a quiet line; an unplugged camera turns off. States: connecting,
    connected, reconnecting (LiveKit's own resume and full reconnect), and
    lost, with "Lost the connection to the call · Rejoin" (a new ticket,
    the camera as you had it).
  - `CallParticipant(identity:name:metadata:)` in PeelCore reads a room
    participant through the presence feed's cleaning (names without
    control characters, photos only public https); tested.
  - `CallWindow`: the title bar ("#design 24:12", or the connection's
    state), the grid (1, 2 side by side at 16:11, 2×2 up to four, three or
    four across beyond, scrolling under 140 pt tiles), avatars in person
    hues with the camera off, the accent edge while someone speaks, a
    muted mic on the name tag; the bar: Mute (⌘⇧A) and Camera (⌘⇧V), each
    with a chevron to Peel's device menu (Microphone, Speaker, Camera,
    with checks), and Leave in `#ED7474` with dark text (⌘W). No Share
    button: the board's bar keeps its layout without it; PR 6 adds it.
    Refused access disables the control and says "Peel can't use the
    microphone · Open System Settings". 960 × 640 at first; closing it
    leaves; it closes when the call goes from anywhere else.
  - The sidebar's on-a-call bar (`OnCallBar`): the chat, the running
    time, up to three avatars and "+N", "N on the call", Mute and "Return
    to call". The header pill's "Open · N" is #59's.
  - One call at a time: Join on another call's card, or the header's
    Join or Audio/Video call (and ⌥⌘A/⌥⌘V), first asks in place, "Leave
    the call in **#design** and join?" with Cancel and the blue "Leave and
    join" ("Leave and start" in the header). The call you are on goes only
    once the new ticket has come, so a failed join leaves you on it. The
    header's question is dropped when another chat opens.
  - Leaving cleanly: Leave, ⌘W, a switch, forgetting the account
    (`resetAccountState`) and quitting all disconnect the room; a quit is
    held (`applicationShouldTerminate`) until every room left has said
    goodbye, or two seconds.
- **Verified** on a local stack (broker 2011, tribes 8911, mixer 8111,
  `livekit-server --dev` on 7980/7981/7982 with a config, PR 4's stub
  copied to 8913 with the LiveKit port as an argument), profiles
  `p5-alice` and `p5-bob` in a tribe, joined at launch through a scratch
  hook that was never committed (this session cannot click):
  - Two Peels in one call: the 2-person layout, both tiles named and in
    their hues; the sidebar bar ("#design 00:16", two avatars, "2 on the
    call", Mute, Return to call); the card's "You're on this call" with
    Open; the header's "Open · 2".
  - `lk load-test` video publishers: the 2×2 layout with live video in
    the tiles (LiveKit's test publishers send video with no source, so the
    camera is the first video that is not a screen share), "Guest" for a
    publisher with no name, the muted icon on tags.
  - Both apps published their microphones (`addTrack` in LiveKit's log);
    a quit sent LiveKit's leave (`CLIENT_REQUEST_LEAVE`) before exit.
  - Seven on the call (`lk load-test` with five video publishers, two
    of them with audio, plus both Peels): three across, the sidebar's
    three avatars, "+4" and "7 on the call", the header's "Open · 7".
  - Connection loss: with the call stub (the signal path) and LiveKit
    killed, "Reconnecting…", then "Disconnected" in the title and the
    sidebar (grey dot), only your tile, and "Lost the connection to the
    call · Rejoin". With both restarted three seconds later LiveKit's
    resume was refused ("could not restart participant": a new server
    knows no one) and its full reconnect came as it gave up, so the call
    still ended lost; Rejoin, a new ticket, is the way back. With only
    the signal path dropped and the media server alive, the call stayed
    connected and media kept flowing; with only LiveKit killed behind the
    stub's half-open proxy, LiveKit 2.10.2 noticed nothing for two
    minutes (frozen video, still "connected"), which a real server
    without the proxy would not show.
  - Quitting both apps during the call, and after the server had gone,
    exited at once.
- **Left as is**: the sidebar's green phone stays on your call's tribe
  while that call is lost (the live set is worked out when the call
  changes, not its state); unnamed participants are all "Guest" in one
  hue.
- **Not verified**: a reconnect that recovers (`.reconnecting` back to
  `.connected`); clicking anything (the device
  menu, Mute, Camera, Leave, Rejoin, the switch confirm, Return to call,
  Open System Settings); the camera (its prompt was never answered);
  unplugging a device; refused access. Tom: `.build/PeelCallWindowTest.app`.
- **Reviews**: `/code-review` (high): the audio-device handler kept by
  the newest session only; quit no longer waits past two seconds; the
  header's question dropped on a chat change; nothing published after
  leaving during a permission prompt; Rejoin keeps your camera and shows
  why it failed in the window; people read once per name and metadata;
  one `avatar(of:)` for the card, the bar and the tiles. `/simplify`: one
  status view that ticks only while connected; shortcuts on the controls
  themselves; one `joining` flag for the confirm; a stored `people` so
  speaking does not redraw the sidebar; camera notifications only for
  video devices; `Duration` formatting; `OnlineDot(color:)`; quits wait
  for rooms already left. `/security-review`: no findings at confidence
  8 or above. Not applied, with reasons:
  - Leaving while still connecting waits for the connect to finish (as
    PR 3 decided), so a slow connect delays the leave.
  - A participant whose identity the presence rules refuse (control
    characters, over 256 bytes) gets no tile; identities come from the
    call server's token.
  - The audio-device handler and the switch question stay out of
    `AppModel`, which does not import LiveKit, and the question belongs to
    the button that asked (as other in-place confirms do).
  - `PaneLink` and `Notifier`'s settings opener are not shared: both sit
    outside this PR.

## PR 6 journal (2026-10-08)

- **Decided by Tom (2026-10-08):** screen share as planned, click to focus
  as the official app does it, plus a strip of everyone else beside the
  focused tile; "Keep on top"; the full-screen button.
- **Built** in PeelApp only:
  - **Screen share** (`Sources/PeelApp/CallScreenShare.swift`). Share (⌘⇧S)
    opens macOS's `SCContentSharingPicker`, so Peel holds no standing Screen
    Recording permission and sees only what was picked.
    - LiveKit 2.10.2 has no picker path on macOS. Its `MacOSScreenCapturer`
      takes a `MacOSScreenCaptureSource` listed from `SCShareableContent`,
      which needs the permission; the official app lists sources this way in
      `ScreenShareSourcePickerView`. So Peel runs its own `SCStream` on the
      picker's filter and feeds each complete frame into
      `LocalVideoTrack.createBufferTrack` (`BufferCapturer`). Frames are
      420v, the long side at most 1920, 15 fps. The last frame is sent again
      each second while the screen is still, so a late joiner sees it.
    - The picker is active only while Peel asks. Peel's bundle is excluded
      from it, so its own windows or app can never be picked. Changing the
      content from the menu bar is off. Nothing is shared unless the picker
      returned something and the call is still connected.
    - **Peel's windows are left out of display shares** (all of them, the
      call window included, as the official `getWindowsToExclude` leaves out
      its call window). A picker filter cannot be edited without the
      permission, so `excludedWindowIDs` on the picker does not help a
      display share. Instead, during a display share, every Peel window gets
      `sharingType = .none`, applied again after each event so a window
      opened mid-share is covered, and given back when the share ends.
      ScreenCaptureKit honours it: checked on macOS 26.6 with a standalone
      display capture (a `.none` window was left out, a `.readOnly` one was
      captured), and in the app, where Bob's own Peel window shared with the
      cloak on reached Alice blank. While a display is shared, Peel is also
      blank in screenshots and other apps' shares.
    - The bar: Share, filled "Stop sharing" while you share; under it
      "You're sharing your screen, without Peel's windows" (or "a window",
      "an app") · Stop. The share stops on Stop, on the menu bar's Stop or a
      closed window (macOS ends the stream), on leaving, and when the call is
      lost.
  - **Focus**, as the official app (`RoomView.swift` ~L800, `focusParticipant`):
    a click on a tile focuses it, a click on the focused tile or Escape goes
    back to the grid, and the grid comes back when the focused person leaves.
    Tom's addition: while focused, everyone else sits in a 200 pt strip on
    the right (board C3's screen-share layout), with the speaking edge; a
    click on a strip tile moves the focus there. A screen someone starts
    sharing takes the focus (the newest, when several start); your own never
    does. A screen that comes back after a pause or a reconnect (same track)
    does not take it again. When a focused screen ends, the newest screen
    still shared takes it, else the grid. Screens are tiles of their own
    ("Maya's screen", never cropped).
  - **Keep on top**: a pin at the right of the title bar, accent while on,
    with a tooltip; the window floats (`.floating`, as the official
    `pinned`). It lives on the `CallSession`, so it lasts for that call.
  - **Full screen**: the call window gets `.fullScreenPrimary` (it had it
    already as a SwiftUI `Window`; now explicit).
- **Verified** on a local stack (broker 2061, tribes 8961, mixer 8161,
  `livekit-server --dev` on 8030, PR 4's call stub on 8963), profiles
  `p6-alice` and `p6-bob` in a tribe, `lk load-test` video and audio
  publishers with simulated speakers, driven at launch through a scratch hook
  that was never committed (this session cannot click):
  - Bob shared his own Peel window (a filter from
    `SCShareableContent.currentProcess`, standing in for the picker) through
    the real `ScreenShare` path: published, Alice's window switched to the
    focus layout on "Jonas_Weber's screen" with the strip; Bob saw "Your
    screen", "Stop sharing" and the note; after Stop, Alice was back on the
    grid.
  - Two shares at once: Bob's focus moved to Alice's newer screen; Alice
    kept Bob's (her own does not take it).
  - Focus on a person with the strip, the speaking edge on the main tile
    and on strip tiles.
  - Keep on top: the window's level 3 (floating), drawn above a newer
    ordinary window of another app. `fullScreenPrimary` set.
  - A display filter built without the picker failed to start (no
    permission), and the window showed "Could not start sharing" with Peel's
    windows given back.
- **Not verified** (needs clicks): the picker itself and what it returns;
  a display share's frame with chats open; clicks on tiles (camera tiles'
  video views are made not to take clicks, untested); Escape; the pin;
  ⌘⇧S; the full-screen button; the menu bar's Stop. Tom:
  `.build/PeelShareTest.app`.
- **Reviews**: `/code-review` (high): a stop notice from macOS that lands
  while the capture starts no longer leaves a zombie share; Stop shows as
  soon as capture starts; Stop never opens the picker; video views do not
  take tile clicks; a screen coming back does not steal the focus; the cloak
  gives back only the windows it hid. `/simplify`: `sharing` derived from the
  share; the cloak only for display shares; the shared pill for Share and
  Leave; `HoverIconButton` for the pin; a lazy strip; one note per content
  kind. `/security-review`: no findings at confidence 8 or above. Not
  applied, with reasons:
  - The picker cannot be dismissed when you leave mid-pick (no API); a later
    choice is dropped because the call is gone.
  - The cloak runs after each event rather than at window creation: Peel
    has three window sources and the sweep over a few windows is cheap.
  - `keepOnTop` stays on `CallSession` (Tom asked for it per call) rather
    than in view state or a scene `.windowLevel`.
  - `refresh` reads each participant's tracks twice (screen, then person):
    a few lock reads at most ten times a second.

## PR 7 journal (2026-10-08)

- **Decided** (Tom, 2026-10-08): no ring. A call is an incoming alert like
  a tribe message, viewed in the chat. This replaces the plan's Join action
  and its two-minute, live-only window (see "Incoming calls"). After
  review, the coordinator set the notification window to ten minutes
  (`CallLink.notifyAge`) and the body to "Started a call", which the title
  and subtitle already qualify; Tom can change either.
- **Built**:
  - `CallLink.isAnnounced(by:server:now:)` (PeelCore): someone else's type 32,
    not deleted, at most `CallLink.notifyAge` (10 minutes) old and at most
    5 minutes ahead of this Mac's clock, whose link validates against the
    account's call server. `liveAge` (12 hours) and `CallLink.isRecent`
    move here from `AppModel.presenceAge`, and `isRecent` now also refuses
    a date more than 5 minutes in the future, which would otherwise stay
    recent for good.
  - `MuteLevel.notifies(_:)` (PeelCore): the chat-level rule `Notifier`
    already applied, now shared and tested.
  - `Notifier` lets an announced call in beside text, attachments and join
    requests; its body is "Started a call" under the usual title (the
    contact, or the sender with "#tribe" as subtitle). A call is never
    folded into the "N new messages" summary. Sound, grouping, the locked and
    hidden-text rules, and the click (`openFromNotification`, which
    focuses the message) are the message path's, unchanged.
- **No Join action**: joining from a notification would skip the card's
  in-place "Leave the call in #design and join?" confirm and needs the
  window-opening action only views hold; Tom joins from the card.
- **Tests**: `CallTests` covers who is announced (own calls, the
  ten-minute edge, a call live for the card but too old to announce, clock
  skew, links that fail validation, Jitsi, no call server, text links,
  deleted) and the chat level (all, mentions-only, muted).
- **Verified on the local stack** (broker 1979, tribes 8879, mixer 8079,
  call server `127.0.0.1:7899` with nothing on it: no call-server or
  production requests), profiles `cn-alice`, `cn-bob`, `cn-carol`, bob in
  `.build/PeelNotifyTest.app` in the background, with a temporary
  (uncommitted) hook that logged each posted request and called the click
  handler with its `userInfo`:
  - DM video call: title "cn-alice"; the click opened the DM at the
    card.
  - Tribe audio call: "cnalice", subtitle "#Design Crew"; the click opened
    the tribe at the card. (The run used the earlier "Alice started a call
    …" body; only the body text and the window changed after it.)
  - Tribe muted, DM all: only the DM call posted. Both mentions-only:
    nothing posted, while both calls arrived (unread 4 each).
- **Not verified**: a real click in Notification Center (the test bundle
  shares `dev.peel.mac` with Tom's running Peel, so a click could go to
  it); the hook called the same handler with the posted `userInfo`.
- **Reviews**: `/code-review` (high): each notification names its own
  sender (a batch could name the last one's); a future-dated call is not
  recent; the link is parsed only after the arrival checks; a call is
  never hidden in a summary; the status lines. `/simplify`: the
  `AppModel.isRecent` wrapper removed; `isAnnounced` a Bool rather than a
  failable init; the summary split. `/security-review`: no findings at
  confidence 8 or above (checked: locked and hidden-text notifications,
  the click opening only the chat with no join or URL, validation against
  the call server, mute levels, the clock-skew bound). Not applied, with
  reasons:
  - A `NotificationKind` in PeelCore for every type that notifies: three
    types, one switch; worth it when a fourth arrives.
  - One mute rule shared with `ChatReadState.shownUnread` and
    `moneyReceived`: counts and receipts are not messages, and it would
    touch code outside this PR.

## Live-call indicator journal (2026-10-08)

Tom: "There's a call in a tribe. We should render the green icon to know
that there's a call in the tribe. Currently when you move tribes it drops."

- **Premise, confirmed in the code**: presence was watched only by views.
  The card's `.task` and the header's `.task` (the open chat's newest
  three calls, from `chatRows`) called `AppModel.watchCall`, whose
  `defer` dropped `callPresence[room]` once the last watcher left. So
  switching chats cancelled both tasks and cleared the room's presence:
  the sidebar's phone (tribes only, from the watched rooms) went out, and
  coming back the card showed nothing until the feed answered again. The
  feed itself was fine: `CallServer` already shares one `/ws` socket per
  call server with a subscription per room, and backs off on drops.
- **Built**:
  - PeelCore (`Call.swift`): `WatchedCall.watched(in:server:now:)` picks,
    from messages newest first, each chat's newest call link valid against
    the call server that `CallLink.mayBeLive` (recent, not a call of yours
    that was never sent; the card uses it too), at most
    `WatchedCall.limit` (8). `WatchedCall.nextChange` is the soonest a
    watched call ages out or a call dated ahead becomes recent.
    `Storage.recentCallMessages()` is the live query feeding it: call
    messages and text holding `sphinx.call.` in shown chats (ready
    contacts, tribes not left), not deleted, under 12 hours, at most 500;
    beside `CallLink` rather than in `Storage+Reads.swift` (storage is
    being cleaned up in parallel), as `PaymentHistory.swift` keeps its own.
    `Message.notSent` names the rule the card and `isDiscardable` share.
  - The app (`CallViews.swift`): `observeRecentCalls` (an account task)
    and `refreshCallWatches`, one model watch per call and chat through
    the same `watchCall`, so a card or the header shares its presence. A
    watch stops when its call ages out (one wake-up at `nextChange`), its
    chat is left or deleted (it leaves the query), on lock (`phase` is not
    `.ready`) and on an account change (`stopWatchingCalls`, one line in
    `resetAccountState`). A watch that ends on its own (a refusal, a
    closed feed) is started again by the next refresh, never in a loop.
  - The sidebar: `liveCallCounts` (chat to the busiest watched call's
    count) replaces `liveCallChats`; `liveCallCount(in:)` adds the call
    you are on. The green `phone.fill` (11 pt, `Theme.confirmed`, the
    card's live green) now shows on DMs too, before the unread badge,
    labelled "Call in progress, N people" (help and accessibility), and
    hides at zero.
- **Privacy**: this widens what the call server learns. Before, it saw
  the rooms of cards on screen and the open chat's header; now it sees up
  to eight recent rooms whenever Peel is unlocked, from the same IP. Only
  the configured call server, only rooms that passed `CallLink`'s checks,
  none while locked. Tom asked for it; the cap is the bound.
- **Verified** on a local stack (broker 2071, tribes 8971, mixer 8171,
  `livekit-server --dev` on 8040, PR 4's call stub on 8973), profiles
  `lv-alice` (the app) and `lv-bob` (the CLI), tribes alpha and beta:
  - Bob's `call-start` in alpha, one `lk load-test` audio publisher in
    the room, Alice's app opened on beta (a scratch launch argument, not
    committed): the stub got one subscribe for alpha's room while beta was
    open, and alpha's row showed the green phone.
  - Switched to alpha: the card read "1 on the call" and the header
    "Join · 1" in the first frame; the model's log at the switch already
    held the count, and no second subscribe went out.
  - The publisher gone: the phone left alpha's row and the card read "No
    one on the call".
  - **Not verified**: a DM's phone (the same code path), the cap and the
    age-out in the app (unit-tested), lock and unlock in the app, and your
    own call's phone. Tom: `.build/PeelLiveCallTest.app`.
- **Reviews**: `/code-review` (high): a watch that ends on its own is
  restarted; one watch per call and chat, and counts refreshed when a
  watcher comes or goes; a wake-up for calls dated ahead; the engine's
  "only on screen" contract and the file map updated; storage's newest
  first trusted (no second sort). `/simplify`: `Message.notSent` and
  `CallLink.mayBeLive` shared with the card and header;
  `Formatting.people`; `refreshLiveCallCounts`; no double refresh; one
  dictionary for the wanted watches; the query's comment says it is a
  coarse filter. `/security-review`: no findings at confidence 8 or above
  (checked: the SQL has only constants and one bound argument; links
  checked against the call server twice; nothing new shown from the feed
  but a count; locked and account-reset paths). Not applied, with
  reasons:
  - The watch set owned by the engine (`liveCalls()` for the CLI and
    agents): presence state has lived in the app since PR 4; worth it
    when an agent needs "which chats have a live call".
  - The header's three folded into the model's watches: it still adds
    the open chat's second and third calls.
  - Selecting fewer columns, or a stored call flag with a partial index:
    a few ms per write at worst on a pool reader, and a migration; only if
    a sync profile shows it.
  - Calling `refreshCallWatches` at the lock and unlock sites instead of
    `phase`'s `didSet`: three sites set `phase`, one observer covers them.
  - Your own call's count folded into `liveCallCounts`: rows read
    `call` only on join and leave, and `people` changes only on joins.

## Call card presence and the production media host (2026-10-12)

Tom on the real #hive call, beside the official app (Jamie, Gonza and
rasul on it):

- **The card said "G, G, G, +1 · 4 on the call".** Peel showed every
  participant in the feed, and one with no `nickname` as "Guest" (so "G").
  The official Mac app keeps only participants with a name, both in
  `current_participants` and on a join
  (`NewChatTableDataSource+CellDelegateExtension.swift:1260-1283`), and for
  a join with no name asks again (a second `subscribe`) two seconds later,
  since LiveKit may not have passed the name on yet. Peel now does the
  same (`CallServer.applying`, `askAgain`, one at a time per room, and not
  before the first list), still one entry per identity; a name of only
  spaces is no name (trimmed as the feed is read), and someone listed unnamed keeps a name
  they had earlier in the same list or before it (their client
  reconnected; not after Peel's own feed drops, when every room starts
  again from unknown). The real feed was never read (no production
  request from an agent): that the extra entries were nameless (a
  recorder, an agent, or a join not yet named) is inferred from the three
  identical "G"s and the official filter, not observed.
- **Join said "the call server named a media server Peel does not know
  (livekit.sphinx.chat:443)".** The production call server's answer is now
  known: `CallServer.mediaHosts["chat.sphinx.chat"] = ["livekit.sphinx.chat"]`,
  exact host on 443, only for that call server on its default port.
  Lookalikes, other ports, userinfo and other call servers (also
  `chat.sphinx.chat:8443`) are refused (tests). A call server set in
  Account still may name only itself.
  The same error came back on 2026-10-13: the call server now answers
  `serverUrl` as `https://livekit.sphinx.chat`, which LiveKit reads as
  `wss://`. `CallServer.mediaURL` now takes `https://` as `wss://` (and
  `http://` as `ws://`, still only for a call server on this machine).
- **The header showed that error, cut short, beside "Join · 4".** A join
  or start from the header (or ⌥⌘A, ⌥⌘V) now fails into the chat's notice
  ("Could not join the call. …"), cleared (only that notice) when the
  header joins again; a
  join from the card keeps its line beside Join.
- **The header's "Start a new call" menu opened at the window's bottom
  left.** `MenuAnchor`'s view behind `.menuAnchor` took the anchor on every
  update, and the header's two triggers (the phone, then the split Join)
  shared one anchor: when the phone gave way to the split Join, the
  outgoing view was updated after the new one and took the anchor back,
  then left the window, so the menu had a zero frame. The anchor view now
  takes its anchor when it joins a window and on an update only from a
  view in none, and lets go when it leaves; the chevron has its own
  anchor. Both halves were checked on their own (a shared anchor with the
  new rule also opens under the trigger). Checked offscreen with a scratch
  hook that faked a live call (not committed): the menu under the chevron.
- Checked offscreen against a scratch loopback presence stub (a recorder
  with no name, one identity twice, a join named only on the second
  subscribe): `call-who` and the card read "J, G, R" then "+1 · 4" once the
  late join was named.

## CallStore (2026-10-14)

The call state the journals above name on `AppModel` moved, unchanged,
into `CallStore` (`Sources/PeelUI/CallStore.swift`), which the model holds
as `calls`: `callServer` is `calls.server`, `callPresence` `presence`,
`liveCallCounts` `liveCounts`, `liveCallCount(in:)` `liveCount(in:)`,
`recentCalls` `recent`, `callFailures` `failures`, `startingCallIn`
`startingIn`, `callLeaving` `leaving`; `watchCall`, `joinCall`,
`startCall`, `leaveCall`, `endCall` and `rejoinCall` are `watch`, `join`,
`start`, `leave`, `end` and `rejoin` (a join or start is given the
chat's title); `refreshCallWatches`, `stopWatchingCalls` and
`refreshRecentCalls` are the store's own, run when the model locks
(`watchesRecent`), resets and rebuilds the open chat's rows. Its tests are
`Tests/PeelUITests/CallStoreTests`.

## Share opens on the screen (2026-10-15)

Share now opens macOS's picker in screen mode, so the entire screen is the
easy default. A chevron beside it offers Entire screen, A window and An
app. Each uses `present(using:)` with the matching style and only that
kind's `allowedPickerModes`; a window or an app may still be several. No
new permission. While sharing, the button is
still the one filled Stop sharing.

## Floating call bar

A non-activating `NSPanel` (`Apps/Mac/Peel/CallFloatingBar.swift`) with
Mute, Camera, Share / Stop sharing, Return to call and Leave, shown
bottom-centre (dragged position remembered) whenever the call window is open
but not key during a connected or reconnecting call, so you can control the
call from another window or while sharing. `CallRoomView` owns it: attached
through its `WindowReader` window, updated on key, miniaturize and close
notifications and on the call's state, detached on disappear. The buttons
call the same `CallSession` / `model.calls` actions as the control bar. It is
out of captures with `sharingType = .none`; the picker's filter is not
built by Peel, so there is nothing else to exclude it from. Ported in shape
from the Sphinx Mac app's draggable panel. Not built or run in this session:
manual testing of focus, drag, Spaces, full screen and display share is open.

Reference: sphinx-mac-v2. Sphinx (`WindowsManager.createControlsPanel`,
`showControlsPanel`, `presentCallControlWindowWith`) keeps one lazily created
`DraggablePanel` (an `NSPanel`, style `[.nonactivatingPanel, .borderless]`,
transparent, level `.mainMenu`, `canJoinAllSpaces` + `fullScreenAuxiliary`,
392x100, bottom-centre, position remembered, manual `mouseDragged`) hosting
`CallControlView` bound to the `RoomContext`. `RoomContext` is the call
window's `NSWindowDelegate`: `windowDidResignKey` (when connected) shows the
panel, `windowDidBecomeKey` hides it (alpha 0), and `windowWillClose` or the
call ending closes it. `getWindowsToExclude()` feeds the panel's
`windowNumber` and the call window's into LiveKit
`ScreenShareCaptureOptions.excludeWindowIDs`.

Open questions:

- `sharingType = .none` against ScreenCaptureKit on current macOS: the system
  picker's filter may still capture the bar. Verify in a real share.
- Full-screen and Spaces behaviour.
- Interaction with Keep on top.
- Multiple Peel windows.

## Hive calls with Jamie (2026-10-27)

The design is `../hive-calls.md`. A call can bring Jamie from a workspace
Peel is paired with (Stadeum), so a tribe needs no `app_url` and the person
no Sphinx key linked in Hive. Peel asks Hive's new
`POST /api/strut-devices/calls` with the device credential and the org's
peer id. Hive dispatches Jamie into a new room and answers the link, which
Peel checks against its call server (`CallLink.hive`), posts and joins.

- `HiveClient.startCall`, `Stadeum.callLink(on:)`, `CallStore.start(in:audioOnly:jamie:)`,
  `Engine.startCall(in:audioOnly:hiveLink:)`.
- The pick per chat is `Setting.callJamie`. With none, the tribe's swarm
  decides, as in the official apps; else no Jamie (`HivePeer.jamie`).
- The menu's Jamie section is on the Mac and, as an inline picker, on the
  iPhone.
- Nothing is posted when Hive cannot make the call.
- Hive's side is stakwork/hive#5647. Not yet checked against a Hive with
  the route; a Hive without it turns the device away with a 401, as for a
  revoked device.

## Jamie's deliverables in the call's chat (2026-10-29)

The plan is sphinx-voice `plans/call-artifacts.md`; Hive (stakwork/hive#5659)
and voice (stakwork/sphinx-voice#20) put strut's own entries on a reply's
chat payload as `strut: { workspace, artifacts }`, beside the markdown links.

- `CallChatWire.decode(_:fromJamie:)` reads `strut` only from the
  participant `CallSession.isJamie` names, so another person in the room
  cannot hand you something that opens on your strut. A malformed `strut`
  never costs the message.
- `AgentArtifact(strutEntry:workspace:)` resolves each entry as strut's UI
  does (`peerArtifactPath`): a peer's file to
  `/peers/<workspace>/peers/<peer>[/peers/<via>]/jobs/<job>/files/<path>`, a
  strut-relative url behind `/peers/<workspace>`, an app to
  `@<workspace>/<name>[@vN]`; an https url stays a link.
- `Handle` now takes three `/peers` hops and a version pin on an app
  (`?app=` reads `name@vN`). A peer's app, two hops off, has no `?app=`
  form and opens nothing; its link is still in the text.
- The Mac's call chat shows `AgentArtifactLine` under Jamie's message,
  opened in the main window's web pane on Peel's own strut, as from the
  DM. The iPhone has no call chat yet.
- First live call (2026-10-29): plans, pages, notes, a screenshot and a
  PR opened; an app did not. Jamie named it by its document link
  (`/apps/<name>/<vN>/files/dist/index.html`) with no `app`, which strut
  passes on as a url and Hive's canvas shows as "Unavailable (bad url)".
  Peel now reads that link as the app, as Hive's `workspaceAppOfKey` does;
  strut turning it into an `app` entry is strut's to do.
- An app the Apps list has opens on its page there (`.app(peer:name:)`),
  as from the sidebar, in the call's chat and the agent's DM alike; one
  not listed, or pinned to a version that is not live, opens in the web
  pane as before (the page shows the live version).

## Jamie in tribes (2026-10-29)

The design is Hive's `docs/plans/jamie-in-tribes.md`; Peel's side is
`../hive-tribes.md`, the twin of `../hive-calls.md`. A tribe's owner links
it to one of their Stadeum orgs from the tribe's details, and `@jamie`
there is a turn of that org's orchestrator, answered in the tribe by Jamie,
one Sphinx account (stakwork/sphinx#401). Hive's routes are
stakwork/hive#5667.

- `HiveClient.jamieLinks`, `linkTribe`, `unlinkTribe`; `Stadeum.jamieLinks`,
  `setJamie`; the Jamie row is `TribeJamieSection` on the Mac and
  `TribeJamie` on the iPhone, over `TribeJamiePicker`.
- The check is always Hive's link, read when the details open. The org the
  tribe's pages point to, which a call would bring Jamie from, is a
  one-tap "Add Jamie from …" button, never shown as picked.
- Jamie's request to join a private tribe is approved unasked, by its key
  on the tribes server's list (`Engine.approveWaitingMember`, from
  `AppModel.approveJamie` on every member request in an owned tribe).
- Jamie's replies carry `metadata.strut`. A tribe member's row shows those
  deliverables (`Message.strutArtifacts`): opened only on the viewer's own
  paired orgs, an app only after a confirm. The one rule beside "control
  lines are never shown in a tribe".
- Built and tested offline; the Mac and iPhone apps build. Not checked in
  the running app, nor against a Hive with the routes on.

## Decided (Tom, 2026-10-08)

Tom approved the five defaults PR 1 used:

1. **Form** (question 1): Peel sends `call::{"link":…,"recurring":false,"cron":""}`
   and reads both forms.
2. **Room names** (question 2): random 128 bits, `sphinx.call.<32 hex>`.
3. **Price** (question 3): only the 3-sat floor in a paid tribe.
4. **Pubkey in metadata** (question 5): left out; PR 2 sends only the
   photo URL.
5. **Hive** (question 8): join only. Hive links are read and validated,
   never made. Reopened 2026-10-27 (`../hive-calls.md`).

## Open questions for Tom

Questions 1, 2, 3, 5 and 8 are decided (above). Questions 4, 6 and 7 stay
open; for 6, Tom checks PR 2's token and presence on production himself.

1. **Which form does Peel send?** The `call::` JSON form is the only one
   all three official apps read as a call (Android ignores a bare link as
   type 32), and iOS and Android already send it; only the Mac app sends
   the bare link. Recommendation: `call::` JSON, after one check that the
   current Mac app shows it as a card (its parser handles it).
2. **Random room names.** Peel's would look different from everyone else's
   timestamps (`sphinx.call.9f2c…`). They work in every client's parser, but
   is anything on the server or in Hive keyed on the timestamp format?
3. **Price on a call message in a paid tribe.** Pay price plus escrow like
   the official app (the tribes server keeps it and probably never refunds
   the escrow), or only the 3-sat floor (correct per the tribes server, but
   different from the official app)? Recommendation: the floor, verified on
   the local tribes server first.
4. **Camera when joining a video call.** Plan: off for everyone but the
   person who started it. Or on when the link says video?
5. **Pubkey in metadata.** Put the account's pubkey next to the photo URL so
   Peel users can at least see it? It cannot be verified without a server
   change, and it tells the call server which account joined.
6. **A real call on production.** When PRs 1 to 5 work locally, may the
   throwaway account call Tom's real account in the official app for one
   end-to-end check, with Tom present?
7. **Report the server issues?** No auth on token, presence and recording,
   and client-asserted `isHost`. Should this go to Stakwork, and does
   anyone own the call server's code?
8. **Hive and second-brain tribes.** Join their links (passing `callKey`
   and `hiveToken` on) but never create the Hive form (Hive is out of scope)? That is the
   plan.
