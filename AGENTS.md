# Agent Guide

Peel is a native Sphinx chat client written from scratch in Swift on the shared
Rust core. Read `docs/PLAN.md` first (architecture and phase index), then the
phase you are working on under `docs/phases/`: each says what is done, what is
in progress and what comes next. Update it when you finish something.

## Project layout

- `Sources/PeelCore/` — the client engine, no UI
  - `Engine.swift` — the actor that drives one account: runs core calls, commits
    the state they return in one transaction, performs the subscribes and
    publishes they ask for, owns the connection and reconnect loop
  - `Account.swift` — load, signup, create and restore: the one place that
    decides where the mnemonic and server come from
  - `Storage.swift` — SQLite via GRDB: core state, settings, messages, contacts,
    live queries (`conversations()`, `messages(in:)`); holds the profile lock
  - `Transport.swift` — one MQTT connection (mqtt-nio); `ServerAddress`
  - `StateCodec.swift` — the MessagePack shape the core uses for its state
  - `Profile.swift`, `SecretStore.swift` — a local account: `.app` profiles keep
    the words in the Keychain, `.development` profiles in a plain file (CLI only)
  - `ServerConfig.swift` — the public config endpoint a restore reads
- `Sources/PeelApp/` — the SwiftUI Mac app (`AppModel`, `MainView`,
  `ConversationView`, `OnboardingView`)
- `Sources/peel/` — command-line harness for PeelCore
- `Sources/Sphinxrs/` and `Vendor/` — generated bindings and the core's static
  library, produced by `scripts/build-ffi.sh`; not checked in
- `scripts/build-ffi.sh` — assembles the bindings from sibling `sphinx-rs` and
  `sphinx-mac-v2` checkouts
- `scripts/run-app.sh` — builds, bundles and opens the Mac app
- `scripts/build-icon.sh` — renders `Assets/peel.svg` into `Assets/AppIcon.icns`

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

Xcode is installed, but there is no Xcode project yet (phase 2 adds one for a
signed bundle). Until then build with `swift build`; the app bundle is
assembled by hand in `scripts/run-app.sh`.

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
- The sender inside a message is self-declared. For a live message the child
  index in the topic names the contact whose key decrypted it, and `Engine`
  files the message under that contact; names and photos are only taken from
  senders that match. History (`batch`) messages carry no index, so they are
  accepted only from known contacts and never rename anyone.
- Names and photos are not core state; they arrive with messages and invites.
  A contact is a conversation only once the core holds their key (`ready`).

## Rules

- Develop against the throwaway account (profile `throwaway`), never a real
  one. Do not call `setPushToken` for a real account: the server keeps one push
  token per account and it would take notifications away from the official app.
- One process per profile: `Storage` takes a lock, so a second app or CLI on the
  same profile fails with "another Peel process is using ...". Quit the other one.
- TLS is on by default; `ServerAddress` only goes plaintext for an explicit
  `mqtt://` scheme or a loopback host, and the scheme is persisted. The
  `--insecure` flag (CLI only) disables certificate verification.
- Never log the seed, the mnemonic, or invite links.
- Swift 6 language mode with strict concurrency in `PeelCore` and `PeelApp`.
  Actors for shared state, `@MainActor` for UI. `Sources/Sphinxrs` is generated
  and compiles in Swift 5 mode; do not edit it.
- Do not add a dependency for something under a hundred lines.
- Keep the engine agent-ready (`docs/agent-native.md`): no UI types, global
  state or single-account assumptions in `PeelCore`; every user action is an
  engine operation, never logic inside a view; message conventions live in the
  engine.
- UI follows `docs/design/README.md` (Slack-style layout, Sphinx colours and
  Roboto) and Tom's `tom-ui` and `taste` skills: colour is state, not
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
