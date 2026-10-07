# Agent Guide

Peel is a native Sphinx chat client written from scratch in Swift on the shared
Rust core. Read `docs/PLAN.md` first: it says what is done, what is being worked
on, and what comes next.

## Project layout

- `Sources/PeelCore/` — the client engine, no UI
  - `Engine.swift` — the actor that drives one account: runs core calls, commits
    the state they return, performs the subscribes and publishes they ask for
  - `Storage.swift` — SQLite via GRDB: core state, settings, messages, contacts,
    live queries (`conversations()`, `messages(in:)`)
  - `Transport.swift` — one MQTT connection (mqtt-nio); `ServerAddress`
  - `StateCodec.swift` — the MessagePack shape the core uses for its state
  - `Profile.swift` — a local account directory; mnemonic in a plain file (dev only)
  - `ServerConfig.swift` — the public config endpoint a restore reads
- `Sources/PeelApp/` — the SwiftUI Mac app (`AppModel`, `MainView`,
  `ConversationView`, `OnboardingView`)
- `Sources/peel/` — command-line harness for PeelCore
- `Sources/Sphinxrs/` and `Vendor/` — generated bindings and the core's static
  library, produced by `scripts/build-ffi.sh`; not checked in
- `scripts/build-ffi.sh` — assembles the bindings from sibling `sphinx-rs` and
  `sphinx-mac-v2` checkouts
- `scripts/run-app.sh` — builds, bundles and opens the Mac app

## Build and run

```sh
./scripts/build-ffi.sh      # once, and after the core changes
swift build
./scripts/run-app.sh --profile throwaway
.build/debug/peel --profile throwaway listen
```

Only the command-line tools are installed on this Mac, not Xcode: build with
`swift build`, not `xcodebuild`. The app bundle is assembled by hand in
`scripts/run-app.sh`.

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
- `send` returns only a tag and a uuid; Peel writes its own outgoing row before
  publishing. The server echoes sent messages to all of the account's devices.
- Names and photos are not core state; they arrive with messages and invites.

## Rules

- Develop against the throwaway account (profile `throwaway`), never a real
  one. Do not call `setPushToken` for a real account: the server keeps one push
  token per account and it would take notifications away from the official app.
- Never run the app and the CLI on the same profile at the same time.
- Never log the seed, the mnemonic, or invite links.
- Swift 6 language mode with strict concurrency in `PeelCore` and `PeelApp`.
  Actors for shared state, `@MainActor` for UI. `Sources/Sphinxrs` is generated
  and compiles in Swift 5 mode; do not edit it.
- Do not add a dependency for something under a hundred lines.
- UI follows Tom's `tom-ui` and `taste` skills: lens is Apple calm; colour is
  state, not decoration; no red for ordinary failure; restraint in motion.
- Keep this file and `docs/PLAN.md` current when you change the layout or
  finish a step.

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
