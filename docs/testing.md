# Testing plan

Status (2026-10-08): part 1 (integration journeys) built, see "Integration
journeys: built" below; part 2 (click-through) not started. Tom: "do we
have any proper tests? … encryption, payments, etc. Integration and user journey click
through tests for real."

## What exists

About 350 tests in `Tests/PeelCoreTests`, run by `swift test`. They test
real logic, mostly without the Rust core or a server:

- Media encryption against an RNCryptor vector; wrong keys and tampering are
  refused.
- The payment gate: balance, confirmation threshold, already paid, own
  invoice (`MoneyRefusalTests`, `PaymentTests`); invoice parsing and amounts.
- Storage against a real SQLite database: migrations, unread counts, threads,
  read markers.
- Call links, time zones, markup, contact codes, dropped connections (fake
  transport).

## What is missing

1. **The real core.** Only `PublishPlanTests` calls `Sphinxrs`. Sending,
   receiving, key exchange, payments and invites are tested against fakes.
2. **Integration.** Each PR's end-to-end check was an agent driving the local
   stack by hand. Nothing repeats it.
3. **UI.** `PeelApp` has no test target. Agents cannot click the app
   (synthetic events do not reach a background app, and the terminal has no
   Accessibility permission), so every click-through so far was Tom's.

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
(`NO_LIGHTNING`), a memes stub and a wire tap in front of the broker
(`scripts/test-stack-helpers.py`, python3 with `cryptography`), each on a
random free port, never 1883 or 8000. Binaries come from `SPHINX_BIN_DIR`
(default `~/Documents/sphinx/target/debug`) or `SPHINX_BROKER`,
`SPHINX_MIXER`, `SPHINX_TRIBES`. It records the PIDs it started in the
stack's directory, and `stop` kills only those.

Funding (`Bank.swift`): the mixer starts with `TESTING_ONLY_ADD_TO_SENDER`;
two accounts pay each other their whole balance through Peel's normal
checks until one holds 2,000,000 sats; then `test-stack.sh mixer <dir> real`
restarts the mixer with real accounting, and every journey runs under it.
Peel's checks are not loosened; the one value set by hand is the bank's
first balance (5 sats, for its key exchange with the mint; finding 4).
The one change to PeelCore is a test seam,
`Profile.init(developmentAt:)` (internal): a development profile in any
directory.

### Journeys and results (four full runs, the last after #80 to #90)

| Journey | Test | Result |
|---|---|---|
| Sign up; restore from twelve words in a second directory | `Accounts` | pass |
| Key exchange by contact info; both sides ready; no second exchange | `Contacts.keyExchangeByContactInfo` | pass |
| Key exchange from an invite's code (inviter added, invite untouched) | `Contacts.keyExchangeByInvite` | pass |
| DMs both ways through the wire tap; the plain text never on the wire (raw, base64, hex, a 16-byte run) | `DirectMessages` | pass |
| Create a free and a paid tribe; join free (1 sat) and paid (50); a paid post (10); a boost (20 + 10, all to the author, owner unchanged) | `Tribes` | pass |
| Keysend both ways, both balances after each | `Payments.keysendBothWays` | **known issue**: the sender is debited 1 sat more |
| Over the balance, over the threshold unconfirmed: nothing moves | `Payments.refusedPaymentsMoveNothing` | pass |
| `request_invoice` on a `NO_LIGHTNING` server | `Payments.requestInvoiceWithoutLightning` | pass (`noInvoiceFromServer`, nothing stored) |
| Attachment: uploaded encrypted to the memes stub, downloaded, decrypted, cached | `Attachments` | pass |
| Invite: make (exactly its amount), redeem by signup, seen used | `Invites.makeAndRedeem` | pass |
| Invite: cancel refunds exactly; a signup with it afterwards gets nothing | `Invites.cancelRefunds` | pass |
| Restore history on a second device: contact, DMs both ways, payment, tribe and post, balance | `History` | pass; once, a key exchange timed out (finding 3) |

Findings:

1. **A keysend costs the sender one sat more than its amount.** Alice pays
   Bob 300 sats: Bob +300, Alice -301; Bob pays 120: Alice +120, Bob -121.
   Peel's row says 300, and its balance check (`checkPayment`) compares
   only the amount, so a payment of the whole balance would pass Peel's
   gate and fail at the mixer. `04-money.md` records the same extra sat
   (the "1-sat async ping"); whether Peel should show or reserve it, or the
   server should not take it, is Tom's call. Marked `withKnownIssue`.
2. **Key exchanges move fewer sats than Peel attaches.** `addContact`
   attaches 5 sats, but balances moved by 1 to 3: Dana, signing up from a
   1,000-sat invite, held 997 after adding Alice, and Alice gained 1.
   Cause not pinned down. The invite journey asserts the invite's own
   amounts exactly and allows Dana's key exchange up to its 5 sats.
3. **An intermittent key exchange.** In one of three full runs, a key
   exchange (the bank adding Alice, in `History`) had not completed after
   20 s. It passed on its own and in the other runs.
4. **A new account with no sats cannot add a contact.** The server
   reports no balance until one changes, and since #80 `addContact` puts
   its 5 sats through `checkPayment`, which refuses an unknown balance:
   "the balance is not known yet; connect first", though the account is
   connected. Before #80 the key exchange went out. Whether an empty
   account should be told it needs sats, or be able to add contacts, is
   Tom's call.

Not built: invoices paid and received (the server makes invoices only with
a Lightning node, so this needs a regtest bitcoind and CLN behind the
mixer), migrations from a real v14 or v16 database fixture (the offline
`MigrationTests` still cover the chain from v1), paid attachments, calls.
