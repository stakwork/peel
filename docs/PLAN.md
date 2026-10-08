# Peel

Last updated 2026-10-08. This is the architecture and the phase index. Each phase
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

Peel is also the client for Tom's personal Sphinx agent: one agent contact, a
Sphinx account of its own on an always-on host, with graph memory in LadybugDB,
jobs run by Strut, and coding workers such as Claude Code behind it over ACP.
The engine must therefore run headless and serve both the app and the agent
host. The engine stays Swift for now (decided 2026-10-07). The design is in
[agent-architecture.md](agent-architecture.md) and the engine rules in
[agent-native.md](agent-native.md); read both before changing the
architecture.

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

One SQLite file per account (`peel.sqlite`, WAL), built by the migrations in
`Storage+Migrations.swift` (`v1` on, append-only). Eleven tables:

- `coreState`: opaque key/value owned by the core.
- `setting`: the account's own values (server, name, photo, balance,
  clock, tribes and memes hosts, payment thresholds and more).
- `message`: upsert on uuid; raw sender and body JSON kept alongside
  extracted columns (replies and threads, attachments, mentions, amounts,
  deleted).
- `contact`: names and photos, which are not core state; `ready` once the
  core holds the contact's key; `isNew` for someone who added this account,
  until their chat is opened.
- `chatState`: read markers, mute levels and a marker not yet sent.
- `tribe`: what the registry says about a tribe, this account's membership
  status and the pinned message.
- `payment`: the server's payment history (`fetch_payments`).
- `invoice`: invoices made or paid here.
- `paymentPing`: the 1-sat pings that belong to an asynchronous payment.
- `chatTimeZone`: whether this account shares its time zone in each chat.
- `invite`: invites made here with sats (the core keeps none), by code.

The money tables' records are in `Invoice.swift` and their joined history in
`PaymentHistory.swift`. Live queries use GRDB `ValueObservation`.

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

Rows are in build order (decided 2026-10-08 night, below). The numbers are
the phase files' names and stay as they are; "—" rows have no phase file.

| # | Phase | Status | File |
|---|-------|--------|------|
| 1 | Core and account | done | [phases/01-core.md](phases/01-core.md) |
| 2 | Safe accounts: Keychain, PIN, onboarding, restore | core goal reached; leftovers listed in the file | [phases/02-messaging.md](phases/02-messaging.md) |
| 3 | Tribes, threads and attachments | built and merged: tribes with parity, replies and threads, attachments, the chat UI, notifications, mark as unread; leftovers listed in the file | [phases/03-chat.md](phases/03-chat.md) |
| 4 | Money | built and merged: boosts, in-chat payments, the Payments screen, invoices, requests in chat, paid attachments; payment templates moved to the v1 extras step; Lightning-backed tests open | [phases/04-money.md](phases/04-money.md); Payments screen plan: [phases/04-payments-screen-plan.md](phases/04-payments-screen-plan.md) |
| 6 | Calls (LiveKit) | built: PRs 1–7 merged (#44, #54, #55, #59, #64, #70, #74); PR 8 open | [phases/06-calls.md](phases/06-calls.md) |
| — | File splits | done: the move-only splits of refactor rows 10–13 (MainView, PeelMenu and Media; Storage; Engine; PeelCommand); row 12's one `JSON.decode` helper (decode the body once) is still open | [reviews/2026-10-08-architecture.md](reviews/2026-10-08-architecture.md), "Refactor plan" |
| 5 | Parity: contacts and the in-app web window | built: the Account screen, the web pane (#73), contacts (#75); self-hosted certificates move to the rest of phase 10 | [phases/05-parity.md](phases/05-parity.md) |
| — | 1. Cleanup | **next**: the second review's cleanup plan: wave 1 bug fixes (batches 1–5), then core tidy, notification policy, money sends, network helpers, app reads, engine structure and the shared app pieces; it folds in the first review's open rows 6, 8, 12 and 14–18. Row 9 (styles and confirm controls) moves to the polish pass's form system; the iPhone model-sharing seams are a later batch (17) | [reviews/2026-10-08-second-review.md](reviews/2026-10-08-second-review.md), "Cleanup plan" |
| — | 2. Polish | a pass over the app: the form and popover redesign (which takes in first-review row 9, styles and confirm controls), and the tribe header as Call plus a More menu | — |
| 10 | 3. Markdown in messages | pulled forward from phase 10, because agent replies are Markdown | [phases/10-v1-extras.md](phases/10-v1-extras.md), item 2 |
| 9 | 4. The personal agent: one agent contact, the agent host, workers over ACP, then graph memory and Strut jobs | planned; the plan was refreshed 2026-10-08 | [agent-architecture.md](agent-architecture.md); [phases/09-agents.md](phases/09-agents.md) |
| 10 | 5. The rest of the v1 extras: search and ⌘K, voice messages, Giphy, payment templates, preferences sync, self-hosted certificates | planned; findings from the official app recorded | [phases/10-v1-extras.md](phases/10-v1-extras.md); templates in 04, sync and certificates in 05 |
| 7 | 6. iPhone | paused (2026-10-08); push notifications ignored for now | [phases/07-iphone.md](phases/07-iphone.md) |
| 8 | 7. Audit before sharing: whole-repo review, features frozen | planned | [phases/08-audit.md](phases/08-audit.md) |
| — | Later: agent Connections (calendar first, then email, contacts, files and notes) | ideation | [agent-architecture.md](agent-architecture.md), "Connections" |

### Refactor plan status

From [reviews/2026-10-08-architecture.md](reviews/2026-10-08-architecture.md),
"Refactor plan", as of 2026-10-08 evening:

- Merged: rows 1 (#30), 2 (#31), 3 (#32), 4 (#37) and 5 (#33).
- In review: row 7, typed engine failures (#57).
- Started: row 12, splitting Engine. Part of it is under way, but nothing
  is on `origin` yet.
- Next, with the file splits: rows 10, 11, 12 (the rest) and 13.
- After contacts and the web window: rows 8, 9, 14, 15, 16, 17 and 18.
- Not placed in the evening order: row 6, one sender resolution. The
  "Someone" fallback is still written in several views.
- Since then (`cd194a0`): rows 7 and 10–13 merged, apart from row 12's
  `JSON.decode` helper. The open rows are now batches in
  [reviews/2026-10-08-second-review.md](reviews/2026-10-08-second-review.md),
  "Cleanup plan", which this list no longer tracks.

## Scope (decided 2026-10-05, changed 2026-10-08 twice)

In v1:
- Onboarding: invite signup, mnemonic restore, name, PIN, photo.
- Contacts as the Mac app does them.
- Payments: send in chat, pay an invoice, request, boosts, plus a new
  Receive screen. Paid messages and templates.
- Chat: tribes, attachments, threads and replies, LiveKit calls, search in
  a chat and a ⌘K palette across the app, Markdown, voice messages, Giphy.
- An in-app web window for links and tribe apps.
- Preferences sync and self-hosted certificates.

The personal agent (phase 9) is built after Markdown and before the rest
of the v1 extras (decided 2026-10-08 night). Out of v1: People (the public profile and bounty
directory at people.sphinx.chat), LSATs, languages, feeds and podcasts,
Hive workspaces, the knowledge graph view, Jitsi, Strut dictation, Tor and
relay-era code.

## Decided 2026-10-08 (night, Tom)

This replaces the order in "Decided 2026-10-08 (evening, Tom)" below.

- **Peel's real purpose** is to become the client for a personal Sphinx
  agent: one agent contact, graph memory in LadybugDB, jobs run by Strut.
  The agreed design and the open decisions are in
  [agent-architecture.md](agent-architecture.md). It supersedes PR #15's
  "an agent is a contact; the harness is a setting": workers such as Claude
  Code are not contacts.
- **Order:**
  1. Cleanup: the second review's cleanup plan
     ([reviews/2026-10-08-second-review.md](reviews/2026-10-08-second-review.md)).
  2. Polish, including the form and popover redesign and the tribe header
     as Call plus a More menu.
  3. Markdown in messages, pulled forward from phase 10, because agent
     replies are Markdown.
  4. The personal agent ([phases/09-agents.md](phases/09-agents.md)): the
     refreshed plan, then the agent host and the agent as a contact over
     ACP, then graph memory.
  5. The rest of phase 10: ⌘K search, voice, Giphy, payment templates,
     preferences sync, self-hosted certificates.
  6. iPhone, paused; push notifications ignored for now.
  7. The audit.
- **Later:** Connections for the agent (calendar first), after graph memory.

## Decided 2026-10-08 (evening, Tom)

This replaced the order in "Decided 2026-10-08" below, and is itself
superseded by the night decision above.

- **Added to v1:** search (in a chat, and a ⌘K palette over every chat's
  messages, people and tribes), Giphy, voice messages, and Markdown beyond
  the inline code and fences of #41. What the official app does for each
  is in [phases/10-v1-extras.md](phases/10-v1-extras.md).
- **Confirmed out of v1:** People, LSATs, languages, feeds and podcasts,
  Hive workspaces, the knowledge graph view and Jitsi.
- **Order:**
  1. Finish calls: PRs 4–8 of [phases/06-calls.md](phases/06-calls.md).
  2. The file splits (refactor rows 10–13), done while things are quiet.
  3. Contacts (scan a QR, invites with sats, inbound requests) and the
     in-app web window.
  4. The remaining cleanup rows: 8, 9, 14, 15, 16, 18, and the docs
     refresh (17).
  5. A general polish pass over the app.
  6. The v1 extras (search and ⌘K, Markdown, voice, Giphy, payment
     templates, preferences sync, self-hosted certificates), then the
     iPhone, the audit and local runtimes.

## Decided 2026-10-08 (Tom)

Its order is superseded by the evening decision above.

- **Order:** the architecture-review cleanup, then calls, then parity, then
  the iPhone.
- **Cleanup first.** Finish the refactor plan's open rows in
  [reviews/2026-10-08-architecture.md](reviews/2026-10-08-architecture.md)
  before new features.
- **Calls before parity.** LiveKit calls are core messaging and needed for
  daily use. Its plan is in [phases/06-calls.md](phases/06-calls.md).
- **Parity, narrowed** ([phases/05-parity.md](phases/05-parity.md)): keep
  the contacts UI (QR, invites, inbound requests) and self-hosted
  certificates; web apps become an in-app web window; People, LSATs and
  languages move out of v1.

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
