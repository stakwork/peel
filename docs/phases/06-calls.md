# Phase 6 — Calls

Status: **PRs 1 and 2 built** (the call link and message, #44; the ticket
and presence, branch `feat/calls-token`); PRs 3 to 8 open. Plan and boards
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
- Open: the production check of PR 2 (Tom, through the app once PR 4 ships;
  see the PR 2 journal), and everything from PR 3 on (LiveKit, the card, the
  window, notifications).
- Decided in PR 1: calls stay out of `shownInChats`, `unreadTypes` and the
  preview until PR 4 has the card (see "Engine and app split", Storage).

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
| C6 Notification | A DM call notification with Join |

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
- **Out of v1**: recording, removing participants, in-call chat, E2EE (the
  official apps would not be able to join), reactions, and background blur.

### On a call (the main window)

- While you are on a call, a bar at the bottom of the sidebar shows the
  chat's name, the time, Mute, and "Return to call", like a Slack huddle
  bar. The call stays visible even when its window is behind others.

### Incoming calls

- **A notification, not a ring**: neither official app rings. A **live**
  type 32 (never history, and only if its timestamp is within two minutes)
  whose link passes `CallLink` validation posts through `Notifier` (a type
  32 with any other link is never announced as a call):
  - In a DM: "Alice started a video call", with a **Join** action.
  - In a tribe: "Alice started a call in #design", following that tribe's
    notification level (muted or mentions-only tribes stay quiet).
  - Clicking the notification opens the chat at the card; Join joins
    directly.
- No sound loop, no full-screen prompt and no missed-call state in v1. The
  card already says who is on the call.

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
    (`Media.swift:315-344`). Never `URLSession.shared` (used today by
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
    leak.
  - The SFU sees all media: calls are not end-to-end encrypted, here or in
    the official apps.
- **A hostile call message** cannot steer Peel elsewhere:
  - The link must be `https` (plain `http` only when the configured call
    server is itself loopback, exactly `127.0.0.1`, `localhost` or `::1`,
    `ServerAddress.isLoopback` in `Transport.swift:37-39`, as
    `MemesServer.redirect` uses it, `Media.swift:336-338`). Its host,
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

- **SDK**: `livekit/client-sdk-swift`, latest **2.17.0** (2026-09-14). Its
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
   list a migration reads.
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
7. **Notifications.**
   - Live type 32 posts through `Notifier` with a Join action, following
     tribe levels, only when its link passes `CallLink` validation. History
     never notifies.
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
- **`mediaHosts` is empty** until Tom's production check names the
  LiveKit host. Until then a production ticket whose `serverUrl` is not on
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

## Decided (Tom, 2026-10-08)

Tom approved the five defaults PR 1 used:

1. **Form** (question 1): Peel sends `call::{"link":…,"recurring":false,"cron":""}`
   and reads both forms.
2. **Room names** (question 2): random 128 bits, `sphinx.call.<32 hex>`.
3. **Price** (question 3): only the 3-sat floor in a paid tribe.
4. **Pubkey in metadata** (question 5): left out; PR 2 sends only the
   photo URL.
5. **Hive** (question 8): join only. Hive links are read and validated,
   never made.

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
