# Peel

Last updated 2026-10-07. This is the architecture and the phase index. Each phase
has its own file under `docs/phases/` with what is done, what is in progress and
what is next.

## Why

The official Sphinx clients (iOS, Mac, Android) are old and heavy. Peel is a
from-scratch native client that connects to the same server, is
indistinguishable to colleagues at the protocol level, and could replace the
official apps if it turns out better. Mac first, iPhone second.

Only what other clients and the server can observe is fixed: the core's wire
protocol, the JSON shape of each message type, and the side services. Everything
else is designed from first principles. "Parity" with the official app means the
same capabilities, not the same screens.

Peel is also the base for the sovereign Sphinx agent: always-on agents, each a
Sphinx account with its own child key, balance and memory, that you talk to by
DM. The engine must therefore run headless and serve both the app and an agent
host. The engine stays Swift for now (decided 2026-10-07); a separate always-on
engine is a later phase. See [agent-native.md](agent-native.md) before changing
the architecture.

## Architecture

```
┌──────────────────────────────┐   ┌──────────────────────┐
│ PeelApp (SwiftUI, Mac)       │   │ peel (CLI harness)   │
│ AppModel · views             │   │ dev and testing only │
└──────────────┬───────────────┘   └──────────┬───────────┘
               │                              │
┌──────────────▼──────────────────────────────▼───────────┐
│ PeelCore (Swift package, no UI)                         │
│                                                         │
│  Engine (actor)  ── runs core calls, commits state,     │
│       │             performs the network work           │
│       ├── Storage (GRDB / SQLite): core state, settings,│
│       │   messages, contacts, live queries              │
│       └── Transport (mqtt-nio): one signed MQTT session │
└──────────────┬──────────────────────────────────────────┘
               │ Sphinxrs (generated Swift bindings)
┌──────────────▼──────────────────────────────────────────┐
│ Rust core: stakwork/sphinx via sphinx-rs/sphinx-ffi      │
│ keys, onions, key exchange, tribes, invoices, routing   │
└─────────────────────────────────────────────────────────┘
               │ MQTT over TLS
        broker + mixer (the LSP), tribes server, memes,
        LiveKit, hub (push), config endpoint
```

### The core contract

The core is a library of pure functions. Each call takes the seed, a unique
time and the whole state (a MessagePack map), and returns a `RunReturn`: state
entries to save or delete, topics to subscribe, payloads to publish, messages
that arrived, balance, reads, mutes, payments, errors. `Engine.run` is the whole
contract: run the call, commit the returned state before anything else can run,
then perform the network work in the order the core gave it. Everything the
client does is a sequence of such calls.

Reference implementations, in order of authority:

1. The core itself: `~/Documents/sphinx/sphinx/src/bindings/`.
2. The core's own TypeScript client: `~/Documents/sphinx/wasm/test/auto/`
   (`main.ts` has `handle_rr`, the contract in 180 lines).
3. The official Mac app, for message conventions the core does not define:
   `~/Documents/sphinx-mac-v2/.../Crypter/SphinxOnionManager+*.swift`.

### Storage

One SQLite file per account (`peel.sqlite`, WAL). Tables: `coreState` (opaque
key/value owned by the core), `setting`, `message` (upsert on uuid; raw sender
and body JSON kept alongside extracted columns), `contact` (names and photos,
which are not core state). Live queries use GRDB `ValueObservation`.

### Identity and secrets

The twelve-word mnemonic is the account. Today it lives in a plain file inside
the profile directory (`Profile`), which is only acceptable for the throwaway
account. Keychain storage is phase 2 work. Core state holds contact keys and the
device's child-key indices; it is sensitive but not the seed.

### Platform

macOS 14+, Swift 6 strict concurrency in PeelCore and PeelApp. The generated
bindings compile in Swift 5 mode. The Rust static library comes prebuilt from
the Mac app's repo; building it from source needs Rust 1.88.0. This Mac has
only the command-line tools: builds use `swift build` and the app bundle is
assembled by `scripts/run-app.sh`.

## Phases

| # | Phase | Status | File |
|---|-------|--------|------|
| 1 | Core and account | done, in daily-use trial | [phases/01-core.md](phases/01-core.md) |
| 2 | Restore, secrets and the rest of messaging basics | next | [phases/02-messaging.md](phases/02-messaging.md) |
| 3 | Tribes, threads and attachments | planned | [phases/03-chat.md](phases/03-chat.md) |
| 4 | Money | planned | [phases/04-money.md](phases/04-money.md) |
| 5 | Parity: contacts, profile, People, web apps, languages | planned | [phases/05-parity.md](phases/05-parity.md) |
| 6 | Calls | planned | [phases/06-calls.md](phases/06-calls.md) |
| 7 | iPhone | planned | [phases/07-iphone.md](phases/07-iphone.md) |

## Scope (decided 2026-10-05)

In v1: onboarding (invite signup, mnemonic restore, name, PIN, photo); contacts
as the Mac app does them; payments (send in chat, pay invoice, request, boosts)
plus a new Receive screen; chat with tribes, attachments, threads and replies,
LiveKit calls; web apps; People and LSATs; paid messages and templates; six
languages. Later: AI Agent. Out: feeds and podcasts, Strut dictation, Hive
workspaces, Tor and relay-era code, Jitsi.

## Open questions


- Install Xcode on this Mac? Needed for a signed bundle, entitlements, Keychain
  access groups, TestFlight and the iPhone target.
- Build the Rust bindings from source or keep using the prebuilt library?
- Repo hosting: local only so far.

## Accounts

- Throwaway account: profile `throwaway`, alias "Peel", created from Tom's
  invite on 2026-10-07. Its only contact is Tom's real account. Mnemonic at
  `~/Library/Application Support/Peel/dev/throwaway/mnemonic`. Never develop
  against a real account.
- Production broker: `mqtt-broker.v2.sphinx.chat:8883` (valid Let's Encrypt
  certificate). Config endpoint:
  `https://config.config.sphinx.chat/api/config/bitcoin`.
