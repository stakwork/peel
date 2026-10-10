# Payments correctness review, 2026-10-09

The question: does Peel do the right thing with money in every case, and
does it match the core and the official app? Abuse was the earlier audit
([2026-10-08-audit-keys-money.md](2026-10-08-audit-keys-money.md)); its
findings are not repeated here, only referred to.

Base: `origin/main` at `dcf79c4` (#110).

References, in order of authority:

1. The core Peel links: `stakwork/sphinx` at `bd9e140`, the rev
   `sphinx-rs` pins (`sphinx-ffi/Cargo.toml:21`). The official Mac app
   ships the same rev. Paths below are in that checkout.
2. Its TypeScript client, `wasm/test/auto/main.ts` (`handle_rr`).
3. The official Mac app, `sphinx-mac-v2`
   (`Crypter/SphinxOnionManager/*.swift`).

Method:

- I traced each money flow from the view to storage and back, and read
  the same flow in the core, the mixer and the Mac app.
- I ran one throwaway journey on the local stack (`scripts/test-stack.sh`,
  real accounting, temporary accounts, deleted afterwards) to check the
  three findings that only a server can show. It is not committed.
- No code was changed. No real sats, no production server, no app profile.

Labels:

- **Severity**: *money lost or stuck*, *wrong state shown*, or *cosmetic*.
- **Confidence**: *verified* (in the code on both sides, or run on the
  local stack) or *inferred* (read in the code, not run).
- **Fix size**: S (an afternoon), M (a day or two), L (more, or outside Peel).

## Verdict

Peel's own money logic is sound. Amounts are msat end to end. Every
payment a person starts goes through one gate. A send is written before it
is published, its status only moves forward, and nothing that may have
paid is offered again. In most flows Peel is stricter than the official app.

What is wrong comes from what Peel believes about the server and the
core. Three beliefs are false:

- **The balance is what you can spend.** Sats to a contact who is offline
  stay in the balance until that contact comes online. Peel lets you
  promise them twice; the second payment fails hours later (F1).
- **A received payment's amount is what arrived.** A payment that failed
  at the server still showed on the recipient's side as received (F2).
  The core Peel links reads the amount from the sender's onion, not from
  the payment that came (F3).
- **Our own rows from history were sent.** After a restore, or on another
  device, a payment that failed shows as sent (F4).

No path loses sats outright in normal use. F3 can lose a seller's paid
attachment to a modified client. The rest show the wrong thing, in places
where Tom would reasonably stop trusting the numbers. The official app has
F1, F2, F3 and F4 too.

The 1–3 sats a key exchange moves are explained (F6). They are the core's
fixed prices, and they add up exactly.

## Status

Tom approved fixing what the review found, one concern per PR.

| # | Status |
|---|---|
| F1 | **Fixed** (PR "Payments: real amounts, waiting payments count, labelled key exchange"): `checkPayment` and `invoiceProblem` take what is waiting for people to come online from the balance (`Storage.spendableMsat`); the header shows "4,996 sats · ◷ 4,000" (the clock alone where it is short of room), Payments and the payment forms "4,000 waiting"; a waiting payment or boost in a DM reads "Payment waiting for Bob to come online", and "Waiting" in Payments. No cancel or expiry (Tom: not now). Journey 1: the second payment is refused, Bob gets one. Not counted yet: the key exchange's 5 sats to someone offline, and an invoice paid the async way by route hint |
| F2 | **Fixed** (PR "Payments: reconcile received and restored payments with the server"): someone else's payment or boost counts, and is told, only once the server's history has its incoming row (`Message.arrived`, v21; matched by message index, a hash only for a row and message with none); one a complete history fetch after it came does not have reads "Not received" in the chat and Payments and counts for nothing. Confirmed on the local stack first: two devices of one account paid an offline contact, both messages reached him, the history had one row. Journey `Payments.twoDevicesPayAnOfflineContact` |
| F3 | **Peel's half fixed** (same PR): a received payment counts for no more than the server says arrived (`Engine.cappedToArrived`), the topic's amount for a live message and the amount beside each onion for a history page (`StateCodec.paymentAmounts`), so the key release, received rows and totals, notifications, type 3s and invoice settles all use it. `04-money.md` corrected; `testing.md` records the stack's rev. Core half (linking a core with SR-016) open |
| F4 | **Fixed** (same PR): restored rows of ours carry a tag but no payment hash and no status, and the failed one has no history row at all (the mixer's `move_funds` failed after delivering), so the history cannot settle them; the server's send record by tag can. After a restore, and on each connect, `checkPendingSends` also asks about our money rows with no status; COMPLETE or FAILED moves them, nothing else does (no "no record" failure). Same journey, on a third device |
| F5 | **Words fixed** (#154): a waiting payment or boost in a DM reads "Payment waiting for Bob to come online · can't be cancelled from here"; its help and Payments' detail say "It should pay when Bob next opens Sphinx, however long that takes. It can't be cancelled from here" (one owner, `WaitingForServer.waitsForPerson`, hedged because a ping that never left wakes nothing and an unrecorded send fails later); the help adds that for 7 days (`Message.waitingLimit`) it is kept out of what can be spent, after which the sats count as spendable again but it may still go through if the balance covers it. Counted in F1's waiting sum already. Cancel: open, needs the mixer (below) |
| F6 | **Fixed** (same PR): key exchange rows read "Contact added" / "Added you" with the contact's name, their half joined by hash, ours paired by time and amount with the ping folded in; detail says why. Journey 3 asserts −3 / +1 and the labels. Left: the adder's ping stays a keysend when the contact was offline (it went long before the 5 sats) |
| F7 | **Fixed** (same PR): `PaymentItem.Status.unsettled`, "Not settled" in Payments as in the chat |
| F8 | **Fixed** (same PR): a request of ours is also paid (or partly) by an incoming history row with its hash |
| F9 | **Fixed** (#154): `publishPlan` splits off `afterPay`, everything after the async pay; a send publishes it once the server answers with the pay's tag (`asyncpayTag`, noted in `MoneyWork.asyncPays` by `commit`), or after `asyncPaySettle` (10 s), as the official apps do. Not while handling what the server sent (a key exchange's answer from `receive`): the inbound queue is what would bring the tag, so it goes back to back as before. Journey `paymentsToAnOfflineContact` asserts the send returns well inside the 10 s, so the tag came |
| F10 | Open: not cheap. A join sends no tag or hash to track (`join_tribe` passes `is_tribe` as `not_async`, so `push_kac` pushes no message, `bindings/send.rs:189-193`); its row already shows as "Joined #tribe" by time. Keeping the tribe when the publish may have gone (`commitAndPublish`) is the small part left |
| F11 | **Three of four fixed** (#154). Invite cancel: the make form says only this Mac keeps the invite, so only here can it be cancelled (the balance-rise refund rule is unchanged, as its code says). Invoices: a balance change in either direction while an invoice made here is open and unexpired also reconciles (`Engine.balanceCallsForReconcile`, `Storage.hasOpenInvoice`). Own server-made invoice on another device: an invoice one of our own payment requests (type 2, from history) carries is ours (a separate check in `invoiceProblem` after `paidState`, `Storage.isOurRequest`, only for an invoice our own server made and only a request ours by its tag, so a message the core takes for ours by its date alone cannot trigger it), so it is refused; one made in Receive on the other device still cannot be told (no message carries it). **Left, needs Tom:** the tribe text's Retry. Every tribe text carries sats (at least 3), so treating it like a payment (Retry only once failed, failed after 30 min with no record) would take the 30-second Retry away from every tribe message; that is his call |
| Follow-ups (from #140's review) | Open: a paid attachment's key is still sent on the purchase message's `msat`, before the history confirms the sats; the mixer keys a payment row by scid, time and amount (`pmt_key`), so two of the same amount in one millisecond share a row (upstream) |
| Follow-up (from #154's review) | Open, tracked: a ping that never left (the connection went, or the app quit, during the up-to-10 s wait for the async pay's tag) leaves the async pay held with nothing to wake it, since the mixer redeems only on the recipient's answer to a ping. Fix: re-send the ping for our pending async pays (by tag) on the next connect. Not built |

## Findings, ranked

| # | Finding | Severity | Confidence | Official app | Fix |
|---|---|---|---|---|---|
| F1 | Sats to an offline contact are not taken from the balance until they come online, so Peel's gate passes a second payment the balance cannot cover | wrong state shown | verified, local stack | same | S |
| F2 | A payment that failed at the server shows as received on the other side, with a notification | wrong state shown | verified, local stack | same | M |
| F3 | The pinned core takes a received amount from the sender's onion, not the payment that arrived; the stack tests a newer server | money lost (a seller, to a modified client) | verified in code, not run | same core | S in Peel, L for the core |
| F4 | After a restore, or on another device, a failed payment shows as sent | wrong state shown | verified, local stack | same, inferred | M |
| F5 | A payment to someone who never comes online waits for ever, cannot be cancelled, and may pay months later | money stuck (in limbo) | verified in code | same | S (words), L (cancel) |
| F6 | Key exchanges: the 1–3 sats explained; they show as unexplained keysends | cosmetic | verified, local stack | same | S |
| F7 | An unsettled payment reads "not settled" in the chat and "Pending, on its way" in Payments, for ever | wrong state shown | verified in code | n/a | S |
| F8 | Our own request never shows Paid after a restore | wrong state shown | verified in code | worse (never) | S |
| F9 | Peel publishes the ping without waiting for the server to take the async payment | wrong state shown (a stuck pending row) | inferred | different | S |
| F10 | A tribe join's payment is not tracked; a join cut off mid-publish is rolled back though it may have paid | money lost (a join price, rarely) | verified in code | same, no tracking | S |
| F11 | Smaller edges: invite cancel, invoices only on a balance rise, own invoice on another device, a tribe text's retry | wrong state shown / cosmetic | inferred | mixed | S each |

### F1. The balance still holds sats you have sent to someone offline

- **What happens.** A payment in a chat to a contact goes the
  asynchronous way: an async pay held by the server, and a 1-sat ping to
  wake the contact. The server records the async pay as pending and takes
  nothing from the balance yet: "decr_balance is done when trigger_pay is
  called" (`mixer/src/handler.rs:231-242`). The sats move only when the
  contact's app answers the ping (`mixer/src/ping.rs:77-140`, `pay_now`).
- **Peel.** `checkPayment` compares the amount with the last balance the
  server reported (`Engine+Payments.swift:149-157`). Pending payments are
  not subtracted. The header balance (`MoneyArrivals.balance`) is that
  same number.
- **Run on the local stack.** Alice had 4,998 sats and Bob was offline.
  She sent Bob 4,000 sats: her balance went to 4,997 (the ping only). She
  sent 4,000 sats again: Peel passed it, and her balance went to 4,996.
  When Bob came online the first payment completed. The mixer refused the
  second ("not enough balance") and it turned failed, with Retry. Alice
  ended at 996.
- **Official app.** The same. It shows the server's balance
  (`SphinxOnionManager+HandleStateExtension.swift`, `handleBalanceUpdate`)
  and has no gate of its own.
- **What the person sees.** "You sent 4,000 sats" twice, each "waiting for
  Bob to come online", with the whole balance still in the header. Hours
  later one of them fails.
- **Fix (S).** Subtract our pending payments, boosts and purchases to a
  person (`Storage.pendingSendTags` already reads them) from the balance
  in `checkPayment`. Show the sum under the balance as "4,000 sats on
  their way". Unsettled rows stay out of it: their sats did not move
  locally.

### F2. A failed payment shows as received on the other side

- **Run on the local stack** (continuing F1). Bob's Peel stored two rows,
  "Alice sent you 4,000 sats", each with `msat` 4,000,000. His balance rose
  by 4,000 once, and his server history has one incoming 4,000,000 row.
  The second payment never arrived, but Bob was shown it, counted it as
  unread and notified (`Storage+Writes.swift:181`, `isMoneyForMe` at
  `:322`; `Engine.swift:651`).
- **Why.** The server passed the message on when it redeemed the async
  pay, before or apart from moving the sats. The pinned core then reports
  the amount the onion claims (F3). Which of the two is the cause here was
  not pinned down.
- **Official app.** The same: it stores the core's `msat` as the amount
  (`SphinxOnionManager+ChatExtension.swift:990-993`).
- **Related, open since 2026-10-07.** A payment that missed the settle
  window (`UNSETTLED` on the sender's side) is also shown as received by
  the recipient (`04-money.md`, "Boost stuck waiting", Open).
- **Fix (M).** Treat a received payment as unconfirmed until the server's
  history has an incoming row for its payment hash (or message index). The
  history is already fetched on a balance rise for invoices
  (`checkInvoicesInBackground`). Hold the notification and the green
  amount until then, and show "not received" when the history says
  nothing came.

### F3. The pinned core reads the received amount from the sender's onion

- **The core Peel links.** `handle_msg.rs:27` reads the HTLC amount from
  the topic and ignores it (`_msat_str`). `peel_received_payment` peels the
  onion with `amount_msat: u64::MAX` (`onion_payment.rs:196`), so LDK's
  check that the onion claims no more than arrived never fails. `msg.msat`
  is what the sender wrote. The same holds for history pages
  (`handle_batch.rs:65`).
- **Upstream.** Fixed in `c3ddbb7` ("SR-016: check onion payment amount
  against the real HTLC amount", 2026-09-25). `bd9e140` is 70 commits
  behind `master`, and `sphinx-rs` still pins it, so the official app has
  the same gap.
- **Peel's belief.** `04-money.md` says the core "peels it against the
  real HTLC amount and reports msat (never more than what arrived)". That
  is true on `master`, not on the rev Peel ships.
- **What it touches.**
  - The amount shown and notified for a received payment or boost (F2).
  - **Paid attachments:** the seller's Peel sends the key when
    `purchase.msat` covers the price (`Engine+Attachments.swift:294-310`).
    A modified client could pay 1 sat, claim the price, and get the key.
  - A request paid with `pay_contact_invoice`: the type 3 counts when its
    `msat` covers the invoice (`PaymentHistory.swift:218`).
  - An old `make_invoice` invoice settled on the device (`Engine.swift:485-490`).
- **The other half of the same gap.** The integration suite runs the
  stack built from `~/Documents/sphinx` at `master` (`caa76a1`), so its
  mixer and tribes server have the September security fixes (self-pay
  refused, tribe amounts clamped to the HTLC, ContactKey answered only when
  paid, purchase payouts). Peel's core and production's server may not. A
  passing journey therefore says how Peel behaves against `master`, not
  against what Tom's account talks to.
- **Fix.** S in Peel: for a live message, clamp `msg.msat` to the HTLC
  amount in the topic (`parts[9]`) before storing it; the topic is in
  `receive` (`Engine.swift:886-917`). History pages cannot be clamped this
  way; F2's history check covers them. L: link a core with SR-016, which
  means building the static library rather than taking the Mac app's. Also
  record in `docs/testing.md` which server rev the stack runs.

### F4. After a restore, a failed payment shows as sent

- **Why.** The core's `send` always publishes a copy of a payment to the
  account itself, as an onion message with no sats (`bindings/send.rs:96-118`).
  The server stores it whatever becomes of the payment. On restore, or on
  the account's other device, that copy is our own row with the declared
  amount and no status (`Engine.swift:848-862` sets none). No status reads
  as delivered: no caption in the chat (`PaymentChatRows.swift:238-243`)
  and "Payment sent" in Payments (`PaymentHistory.swift:731-736`).
- **Run on the local stack** (continuing F1). Alice restored on a second
  device: both 4,000-sat payments came back as sent, with no status. One
  of them had failed.
- **Fix (M).** For our own payments, boosts and purchases that come from
  history with no status: mark them confirmed when the server's history
  has an outgoing row for their payment hash, else "not confirmed". The
  restored row keeps its tag (`msg.tag`), so `getTags` can be asked about
  recent ones on the first connect.

### F5. A payment to someone who never comes online is in limbo for ever

- The server keeps an async pay with no expiry (`mixer/src/db/asyncpay.rs`)
  and has no way to cancel one.
- Peel never fails a send the server records as pending
  (`Engine.recordedStatuses`, `Engine.swift:1034-1044`). The row reads
  "Waiting for Bob to come online" for ever, with no Retry and no Discard.
- The sats are not taken (F1), so nothing is lost now. They leave whenever
  Bob next opens Sphinx: a month later, from whatever balance there is
  then. If that balance is short, it fails then.
- The official app shows nothing pending at all.
- **Fix.** S: say so on the row and in its detail: "Pays when Bob next
  opens Sphinx. It cannot be cancelled." Count it in F1's "on their way".
  L: a cancel needs the mixer.
- **Can it be cancelled? (Tom asked, 2026-10-09.)** Not as things are;
  possible with a mixer change and a core binding to ask for it.
  Checked in `~/Documents/sphinx` at `caa76a1` (mixer) and the core at
  `bd9e140`.
  - The mixer keeps a held payment in one table and has exactly two ways
    to take one out: `redeem_async_pay`, which pays it, and `drain_asyncpay`,
    which empties the whole table with the rest of the database
    (`mixer/src/db/asyncpay.rs:9`, `:14`, `:29`; `db/mod.rs:60-62`). The
    only caller of the first is the recipient's "online" answer to the
    ping (`ping.rs:52`, `pay_now` at `:87`). `ASYNC_PAY` only adds
    (`handler.rs:231-243`). No topic in the core's list withdraws one
    (`sphinx/src/topics.rs:1-32`).
  - Nothing expires it: the time in its key (`asyncpay.rs:72`) is never
    swept, and `cltv_delay` matters only once it is paid (`ln.rs:289`).
  - The sender cannot take back the ping either: it is stored on the
    recipient's server under the recipient's key, and only the recipient
    removes it (`PING_DONE`, `handler.rs:299-304`).
  - The sender's core has no call for it: the bindings offer
    `cancelInvite`, `pingDone` and `fetchPings`, nothing for an async pay
    (generated `sphinxrs.swift:2450`, `:2720`, `:2733`). The TypeScript
    client only waits for the tag (`wasm/test/auto/main.ts:25-41`,
    `:83-93`); the Mac app sends and waits the same way and shows nothing
    pending (`SphinxOnionManager+HandleStateExtension.swift:97`,
    `:154-155`). Neither ever withdraws a payment.
  - What a cancel would take: a mixer topic (say `cancelasyncpay`) that
    removes the async pay by tag only when its `from` is the asking
    account's scid (as `ASYNC_PAY` checks, `handler.rs:235-238`), records
    the send FAILED and answers on `send`; redb's `remove` lets it race
    `pay_now` safely (whoever removes it first wins). And a core binding to
    publish it. The recipient's ping would stay; their answer would find
    nothing ("async pay not found", which Peel already handles).

### F6. The key exchange's 1–3 sats

- **The prices** (core, all verified):
  - The one who adds pays 5 sats (`Engine.keyExchangeMsat`, as the official
    apps) the asynchronous way, plus the 1-sat ping (`PING_PRICE`,
    `ping/asyncpay.rs:13`).
  - The other side's core answers at once with a confirmation that pays
    back 3 sats (`PRICE_TO_MEET`, `bindings/mod.rs:43`;
    `handle_msg.rs:121-160`), plus its own 1-sat ping.
  - Each ping goes to the other side's server, which keeps it.
- **So:** the one who adds is down 5 + 1 − 3 = **3 sats**; the one added is
  up 5 − 3 − 1 = **1 sat**; the server keeps 2. On the local stack: Alice
  5,001 → 4,998, Bob 5,001 → 5,002. That is the integration finding "Dana
  held 997, Alice gained 1" (`docs/testing.md`, finding 2), exactly.
- The answer's 3 + 1 sats are paid by the core with no gate. That is
  audit F2 (accepted); upstream now answers only a paid ContactKey
  (`031427c`), which Peel does not have (F3).
- **What the person sees.** Four rows in Payments: "Keysend, received, not
  tied to a chat" (5) and three sent (3, 1, 1), or the mirror. Nothing says
  they were adding a contact.
- **Fix (S).** Tie the history rows to the key exchange (type 10/11) by
  payment hash where the core reports one, else by time as old pings are
  paired (`PaymentHistory.swift`, `pairedByTime`), and label them
  "Contact added: Bob" with the ping folded in, as payments' pings are.

### F7. Unsettled reads two ways

- In the chat an `UNSETTLED` payment says "Payment not settled", with no
  action (`PaymentChatRows.swift:201-210`).
- In Payments the same row is `.pending`: grey, "Pending", "Payment on its
  way" (`PaymentHistory.swift:734`, `PaymentItem+Display.swift:71`). It
  never changes: the server publishes nothing more for that tag.
- **Fix (S).** A fourth `PaymentItem.Status`, `.unsettled`, shown as the
  chat shows it.

### F8. Our own request never shows Paid after a restore

- A request of ours is Paid from the invoice we made (local table) or a
  payer's type 3 (`PaymentHistory.swift:251-257`). Requests are made by the
  server now (`request_invoice`), and a plain payment brings no type 3.
- After a restore the invoice table is empty, so a request that was paid
  reads "Waiting to be paid" until it expires, while the history has the
  incoming row with its hash.
- Before the restore it is right: `checkOpenInvoices` matches the row.
- The official app never shows a server-made request paid
  (`04-money.md`, "Receive and requests made by the server").
- **Fix (S).** For ours, also take an incoming history row with the
  request's payment hash, as theirs already take `sentInHistory`.

### F9. The ping goes before the server has taken the payment

- The core returns the async pay first and the ping and self copy after.
- The official app holds everything after the async pay until the server
  answers with its tag (`asyncpay_tag`), or for 10 s
  (`SphinxOnionManager+HandleStateExtension.swift:150-165, 329-343, 389-418`).
  The TypeScript client does the same (`main.ts:87-93`).
- Peel publishes them back to back (`Engine.publishPlan`,
  `Engine.swift:695-714`) and ignores `asyncpayTag`.
- **Risk (inferred).** If the contact's app answers the ping before the
  server stores the async pay, the server finds no payment ("async pay not
  found"), the contact acknowledges the ping, and nothing wakes the
  payment again. The sender's row then waits for ever (F5). On one server
  the order makes this unlikely; across servers it is not tested.
- **Fix (S).** Wait for `asyncpayTag` (or 10 s) before publishing `later`,
  as the official app does. `complete` already waits for a register.

### F10. A tribe join's payment is not tracked

- `joinTribe` sends through `run`, so its tag is never stored and its
  status is ignored (`Engine+Tribes.swift:63-77`). A join whose payment the
  server refuses shows the tribe as joined, and sending there then fails.
- If the publish fails after something left (`complete` throws "the
  connection went after sending"), Peel restores the tribe as it was
  before. The price may have been paid, and Join is offered again.
- The official app tracks nothing either (`SphinxOnionManager+TribesExtension.swift:97-143`).
- **Fix (S).** Route the join through `commitAndPublish` and keep the
  tribe on `.unknown`, as `deliver` keeps a payment pending.

### F11. Smaller edges

- **Invite cancel.** The refund is taken to be any balance rise of at most
  the invite's amount within 20 s (`Engine+Contacts.swift:133-162`). A
  payment that lands meanwhile can pass for it; the code says so. The
  official app has no cancel at all. Invites and invoices are local
  tables, so neither follows a restore: an invite made on the old device
  can no longer be cancelled from the new one. Cosmetic; S to say so.
- **Invoices noticed only on a balance rise.** `checkInvoices` runs when a
  new balance is above the stored one (`Engine.swift:458-462`). A payment
  in and a payment out in one notice leave Receive waiting until the next
  connect. Inferred; S (also check on any balance change while an invoice
  is open).
- **Our own server-made invoice, pasted on another device.** Peel cannot
  tell it is ours (the payee is the server). `04-money.md` says the mixer
  refuses it; that refusal is `3d84568`, after `bd9e140`. Against an older
  production mixer the payment would mark the invoice paid with no sats
  moved. Inferred; depends on production's rev.
- **A tribe text retried after 30 s.** Text is retryable once unconfirmed
  for 30 s (`Message.isRetryable`), and in a tribe it carries the price. If
  the first went and its status was lost, Retry pays the price again and
  posts twice. A few sats; inferred.

## The flows, one by one

"Matches" compares with the core's contract and the official app.

| Flow | What Peel does | Reference | Matches | What the person sees |
|---|---|---|---|---|
| Keysend in a DM, send | `sendPayment` → `checkPayment` (amount + 1-sat ping, threshold) → `deliver` writes the row PENDING with the core state, then publishes; `.none` → FAILED, `.unknown` → stays pending | Mac `finalizeDirectPayment`: no gate, no pending state | yes, stricter; F1, F9 | "You sent 1,000 sats", "waiting for the server…" after 30 s, the bolt on COMPLETE, Retry on FAILED |
| Keysend in a DM, receive | Row from `msg.msat`; `.moneyReceived` if past the read marker | Mac stores `msat` | yes; F2, F3 | "Bob sent you 1,000 sats", a notification, the balance rolls up |
| Receive pane | `request_invoice`, answer checked (payee, amount, memo, expiry); paid when a history row has its hash | Mac: same call; never shows Paid | yes, better | QR, countdown, then Paid with what arrived |
| Pay a pasted invoice | `invoiceProblem` (amount, expiry, own, pending, paid, balance + fee reserve), threshold, one in flight; same server → `pay`, else `pay_invoice` falling back to `pay` | Mac: `payInvoice`, `pay` after 60 s | yes | Paying, then Paid with the fee from the history |
| Request in chat (ours) | Server invoice, then type 2 | Mac: same | yes; F8 | A card: "Waiting to be paid · expires …", then Paid |
| Paying their request | As a pasted invoice; `pay_contact_invoice` only for an invoice of their own node | Mac: only `payContactInvoice`, which fails for server-made requests | better | Pay, Paying, Paid; an amber note that it pays their server |
| Boost, DM and tribe | Tip (+ tribe price and escrow); one-tap unasked, once per message | Mac: same sum, no guard | yes | The chip; "Boost … not settled" or Retry |
| Paid message in a tribe | `deliver` pays the tribe's current price, at least 3 sats | Mac: same | yes (audit F1, accepted) | Nothing per message; the header shows the price |
| Paid attachment, buy | `checkPayment`, one purchase per token in flight, type 7 for the token's price | Mac: no confirmation | yes, stricter | Locked, Unlock, "waiting for Bob to send the key", the file |
| Paid attachment, sell | Key when `msat` covers the price less min(3 sats, a tenth); never a refund | Mac: refunds underpaid | differs by decision; F3 | "For sale · bought once" |
| Tribe join, free and paid | Price shown is the price paid; `checkPayment`; tribe written before the join | Mac: same core call, no gate | yes; F10 | Join (armed over the threshold), then the tribe |
| Invite make | Always confirmed; record before publish; waits up to 30 s for the server | Mac: same call | yes | The code once confirmed, or "waiting" |
| Invite redeem | Signup with the code; the inviter sees it used by the code in the new contact's key exchange | Mac: same | yes | The invite marked used |
| Invite cancel | `cancel_invite`, refund by balance rise | Mac: none | n/a; F11 | Cancelling, then cancelled, or "forget" |
| Key exchange | 5 sats + ping through `checkPayment`; the core's 3-sat answer | Mac: same amounts | yes; F6 | The contact; keysend rows in Payments |
| Balance | `new_balance` from any core reply, stored, shown in the header | Mac: same | yes; F1 | The header, rolling up on arrivals |
| Pending and status | Forward-only `setStatus`; live COMPLETE/FAILED, live PENDING → UNSETTLED; `getTags` on each connect; no record after 30 min → FAILED | Mac: `getTags` on start, same mapping, no unsettled | yes, better; F5, F7 | Waiting, not settled, failed with Retry |
| Restore | Messages from history; server's payment history fetched; invoices and invites not restored | Mac: similar | partly; F4, F8 | Payments and boosts with amounts; old failures as sent |

## Cases asked about

- **The app quits mid-send.** The row and the core state are written
  before anything is published. If nothing left, the next connect's
  `getTags` finds no record; after 30 minutes the row turns failed and can
  be sent again. If the async pay left but the ping did not, the server
  holds the payment and nothing wakes it: F5's limbo.
- **Offline when a payment arrives.** On connect the server re-sends the
  pings; Peel answers, the payments land live with `.moneyReceived` and the
  balance rises (verified on 2026-10-08, `04-money.md`). The ping times are
  kept only in memory; a quit before the payment lands is recovered by the
  server re-sending the ping and the core's "async pay not found" path
  (`Engine.swift:671-677`).
- **The core's or server's answer never comes.** A money send stays
  pending until the next connect asks `getTags`. A connection that stays
  up for days never asks again; a reconnect does.
- **Duplicates and double sends.** Two clicks: `moneyInFlight` in the app,
  `sendsInFlight` and the invoice table's unique row in the engine, one
  one-tap boost per message. Retry only after FAILED. Two different
  payments at once: see F1.
- **Mixer or server restarts.** An async pay is in the server's database
  and survives. A tribe boost's `SEND` has no record while in flight; a
  crash after moving funds then reads as "no record" after 30 minutes, and
  Retry could pay twice. Known and left (`04-money.md`, the first
  security review).
- **Restore on a new device.** The server's payment history follows, and
  so do messages with their amounts. Invoices and invites do not. Our own
  rows come back without a status (F4), and our paid requests as unpaid
  (F8).
- **msat and sats.** Everything sent and checked is msat. Display drops
  the rest of a sat, as the official apps do (`Sats.swift`); "1 of 2 sats"
  switches to msat where truncating would hide a shortfall. Typed amounts
  are whole sats. An invoice of 100,500 msat reads "100 sats" and still
  asks to confirm at the 100-sat threshold, which can look odd; cosmetic,
  known (`04-money.md`, "Whole sats everywhere").

## What holds

These were checked and are right; they are listed so they are not
re-reviewed:

- One gate (`checkPayment`) for every payment a person starts, with the
  ping counted for sends to a person and the fee reserve for invoices.
- A confirmation covers exactly one amount.
- Statuses only move forward, for messages, invoices and invites alike.
- A money send that may have gone is never offered again.
- An invoice is paid once, here; the server refuses a second payment.
- Server-made invoices are checked against what was asked.
- An invoice made here is Paid only if what arrived covers it.
- Received purchases are answered once; underpaid ones never refunded.
- The 30-minute "no record" rule fails only sends the server never took,
  except the tribe-boost crash case above.
- Expiry is the invoice's absolute time (`expires_at`), and #110 fixed the
  only timeline that drew a future date as passed; no other
  `TimelineView` in the app has the same pattern.

## What the integration suite covers

Covered (`Tests/PeelIntegrationTests`): key exchange both ways and by
invite; keysend both ways with exact balances and the ping; refusals that
move nothing; `request_invoice` without Lightning; free and paid tribe
join, a paid post and a tribe boost with balances; invite make, redeem and
cancel with exact amounts; restore with contact, DMs, a payment, a tribe
and the balance.

Not covered: anything with a recipient offline; anything failing at the
server; paid attachments; restore after a failure; invoices paid (needs a
regtest Lightning node).

## Journeys worth adding

Each tests something that cannot be checked by hand without two accounts
and a server, and each would have caught a finding above.

1. **Two payments to an offline contact.** Pay 4,000 of 5,000 sats twice
   while Bob is offline; Bob comes online. Assert one COMPLETE and one
   FAILED for Alice, Alice's balance, and that Bob shows one payment, not
   two. Pins F1 and F2. (The throwaway journey for this review did exactly
   this; about 60 s.)
2. **Restore after a failed payment.** Continue 1: restore Alice on a
   second device and assert the failed payment is not shown as sent. Pins F4.
3. **Key exchange accounting.** In `Contacts.keyExchangeByContactInfo`,
   assert the adder −3 and the added +1. Pins F6 and catches a change in
   the core's prices; two lines.
4. **A paid attachment in a DM.** Bob sells a 200-sat image, Alice buys
   it: Bob +200, Alice −201, the key arrives and the file decrypts. Then
   Alice buys again: refused. Not covered at all today, and it is the one
   flow where Peel's own code decides whether to hand over something paid for.
5. **A held payment survives a mixer restart.** Pay Bob while he is
   offline, restart the mixer (`test-stack.sh mixer <dir> real`), bring Bob
   online: the payment completes once and Alice's row turns COMPLETE on
   her next connect. Pins the async pay's durability and the `getTags`
   path after a restart.

Not worth it: confirmation and threshold rules (unit-tested), rounding
(unit-tested), UI states (no click-through tests, by Tom's decision).

## Suggested order

1. F1 (S): the gate and the header count pending payments to people.
2. F3, Peel half (S): clamp a live message's amount to the HTLC amount;
   record the stack's server rev in `testing.md`.
3. F2 and F4 (M): one history check for both directions: received
   payments confirmed by an incoming row, restored sends by an outgoing row.
4. F7, F8, F6 (S each): the labels.
5. F9, F10 (S): wait for the async pay's tag; track the join.
6. Journeys 1–4 with the fixes; 5 when convenient.
7. F3, core half (L): a core with the September fixes, when Tom decides to
   build the library rather than take the Mac app's.
