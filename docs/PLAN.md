# Peel

Last updated 2026-10-16. This is the architecture and the phase index. Each phase
has its own file under `docs/phases/` with what is done, what is in progress and
what is next.

**Before a stable build:** five foundation decisions and the road to stable
are in [foundation.md](foundation.md) (2026-10-16). Where this page's
architecture disagrees with [brain-handover.md](brain-handover.md), it is
under review until those decisions are answered.

## Why

The official Sphinx clients (iOS, Mac, Android) are old and heavy. Peel is a
from-scratch native client that connects to the same server, is
indistinguishable to colleagues at the protocol level, and could replace the
official apps if it turns out better. Mac first, iPhone second.

Only what other clients and the server can observe is fixed: the core's wire
protocol, the JSON shape of each message type, and the side services. Everything
else is designed from first principles. "Parity" with the official app means the
same capabilities, not the same screens.

Peel is also the client for the Sphinx agent. The agent runs inside Peel
(Mac now, iPhone next, an always-on server later) and walks a LadybugDB graph
that is the same on every device and in the official Sphinx apps, synced as an
encrypted change log on the memes server (decided 2026-10-10). The engine must
therefore stay free of UI types, so the same code can later run headless. The
engine stays Swift for now (decided 2026-10-07). The design is in
[agent-architecture.md](agent-architecture.md) and the engine rules in
[agent-native.md](agent-native.md); read both before changing the
architecture.

The target layout and visual language are in [design/README.md](design/README.md):
Slack-style tribes, direct messages and threads, in Sphinx's colours.

## Architecture

```
┌──────────────────────────────┐   ┌──────────────────────┐
│ PeelApp (SwiftUI, Mac)       │   │ peel (CLI harness)   │
│ views · Mac services         │   │ dev and testing only │
├──────────────────────────────┤   │                      │
│ PeelUI: AppModel, shared     │   │                      │
│ with the iPhone              │   │                      │
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
- `setting`: the account's own state and configuration (server, name,
  photo, balance, clock, tribes, memes and call servers and more).
- `preference`: every user setting (`Preferences.swift`), each row the
  official preferences file's item for its key and identifier, with its
  date (phase 11): the boost amount, the confirmation threshold, time
  zones (the account's, and the switch per chat), and this device's PIN
  timeout and notification text.
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

macOS 15+ for the core and CLI, macOS 26+ for the app (the agent's memory: Ladybug's addon is built for 26), Swift 6 strict concurrency in PeelCore, PeelUI and PeelApp. The generated
bindings compile in Swift 5 mode. The Rust static library comes prebuilt from
a `sphinx-rs` release, is pinned by hash and tag in `Vendor/sphinxrs.lock`
and is downloaded by `scripts/build-ffi.sh`; building
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
| 6 | Calls (LiveKit) | built: PRs 1–7 merged (#44, #54, #55, #59, #64, #70, #74); PR 8 (docs only) closed 2026-10-09: later work covered it; done | [phases/06-calls.md](phases/06-calls.md) |
| — | File splits | done: the move-only splits of refactor rows 10–13 (MainView, PeelMenu and Media; Storage; Engine; PeelCommand); row 12's one `JSON.decode` helper (decode the body once) followed in cleanup batch 7 (#94) | [reviews/2026-10-08-architecture.md](reviews/2026-10-08-architecture.md), "Refactor plan" |
| 5 | Parity: contacts and the in-app web window | built: the Account screen, the web pane (#73), contacts (#75); self-hosted certificates move to the rest of phase 10 | [phases/05-parity.md](phases/05-parity.md) |
| — | 1. Cleanup | done through batch 15 (#78–#81, #90, #92, #94, #96–#98, #100, #101, #104, #106, #108, #109), with batch 16, this docs refresh. Proposed, not started: batch 15b (`ComposerStore`, `CallState`, one balance, and settings kept fresh from the engine, which is a behaviour change for Tom: a CLI change on the same profile would show in the app). Later: batch 17, the iPhone seams, when the iPhone work resumes. It folded in the first review's open rows 6, 8, 12 and 14–18; row 9 (styles and confirm controls) moved to the polish pass's form system. **Next**: Markdown in messages | [reviews/2026-10-08-second-review.md](reviews/2026-10-08-second-review.md), "Cleanup plan" |
| — | Hardening (2026-10-08, beside cleanup) | done: integration journeys on the local stack with the real core (#91) and the three-part security audit (#86, #87, #88, with follow-ups in #89). The click-through tests (XCUITest) and an audit of the unit tests were stopped by Tom: "be really pragmatic". Payments correctness review (2026-10-09): Peel's logic holds, but pending payments to offline contacts stay in the balance, failed payments show as received or (after a restore) as sent, and the pinned core trusts the onion's amount; fixes proposed, not started | [testing.md](testing.md); audits in [reviews/](reviews/); payments in [reviews/2026-10-09-payments-correctness.md](reviews/2026-10-09-payments-correctness.md) |
| — | 2. Polish | done 2026-10-09 (forms #85, #99, #105; header #95). A pass over the app: the form and popover redesign (which takes in first-review row 9, styles and confirm controls; step 1 #85, step 2 #99 rolls the forms out and retires the old boxes and confirms; on 2026-10-09 shadcn's form pattern replaces direction A's row fields, and a click outside a field ends editing), and the tribe header as Call plus a More menu | [design/README.md](design/README.md), "Forms" |
| 10 | 3. Markdown in messages | pulled forward from phase 10, because agent replies are Markdown | [phases/10-v1-extras.md](phases/10-v1-extras.md), item 2 |
| — | 3b. Design library and duplication cleanup: one button style with variants and sizes, one panel shell with a placement rule, the composer's buttons inside the field, then cards, badges, rows, empty states and tokens; with the logic fixes it found (tribe prices shown as "Free", error wording, one owner for names, tribe pages and keys). Before the payments correctness fixes and the personal agent | in progress: 15 PRs, buttons and the panel first; batch 1 (`PeelButton`) built 2026-10-09 | [reviews/2026-10-09-design-library.md](reviews/2026-10-09-design-library.md) |
| 9 | 4. The Sphinx agent: AgentKit first (models, the Agent chat, Sphinx tools, compaction), then the graph shared with the official apps and synced as a change log, once agreed with Tom T; always-on, ACP, Strut and the Inbox later | replanned 2026-10-10; v1 planned in phase 9; 09b predates the replan and is kept for its research | [agent-architecture.md](agent-architecture.md); [phases/09-agents.md](phases/09-agents.md); Inbox: [phases/09b-inbox.md](phases/09b-inbox.md) |
| 11 | Preferences and their sync (before the iPhone): one `Preferences` layer owning every setting, the account-wide ones synced through the official apps' encrypted `/preferences` file | planned 2026-10-10: research and architecture; three PRs (plan, layer and migration, sync) | [phases/11-preferences-sync.md](phases/11-preferences-sync.md) |
| 10 | 5. The rest of the v1 extras: search and ⌘K, voice messages, Giphy, payment templates, self-hosted certificates | payment templates built (2026-10-10); the rest planned, findings from the official app recorded | [phases/10-v1-extras.md](phases/10-v1-extras.md); templates in 04, certificates in 05 |
| 7 | 6. iPhone: a full Sphinx client in Liquid Glass (iOS 26), and the remote for the brain through the agent's own Sphinx identity; queues, a Mac mini home server, push via the hub | resumed 2026-10-13: architecture and build order proposed, for Tom's review; spikes S1–S4 first | [phases/07-iphone.md](phases/07-iphone.md) |
| 8 | 7. Audit before sharing: whole-repo review, features frozen | planned | [phases/08-audit.md](phases/08-audit.md) |
| — | Agent jobs and connections: Peel's agent hands any job to Strut with `start_job` / `continue_job` (Hive's pattern); connectors are Strut steps a job may use, tokens in Strut; Calendar stays in Peel (EventKit); writes in a job reach Peel's approval card | architecture proposed 2026-10-13, for Tom's review; PRs J1–J2 (strut), P1–P6 (peel) | [jobs-architecture.md](jobs-architecture.md) |
| — | Peel Brain: the Mac's bundled strut or your own strut on a home server, by URL and key; the graph moves, never syncs; automations by pull; strut's image and a Swarm preset | proposed 2026-10-14, for Tom's review | [peel-brain.md](peel-brain.md) |
| — | Brain handover: the brain is one strut workspace moved whole (memory, automations, secrets, settings); one active brain with a generation; handover parks the old one, which forwards devices to the new | proposed 2026-10-14, for Tom and Evan | [brain-handover.md](brain-handover.md) |
| — | Foundation before stable: five decisions (where the agent loop runs, key derivation, whose account lives on the brain, how devices reach it, backups), then one architecture of record, the small gates in code, the structure, backups and restore, the audit | proposed 2026-10-16, for Tom's answers | [foundation.md](foundation.md) |
| — | Phase 1 of the end state, the agent is a contact: the loop as a strut workflow (`peel-agent`), the agent's own Sphinx account in a Rust bridge bundled in Peel.app, device requests in the agent DM for your chats, sends as you and Calendar (only the Mac answers), one conversation | designed 2026-10-16, for Tom's review; PRs S1 (strut), B1 (bridge), 0–11 (peel); B1's home and PR 10's key derivation wait on Evan | [agent-on-strut.md](agent-on-strut.md) |
| — | Later: Inbox quick capture (⌃⌥Space anywhere sends a line to the agent) | planned after the Inbox | [phases/09b-inbox.md](phases/09b-inbox.md), "Quick capture" |

What is left for parity with the official Mac app, and what to do before
the agent: [reviews/2026-10-09-parity-sweep.md](reviews/2026-10-09-parity-sweep.md) (2026-10-09).

How we find the bugs we have not seen yet, before the team relies on
Peel: [finding-bugs.md](finding-bugs.md) (2026-10-11, proposed). What its
first pass found: [reviews/2026-10-11-bug-hunt.md](reviews/2026-10-11-bug-hunt.md).

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
of the v1 extras (decided 2026-10-08 night). The Inbox is part of the
personal agent, its Wave D (2026-10-09). Out of v1: People (the public
profile and bounty directory at people.sphinx.chat), LSATs, languages, feeds and podcasts,
Hive workspaces, the knowledge graph view, Jitsi, Strut dictation, Tor and
relay-era code.

## Decided 2026-10-09 (Tom): parity before the agent

From the parity sweep ([reviews/2026-10-09-parity-sweep.md](reviews/2026-10-09-parity-sweep.md)):

- **Before the agent:**
  - Pictures are picked, never typed: no memes-server URL is shown or
    entered anywhere (profile photo, tribe image). In progress.
  - A tribe details page, with tags, the tribe's image, and a per-tribe
    alias and photo.
  - Payment templates, and Giphy.
  - The foundation for preferences sync, before the iPhone app.
  - Markdown (in progress), HTML attachments in the web pane (in
    progress), and the payments correctness review (in progress).
- **Tom tests:** signing up with an invite in the app.
- **After the agent:** search and ⌘K, voice messages, the Reply action on
  notifications (a nice-to-have).
- **Dropped:** browsing the tribes directory.
- **Open:** the sweep's other "before agent" items (delete a contact,
  showing received Giphy and animated GIFs, tribe and contact link cards,
  search inside one chat, fuller contact and tribe details).

## Decided 2026-10-09 (Tom): the Inbox is the agent's

- **Agent first.** There is no standalone to-do app before the agent.
  The agent keeps items in its LadybugDB from the first day.
- **The Inbox is a read-mostly view.** It shows the agent's commitments
  to Tom: the open items and their reminder times, one-click tick and
  snooze, and a link to the conversation each item came from.
- **Everything else goes through the agent,** by text or voice:
  capture, questions, grouping, briefs and upkeep.
- **Peel keeps a local cache** for the view and for per-device
  reminders.
- **When:** it is phase 9's Wave D, after graph memory
  ([phases/09b-inbox.md](phases/09b-inbox.md)).
- **Quick capture** (⌃⌥Space) comes later.

## Decided 2026-10-10 (Tom): the agent replanned

This replaces the agent parts of "Decided 2026-10-08 (night, Tom)" below.
The always-on agent host with its own account, Strut and ACP workers was
too much, too early. The design is in
[agent-architecture.md](agent-architecture.md).

- **The agent runs on the client** (Peel on the Mac, then iPhone), with an
  always-on server later running the same code.
- **One graph per user,** the same data on every device and in the official
  Sphinx apps, synced as an encrypted change log on the memes server. Tom T
  is adding LadybugDB to the official apps (`tt/feature/graph-db`); the
  graph tools, the starting ontology and the event format are agreed with
  him before either app writes graph data.
- **Order:** AgentKit first (models, the Agent chat, Sphinx tools,
  compaction), storing its records in SQLite shaped as graph nodes; then the
  graph in Peel, then sync, then iPhone and always-on.

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

Connection control polish (2026-10-15): the Mac bolt now opens a single status
row with a real server check or immediate reconnect. Phase 3 records validation.
