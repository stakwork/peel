# Testing plan

Status (2026-10-08): planned, not started. Tom: "do we have any proper
tests? … encryption, payments, etc. Integration and user journey click
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
