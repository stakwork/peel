# Audit A: keys and money, 2026-10-08

Part A of the phase 8 security pass (`docs/phases/08-audit.md`, item 6).
Scope: the twelve words, the PIN, the Keychain, what sits on disk and in
memory, lock and unlock; and every path that spends sats.

Base: `origin/main` at `2a945d7` (#83), rebased onto `4112735`, which includes
#80 (cleanup batch 1). Line numbers were taken before the rebase; F3 and F6
were re-checked against the merged code.
Core references are to the vendored sphinx core (`stakwork/sphinx` at
`bd9e140`, the rev `sphinx-ffi` pins).

Method:

- I wrote a threat list per area and traced each threat in the code.
- Verdicts:
  - **holds**: blocked, with the reason;
  - **weak**: partly blocked;
  - **vulnerable**: a concrete way to lose sats or secrets exists.
- Each cheap-to-test threat that holds now has a regression test in
  `Tests/PeelCoreTests/AuditSecretsTests.swift` or `AuditMoneyTests.swift`.
  Threats that existing tests already pin are marked with those tests.
- Nothing was run against a server. No real sats were used, and Tom's
  profiles were not opened.

## Verdict in plain words

This part of Peel was not vibe built. The secret handling is careful:

- The words are sealed with a key made from the PIN, inside a
  Keychain item that never leaves this Mac.
- The development file and the profile folder are owner-only.
- Nothing logs the words, and no error repeats them.
- The clipboard copy is concealed, local and cleared.

The money gate is consistent. Every payment a person starts goes through
one check: the balance, then the threshold, then a confirmation for exactly
that amount. Amounts cannot wrap. An invoice is paid once, and our own
invoices are refused. Earlier reviews' money bugs are mostly fixed, with
tests.

The real gaps are at the edges, where **someone else sets the amount**:

1. **A tribe's owner can raise the price per message.** Your next message,
   attachment, delete or leave pays the new price with no balance or
   threshold check. Tom accepted this risk on 2026-10-08 (F1).
2. **Anyone can make Peel pay them 3 sats.** Each key-exchange message
   makes the core answer with a 3-sat payment, with no limit.

Both are capped by your balance and are slow drains, not a theft in one
go. The same behaviour is in the official apps' core.

The PIN is six digits. Its strength rests on the Keychain, and code
running as Tom on his own Mac can get past the Keychain because the
signing identity is on it.

Nothing found lets a remote stranger read the words or take the balance at
once.

Two money bugs found here were already fixed by #80 (cleanup batch 1),
which merged first: an invite whose confirmation timed out could be paid
for twice (F3), and adding a contact paid 5 sats with no check (F6). This
PR adds tests and the report; it changes no code.

## Area 1: secrets

| # | Threat | Evidence | Verdict |
|---|---|---|---|
| S1 | The words are stored in the clear | `KeychainSecretStore.add` stores only `PINBox.seal` output (`SecretStore.swift:100-104,144-154`): AES-GCM under PBKDF2-SHA256 of the PIN, with a 16-byte random salt and 2.5 M iterations (`:184-237`). | **holds**; test `thePINBoxOpensOnlyWithItsPINAndNeverSealsTheSameTwice` |
| S2 | The Keychain item syncs to iCloud or restores onto another Mac | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable: false` in the data-protection Keychain (`SecretStore.swift:145-150`). | **holds** |
| S3 | Another app reads the item | The data-protection Keychain is limited to the app's access group (`Provision.entitlements`). The bundle is signed with hardened runtime and without `get-task-allow` (`sign-app.sh:43,121-123`), so no debugger can attach. | **holds** against other developers' apps; see S4 |
| S4 | Offline PIN brute force | Six digits are 10⁶ guesses. One guess costs about 0.45 s on one M-series core (measured in the tests), so the whole space takes hours on a laptop and minutes on a GPU. The comment at `SecretStore.swift:49-51` says so. The Keychain is the real wall, but Tom's Apple Development identity, the provisioning profile (`.build/provision`) and `sign-app.sh` are on the same Mac. Any process running as Tom can sign its own binary into the access group, read the sealed item while the Mac is unlocked, and crack the PIN offline. | **weak** (F4) |
| S5 | A forged blob with fewer iterations makes cracking cheaper | `PINBox.open` refuses any version or iteration count but its own before deriving a key (`SecretStore.swift:204-210`). | **holds**; test `thePINBoxRefusesAnotherFormatOrIterationCount` |
| S6 | A corrupted blob crashes or yields garbage | An authentication failure reads as `wrongPIN` (`SecretStore.swift:212-220`). | **holds**; same test as S1 |
| S7 | A PIN typed with non-ASCII digits can't be retyped | `PIN.validate` accepts six ASCII digits only (`SecretStore.swift:36-40`). | **holds**; test `aPINIsSixASCIIDigits` |
| S8 | Online PIN guessing at the lock screen | `LockView.unlock` (`LockView.swift:38-48`) and the words reveal (`AccountView.swift:572-586`) allow unlimited attempts. Each costs about 0.45 s, so the whole space takes days at the keyboard of an unlocked Mac. | **weak** (F8) |
| S9 | The PIN is bypassed | Opening needs `loadMnemonic(pin:)` (`Account.swift:14`). Unlocking a live session re-derives the key (`AppModel.swift:287-296`). Showing the words (`Profile.swift:54`) and changing the PIN (`SecretStore.swift:106-112`) each check the PIN again. | **holds** |
| S10 | The lock doesn't lock | The lock is the UI only. The engine stays connected with the seed in memory (`AppModel.swift:405-417`). The timeout is checked only when Peel comes to the front (`PeelApp.swift:41-42`), so a Peel left frontmost never relocks. The default timeout is 0, which means "only at launch". | **weak** (F7) |
| S11 | The development profile's file is readable by others or overwritten | It is created with `O_CREAT\|O_EXCL`, mode 0600, in a 0700 folder (`SecretStore.swift:257-268`). | **holds**; test `theDevelopmentFileIsOwnerOnlyAndNeverOverwritten` |
| S12 | The CLI opens the real account | The CLI opens only `.development` profiles under `Peel/dev/` and refuses `default` (`PeelCommand.swift:130-135`). An app profile can't be named `dev` (`Profile.swift:21-24`). | **holds**; test `developmentProfilesLiveApartFromTheApps` |
| S13 | The profile folder is readable by others | `Storage.init` creates the folder 0700 and forces 0700 on one that already exists (`Storage.swift:18-21`). The lock file is 0600. | **holds**; test `theProfileFolderIsOwnerOnly` |
| S14 | Core state or the database holds the words or seed | The seed is derived in `Engine.init` and kept only in memory (`Engine.swift:131`). The core state holds contacts, the scid and preimages, not keys. | **holds**; test `theProfileFilesNeverHoldTheWordsOrTheSeed` scans every file in the profile |
| S15 | Error messages repeat the words | The core reports a bad mnemonic by the bip39 error's Debug form, such as `UnknownWord(11)` or `InvalidChecksum`, never the word. | **holds**; test `refusedWordsAreNeverRepeated` |
| S16 | Logs or stdout carry secrets | PeelCore has no `print` or `Logger`. The app prints only in `CallTestRoom`. The core's own `println!`/`eprintln!` lines (chunking, onion diagnostics) carry lengths and indexes, never keys, and a GUI app's stdout goes nowhere. | **holds** |
| S17 | Notifications leak while locked | `Notifier.post` replaces the title and body when locked or when a lock is due (`Notifier.swift:299-307`). Notifications are cleared on lock and on quit (`AppModel.swift:405-423`). | **holds** |
| S18 | Copied words linger or sync | `copySecret` marks the copy current-host-only and concealed, and clears it after 60 s unless something else was copied (each task keeps its own change count; second review 1.12 is fixed). It is also cleared on lock, on account switch and on quit (`Clipboard.swift:26-54`, `AppModel.swift:407,421,795`). Copying needs a second click with a warning (`AccountView.swift:518-543`). A crash or force quit leaves the words on the clipboard. | **holds**; the crash case is **weak** (F9) |
| S19 | Pasted words linger | "Paste twelve words" reads the clipboard and leaves the words there (`OnboardingView.swift:421-427`). | **weak** (F9) |
| S20 | Shown words linger on screen or in memory | The words hide after 30 s, when Peel leaves the front, or when the screen closes. A PIN check still running when the words are hidden can't show them after all (`AccountView.swift:442-596`). Onboarding drops its copy on "Open Peel" (`OnboardingView.swift:143`). Swift strings are never zeroed, and the seed lives as a `String` for the whole session and is copied into every core call. | **weak** (F10; this is how Swift works) |
| S21 | Forget account destroys the words without the PIN | It is allowed from the lock screen on purpose, for a lost PIN, and confirmed in place with what it deletes (`LockView.swift:28-33`). Someone at the Mac can delete the local copy but cannot read it. | **holds** by design; Tom should know it |

## Area 2: the money gate

The gate is `Engine.checkPayment` (`Engine+Payments.swift:137-145`). It
checks, in order:

1. The balance is known.
2. The amount plus any fee reserve fits in the balance, with overflow
   refused.
3. Over the threshold, the confirmation names exactly this amount.

| # | Path | Gate | Verdict |
|---|---|---|---|
| M1 | Send sats (type 5) | People only, never a tribe or a stranger; `checkPayment` with the threshold (`Engine+Payments.swift:118-129`). | **holds**; `MoneyRefusalTests` |
| M2 | Boost with an amount | The tip plus the tribe's price, counted without wrapping, all under the threshold (`Engine+Payments.swift:44-53,100-103`). | **holds**; `MoneyRefusalTests.aTribeBoostCountsTheTribesPrice` |
| M3 | One-tap boost | Balance only, once per message (`Engine+Payments.swift:65-71`). The amount was confirmed when saved (`:83-89`). The tribe's price rides on top unasked (decided 2026-10-07, `04-money.md`). Reentrancy is safe: nothing suspends before the row is committed, so a second tap sees it. | **holds**, but see F1 for the price |
| M4 | Pasted invoice and payment request | `invoiceProblem` refuses no amount, expired, ours by payee, ours by stored incoming record, pending or paid here or on another device, and over the balance less a fee reserve (`Engine+Payments.swift:346-359`). Then the threshold. `payingInvoices` stops a second click (`:367`). The record is committed PENDING before publishing (`:400-407`). `overpayMsat` is the invoice's own amount, which the core uses as the total, not as extra (core `invoice.rs:246`). A request is paid only from someone else's type 2, with amounts read from the BOLT11, never from the message (`:333-338`). | **holds**; `InvoiceTests`, `MoneyRefusalTests` |
| M5 | `request_invoice` (Receive, requests) | The server's answer must name our server as payee, the exact amount and memo, and not be expired. A late answer to another request is dropped (`Engine+Payments.swift:233-260`). | **holds**; `InvoiceTests.theServersInvoiceMustBeWhatWasAskedFor` |
| M6 | Buying a paid attachment | It must be someone else's, priced in a token from our memes host, not bought or on its way, and the price must fit in msat. Then `checkPayment` for exactly the token's price, with one purchase per token in flight (`Engine+Attachments.swift:227-248`). | **holds**; new tests `aPurchaseIsHeldToTheBalanceAndTheThreshold`, `aPurchaseWaitsForTheBalance`, `onlySomeoneElsesPricedAttachmentFromOurHostIsBought`, `aPurchaseIsPaidOnce` |
| M7 | Selling: answering a purchase | Received purchases trigger a key reply with no sats in a DM, and none in a tribe (`Engine+Attachments.swift:259-278`). No automatic refund (the comment explains why). | **holds** |
| M8 | Retrying a payment, boost or tribe message | Payments are retried only once failed, for the same amount and through `checkPayment`. A tribe message is never retried at a raised price (`Engine+Messages.swift:111-141`). | **holds**; `MoneyRefusalTests`, new test `aRetriedTribeMessageNeverPaysARaisedPrice` |
| M9 | Invites | Balance and connection first, then always a confirmation for the exact amount, then `checkPayment` (`Engine+Contacts.swift:51-60`). A timeout used to throw: the app showed it as a refusal and left the form armable, so a second confirm paid again. | **was vulnerable, fixed by #80** (F3) |
| M10 | Tribe messages, attachments, deletes, leaves, membership messages, calls | Each pays `tribe.messageAmountMsat`, the registry's current price, with no balance, threshold or agreed-price check (`Engine+Messages.swift:196`, `Engine+Tribes.swift:90-99`). The price follows the registry on every refresh (`Tribe.swift:344-349` via `Engine+Tribes.swift:448-452`). Only the header shows it (`ConversationView.swift:146-152`). | **accepted risk**, Tom's decision 2026-10-08 (F1) |
| M11 | Joining a tribe | The app passes the price it showed and the engine refuses if it changed (`Engine+Tribes.swift:40-42`). There is no balance or threshold check: one click pays any price to join. The CLI passes no agreed price. | **weak** (F5) |
| M12 | Adding a contact | Since #80, `addContact(code:)` needs a connection, then `checkPayment(keyExchangeMsat, .threshold(confirmedMsat))` before the key exchange; the app and CLI confirm through it. The unchecked core call (`Engine+Messages.swift`) is reached otherwise only by signup's add of the inviter. | **holds** since #80 (F6) |
| M13 | A received message triggers a spend | Peel's own receive path spends nothing. But every live type 10 (key exchange) makes the core build a confirmation carrying `PRICE_TO_MEET` = 3 sats (core `handle_msg.rs:121-151`, `mod.rs:43`), from a stranger or an existing contact alike. Peel publishes whatever the core returns (`Engine.swift:787-793` → `run` → `complete`). | **vulnerable** (F2) |
| M14 | Amount overflow | `checkPayment` and `invoiceProblem` add with overflow checks. The boost total, the token price × 1000, `Sats.msat` and the tribe price sum (which saturates) all refuse to wrap. | **holds**; new tests `anAmountAndItsReserveNeverWrap`, `aTribesPriceNeverWraps`, `typedSatsAreWholeASCIIAndCountable` |
| M15 | Confirmation reused for another amount | `needsConfirmation` requires `confirmedMsat == amountMsat` (`Engine+Payments.swift:93-95`), so a total that changed between the two clicks asks again. | **holds**; new test `aConfirmationCoversExactlyItsAmount`, plus `MoneyRefusalTests` |
| M16 | Double spend after a dropped connection | `deliver` marks a payment failed (retryable) only when there was no transport before publishing; otherwise it stays pending until the server says (`Engine+Messages.swift:224-243`). `pay()` never marks failed, because its `unsent` is always false (second review 1.3). That fails safe: the payment stays pending up to 30 minutes and is never paid twice. | **holds** (F11 explains why the suggested "fix" would weaken it) |
| M17 | Two payments racing past the balance | The engine is an actor, but `checkPayment` and the publish are separated by awaits, so two different payments can both pass a balance that covers only one. The server refuses the second. Nothing is lost, and the app keys sends by `moneyInFlight`. | **holds** (the server is the last check) |

## Findings, ranked

**F1. A tribe owner can raise what your next message costs (medium; accepted risk, Tom's decision 2026-10-08).**

- *Decision:* Tom decided on 2026-10-08 that a message in a priced tribe
  is not a payment. Peel keeps paying the tribe's current price per
  message without asking, as the official apps do. Nothing below is a
  pending fix; it is kept as the record of what was accepted, and as the
  design to use if the decision changes.

- Prices come from the tribes registry and are applied on every refresh.
- `deliver` sends `tribe.messageAmountMsat` for any text, attachment,
  delete or call, with no check of any kind. `sendToTribe` does the same
  for leave and the membership messages.
- One-tap boosts carry it too, by Tom's decision.
- *Scenario:* an owner sets the price per message to 50,000 sats. Each
  message you send there pays 50,000 sats, up to your balance. The only
  sign is the header's subtitle.
- `resend` already refuses a raised price (`tribePriceRose`); first sends
  don't.
- *Where the price comes from:* the stored tribe record, never the registry
  at send time. `deliver` reads `tribes[pubkey]` (`Engine+Messages.swift:187,196`),
  the in-memory copy of the `tribe` table loaded at init (`Engine.swift:150`).
  The background refresh overwrites that record whenever the registry
  answers differently (`Engine+Tribes.swift:457-498`, `merged` → `Tribe.update(from:)`).
  It runs on every connect, and again for a tribe at most every 5 minutes
  after a send to it (`recheckIfStale`, `:505-511`). A raise therefore lands
  silently between two sends: no event, no prompt, only the header's
  subtitle changes. A stale low price fails safe: the tribes server refuses
  the underpaid message, and `resend` won't pay the higher price.
- *Should a raise need confirmation?* Yes. Every other amount someone else
  sets (an invoice, a paid attachment, the price to join) is either confirmed
  over the threshold or pinned to what the person was shown. The per-message
  price is the only one that is neither.
- *Why not fixed here (before the decision):* the gate needs something to compare against. The
  clean version stores the accepted price on the tribe, which is a schema
  change with a migration, plus an "accept new price" control in the app.
  A no-migration version could compare against the most this account
  already paid per message in that tribe. Without the app control, though,
  either one stops all sending in a tribe that raised its price. That is
  a visible behaviour change, so it is not "small and obviously right".
- *Fix, if the decision is ever reversed:*
  - Store on the tribe the per-message price you last accepted, set at
    join and when you acknowledge a raise.
  - Have `deliver` and `sendToTribe` refuse with
    `tribePriceRose(boost: false)` when the current price is above it.
  - Hold any price over the threshold to `checkPayment`.
  - The app needs an "accept new price" control in the tribe header.

**F2. Anyone can make Peel pay them 3 sats per message (medium, open; inherited from the core).**

- The core answers every live type 10 with a confirmation key exchange
  that pays `PRICE_TO_MEET` (3 sats). That includes a repeat from a
  contact already confirmed.
- The core's own comment reads "FIXME key exchange msgs must be paid?".
- Peel publishes the answer unconditionally.
- *Scenario:* someone with your contact code sends key-exchange messages
  in a loop. Each one moves 3 sats from you to them.
- Not verified against a live server (no real sats): whether the server
  rate-limits, or charges the sender, is unknown.
- *Fix,* in Peel:
  - After `Sphinxrs.handle` returns a type 10 from a pubkey whose contact
    key is already stored and unchanged, commit the state but skip the
    publish.
  - Cap automatic confirmations, for example one per sender per hour and
    20 an hour overall.
  - Report the core FIXME upstream.
- Needs a local-stack test, because the two sides must still finish a
  first key exchange.

**F3. An invite that timed out could be paid for twice (medium, fixed by #80).**

- The cause is the second review's 1.2.
- #80's `confirmedInvite` returns the stored record, still sending, when
  the server doesn't confirm within `wait`; a failed one still throws
  `inviteFailed`.
- The app's form then shows "waiting" instead of a refusal with a
  re-armable button, and the CLI says it isn't confirmed yet.
- This PR's own fix for it was dropped in the rebase as a duplicate.
- No unit test: it needs a connected transport, so check it on the local
  stack.

**F4. Six digits, and the Keychain wall has a door on a developer Mac (medium, open; design).**

- The PIN slows offline guessing by minutes at most, as the code says.
- The data-protection Keychain restricts the item to the team's access
  group. The identity and the profile that grant that group sit in Tom's
  login Keychain and in `.build/provision`, and `sign-app.sh` uses them
  unattended.
- Code running as Tom could therefore read the sealed words and crack the
  PIN.
- Such code could also keylog, but that needs a permission prompt; this
  needs none.
- *Fix,* either of:
  - Add `SecAccessControl` with `.userPresence` to the item, so each read
    needs Touch ID or the login password from the system. The 6-digit PIN
    stays as the app's own lock.
  - Wrap the PIN box key with a Secure Enclave key.
- Both change the unlock flow, so Tom decides.

**F5. Joining a tribe pays any price in one click (low, open).**

- The app makes sure the price paid is the one shown. Neither the balance
  nor the threshold applies.
- The CLI doesn't pass the shown price.
- *Fix:*
  - Call `checkPayment(info.joinAmountMsat, .threshold(confirmedMsat))`
    in `joinTribe`.
  - Arm the Join button like `PayButton` over the threshold.
  - Make the CLI go through `confirming`.
  - Watch out: the balance is unknown until the server reports it, so a
    brand-new account could not join until then.

**F6. Adding a contact paid 5 sats with no check (low, fixed by #80; second review 2.3, Q1).**

- Re-checked on the merged code: `addContact(code:)` refuses offline,
  then holds the key exchange's amount to the balance and the threshold,
  with the app and CLI confirming through it. At threshold 0 it now asks.
- The only unchecked caller left is signup adding the inviter, on a new
  account funded by the invite. That is fine as it stands.

**F7. The lock is a curtain, and it only falls when Peel comes to the front (low, open).**

- With a timeout set, a Peel left frontmost past it stays open, and so
  does the Mac after a screen lock. With the default (0) it never relocks.
- While locked, the engine keeps the seed and stays online. That is
  expected for a chat app, but the PIN guards the UI, not the account in
  memory.
- *Fix:* also lock on `NSWorkspace.screensDidSleepNotification` and the
  session-resign notifications, and run a timer for the due time.

**F8. Unlimited PIN attempts (low, open).**

- About 0.45 s each, so days for the whole space, and only at the
  unlocked Mac.
- *Fix:* back off after 5 wrong PINs (30 s, doubling), in `AppModel.unlock`
  and `revealWords`, kept in memory only.

**F9. Words left on the clipboard (low, open).**

- After "Paste twelve words", or after a crash before the 60 s clear.
- *Fix:* clear the clipboard after a paste that filled all twelve boxes
  if its change count is unchanged. Marking a paste concealed is not
  possible after the fact.

**F10. The seed's memory lifetime (info).**

- The hex seed is a `String` on the engine for the whole session, copied
  into every core call. Swift and uniffi give no way to zero it.
- Nothing to do short of moving signing into the Rust side or a
  separate process.

**F11. `pay()`'s dead "nothing was sent" branch (info).**

- It fails safe: an invoice payment interrupted before publishing stays
  PENDING and is refused for up to 30 minutes, never paid twice.
- The second review's fix ("catch `notConnected` from `complete`") is not
  safe in general. `complete` can throw `notConnected` *after* publishing
  `now` when `later` is non-empty (`Engine.swift:672-683`).
- The same caveat applies to `makeInvite`'s catch today, though
  `make_invite` never registers a child key, so its `later` is empty.
- A correct version needs `complete` to report how far it got (the
  second review's 2.2, `Published .all | .none | .unknown`).

## Fixed in this PR

- No code changes: F3 and F6 were fixed by #80 first.
- 18 new tests (9 in `AuditSecretsTests`, 9 in `AuditMoneyTests`)
  for the threats marked above. The PIN box had no test before, though the
  phase 8 checklist lists it.

## Left, in suggested order

1. F2: a decision from Tom (may Peel drop or cap the core's automatic
   confirmations), then a local-stack test. F1 is not left: Tom accepted
   it on 2026-10-08.
2. F4: a decision on `.userPresence` or a Secure Enclave key.
3. F5: small, like #80's add-contact gate.
4. F7, F8 and F9: small app changes.
5. F11: with the second review's 2.2.

## Passes on this diff

- **Code review:** each new test was checked for what it would miss. The file scan reads
  every regular file left in the profile and asserts it read some.
- **Simplify:** the money tests repeat a small engine fixture rather than
  widen `MoneyRefusalTests`' private one. They also reuse `coreContact`,
  `testEngine`, `TempProfile` and `uuid`.
