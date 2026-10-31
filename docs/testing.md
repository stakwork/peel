# Testing plan

Status (2026-10-09): part 1, the integration journeys, is built and
merged (#91), see "Integration journeys: built" below. Part 2, the
click-through tests (XCUITest), and an audit of the unit tests were
stopped by Tom: "be really pragmatic". Tom's
original ask: "do we have any proper tests? … encryption, payments, etc.
Integration and user journey click through tests for real."

## What exists

About 450 tests in `Tests/PeelCoreTests`, run by `swift test`. They test
real logic, mostly without the Rust core or a server:

- Media encryption against an RNCryptor vector; wrong keys and tampering are
  refused.
- The payment gate: balance, confirmation threshold, already paid, own
  invoice (`MoneyRefusalTests`, `PaymentTests`); invoice parsing and amounts.
- Storage against a real SQLite database: migrations, unread counts, threads,
  read markers.
- Call links, time zones, markup, contact codes, dropped connections (fake
  transport).

## What was missing

Written before part 1. Items 1 and 2 are now covered by
`Tests/PeelIntegrationTests`, which runs the real core; item 3 still
stands.

1. **The real core.** Only `PublishPlanTests` calls `Sphinxrs`. Sending,
   receiving, key exchange, payments and invites are tested against fakes.
2. **Integration.** Each PR's end-to-end check was an agent driving the local
   stack by hand. Nothing repeats it.
3. **UI.** `PeelApp` has no test target. Agents cannot click the app
   (synthetic events do not reach a background app, and the terminal has no
   Accessibility permission), so every click-through so far was Tom's.
   Since 2026-10-09 agents drive it offscreen instead, with events posted
   into Peel's own queue and snapshots drawn from its own windows
   (`scripts/check-app.sh`, AGENTS.md "Checking the app").

## Plan

### 1. Integration journeys (`PeelIntegrationTests`)

A test target that boots the local stack (broker, mixer, tribes, a memes
stub, LiveKit when needed) on random free ports from a script, creates two
or three accounts with the real core, and runs journeys through the engine:

- sign up and restore from twelve words
- add a contact (key exchange), both directions
- DMs both ways; the broker sees ciphertext, never the plain text
- create a tribe, join it (free and paid), post a paid message, boost
- keysend, pay an invoice, receive one, `request_invoice`; balances checked
  after each step
- attachments: upload, download, decrypt
- invites: make, redeem, cancel (refund)
- restore history on a second device
- migrations run on a real older database

Opt-in (`PEEL_INTEGRATION=1`), so plain `swift test` stays fast. The local
stack only; no real sats, no production servers.

### 2. Click-through journeys (XCUITest)

A UI test target that drives the built app against the same local stack on
development profiles:

- onboarding
- open a chat and send a message
- paste an invoice and pay it through the confirm step
- join a tribe
- add a contact by QR picture
- start a call
- open a link in the web pane

Needs from Tom once: Accessibility / automation permission for Xcode in
System Settings. Never runs against the `default` profile.

### Order

The integration suite only adds files and a target, so it can run beside the
cleanup batches. The UI target follows once the permission is granted, and
after the polish pass settles the forms it would click.

## Integration journeys: built (2026-10-08)

`Tests/PeelIntegrationTests`, opt-in with a Swift Testing condition trait:
plain `swift test` skips it. Every journey makes its own accounts with the
real core through `Account` and `Engine`, each in a temporary directory
(never under `Peel/`, never `default` or `throwaway`), on a local stack.

### Running it

```sh
# once: the stack's binaries, from ~/Documents/sphinx (stakwork/sphinx)
CARGO_TARGET_DIR=~/sphinx-target cargo build --manifest-path broker/Cargo.toml
CARGO_TARGET_DIR=~/sphinx-target cargo build --bin sphinx-mixer --bin sphinx-tribes
# and the core's bindings, as for swift build: ./scripts/build-ffi.sh

PEEL_INTEGRATION=1 SPHINX_BIN_DIR=~/sphinx-target/debug swift test --filter PeelIntegrationTests
```

The suite starts its own stack with `scripts/test-stack.sh start --owner-pid
<its pid>`; the script's watcher stops it, and checks the ports are free,
once the test process exits. To reuse a stack across runs, start one by
hand and pass its directory as `PEEL_STACK_DIR` (the first line `start`
prints); stop it with `scripts/test-stack.sh stop <dir>`.

`scripts/test-stack.sh` runs the broker, the tribes server, the mixer
(`NO_LIGHTNING`), a memes stub (attachments, and since phase 11 the
`/preferences` file, kept per account under `memes/preferences/`) and a
wire tap in front of the broker
(`scripts/test-stack-helpers.py`, python3 with `cryptography`), each on a
random free port, never 1883 or 8000. Binaries come from `SPHINX_BIN_DIR`
(default `~/Documents/sphinx/target/debug`) or `SPHINX_BROKER`,
`SPHINX_MIXER`, `SPHINX_TRIBES`. It records the PIDs it started in the
stack's directory, and `stop` kills only those.

Which server this is (payments review F3): the stack is built from
`~/Documents/sphinx` at `master`, `caa76a1` on 2026-10-09, which has the
September security fixes (self-pay refused, tribe amounts clamped to the
HTLC, ContactKey answered only when paid). The core Peel links is
`bd9e140`, 70 commits older, and production's server may be older too. A
passing journey says how Peel behaves against that `master`.

Funding (`Bank.swift`): the mixer starts with `TESTING_ONLY_ADD_TO_SENDER`;
two accounts pay each other their whole balance through Peel's normal
checks until one holds 2,000,000 sats; then `test-stack.sh mixer <dir> real`
restarts the mixer with real accounting, and every journey runs under it.
Peel's checks are not loosened; the one value set by hand is the bank's
first balance (5 sats, for its key exchange with the mint; finding 4).
The one change to PeelCore is a test seam,
`Profile.init(developmentAt:)` (internal): a development profile in any
directory.

### Funding a development profile

The only allowed way to give a development profile sats, for the CLI or
`scripts/check-app.sh`. Editing a balance, setting or anything else in a
profile's database is forbidden.

```sh
scripts/test-stack.sh start                       # prints PEEL_STACK_DIR and PEEL_BROKER
.build/debug/peel --profile <dev> --server <PEEL_BROKER> --tribe-host <PEEL_TRIBES> \
  --memes-host <PEEL_MEMES> init
SPHINX_BIN_DIR=<cargo target>/debug scripts/fund-dev.sh <PEEL_STACK_DIR> <dev> 1000
```

The script refuses `default` and `throwaway`, a stack whose broker is not
on 127.0.0.1 (or is on 1883 or 8000), and a profile whose server is not
that stack's broker or wire tap. It keeps the profile online with `peel
listen` while `FundDev` (`Tests/PeelIntegrationTests/FundDev.swift`, run
only by the script) makes a bank as `Bank` does, adds the profile by its
contact info and pays it; the test process never opens the profile. The
script then waits for `peel whoami` to show the sats. The profile ends
with the sats plus 1 (the key exchange), a contact named "bank", and the
mixer under real accounting. Each run makes a new bank (about a minute).

### Journeys and results (four full runs, the last after #80 to #90)

| Journey | Test | Result |
|---|---|---|
| Sign up; restore from twelve words in a second directory | `Accounts` | pass |
| Key exchange by contact info; both sides ready; no second exchange; the adder −3 sats, the added +1, and Payments labels the four rows (review F6, journey 3) | `Contacts.keyExchangeByContactInfo` | pass |
| Key exchange from an invite's code (inviter added, invite untouched) | `Contacts.keyExchangeByInvite` | pass |
| A contact's record (type 33) naming another contact changes nothing (bug hunt N1) | `Contacts.aContactRecordSomeoneElseSentChangesNothing` | pass (2026-10-11); fails without `Engine.isForeignContactRecord` |
| An unpaid ContactKey (type 10) from a contact pays nothing back; the paid exchange is `keyExchangeByContactInfo` (upstream SR-016) | `Contacts.anUnpaidContactKeyPaysNothing` | known issue (2026-10-15): the linked core `bd9e140` answers it, Alice −4 sats and a 3-sat key exchange row; drop the `withKnownIssue` once the lock names a core with SR-016 |
| The account's other device adds a contact; its record adds them here as it happens | `Contacts.aContactRecordFromTheAccountsOtherDeviceAddsTheContact` | pass (2026-10-11) |
| DMs both ways through the wire tap; the plain text never on the wire (raw, base64, hex, a 16-byte run) | `DirectMessages` | pass |
| Create a free and a paid tribe; join free (1 sat) and paid (50); a paid post (10) and a paid file (10, one row, which the tribe's copy finds); a boost (20 + 10, all to the author, owner unchanged) | `Tribes` | pass |
| Keysend both ways, both balances after each; a sent row set back to pending (as older builds left them) is settled by the history on the next connect | `Payments.keysendBothWays` | pass: the recipient gets the amount, the sender pays it plus the 1-sat ping (finding 1) |
| Two payments to an offline contact, the second over what is left (review F1, journey 1) | `Payments.paymentsToAnOfflineContact` | pass (2026-10-09): the first waits, only its ping leaves the balance; the second is refused by Peel's gate; Bob comes online and gets exactly one, confirmed by his history |
| Two devices of one account each pay an offline contact; one goes through (review F2, and journey 2 for F4) | `Payments.twoDevicesPayAnOfflineContact` | see "Payments review, reconciliation" in `phases/04-money.md`: the recipient's history confirms one, the other reads not received, Payments counts one; a third device restored afterwards reads the failed send as failed |
| The whole balance (nothing left for the ping), over the threshold unconfirmed: nothing moves | `Payments.refusedPaymentsMoveNothing` | pass |
| `request_invoice` on a `NO_LIGHTNING` server | `Payments.requestInvoiceWithoutLightning` | pass (`noInvoiceFromServer`, nothing stored) |
| Attachment: uploaded encrypted to the memes stub, downloaded, decrypted, cached | `Attachments.uploadDownloadAndDecrypt` | pass |
| A paid picture in a DM (payments review journey 4): Alice buys it and Bob's key unlocks it; a second purchase Bob stores but does not answer before his engine closes is answered when it connects again (bug hunt N3). Each purchase costs Alice the price and the 1-sat ping once and brings Bob the price; the answers move no sats and are delivered | `Attachments.aPaidPictureIsBoughtAndAnsweredEvenAfterASellerStops` | pass (2026-10-11) |
| Invite: make (exactly its amount), redeem by signup, seen used | `Invites.makeAndRedeem` | pass |
| Invite: cancel refunds exactly; a signup with it afterwards gets nothing | `Invites.cancelRefunds` | pass |
| Invite: a signup whose register reply is lost (tap deafened) keeps its words; the next connect registers with the invite's sats and adds the inviter, who sees the invite used (bug hunt N2) | `Invites.aSignupWhoseReplyIsLostKeepsTheWords` | pass (2026-10-11); fails before the fix (signup throws, the profile deleted) |
| Restore history on a second device: contact, DMs both ways, payment, tribe and post, balance | `History` | pass; once, a key exchange timed out (finding 3) |
| Read markers and a mute across two devices of one account, both ways (nothing pushed live; the other device's ask on coming to the front brings them); a tribe join after a read leaves it behind the server's marker with nothing Peel counts, and reading it moves the marker past the join | `Reads.markersAndMutesAcrossDevices` | pass (2026-10-12) |
| 600 messages while the tap is down, all on the server first; a live one as soon as she is back, then a quit before the catch-up ends (required, so it cannot pass untested); the next launch fetches the rest, no server index missing (bug hunt N4) | `History.aCatchUpCutShortByAQuitLeavesNoGap` | pass (2026-10-12); before the fix 501 never came, server indices 6 to 606 had gaps |
| A malformed chunk (type 34) between two texts while the tap is down: the catch-up keeps both texts, and the next one goes past it | `History.aMessageTheCoreCannotReadLeavesOnlyItselfOut` | pass (2026-10-12); before, neither text came: the catch-up stopped at that page, and the next started there again |
| The agent's read tools over Alice's account, as the device requests call them: Bob's two messages and his tribe thread (unseen, search, contacts and tribes, then the thread), with their real uuids, chat ids and unseen counts, between the markers | `Agent.readToolsSeeWhatArrived` | pass (2026-10-20) |
| The send tool's card and send: nothing leaves while the card is up; allowed, Bob receives exactly the card's words and the answer links to that message (its uuid) | `Agent.aSendGoesOnlyOnceAllowed` | pass (2026-10-20) |
| The Mac answers its agent's `chats.unseen` once, through the read tools; a repeat gets the stored result with no second read; past its time `expired`, an unknown kind refused; a stranger's request and one for another Mac get nothing and are not stored; a read cut short by a stop is finished after a relaunch, and nothing is answered twice on the catch-up | `DeviceRequests.theMacAnswersItsAgentOnce` | pass (2026-10-17) |
| The agent's `send` shows the card and, allowed, reaches the chat once; the same request again gets the stored result with no second card or send; denied, nothing goes; a card still up at the request's time answers `expired`; a request left `sending` by a stop answers `unknown` after a relaunch, with nothing sent | `DeviceRequests.theMacSendsAsYouOnceAndOnlyWhenAllowed` | pass (2026-10-17) |
| A post in Bob's paid tribe: the card's price is exactly what leaves Alice's balance; Bob doubles the price while a second card waits, and allowing it pays nothing, sends nothing, and says why | `Agent.aTribeSendPaysWhatTheCardSaidAndNeverMore` | pass (2026-10-20); without the tool's cap Alice pays the new price; before the fix the row read "The operation couldn't be completed. (PeelCore.Engine.Failure error 6.)" |

Findings:

1. **A keysend costs the sender one sat more than its amount.** Alice pays
   Bob 300 sats: Bob +300, Alice -301; Bob pays 120: Alice +120, Bob -121.
   Peel's row says 300, and its balance check (`checkPayment`) compares
   only the amount, so a payment of the whole balance would pass Peel's
   gate and fail at the mixer. `04-money.md` records the same extra sat
   (the "1-sat async ping"). **Decided (Tom, 2026-10-09):** the balance
   check counts the ping. `Engine.pingMsat` is 1 sat for a send to a
   person and 0 for a tribe, and `checkPayment` takes it as its reserve
   for DM payments, DM boosts (one-tap included), retries of either,
   paid attachments bought in a DM and the key exchange's 5 sats (now 6
   sats needed: "adding a contact needs 6 sats"). The core sends none of
   these to a tribe (tribe messages, boosts and joins go `not_async`), and
   an invite is a plain keysend to the server, so those are unchanged.
   An invoice paid by route hint can also go the async way; its fee
   reserve (at least 10 sats) already covers the ping. The confirmation
   threshold and the amount shown and confirmed are still the payment's
   own. `keysendBothWays` now asserts the debit is the amount plus 1 sat,
   `refusedPaymentsMoveNothing` that the whole balance is refused, and the
   bank pays its balance less 1 sat.
2. **Key exchanges move fewer sats than Peel attaches.** `addContact`
   attaches 5 sats, but balances moved by 1 to 3: Dana, signing up from a
   1,000-sat invite, held 997 after adding Alice, and Alice gained 1.
   Cause not pinned down. The invite journey asserts the invite's own
   amounts exactly and allows Dana's key exchange up to its 5 sats.
   **Explained** (payments review F6, 2026-10-09): the adder pays 5 sats
   and a 1-sat ping, the other side's core pays 3 back with its own ping,
   so the adder is down 3 and the added up 1; the servers keep the pings.
   `keyExchangeByContactInfo` asserts both.
3. **An intermittent key exchange.** In one of three full runs, a key
   exchange (the bank adding Alice, in `History`) had not completed after
   20 s. It passed on its own and in the other runs.
4. **A new account with no sats cannot add a contact.** The server
   reports no balance until one changes, and since #80 `addContact` puts
   its 5 sats through `checkPayment`, which refuses an unknown balance:
   "the balance is not known yet; connect first", though the account is
   connected. Before #80 the key exchange went out. Decided: connected,
   no balance yet counts as 0 sats, so the account is told "Adding a
   contact needs 5 sats." (`contactNeedsSats`); offline it is still told
   it is not connected.

The agent's journeys (`AgentJourneys.swift`) call the Sphinx tools the
Mac answers its agent with over a real account, as the device requests
call them: a read's plan is its answer, a send's plan its card, and only
running it sends. The agent itself, strut's orchestrator through the
bridge, is in `OrchestratorJourneys.swift`, on a stand-in model endpoint.
Run them alone with
`PEEL_INTEGRATION=1 SPHINX_BIN_DIR=~/sphinx-target/debug swift test --filter Journeys/Agent`.

Not built: invoices paid and received (the server makes invoices only with
a Lightning node, so this needs a regtest bitcoind and CLN behind the
mixer), migrations from a real v14 or v16 database fixture (the offline
`MigrationTests` still cover the chain from v1), paid attachments in a tribe,
calls.

## Timeline log

An opt-in log of how a chat's message list is placed, for a list that opens
blank or in the wrong place on a real account, where `check-app.sh` does
not show it. Off by default; while off nothing extra is built or observed.

```sh
defaults write dev.peel.mac PeelTimelineLog -bool YES     # then quit and reopen Peel
/usr/bin/log stream --predicate 'subsystem == "dev.peel.mac" AND category == "timeline"' --level debug
# reproduce, then Ctrl-C and paste the output
defaults delete dev.peel.mac PeelTimelineLog              # off again, after a relaunch
```

Use `/usr/bin/log`: in zsh, `log` alone is a shell builtin. The setting is
read once at launch (`TimelineLog.enabled`) from the app's bundle ID: a build
signed by another team reads `dev.peel.mac.<team>`, and one checked with
`check-app.sh` reads `dev.peel.mac.check`.

Each line starts with six hex characters of a hash of the chat's key, keyed
afresh at each launch (the same chat has another tag after a relaunch;
`/thread` for a thread's list, `agent` for the agent chat's), then the
event. Events: the app's phase; the timeline reset, loaded (messages,
threads, limit) and its rows built (count, the "New messages" row); and
each list's table (`MessageTable`): its appear (rows, where it opens), each
change of rows and the move it made (`rows 200->201 move newest
animated`), each move outside a change (a jump, the pill) and its
dismantle. Never message text, names, keys, ids or amounts. The log changes
nothing about how a list runs.

## Proposal cards check

The proposal cards at the end of the agent chat (docs/agent-on-strut.md,
"Built: proposal cards") are checked offscreen against a stand-in
workspace's strut inside the app (`OffscreenStrut`, fixture records of
every shape a card draws), with `scripts/check-app.sh <dev profile>
<drive> <out>` and this drive:

```
{"width": 1180}
{"agent": "seed", "turns": 4}
{"select": "Peel"}
{"wait": 1}
{"proposal": "stub"}
{"wait": 2.5}
{"snapshot": "cards-pending"}
{"proposal": "input"}
{"wait": 0.7}
{"snapshot": "cards-input-open"}
{"proposal": "accept"}
{"wait": 0.5}
{"proposal": "accept"}
{"wait": 0.5}
{"proposal": "accept"}
{"wait": 0.5}
{"proposal": "reject"}
{"wait": 1}
{"snapshot": "cards-decided"}
{"appearance": "dark"}
{"wait": 0.7}
{"snapshot": "cards-decided-dark"}
```

The accepts land as Applied, as decided in Stadeum first (409, Rejected)
and as Failed with the step's error; the reject as Rejected; another
person's fixture never shows. Peel's own strut's cards (on their
request's line) and a workspace's end to end are the journey
`Journeys/Orchestrator/aProposalsCardComesFromTheRecordHereAndOnAWorkspace`,
on the staged strut and bridge.

## List journeys

Each row of the journey table in `reviews/2026-10-14-message-lists.md`
that the Mac can drive is a drive file in `scripts/journeys/`, checked
offscreen through `scripts/check-app.sh`. A `probe` step records every
message list (chat, thread, agent) each frame, as near as a 120 Hz timer
comes, while the steps after it run: the top row wholly in view (a keyed
hash of its id and its index, never its text), its offset from the list's
top, the rows laid out around it, whether the list is at its end, shown,
or blank (rows to show, hidden or none in view), and where "New messages"
and a jump's target sit. It reads only what the list already reports
(`ListGeometry`: the table engine's report after each move, for the
chat, a thread and the agent chat alike), so a probe does not change how
the list runs, unlike the timeline log's `scrollTargetLayout`; outside
the offscreen mode nothing is registered. `scripts/journeys/evaluate.py`
judges the probe files against each drive's `// check:` lines: any frame
where the reading row moved more than 1 pt (or the bottom left its end)
in a journey that must hold it, any blank frame, and the landing.

```sh
scripts/test-stack.sh start                             # its PEEL_STACK_DIR
SPHINX_BIN_DIR=<cargo target>/debug scripts/journeys/seed.sh <stack dir> lj-me lj-peer   # once, ~15 min
scripts/journeys/run.sh lj-me --peer lj-peer            # or name journeys: … thread-scrolled-narrow
```

The seed makes two development profiles on the stack, contacts, with a
~320-message chat (threads every 25, one "needle"). The runner reads the
chat before each journey, marks it unread for `open-unread`, and sends
from the peer when a drive signals it (a drive's `unread` step waits until
that message has come and the chat counts it); results land in `.build/journeys/<journey>/`.
The probe also records each list's jump button, which `pill=` checks.
Beyond the review's table: `older-history` (a flick into the top screen;
the older page lands above with nothing moving), `late-image` (a jump to
the message under an image older than the newest 200, the image sizing
itself after the list is placed; the target must not move) and
`thread-flicker` (a thread opened, closed and opened again inside one
0.2 s slide in, the chat scrolled up; the chat holds, and its column
narrows once, after the last slide ends), `overscroll-bottom` and
`overscroll-top` (a trackpad's rubber band: 80 pt past the end, or the
top, over 0.3 s, let go and eased back; every frame must follow the
gesture, and the direct chat then follows a new message) and
`overscroll-arrival` (the peer's message during a slow ease back, your own
send during the pull: once back in range, the list ends at the newest) and
`thread-open-slide` (a thread opened beside the tribe, then over it on a
narrow window: each frame the thread's list is drawn, it sits where it
does in the panel at rest, the panel found where it is drawn by a mark
only the offscreen mode draws at its top left, `ListProbe.drawnPanel`) and
the control message journeys (`control-*`: the peer's control message,
`send-control`, arriving with the chat scrolled up, at its bottom, while
the tribe is open, and on a bounce back to the tribe; each a quiet line,
the list held or placed as for any arrival). A step waits
0.3 s after it, or its `"next"` seconds.

The agent chat's journeys (`agent-*`) give the agent an earlier chat of
its own first (`{"agent": "seed", "turns": 14}`, `OffscreenAgent`): the
turns Peel's own loop kept before strut was the agent, read only, in
memory, with a placeholder key. `agent-open` (placed, no hidden frame),
`agent-expand-tool` (a tool row opened at the bottom keeps its top,
`keep=1@agent`), `agent-memory-panel` and `-narrow` (a memory opened and
closed beside or over the chat) and `agent-return`. The streaming
journeys (`agent-stream-bottom`, `agent-stream-scroll-away`,
`agent-reply-ends` and `-open`) went with the Swift loop in Phase 1's PR
11: the agent's replies come whole, as messages in its DM.

A scroll is a live scroll on the list's own scroll view (its start, a
step a frame, its end), which the list sees as a scroll by hand (the
timeline log shows `phase interacting`); wheel events cannot be aimed at
a window off the screens. An `overscroll` step does the same past an end, with the
list's clip view let past its content (`ListClipView.elastic`), as AppKit
lets it only during a real trackpad gesture. A resize steps the window's frame a frame
apart. While a probe runs, the app leaves the background priority band
and App Nap, whose timer coalescing would sample a few frames a second.
