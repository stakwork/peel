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
read once at launch (`TimelineLog.enabled`). A development build checked
with `check-app.sh` reads its own domain, `dev.peel.mac.check`.

Each line starts with six hex characters of a hash of the chat's key, keyed
afresh at each launch (the same chat has another tag after a relaunch), then
the event, then the list's state (`rows`, `atBottom`, `atEnd`,
`following`, `opening`, `pinning`, `phase`, and `realised`, the rows the
lazy stack has made, which the list counts with the log off too). Events: the app's phase; the
timeline reset, loaded (messages, threads, limit) and its rows built
(count, the "New messages" row); the list's appear and disappear (the
focus or divider row asked for); every placement (`place:` the bottom on
appear, a divider pass, `go(to:)`, `scrollToNewest`, a re-pin) and why a
re-pin ran or was skipped; scroll phase changes; `bottom state written`;
the scroll geometry (offset, content and container heights, `below` the
end, insets; not while scrolled by hand); and the rows in view by index,
or `visible NONE with rows: blank`, the blank list itself. Read together:
rows realised and in view while the screen is empty is a drawing problem;
none in view with the offset past the content (`below` negative) is a
placement problem; none realised at all is the lazy stack not making them. Never message
text, names, keys, ids or amounts. With the log on, the lazy stack is a
scroll target layout (`.scrollTargetLayout`) so its rows in view can be
reported; off, it is not. So the list runs a little differently with the
log on: a blank that will not come back with it on says that much, not
that the bug is gone.
