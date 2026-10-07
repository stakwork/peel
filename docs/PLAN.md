# Peel

Last updated 2026-10-07 (evening). This is the architecture and the phase index. Each phase
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

The target layout and visual language are in [design/README.md](design/README.md):
Slack-style tribes, direct messages and threads, in Sphinx's colours.

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

The twelve-word mnemonic is the account. App profiles keep it in the
data-protection Keychain (this device only), sealed under a six-digit PIN
(`SecretStore`); development profiles
used by the CLI keep it in a plain file and are for throwaway accounts only.
The PIN lives only in memory. Core state holds contact keys and the device's
child-key indices; it is sensitive but not the seed. Limits are in phase 2.

### Platform

macOS 15+, Swift 6 strict concurrency in PeelCore and PeelApp. The generated
bindings compile in Swift 5 mode. The Rust static library comes prebuilt from
the Mac app's repo and is pinned by hash in `Vendor/sphinxrs.lock`; building
it from source needs Rust 1.88.0. Xcode is installed and the app is signed
with Tom's Apple Development identity and a Personal Team provisioning
profile that lasts 7 days (`scripts/sign-app.sh`; see "Signing and the weekly
re-sign" in `AGENTS.md`); there is no Xcode project for the app yet, which is
only needed for TestFlight and the iPhone target.

## Phases

| # | Phase | Status | File |
|---|-------|--------|------|
| 1 | Core and account | done | [phases/01-core.md](phases/01-core.md) |
| 2 | Safe accounts: Keychain, PIN, onboarding, restore | core goal reached; leftovers listed in the file | [phases/02-messaging.md](phases/02-messaging.md) |
| 3 | Tribes, threads and attachments | tribes built (branch `phase3/tribes`); threads and attachments planned | [phases/03-chat.md](phases/03-chat.md) |
| 4 | Money | planned | [phases/04-money.md](phases/04-money.md) |
| 5 | Parity: contacts, profile, People, web apps, languages | planned | [phases/05-parity.md](phases/05-parity.md) |
| 6 | Calls | planned | [phases/06-calls.md](phases/06-calls.md) |
| 7 | iPhone | planned | [phases/07-iphone.md](phases/07-iphone.md) |
| 8 | Audit before sharing: whole-repo review, features frozen | planned, after parity | [phases/08-audit.md](phases/08-audit.md) |
| 9 | Local runtimes: dispatch to Claude Code, Goose or Codex | planned, after the agent host | [phases/09-local-tools.md](phases/09-local-tools.md) |

## Scope (decided 2026-10-05)

In v1: onboarding (invite signup, mnemonic restore, name, PIN, photo); contacts
as the Mac app does them; payments (send in chat, pay invoice, request, boosts)
plus a new Receive screen; chat with tribes, attachments, threads and replies,
LiveKit calls; web apps; People and LSATs; paid messages and templates; six
languages. Later: AI Agent. Out: feeds and podcasts, Strut dictation, Hive
workspaces, Tor and relay-era code, Jitsi.

## Working in parallel

Two sessions worked this repo at once on 2026-10-07 with a file split (engine
and CLI in one, app and design in the other) and `main` only, pulling with
rebase before each push. It worked, but it needs the shipping chain in
`AGENTS.md` to run before every push, and commits that build on their own.
From here, prefer a branch and PR per phase task when more than one session
is active.

## Open questions

- Build the Rust bindings from source or keep using the prebuilt library?

## Accounts

- Throwaway account: profile `throwaway`, alias "Peel", created from Tom's
  invite on 2026-10-07. Its only contact is Tom's real account. Mnemonic at
  `~/Library/Application Support/Peel/dev/throwaway/mnemonic`. Never develop
  against a real account.
- Production broker: `mqtt-broker.v2.sphinx.chat:8883` (valid Let's Encrypt
  certificate). Config endpoint:
  `https://config.config.sphinx.chat/api/config/bitcoin`.
