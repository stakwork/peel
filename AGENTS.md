# Agent Guide

Peel is a native Sphinx chat client written from scratch in Swift on the shared
Rust core. Read `docs/PLAN.md` first (architecture and phase index), then the
phase you are working on under `docs/phases/`. A phase with work done opens
with a short status (built, open, decided) above its journal; a planned one
is a short plan. Update the status and the journal when you finish something.

## Project layout

- `Sources/PeelCore/` — the client engine, no UI
  - `Engine.swift` — the actor that drives one account: its stored state and
    init, the connection and reconnect loop, and the core contract (`run`,
    `commit`, `complete`, `receive`): runs core calls, commits the state they
    return in one transaction, performs the subscribes and publishes they ask
    for. The rest of the engine is extensions by area. Stored state, helpers
    and nested types the extensions share are internal rather than private,
    so the module, not the file, is the boundary (`seed` among them: never
    read it, or call `run`/`commit`, from outside the engine files). What
    only `Engine.swift` writes keeps `private(set)`, `state` above all: it
    changes only in `init` and `commit`.
    - `EngineTypes.swift` — `Event`, `Failure` (refusals and their words),
      `ConnectionState`, `Contact`, `Invite`, `JoinRequest` and the other
      public nested types
    - `Engine+Account.swift` — mnemonics, invites, the contact and
      registration helpers, the account's name and photo, mention re-scans,
      settings and server hosts
    - `Engine+Messages.swift` — contacts, text, deletes, resends, discards,
      `deliver` (every message through the core), the `openTribe`,
      `isContact` and `knownTribe` lookups, read markers and mutes
    - `Engine+Payments.swift` — payments, boosts, confirmation thresholds,
      invoices (made, requested, paid), payment history
    - `Engine+Attachments.swift` — sending, downloading and buying
      attachments; the memes server sign-in
    - `Engine+Calls.swift` — the call server, call links, tickets, presence
    - `Engine+Tribes.swift` — join, leave, create, edit, members, approvals,
      the tribes registry and its background refresh
    - `Engine+History.swift` — restore and catch-up: history runs, paging,
      the stall watchdog, recovering the account's own photo
  - `Account.swift` — load, signup, create and restore: the one place that
    decides where the mnemonic, the server and the tribes host come from
  - `Storage.swift` — SQLite via GRDB for one profile: init, the profile lock,
    core state and settings
  - `Models.swift` — the public value types Storage returns: `Setting`,
    `Conversation`, `MuteLevel`, `ChatReadState`, `Timeline`, `BoostSummary`,
    `ThreadSummary`, `ChatThread`
  - `Storage+Reads.swift` — reads and live queries: conversations, read
    states, tribes and their senders, mentions, payments, the shared SQL
    (`tribeChats`, `chatsSQL`, `countsAsUnreadSQL`)
  - `Storage+Threads.swift` — replies and threads: `timeline(in:)` (tribe
    threads collapsed), `thread(_:in:)`, `threads()`, parents, boosts and
    thread summaries
  - `Storage+Writes.swift` — writes: `Commit` and `apply` (one core call's
    changes in one transaction), message upsert and deletes, read markers,
    mutes, send status, invoices, uploads, contacts and tribes
  - `Storage+Migrations.swift` — the schema migrations: append-only, never edit a
    shipped one, literal values only (no live `MessageType` or `Tribe.Status`)
  - `Tribe.swift` — tribe records, tribe links, the tribes server's registry
  - `PersonHue.swift` — a person's colour (direction D): the official apps'
    colour key and its hue, FNV-1a mod 8
  - `Call.swift` — `CallLink`: reads and validates call links against the
    account's call server, and makes new rooms (phase 6)
  - `CallServer.swift` — the call server: `CallTicket` (`GET
    /api/connection-details`, the media server allowlist, the token's claims;
    never stored or logged) and the `/ws` presence feed (`CallPresence`), one
    per engine
  - `Media.swift` — what an attachment is: `AttachmentKind` (by its bytes),
    `OutgoingFile`, media tokens, `AttachmentFields`, `DownloadedAttachment`
  - `MediaCrypto.swift` — the official apps' attachment encryption
    (RNCryptor v3)
  - `MemesServer.swift` — the memes server: sign-in, upload, download, the
    transfer with its size limit and progress
  - `MediaStore.swift` — the profile's `media/` cache and outbox
  - `Files.swift` — `ImageDecoding`, `ProfilePhoto` and `UserFiles` (files
    saved for the person, quarantined)
  - `IncomingFiles.swift` — attachments that arrive by drag or paste: which
    pasteboard items attach, image bytes and promised files written to Peel's
    own temp folder and checked
  - `MessageMarkup.swift` — how message text reads: paragraphs, list items,
    fenced code, and inline code, https links and mentions; `plainText`, the
    one line that previews show
  - `TimeZones.swift` — time zones: the offset in a message's `metadata`
    (sent unless the chat's switch is off, never to a public tribe; read
    with Peel's own parser), the per-chat `chatTimeZone` rows, `localTime(of:)`
  - `Transport.swift` — one MQTT connection (mqtt-nio); `ServerAddress`
  - `StateCodec.swift` — the MessagePack shape the core uses for its state
  - `Profile.swift`, `SecretStore.swift` — a local account: `.app` profiles keep
    the words in the data-protection Keychain sealed under a six-digit PIN
    (moved there from the login Keychain on first unlock), `.development`
    profiles in a plain file with no PIN (CLI only)
  - `ServerConfig.swift` — the public config endpoint a restore reads
  - `Web.swift` — every request outside the memes server (photos, the tribes
    registry, the config): ephemeral sessions (also the memes server's), the
    size-limited `get`, and the public-https host check
- `Sources/PeelApp/` — the SwiftUI Mac app (`AppModel`, `MainView`,
  `ConversationView`, `TribeViews`, `OnboardingView`, `LockView`, `AccountView`;
  for the chat: `ChatModel` (replies, threads, sending, attachments),
  `MessageViews`, `ThreadViews`, `AttachmentViews`, `ComposerView`,
  `ImageViewer`, `PasteboardFiles` (drop and paste into the tray), `PaymentViews` (boosts, payment rows, send sats), and `PeelMenu`, the one menu used instead of native ones;
  `CopyFeedback` (`CopyButton` and the menu's "Copied" pill, for every copy);
  `CallViews` (the call card, the header's call button and presence
  watching, the in-place switch confirm, the sidebar's on-a-call bar),
  `CallSession` (the call you are on: the LiveKit room, microphone, camera
  and devices) and `CallWindow` (the grid and the control bar);
  `ButtonStyles` (`GhostButtonStyle`, `PrimaryButtonStyle`, and
  `buttonProgress`, the spinner inside a running button);
  `TimeZoneViews` (the run header's "14:05 local", the DM header's local
  time, the hover card, a chat's details panel with the time zone switch);
  `Notifier` for local notifications and the Dock badge; `MoneyArrivals` for
  sats received: the header's count-up, the Payments row's "+350", one
  notification per arrival; `CallTestRoom`, the development-only LiveKit
  test room (phase 6, PR 3). PeelApp is the only target that links LiveKit
  and WebRTC)
- `Sources/peel/` — command-line harness for PeelCore
  - `PeelCommand.swift` — usage and dispatch; `Invocation` (one run's
    options and remaining arguments, `load()`, `readOnlyStorage()`) and the
    argument helpers the areas share
  - `Commands+Account.swift`, `Commands+Chat.swift`, `Commands+Tribes.swift`,
    `Commands+Money.swift`, `Commands+Calls.swift` — the commands by area,
    each an `Invocation` method that returns false for a command not its own
  - `Output.swift` — `Session` (an engine with its events printed) and the
    row and payment lines every command prints
- `Sources/Sphinxrs/` and `Vendor/` — generated bindings and the core's static
  library, produced by `scripts/build-ffi.sh`; not checked in
- `Tests/PeelCoreTests/` — offline unit tests for PeelCore (see Tests below)
- `scripts/build-ffi.sh` — assembles the bindings from sibling `sphinx-rs` and
  `sphinx-mac-v2` checkouts
- `scripts/bundle-app.sh` — builds the Mac app and wraps it as a signed bundle
  (default `.build/Peel.app`, or the path given), without installing it;
  embeds the frameworks the app loads through `@rpath` (LiveKit's
  `LiveKitWebRTC.framework`) in `Contents/Frameworks`
- `scripts/run-app.sh` — `bundle-app.sh`, then installs to
  `~/Applications/Peel.app` and opens it from there (so a Dock pin survives rebuilds)
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
./scripts/run-app.sh -profile throwaway      # app: single dash, read via UserDefaults
.build/debug/peel --profile throwaway listen  # CLI: double dash
```

`scripts/build-ffi.sh` checks the static library against `Vendor/sphinxrs.lock`
(sha256 plus the `sphinx-rs` commit); pass `--update` after deliberately taking a
new build of the core.

The app bundle is assembled by hand in `scripts/bundle-app.sh`; there is no
Xcode project for the app itself. To check a build without replacing the
installed app, `./scripts/bundle-app.sh /some/dir/Peel.app`.

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
query keys) and the call server setting; call tickets (strict query encoding,
the media server allowlist, token claims, the token never described, and a
fetch from an in-process loopback stub that leaves no cookie or URL cache) and
the presence feed (each message, names, photos, joins and leaves); time zones (the offset's format and
parser, malformed metadata, the per-chat switch and public tribes, the
stored tribe record and its background recheck, local
times, a sender's zone at a moment for a page of runs, the v14 column on stored history); refusals as typed
`Engine.Failure` cases with their words; and the whole migration chain from a v1
database, with the literals frozen into shipped migrations. Nothing talks to
a broker: anything protocol-level is still verified against the local test
server.

### Local LiveKit server

For the development test room (`Sources/PeelApp/CallTestRoom.swift`;
details in `docs/phases/06-calls.md`, PR 3 journal):

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
`sphinx-swarm` (which points at the hosted one). Local tests use a throwaway
stub of the endpoints in `docs/phases/03-chat.md` ("How attachments work"),
not kept in the repo, on a free port; pass `--memes-host 127.0.0.1:<port>` to
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
  only ever name themself. For a live message the child index in the topic
  names the contact as well and `Engine` requires the two to agree. History
  (`batch`) messages are accepted only from contacts the core knows. Contact
  records (type 33) are honoured by the core only when signed by this account.
- Names and photos are not core state; they arrive with messages and invites.
  A contact is a conversation only once the core holds their key (`ready`).

## Rules

- The app's profile `default` (`~/Library/Application Support/Peel/default`,
  words in the data-protection Keychain) holds Tom's REAL account since
  2026-10-07. Never open, test against, migrate, copy or delete it, and never
  run `scripts/run-app.sh` (it replaces the Peel Tom uses every day); build
  with `scripts/bundle-app.sh` into `.build` and launch with `-profile <dev>`.
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
  `mqtt://` scheme or a loopback host, and the scheme is persisted. The
  `--insecure` flag (CLI only) disables certificate verification.
- Never log the seed, the mnemonic, or invite links.
- Never use `URLSession.shared` (its disk cache records what was fetched and
  its redirects go anywhere): fetch with `Web.get` (size-limited; a public
  https host, or loopback http for the local test stack), or through the memes
  server. A photo someone else chose goes through `Web.photo`.
- Swift 6 language mode with strict concurrency in `PeelCore` and `PeelApp`.
  Actors for shared state, `@MainActor` for UI. `Sources/Sphinxrs` is generated
  and compiles in Swift 5 mode; do not edit it.
- Do not add a dependency for something under a hundred lines.
- Keep the engine agent-ready (`docs/agent-native.md`): no UI types, global
  state or single-account assumptions in `PeelCore`; every user action is an
  engine operation, never logic inside a view; message conventions live in the
  engine.
- UI follows `docs/design/README.md` (Slack-style layout, Sphinx colours and
  the system font) and Tom's `tom-ui` and `taste` skills: colour is state, not
  decoration; no red for ordinary failure; restraint in motion.
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
   the server sees. Never a real account.
4. **Review.** `/code-review` for correctness, `/simplify` for reuse,
   simplicity, efficiency and altitude (it applies its fixes), then
   `/security-review`. Fix what they find. Findings deliberately not applied go
   in the phase file with the reason.
5. **Record.** Update the phase file (done, learned, next) and this file if the
   layout or rules changed.
6. **Ship.** Commit with a plain message and push.

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
