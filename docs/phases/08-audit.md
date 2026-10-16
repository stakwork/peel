# Phase 8 — Audit before sharing

Status: planned. Runs after the feature phases (1 to 7, 9 and 10) and after
Tom has used the app on his real account for a while. Nothing goes to the team before it
passes. Added 2026-10-07.

The bug hunt does not wait for the freeze: it is planned in
[../finding-bugs.md](../finding-bugs.md) (2026-10-11), and items 6 to 8
below draw on it. Its stage 1 (three to five people from the team who opt
in, with small balances) runs inside this phase; nobody else gets a build
until it passes.

## Why a separate phase

The shipping chain in `AGENTS.md` reviews one diff at a time. It cannot see
what accumulates when many sessions build in parallel: the same thing written
twice, naming and error handling that drift between files, abstractions that
grew sideways, code kept "just in case", tests that assert nothing, docs that
describe last month's design. That is what reads as slop to a colleague who
opens the repo cold, and it is the reason this phase exists: one whole-repo
read, against a written bar, with the features frozen.

## Rules

- **Features are frozen.** Only fixes land while the audit runs.
- **The reviewer has no history.** A fresh session, or a person, with the repo
  only and none of the conversations that built it. If the code needs the
  conversation to make sense, the code fails.
- **Findings are fixed, not filed.** The audit ends with a clean pass, not a
  backlog. Each fix goes through the normal chain. A finding deliberately left
  is written down with the reason.
- **Tom does the manual pass himself,** on his real account, phone and Mac.
- **Done means** a colleague can clone, build, run and read the engine in an
  afternoon, and nothing in it embarrasses us.

## The checklist, in order

1. **Cold read.** `AGENTS.md`, `docs/PLAN.md`, one phase file, then
   `Engine.swift` and its `Engine+*.swift` extensions top to bottom. Time it. Anything that needed explaining gets
   a comment or a rewrite.
2. **Duplication and drift.** The same logic in two places (queries, message
   parsing, formatting, date handling); names and error handling that differ
   between files written by different sessions; dead code (unused functions,
   settings, CLI commands, flags); leftover prototype or debug code; comments
   that no longer match the code.
3. **Boundaries.** `PeelCore` has no UI types and no single-account
   assumption; every user action is an engine operation; message conventions
   live in the engine, not in views; views never reach storage directly. These
   are the `docs/agent-native.md` rules, checked rather than assumed.
4. **Concurrency.** Actor isolation holds; no `@unchecked Sendable` or
   `nonisolated(unsafe)` without a reason written beside it; no task outlives
   its owner; cancellation is handled where work is long.
5. **Storage.** Migrations run in order from v1 on a copy of a real database;
   every query that scans has the index it needs; no unbounded reads; the
   profile lock and read-only mode still behave with two processes.
6. **Security, with the threat model written down first.** Seed, PIN and
   Keychain handling; nothing secret in logs or stdout (grep for it, including
   the core's own debug lines); TLS and the trust-on-first-use path; the
   message trust rules (sender from signature, type 33 only when sent by me);
   every untrusted input (message JSON, invites, URLs, attachments, web apps in
   `WKWebView`, local runtime grants). Dependencies: each package pinned, its
   licence and maintenance checked, the vendored core matched to its lock.
7. **Tests that matter.** Not a coverage number: a list of the behaviours that
   would hurt if they regressed, each with a test. At least: state codec
   round trip, migrations, message trust rules, the PIN box, the restore plan,
   send and retry, and the engine against the local test stack in a form a
   machine can run.
8. **Failure behaviour.** Offline, server down, wrong PIN, corrupt state,
   certificate change, restore interrupted, out of sats. Each is handled and
   shown; no `try?` that hides a real failure; no crash.
9. **Performance.** Launch time, memory with a real history, nothing blocking
   the main thread (PIN derivation included), keep-alive and battery on the
   phone.
10. **Docs match the code.** `README.md`, `AGENTS.md`, `docs/PLAN.md`, the
    phase files and `docs/design/` describe what was built, with stale
    "planned" lines removed.
11. **The repo itself.** History readable, no secret ever committed (scan the
    whole history, not the tree), licence file present, `.gitignore` right, no
    checked-in build output or worktrees.

## Output

- `docs/audit/<date>.md`: what was checked, what was found, what was fixed,
  what was left and why. It goes to the team with the repo.
- The checklist above becomes the bar in `AGENTS.md` for new code, so the
  next audit is smaller.

## Checkpoint, earlier

Slop compounds and is cheapest to remove early. Once phase 3 lands, run items
1, 2, 3 and 10 as a half-day pass and fix what they find. Record it here.

## Bug hunt fixes

### N1, meanwhile: live contact records only from this account (2026-10-11, `fix/contact-record-guard`)

The core Peel links (`bd9e140`) takes a live contact record (type 33) from
anyone and writes it over the contact it names; upstream checks the signer
since SR-017 (v0.6.29). Until `sphinx-rs` moves its pin, `Engine.run` does
it for live messages (`isForeignContactRecord`). The core gives the
rewritten contact as the record's sender, so the call is made again
against the state the record would leave, where it gives the signer, and
the record is kept only when this account signed it. Nothing of a refused
one is committed or published. `scripts/build-ffi.sh` warns while the
pinned core lacks upstream's seven client fixes; `cappedToArrived` and
`isForeignContactRecord` can go once it has them.

- Tests: `ContactRecordTests` (the core's answers made up) and two
  journeys, `Contacts.aContactRecordSomeoneElseSentChangesNothing` and
  `Contacts.aContactRecordFromTheAccountsOtherDeviceAddsTheContact`.
  Without the check, the foreign cases and the first journey fail.
- Learned: the bindings hand back the whole state on almost every
  `handle` call (`handle_chunks` compares its own sorted encoding with
  Peel's, which is in dictionary order), so a result's state does not say
  what a call changed. And the local server stops routing to a contact's
  child key once Peel removes the contact (`delete_all_for_child_key`), so
  a removed contact cannot reach that key there.
- Review: the first version judged a record by the state it would change.
  That could not tell the account's other devices from someone else in
  every case, and with the whole state handed back it would have refused
  the other device's records whenever a contact was ready. Checking the
  signer replaced it.
- Not applied, with reasons:
  - Stopping the build while the fixes are missing: no library with them
    exists yet. Make the warning a refusal once `sphinx-rs` moves.
  - A trace of refused records: they are now only forged ones, and the
    person can do nothing about them.
  - Settling sats a refused record carries: nothing of it is taken.
  - Moving the check into `receive`'s closure: it would need an error
    thrown through `receive`'s catch. `run` takes `live` as it takes
    `arrived`.
  - Caching `accountPubkey()`: its three callers are rare.
  - One upstream merge commit instead of the seven in `build-ffi.sh`: the
    list names what is missing.

### N1, after: dropping the stand-ins once the core is fixed (planned, not done)

`Vendor/sphinxrs.lock` now names a `sphinx-rs` release (`v0.8.35`, the
same library as before, still core `bd9e140`). `build-ffi.sh` fails with
`PEEL_REQUIRE_CORE_FIXES=1` on a core without the seven fixes; set it for
any build that ships. Peel has no release workflow yet, so nothing sets it.
`Contacts.anUnpaidContactKeyPaysNothing` reproduces the ContactKey autopay
against `bd9e140` (Alice −4 sats) and is a known issue until the core
moves.

Do this only once the lock names a release whose core passes
`PEEL_REQUIRE_CORE_FIXES=1`. sphinx-rs#97 pins `2e9bbec1`, which has
SR-016 to SR-019 but not SR-020 (`c1a46181`) or SR-022 (`480b3ae3`):
those merged after it. `caa76a1` (v0.6.29) has all seven.

1. `scripts/build-ffi.sh --update <tag>`, then run it with
   `PEEL_REQUIRE_CORE_FIXES=1` and `SPHINX` set to a current
   `stakwork/sphinx` checkout. It must pass. Commit the lock.
2. `Contacts.anUnpaidContactKeyPaysNothing`: remove the `withKnownIssue`
   (it fails while it records nothing) and run the journeys. Change its
   `docs/testing.md` row to pass.
3. Remove `Engine.cappedToArrived` (`Engine.swift`, near the end of the
   core contract) and its call in `run`, and the `arrived:` parameter
   with it. The core now peels against the HTLC amount for live messages
   (`handle_msg.rs`, topic index 9) and history (`handle_batch.rs`,
   `o.amt`), and fails an onion that claims more. Check in a journey that
   a failed `handle` for such an onion is dropped and does not stall the
   stream or the history cursor. Peel's cap kept that message at the
   capped amount.
4. Remove `Engine.isForeignContactRecord` and its call in `run`, and the
   `live:` parameter with it if nothing else reads it. SR-017 checks the
   signer of a live record in the core.
5. Tests: `StateCodecTests.aReceivedAmountIsNeverMoreThanArrived` goes.
   The `.msat` assertions in `aLiveMessagesTopicNamesWhatArrived` go if
   the `msat` half of `Engine.arrived` goes. `ContactRecordTests` in
   `ContactsTests.swift` (the core's answers made up) goes. The journeys
   `aContactRecordSomeoneElseSentChangesNothing` and
   `aContactRecordFromTheAccountsOtherDeviceAddsTheContact` stay: they now
   prove the core's check. Update the comment on the first journey, which
   names `isForeignContactRecord`.
6. Prose: `AGENTS.md`, "How the core works" (the contact-record paragraph
   and the `build-ffi.sh` warning sentence). `docs/phases/04-money.md`,
   the 2026-10-09 F3 correction (the core Peel links now peels against the
   HTLC amount). The N1 section above ("Until `sphinx-rs` moves its pin").
   The `docs/testing.md` row that says the journey fails without
   `isForeignContactRecord`. Its "Which server this is" paragraph (the core
   is no longer 70 commits older). `docs/reviews/2026-10-09-payments-correctness.md`
   F3 (core half done). The comments that name `cappedToArrived`:
   `Engine.run`'s doc, `Engine.swift` where a message's `amountMsat` is
   set, and `Message.isRetryable`.
   Also the comment above the fix list in `build-ffi.sh`.

What stays:

- The `indices` half of `Engine.arrived(...)`: every message's index,
  those the core cannot read too, moves where history stands.
- Server-history reconciliation (`refreshPaymentHistory`, arrived and
  not-received rows). It answers other questions than the amount.
- `StateCodec.paymentAmounts`, while anything reads it. Its only caller is
  the `msat` half of `Engine.arrived`, so it goes when that half goes.
- The "ours" check in `Engine` (kept only when signed by `accountKey` or by
  a known tribe in its own chat). `dec_ts_matches` is unchanged in v0.6.29
  (`handle_msg.rs`, `dec_tag_or_ts_matches`): no SR commit fixes it, so the
  core still calls a message ours by a date a sender can arrange. That no
  longer matters for amounts, because the core reports the HTLC-bound
  amount whether or not it calls the message ours. So the "from me" reason
  in `cappedToArrived`'s comment no longer argues for the cap, but the
  "ours" check is still needed.
