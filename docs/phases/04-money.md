# Phase 4 — Money

## Status (2026-10-08)

**Built and merged:** boosts and in-chat payments (#16), one-tap boost (#24),
unsettled payments and boost once (#26), the Payments screen, invoices,
requests in chat and paid attachments (#27), sats received shown and
notified (#51). Storage was at v13 then; it is at v21 now.

**Open:**
- Payment templates: moved to the v1 extras step on 2026-10-08 (evening;
  `../PLAN.md`), built there on 2026-10-10 (`10-v1-extras.md`, item 5).
- Lightning behind the server (server-made invoices, real fees), never run locally: "Not tested locally, and why".
- Receive by `make_invoice` or `request_invoice`, and two smaller questions: "Open questions for Tom".
- Restore loses a DM contact this account only answered: "Boosts and payments in chat", "Open".
- Sats counted before they settle, and the mixer's missed settle window: "Boost stuck waiting, and Boost once", "Open".
- The payments correctness review (`../reviews/2026-10-09-payments-correctness.md`):
  F1, F3 (Peel's half), F6 and F7 fixed ("Payments review, first set");
  F2, F4 and F8 fixed, and stale pending rows settled ("Payments review,
  reconciliation"); F5's words, F9 and three of F11's four edges fixed
  ("Payments review, waiting words and the async pay"); F5's cancel, F10,
  F11's tribe-text Retry (needs Tom) and F3's core half open.

**Decided:** msat end to end; one confirmation rule in `Engine.checkPayment`
(100 sats by default, 0 asks every time); nothing that may have paid is sent
again; one-tap boost with the account's amount, once per message; underpaid
purchases are never refunded automatically.

## Journal

The build log, oldest first, kept as written. Branches named below have all
merged.

Status on 2026-10-07: started that day. Boosts and in-chat payments are built in the
engine, storage, CLI and app (branch `phase4/boosts-payments-ui`, one
commit with the engine work). Invoices, the Receive screen, the Payments
screen, paid messages and templates are still to come.

Scope agreed 2026-10-05: send sats in chat, pay an invoice, request payment,
boosts, a Receive screen, transaction history, paid messages and payment
templates.

- Send sats in chat: type 5 (direct payment) and bare keysends; `amtMsat` on
  `send`. The async-payment ping flow is already handled in `Engine`.
- Pay a BOLT11 invoice: `parseInvoice`, `payInvoice`, `payContactInvoice`.
- Request payment: `makeInvoice` / `requestInvoice`, invoices in chat (type 2),
  invoice paid events.
- Boosts: type 29 with `replyUuid` and `amount`.
- Receive screen: amount, QR, copy, live "paid" confirmation. The official app
  has no deposit flow; this is new.
- History: `fetchPayments` with paging; balance from `newBalance`.
- Paid messages (types 7, 8, 9) and payment templates, kept because colleagues
  still send them.
- Safety: amounts in msat end to end; confirm before any send over a threshold;
  never develop against a real account.

## Boosts and payments in chat

Done means: boost a message and pay a contact in chat as the official apps
do, in DMs and tribes as they allow; amounts in msat end to end; refuse
nothing-or-less, more than the balance, and (unless confirmed) more than a
threshold the UI shows a confirmation for; the same pending / delivered /
failed / Retry as text, except that a payment is never sent twice; storage
answers boost totals per message (count, sum, who), payments in a chat and
recent payments; CLI `boost`, `pay`, `payments`, and boosts under each
message in `messages`. Verified on a local stack: DM payment both ways with
balances, boost in a DM and in a tribe (owner and member balances), retry
after the broker went down pays once, over-balance refused, history and
restore keep boosts and payments. No message-row UI in this task.

### Conventions (checked against the code, 2026-10-07)

Sources: the Mac app (`SphinxOnionManager+ChatExtension.swift`: `formatMsg`,
`sendMessage`, `processNewOutgoingMessage`, `processNewOutgoingPayment`,
`sendBoostReply`, `finalizeDirectPayment`, `processIncomingPaymentsAndBoosts`,
`processGenericIncomingMessage`, `restoreGenericPmt`;
`TransactionMessageParamsExtension.getBoostMessageParams`;
`TransactionMessageInfoGetterExtension.isBoostActionAllowed`;
`ChatHelper.processMessageReaction`, `MessageTableCellState.boosts`;
`Chat.calculateUnseenMessagesCount`; `SphinOnionManager+InvoicesExtension`:
`checkAndFetchRouteTo`, `getTransactionsHistory`), the core
(`sphinx/src/bindings/send.rs` `send`, `keysend`; `handle_msg.rs`,
`handle_batch.rs`, `handler.rs` `BALANCE` / `SEND` / `PAYMENTS`;
`msg/mod.rs` `Message.amount`, `MsgType`), the FFI (`sphinx-ffi/src/auto.rs`
`send`, `chunk.rs`), the mixer (`send.rs` `handle_local`, `move_funds`,
`notify_balance_change`; `main.rs` `TESTING_ONLY_ADD_TO_SENDER`), the
tribes server (`forward.rs` `MsgType::Boost`, price and escrow checks;
`incoming.rs` `send_to_single`) and the reference client
(`wasm/test/auto/boost.ts`, `send.ts` `keysend`, `fetch.ts`
`fetch_payments`, `main.ts` `handle_rr`).

- **Amounts.** Everything on the wire is msat: `send(amtMsat:)`, `Msg.msat`,
  `newBalance`, the JSON `amount`, `fetchPayments` (`amt_msat`). The Mac app
  keeps sats for display (`amount / 1000`) and msat beside it. Peel keeps
  msat everywhere and converts only for display.
- **How sats travel.** `send` with `amtMsat > 0` is a keysend to the
  contact's account key (`contact.pubkey`, the "ok key", child index 0)
  instead of an onion message to the contact key; in a DM the core also
  makes a payment hash (`msg.payment_hash`), and it writes `amount =
  amtMsat` into the message JSON itself (`msg.set_amount`). If the
  recipient is offline the payment is an async pay held by the mixer
  (`asyncpay_topic` plus a ping); `msgs[0]` then carries the async pay's tag,
  payment hash and uuid. Same LSP needs no route; the Mac app asks the
  router (`findRoute` / `fetchRoutingInfoFor` / `concatRoute`) only when the
  contact is on another LSP. Peel does not route across LSPs yet (all
  contacts so far are on the one server); a payment that needs a route
  fails at the mixer and shows as failed.
- **Boost (type 29).** JSON `{"content":"","replyUuid":<boosted uuid>}`;
  the core adds `amount`. Only for someone else's message with a uuid
  (`isBoostActionAllowed`: incoming, not an invoice, payment or call link).
  The amount the Mac app sends is the tip (`tipAmount`, default 100 sats)
  plus, in a tribe, the tribe's price per message and escrow:
  `amtMsat = pricePerMessage + escrow + tip` (no 3-sat floor, unlike text).
  In a DM it is the tip. Sent with `isTribe` in a tribe.
- **Boost in a tribe.** The tribes server checks the received amount
  against price per message plus escrow like any priced message, looks up
  the boosted message by `replyUuid` (`fetch_og_msg`), and forwards the
  boost to every member, paying the boosted message's author the whole
  amount it received (`real_sats`); the others get it as a plain message
  with the declared `amount` in the JSON and no sats. The owner gets no cut
  of a boost. The escrow part is staked and paid back to the booster later
  by the tribes server. A boost with no `replyUuid` (podcast boosts) pays the
  owner; Peel does not send those (feeds are out of scope).
- **Direct payment (type 5).** DMs only in the Mac app
  (`finalizeDirectPayment` needs `chat.getContact()`): JSON
  `{"content":<text>}` plus `"mediaType":"image/png"` (and a media token
  when a picture is attached). Peel sends `{"content":<text>}`: the media
  type without a token means nothing, and the Mac app draws the payment
  bubble from the type and amount. A type 5 sent to a tribe would pay the
  tribes server, not a member (no `real_sats` for it), so Peel refuses it.
- **Bare keysend.** `keysend(to:amtMsat:data:routeHint:)`: sats with no
  chat message. On receipt the core cannot parse a Sphinx message, so it
  returns a `Msg` with no type and `{"content":<utf8 of the data>}`; the
  Mac app only copies the amount onto a stored message with the same index
  (`restoreGenericPmt`), never into a chat. Peel does not send them and
  drops them (no type, no sender); they appear only in the mixer's ledger
  (`fetchPayments`), which is where the Payments screen will read them.
- **Receiving.** A paid message arrives on the account key's topic (child
  index 0) with the HTLC amount and payment hash in the topic; the core
  reports `msat` and `paymentHash`. **Corrected 2026-10-09 (payments
  review F3):** this said the core peels against the real HTLC amount and
  never reports more than arrived. That is true of the core's `master`
  (`c3ddbb7`, SR-016), not of `bd9e140`, the rev Peel links: it ignores the
  topic's amount (`handle_msg.rs:27`) and peels with `u64::MAX`
  (`onion_payment.rs:196`), so `msat` is what the sender wrote in its
  onion. Peel now caps it at what the server says arrived
  (`Engine.cappedToArrived`): the topic's amount for a live message, the
  amount beside each onion for a history page (`StateCodec.paymentAmounts`).
  A live "stream" payment is settled by the core (`settle_topic`). History
  (`fetchMsgsBatch`) returns `msat` the same way.
  The JSON `amount` is what the sender declared. The Mac app shows
  `amount ?? msat`. Peel shows `msat` when sats reached this account (or
  left it), and the declared `amount` only for our own sends and for a
  tribe boost seen without sats (someone else's boost on someone else's
  message). Those are self-declared by the booster; the tribes server only
  checks they paid at least the price. Anyone can send a type 5 or 29 with
  no sats and any `amount` in the JSON, so a contact's declared amount is
  never shown as money received.
- **What the Mac app shows.** A boost with a `replyUuid` is not a row: it is
  summed under the boosted message (count, total sats, each booster's alias
  and photo, "boosted by me"), failed ones left out. A direct payment is a
  row (amount, text). Received boosts and payments count as unread, like any
  message other than deletes and key exchanges (`calculateUnseenMessagesCount`),
  and a received one sends a local notification.
- **Status.** A send's status comes back on the `send` topic with the tag of
  `msgs[0]` (`sent_status`: `COMPLETE`, `PENDING`, `FAILED` with a message
  such as "insufficient balance"). The mixer checks the balance before
  moving anything (`handle_local`), and a `FAILED` means nothing moved. An
  async pay stays `PENDING` in the mixer's records (`getTags`) until the
  recipient comes online; nothing is published on `send` until then. The
  mixer publishes exactly one status per tag, and a live `PENDING` is that
  one: it reached the recipient (who has the message) but the payment did
  not settle in its window. Peel shows it as unsettled (see "Boost stuck
  waiting" below).
- **Balance.** The mixer pushes `newBalance` (msat) to both sides after
  every local payment (`notify_balance_change`), and once on connect
  (`initialSetup` asks for it). With `TESTING_ONLY_ADD_TO_SENDER=1` the
  mixer gives the sender the amount back before each payment and skips the
  balance check, so only the recipient's balance moves.
- **Never pay twice.** The core gives every send a fresh tag, uuid,
  preimage and payment hash, so sending a payment again is a new payment;
  the mixer does not dedupe keysends (only invoices, `has_paid_rhash`).
  The Mac app has no resend for payments. The mixer records a direct
  payment's tag as soon as it takes the async pay (`ASYNC_PAY`, pending),
  but a `SEND` (tribe boost, or a payment to an online contact) only once
  it has an answer, a few seconds (local) or up to the payment budget
  (Lightning) later.
- **Status of a send missed while offline.** The Mac app asks `getTags`
  for its pending messages on start; the reply lists the mixer's record
  (`{tag, ts, status, error}`) for each tag it knows.
- **Chunks and sats.** The FFI splits any `send` whose JSON is over about
  570 bytes minus the sender's alias and photo URL (`should_chunk_for_send`)
  into type 34 fragments, and every fragment carries the full `amtMsat`. A
  long payment note would pay once per fragment, and only the last
  fragment's async pay survives the merge. So a payment that would be
  split goes without the time-zone offset, then without the photo URL (the
  apps keep a contact's photo when a message has none), and only then is
  refused: for its note, or with no note (a boost) for the name.
- **History.** `fetchPayments(since, limit, scid, remoteOnly, minMsat,
  reverse)` returns the mixer's ledger as JSON `[{scid, amt_msat, rhash, ts,
  remote, msg_idx, error}]` plus `payments_total`; the Mac app's
  Transactions screen pages it newest first. Not used yet.

### Invoices (not in this task)

From the list above: pay a BOLT11 invoice (`parseInvoice`, `payInvoice`,
`payContactInvoice`), request payment (`makeInvoice` / `requestInvoice`,
type 2 in chat with `invoice`, type 3 when paid, matched by payment hash),
the Receive screen, the Payments screen from `fetchPayments`, paid
messages (7, 8, 9) and templates.

### Plan

- `MessageType.directPayment = 5`, `boost = 29`. Direct payments will show
  in a chat's timeline with the payment row's UI; boosts with a
  `replyUuid` never do.
- Storage migration `v11` (main was at v8 then, and is at v18 now; `phase3/attachments` adds v9
  and `phase3/chat-ui` v10, message delete): `message.amountMsat`, the
  amount a payment or boost row stands for, filled from the copies already
  stored.
- Queries: boost summaries per boosted uuid for a chat (count, total, who,
  boosted by me), also on `Timeline` and `ChatThread`; `payments(in:)` for
  one chat or all (newest first).
- Engine: `boost(messageID:amountMsat:confirmedMsat:)`,
  `sendPayment(to:amountMsat:text:confirmedMsat:)`, `balanceMsat()`,
  `paymentConfirmationMsat()` / `setPaymentConfirmation(msat:)` (default
  100 sats, Tom 2026-10-07, was 10,000; 0 asks every time; above it the
  call fails with `needsConfirmation(amountMsat:)` unless `confirmedMsat`
  is exactly that amount). Refuse 0, more than the last known balance, a note that
  would be chunked, payments to a tribe. Retry (`resend`) only after the
  mixer said `FAILED` or when nothing was published; a payment whose publish
  failed half way stays pending, never retryable.
- Unread counts received boosts and payments, as the Mac app does.
- CLI: `boost <id> <sats> [--yes]`, `pay <pubkey> <sats> [--text <note>]
  [--yes]`, `payments [pubkey]`, boosts under each row in `messages`.

### Built (2026-10-07, branch `phase4/boosts-payments`)

- `Message`: `MessageType.directPayment`, `boost`, `payments`;
  `amountMsat`; `isBoostable` (someone else's text with a uuid);
  `isRetryable` lets a payment or boost go again only once it FAILED,
  never because it waited. `DeclaredAmount` reads the JSON `amount` on its
  own, so an odd value never costs a message its other fields.
- Storage migration `v11` (`phase3/attachments` adds v9, `phase3/chat-ui`
  v10): `message.amountMsat`, back-filled from `msat` or, for our own
  rows and tribe boosts, an integer declared amount; partial indexes
  `message_payment (timestamp)` and `message_pending (id)`.
- `Storage.setStatus` only moves a row forward (pending to delivered or
  failed, failed to delivered, never back), so no late or synthesised
  failure can make a payment that went through retryable. The resend
  update holds `isRetryable`'s rule too (a payment only when FAILED).
- Queries: `Timeline.boosts` and `ChatThread.boosts` (`BoostSummary`:
  boosts oldest first, count, total, boosted by me; our failed boosts left
  out); `payments(in: chat?)` (newest 200, one chat or all); unread counts
  received boosts and payments; `balanceMsat()`.
- Engine: `boost(messageID:amountMsat:confirmed:)` (total = the tribe's
  `paymentPriceMsat`, price plus escrow with no floor, plus the amount);
  `sendPayment(to:amountMsat:text:confirmed:)` (people only);
  `resend(messageID:confirmed:)`; `balanceMsat()`;
  `paymentConfirmationMsat()` / `setPaymentConfirmation(msat:)` (default
  100 sats, `needsConfirmation` above it unless confirmed, for a retry
  too). Refusals: `invalidAmount`, `balanceUnknown`, `insufficientBalance`,
  `notBoostable`, `paymentToTribe`, `noteTooLong` (`wouldBeSplit`, the FFI's
  chunk rule with a margin). `deliver` takes a type and amount; a payment
  is marked failed only when nothing was published (no connection), else it
  stays pending.
- On each connect, `checkPendingSends` asks `getTags` (best effort) for
  pending payments and for text past the confirmation timeout. COMPLETE or
  FAILED records land; a payment over 30 minutes old that the mixer has no
  record of is marked failed (it never got it). The query and its reply
  belong to one connection (clean session), so the set is cleared on
  teardown.
- CLI: `boost <id> <sats> [--yes]`, `pay <pubkey> <sats> [--text <note>]
  [--yes]`, `payments [pubkey]`, `resend <id> [--yes]`; `messages` prints
  boosts under each row; `whoami` shows msat too.
- Tests: `PaymentTests` (boost summaries in timeline and thread, failed and
  other-chat boosts left out, payments in a chat and in all, first copy
  keeps its amount, a paid copy corrects an unpaid one, unread counts, the
  v11 back-fill incl. unpaid and odd amounts, retried payment takes the new
  send, only failed payments retry, boostable, chunk rule, declared amount
  read on its own). `swift build --build-tests` passes; not run here.

### Verified (local stack, 2026-10-07)

Broker 1963, mixer 8073 (`NO_LIGHTNING`, real balance accounting after a
funding phase), tribes server 8883; profiles `bp-*`, deleted afterwards.
Funding: invites made with a temporary, never-committed CLI command while
the mixer ran with `TESTING_ONLY_ADD_TO_SENDER`, then the mixer restarted
without it, so every balance below is real.

| Check | Result |
|---|---|
| DM payment Alice to Bob, 1000 sats + note, Bob offline | Bob +1000, Alice -1001 (1-sat async ping); Alice's row confirmed on her next connect by `getTags` |
| DM payment Bob to Alice, 250 sats, both online | Alice +250, Bob -251 |
| Over balance, over threshold, 0 sats, 560-char note | Refused locally, nothing sent; a 481-char note went whole and paid once |
| Broker down: payment recorded FAILED; broker up, `resend` | Paid once (Bob +100); a second `resend` refused |
| Resend published while the mixer was still reconnecting | Lost, stayed pending (not retryable); backdated an hour, the next connect marked it FAILED (no record); `resend` paid once |
| Tribe boost, price 10 sats: Carol boosts Bob's post by 100 | Carol -110, Bob (author) +110, Alice (owner) unchanged; all three see "boosted 1x, 110 sats, by carol" |
| DM boost 50 sats | Bob +50, Alice -51; shown under Bob's message on both sides |
| Boost own message, pay a tribe | Refused |
| Restore Alice's words (`bp-alice2`) | All payments and boosts back with amounts, boost under its message |
| Restore Bob's words (`bp-bob2`) | Tribe boost back; the DM with Alice lost (see open, a restore issue on main too) |
| After the simplify fixes: broker down payment, broker up, `resend` | FAILED, then paid once and confirmed |

Not verified: the mixer refusing for balance (connecting refreshes the
balance first, so Peel always refused first); escrow; cross-LSP routes;
anything on production or against the official Mac app.

### Reviews

`/code-review high`, applied: direct payments kept out of the timeline
until the payment row exists (the app drew them as "joined" notes); a
retry needs confirmation over the threshold like a new payment; the
pending-status check cannot stop catch-up; an odd `amount` no longer
wipes a message's content and links; the migration takes integer amounts
only; pending sends have a partial index; a synthesised failure cannot
overwrite a confirmation; the tribe price sum simplified.
Not applied: unread counts include payments and boosts, but the sidebar
preview and order still follow text only, so a payment can leave a badge
with nothing new to see. Left for the payment row UI (Tom to decide).

`/simplify`, applied: `setStatus` monotonic (replaces a separate
"unrecorded" list); the resend update holds the retry rule;
`Tribe.paymentPriceMsat` reuses `messageAmount` (with a floor parameter)
instead of a second sum; `MessageType.sqlList` for every SQL `IN` list;
`Storage.balanceMsat()` shared by engine and CLI; the `uuid`/`dm` test
helpers shared; `wouldBeSplit` names chunk.rs's constants, no dead
fallback; `boostable` list and `Resend.type` dropped; CLI `boost` and `pay`
split, `connectIfPossible` shared with `send`; boost summaries read four
columns and decode the sender once; `message_payment` on `(timestamp)` so
the all-chats list needs no sort; the status check asks only about
payments and text past the timeout.
Not applied: `amountMsat` as a computed property (it would change the
rule that the first copy keeps its amount; kept stored, Tom's call);
`complete` reporting how far it published instead of `deliver` checking
the connection first (`complete` checks the connection before any
subscribe or publish, so the check is exact today); a request id for the
`getTags` query (replies only come on the connection that asked).

`/security-review`, applied: a contact could send an unpaid type 5 or 29
with any `amount` and Peel showed it as money received (`amountMsat` fell
back to the declared amount everywhere). Now a declared amount counts only
for our own sends and for tribe boosts seen without sats, and a later copy
with real sats replaces a stored amount.
Not applied (confidence below the bar, recorded): a tribe boost's `SEND`
has no mixer record while in flight; if the mixer crashed or was
redeployed in that window after moving funds, the 30-minute rule would
mark it failed and a retry would pay twice. Needs a mixer crash at the
wrong moment; the alternative is to check the payment hash against
`fetchPayments` before allowing a retry of a "no record" failure.
Outside this diff: a text message to a tribe pays whatever price the
tribes server now sets, with no balance check or threshold.

### Open

- The Payments screen: merge local rows with `fetchPayments` (bare
  keysends, tribe prices, invoices).
- The sender's balance after a payment can be stale until the next
  connect (the mixer's notice can carry the pre-payment value); the mixer
  refuses what the balance cannot cover.
- Restore loses a DM contact this account answered but never wrote to
  (checked on `origin/main` with fresh `bp-fay`/`bp-gus`: Gus adds Fay,
  Fay restores, the contact is gone; once Fay has sent a message on
  Gus's key it comes back). The server holds only Gus's key exchange (index
  0, on the account key) for Fay: the contact record (type 33) the
  responder's core produces while answering never lands on the server, so
  the first-message-per-key pass has nothing to rebuild from. Not a Peel
  restore bug that can be fixed in a few lines; needs a look at whether the
  responder's type 33 publish reaches the mixer and why it is not stored.

## Boosts and payments in the app (2026-10-07, branch `phase4/boosts-payments-ui`)

Rebased on main (attachments v9, chat UI v10, notifications, mention
back-fill); the boosts migration stays `v11`.

### Tom's decisions

1. A direct payment in a DM is a compact row in the timeline (bolt, "You
   sent 1,000 sats" / "Bob sent you 1,000 sats", the note, the time, the
   delivery bolt or Retry for ours) and moves the DM up the sidebar like a
   message (the sidebar shows names only, so there is no preview line).
2. Someone else's boost on someone else's message is not unread; only
   boosts on your messages and payments to you are.
3. Boost: you pick a tip; in a tribe Peel adds the tribe's price and
   escrow and shows the total before sending. Over the confirmation
   threshold a second click shows the amount. The threshold defaults to
   100 sats for everyone (was 10,000); Account offers Always confirm, 100,
   1,000 and 10,000 sats.
4. Payments to you and boosts on your messages should notify: the engine
   exposes `Engine.Event.moneyReceived` (see `03-chat.md`, Notifications,
   Open); the notifier does not show it yet.

### Built

- Engine: `confirmedMsat: UInt64?` on `boost`, `sendPayment` and
  `resend` (replaces `confirmed: Bool`): a confirmation covers only the
  amount the engine named, so a tribe raising its price between the two
  clicks asks again. `Engine.boostTotalMsat(tipMsat:in:)` is the one sum
  the app shows and the engine charges. `boostTarget` holds the boostable
  rule for a new boost and a retry (no paying for a message deleted
  since); `isBoostable` excludes deleted messages. CLI `--yes` confirms
  the amount the engine names and prints it.
- Unread: text, attachments, direct payments, and boosts only on our own
  messages (`readStatesSQL`, a test). `Storage.apply` reports
  `received` (new to this Mac, real sats, past the read marker, for us)
  and the engine emits `.moneyReceived` (a test).
- Deleted rows: boost summaries and `payments(in:)` leave them out;
  deletes (type 17) only ever apply to text and attachments, so a deleted
  payment cannot arise today, but its row would read "This payment has
  been deleted". The conversations order counts payments that are not
  deleted.
- `BoostSummary`: our failed boosts apart (`failed`, for Retry and
  Discard), `pendingSince` for our unconfirmed ones. Someone else's boost
  on our message counts only the sats that arrived (`msat`), never the
  declared amount (security review).
- `Sats.msat(_:)` parses typed sats for the app and the CLI.
- App (`PaymentViews.swift`): payment rows; the boost chip under a
  message ("⚡ 1,210 sats", then up to three boosters' photos overlapping
  and "+N", as the official Mac app's `NewMessageBoostView`; tinted when
  you boosted it; replaced the first "⚡ 1,210 · 4" chip after Tom's
  feedback, and made quiet like Slack's reactions on 2026-10-08: 11 pt,
  16 pt photos, see the design README) opening a Peel
  panel of who boosted with avatars and amounts; Boost in the hover bar
  (Reply, Boost, More) and "Boost…" in the message menu, where
  `isBoostable`, opening a panel with 10 / 50 / 100 / 500 sats or another
  amount, the tribe's price and escrow and the total, your balance and
  "Boost 110 sats"; a bolt beside the composer in DMs opening Send sats
  (amount, note, balance); `PaymentAttempt` asks the engine first and on
  `needsConfirmation` turns the button orange ("Click again to send 1,000
  sats"), any change to the amount or note disarms it; never twice while
  one is on its way (`working`, and `AppModel.moneyInFlight` per payment).
  Our unconfirmed payments and boosts read "… waiting for the server…"
  after 30 s with no Discard; failed ones "Not sent" / "Boost of 100 sats
  not sent" with Retry (asks "Send 1,000 sats again?" over the threshold)
  and Discard, in `UndeliveredActions`. Account: "Confirm payments"
  (Peel dropdown). Balance in the sidebar header follows the engine's
  `.balance` events.

### Verified (local stack, 2026-10-07)

Broker 2363, mixer 8373 (`NO_LIGHTNING`), tribes 8893, profiles
`bu-bank`, `bu-alice`, `bu-bob`, `bu-carol`, deleted afterwards. Funding:
the mixer ran with `TESTING_ONLY_ADD_TO_SENDER` for the key exchanges and a
few back-and-forth payments (senders are not debited there); a temporary
code change to skip Peel's own balance check was refused by the session's
permission rules and not made, and the payment loop was stopped. So the
balances were small (tens of sats) and the checks below used 1–5 sats under
real accounting (mixer restarted without the flag).

| Check | Result |
|---|---|
| DM payments both ways with notes (5 and 3 sats, then 1) | Rows on both sides, "You sent" / "Bob sent you", delivery bolt on ours; Bob's DM moved to the top and opened first on relaunch |
| Live balance in the sidebar header | 39 → 40 sats when Bob paid 1 sat while the app was open |
| DM boost (Bob on Alice's message, 2 sats) | Chip "⚡ 2 · 1" on Alice's message, tinted on Bob's side; `.moneyReceived` printed live for Alice (`listen`) |
| Tribe boost (Carol on Bob's post, price 1 + tip 1) | Chip "⚡ 2 · 1" under Bob's post for Alice; Alice's tribe unread 1 (Bob's post only); Bob's tribe bold (boost on his message) |
| Payment with the broker down | "Not sent · Retry · Discard" on the row; CLI `resend` paid once, a second refused |

Screenshots (window capture): `shots/02-dm-payment-rows.png`,
`shots/03-bob-failed-payment-retry.png`, `shots/01-after-payment.png` in
the session scratchpad. Those show the first chip; the photo chip with 1,
3 (one of them yours, tinted) and 6 boosters ("+3") is
`shots/04-boost-chips-1-3-6.png`, from a `bu2-alice` profile whose boost
rows were written into its database for the picture (accounts could not
be funded for six boosters), deleted afterwards.

Not checked by hand: this session could not click in the app (no
accessibility or computer-use access), so the boost panel with the tribe
total, the who-boosted panel, Send sats, the two-click confirm, Retry's
confirm and the Account dropdown were built and compiled but not opened;
"waiting for the server…"; anything over 100 sats (balances too small).

### Reviews

`/code-review high`, applied: `isBoostable` excludes deleted messages (and
a retried boost checks its message again); a new note disarms the
confirm; a failed boost under a deleted message can still be retried or
discarded; the unread count keeps index ranges (`type IN (...)` then the
boost condition) and counts deleted rows as before; no `UInt64.init`
trap on a negative stored amount; the unused conversation preview columns
dropped; one sats parser (`Sats.msat`) for app and CLI.
Not applied: a payment whose publish failed with the connection up stays
pending until a reconnect's `getTags` (from the engine PR, by design: it
may have paid); a truncated `getTags` reply could mark an old payment
failed (engine PR, recorded under its security review); failed boosts
outside the newest 200 messages show nowhere until the Payments screen.

`/simplify`, applied: confirmation bound to the amount in the engine
(`confirmedMsat`), so the app's own threshold check and three equality
checks went; one boost sum (`Engine.boostTotalMsat`); one boostable check
(`boostTarget`); `PaymentAttempt` shared by the pay buttons and Retry;
`UndeliveredActions` handles payments (no second copy); `FormFooter`,
`GhostButtonStyle(fill:)`, `fieldBoxed()` and `Formatting.sats(msat:
Int64)` reused; the boost panel's anchor only on boostable rows.
Not applied: `boosts(on:)` still reads whole rows (boost bodies are a few
dozen bytes, and failed ones need the row for Retry); `Storage.store`
reporting insert vs update instead of the `EXISTS` check (rare rows, a
wider change to the shared upsert); the "boost on my message" rule is in
SQL (unread) and Swift (`isMoneyForMe`), cross-referenced rather than
shared; the double-send guard stays in the app (the engine is reentrant
across `deliver`, but two calls are two requests from the person).

`/security-review` (money UI): the only finding (confidence 7, below the
skill's bar, fixed anyway): in a tribe, someone else's boost on our own
message that arrived without sats showed its self-declared amount in the
chip and the who-boosted panel. Now a boost on our message counts only
`msat` (test). The v11 back-fill keeps declared amounts for tribe boosts
but the summary ignores them on our messages. Checked and sound:
confirmation binding, double clicks, retries, `.moneyReceived` (needs real
sats), SQL built only from constants.

## One-tap boost (2026-10-07, branch `phase4/one-tap-boost`)

As in the official apps, the hover bar's bolt boosts at once with the
account's boost amount: no panel, no confirmation.

### What the official apps do (checked in the code)

- **Setting.** Mac and iOS call it "Default tip amount", on the Profile
  screen (Mac `Scenes/Profile/Base.lproj/Profile.storyboard`,
  `meetingAmountField`). The default is 100 sats
  (`UserDefaults.Keys.tipAmount.get(defaultValue: 100)`; iOS uses the key
  `meetingPmtAmount`). It syncs between devices as `tip_amount` and is not
  validated.
- **Sending.** The menu item sends `pricePerMessage + escrow + tip` at once
  (`TransactionMessageParamsExtension.getBoostMessageParams`). In a DM it
  sends the tip alone. There is no confirmation and no guard against double
  taps.
- **What they show.**
  - The menu item is the plain word "Boost" with the `boostIconGreen` icon
    and no amount (Mac `TransactionMessageInfoGetterExtension.swift:706`,
    iOS `:612`).
  - Nothing is shown on success. Failure shows an alert ("boost.error",
    or "Routing Error" in a DM).
  - No screen breaks out the tribe's price.
  - The chip under the message sums each boost's stored amount. For your
    own boost that is everything sent, the price included
    (`MessageTableCellState.swift:578`).

### Decided (Tom, 2026-10-07)

- Account: "Boost amount" (10 / 50 / 100 / 500 / 1,000 sats, Custom…), per
  account, default 100 sats.
- **One tap sends the boost amount plus the tribe's price and escrow, with
  no confirmation of any kind.** There is no price-spike prompt, and neither
  the threshold nor "Always confirm" applies to it. Those still apply to
  "Boost…" (the panel for a custom amount), Send sats and, later, invoices.
- Saving a custom boost amount over the threshold takes two clicks on the
  Account screen. That is the one place a big amount is approved.
- Labels name the boost amount only: "Boost 100 sats" in the menu and on
  the bolt's tooltip, never the tribe's price. The chip's total includes
  the price, as in the official apps.
- The chip shows pending at once, and a failure shows Retry as before.
- Two taps on one message within a second are one boost, silently.
- Money buttons use plain verbs: "Boost" or "Send" when idle; when armed,
  "Boost 150 sats" with "Click again to confirm" beside it. This applies to
  every money confirm.

### Built

- **Engine.**
  - `quickBoost(messageID:)` checks the balance only (`Confirmation.unasked`
    in `checkPayment`).
  - `boost(…confirmedMsat:)` and `sendPayment` keep the threshold
    (`Engine.needsConfirmation`: over the threshold, unless confirmed for
    exactly that amount; 0 asks for everything).
  - `boostAmountMsat()` and `setBoostAmount(msat:confirmedMsat:)` read and
    set the `boostAmountMsat` setting. Saving asks over the threshold.
  - The double-tap guard is in the engine. A one-tap boost within
    `quickBoostGap` (1 s) of our last boost on the same message
    (`Storage.lastOwnBoost`, failed ones included) is ignored.
- **CLI.**
  - `boost <id>` without an amount is the one-tap boost, with no `--yes`.
  - `boost-amount [sats]` shows or sets the amount, with `--yes` over the
    threshold.
- **App.**
  - The bolt and the menu's "Boost 100 sats" (B in the menu) call
    `AppModel.quickBoost`. A refusal (balance) shows in the chat's notice,
    as the official apps show an alert.
  - Account has `BoostAmountRow`. A preset saves as picked. A typed amount
    over the threshold takes a second click (`PayButton`).
  - `PayButton` and Retry use the plain-verb copy with `ConfirmHint`.

### Verified (local stack, real accounting)

Ports: broker 2363, mixer 8373, tribes 8893. Profiles `ob-alice`, `ob-bob`
and `ob-carol` were deleted afterwards. The balances came only from key
exchanges (6–10 sats). These checks ran on the first version of the
branch. The one-tap path they exercise did not ask in either case, so they
still hold. The price-spike prompt they did not reach has since been
removed.

| Check | Result |
|---|---|
| One-tap at the default 100 sats with a 10-sat balance | Refused locally ("the balance is not enough for that"); nothing sent |
| Boost amount 2 sats, one-tap in a DM | Sent at once; Alice +2 sats; `.moneyReceived` live |
| Tribe with a 3-sat price, boost amount 2 sats, one-tap | Sent 5 sats (3 + 2) at once |
| `boost-amount 200` (over the 100-sat threshold) | Refused without `--yes`; with it, "confirmed 200 sats" and saved |

Not checked by hand, because this session cannot click in the app: the
hover bolt, the menu item, the Account row and the new button copy.

### Reviews

- **`/code-review high`, first version.** Applied: a custom boost amount
  over the threshold takes a second click, now in the engine; a failed save
  keeps the typed amount; docs. The rest (price-spike prompt, "Always
  confirm" on one-tap, total labels) was dropped with Tom's decision for no
  confirmation.
- **`/simplify`.** Applied: the double-tap guard is in the engine, which
  covers the CLI; `BoostAmountRow` reuses `PayButton`, `SatsField` and a
  shared presets helper; there is one CLI sats parser. The second version
  removed the per-message confirm state and `QuickBoostConfirm` altogether.
- **`/security-review` (unintended sends), first version.** Nothing at the
  bar. The rule it checked (a tap never confirms; confirmations bind to the
  exact total) still holds for the panel, Send sats and Retry. One-tap is
  now unasked by design, and it is bounded by the saved boost amount plus
  the tribe's price and by the balance.
- **`/code-review high` on the second version.**
  - Applied:
    - A later successful one-tap clears a stale "Could not boost" notice.
    - One `checkPayment` with the `Confirmation` enum, with no wrapper
      overload.
  - Not applied, Tom's decision for this UX, recorded here for him:
    - One-tap is bounded only by the balance and the saved boost amount
      plus the tribe's price. A tribe owner who raises the price to 50,000
      sats makes one tap send 50,100, unasked.
    - The 100-sat default was never approved through `setBoostAmount`. A
      boost amount saved under an earlier, higher threshold is not checked
      again when the threshold is lowered.
    - The label says "Boost 100 sats" while a tribe's price is added on
      top.
  - Not applied:
    - Retrying a failed one-tap boost goes through `resend`, which keeps
      the threshold, so Retry may ask where the tap did not. Retry only
      knows the stored total, not whether it was a one-tap. It errs on
      asking.
    - No engine test drives `quickBoost` end to end. It needs a connected
      core; the rule is checked on the local stack and
      `needsConfirmation` is unit-tested.
    - The bolt's tooltip has no "(B)"; the shortcut lives in the menu.

## Boost stuck waiting, and Boost once (2026-10-07, branch `fix/boost-status`)

### The bug

Tom boosted a DM message with 21 sats on production. The official app on
the other side showed the boost; Peel kept "Boost waiting for the server…"
under it for good.

### Root cause (checked in the code, reproduced locally)

For a DM payment the core returns two sends: `msgs[0]` the async pay
(tag T, the payment hash, the uuid; Peel stores T on the row) and `msgs[1]`
the 1-sat ping (another tag). The mixer records T as pending when it takes
the async pay (`ASYNC_PAY`, answered on the `async_pay` topic, not `send`).
When the recipient answers the ping, `ping.rs` `pay_now` redeems the async
pay, stores the message for the recipient, waits for the recipient's settle
(`handle_local`, at most `TIMEOUT_MS`, 4.2 s by default) and publishes
exactly one status on `send/T`: `COMPLETE` with the preimage, or `PENDING`
if the settle did not come in time. After a `PENDING` nothing more is ever
published for T: the async pay is gone, a late settle is refused ("no htlc
outcome") and `getTags` answers `PENDING` for ever. Peel treated only
`COMPLETE` and `FAILED` as answers, and the 30-minute rule only fails a
payment the mixer has *no* record of, so the row stayed pending for ever,
while the recipient already had the message. The official apps never show
a pending state on a boost, so they hide this.

Reproduced on the local stack by restarting the mixer with `TIMEOUT_MS=1`
(the settle always misses the window): Bob's side showed the boost, Alice's
got `send PENDING <T>` and the row stayed `PENDING` across reconnects
(`getTags` said `PENDING`). With the default window every other path
confirmed: one-tap and amount boosts with Bob online (`COMPLETE` live) and
offline (`COMPLETE` from `getTags` on Alice's next connect), so tag
matching, the one-tap path and the order of writing the row are fine.

What the sats did: in that reproduction Bob's balance did not move. In this
mixer a local payment that misses the window is never paid (only
`move_funds`, after the settle, moves sats), although the recipient's app
shows the boost. A Lightning payment answered `PENDING` after its 5-minute
budget has left the sender's balance and is in flight. Whether Tom's 21
sats moved shows in the two balances; if the sender's did not drop, the
mixer missed the settle (a mixer issue: it should keep the async pay or
pay a late settle).

### Fix

The first version marked a live `PENDING` delivered. `/code-review` pointed
out that this shows the bolt for sats that, in the reproduction, never
moved, and that a Lightning payment still in flight could then never show
its failure. So a live `PENDING` now has its own state:

- `Message.Delivery.unsettled` (`UNSETTLED`): the server passed the payment
  or boost on and the recipient has the message, but it never settled.
  Not retryable (it may have paid), not asked about again by `getTags`
  (the mixer's record says `PENDING` for good), and still moved on by a
  later `COMPLETE` or `FAILED` (`Storage.setStatus`: pending to anything,
  unsettled to delivered or failed, failed to delivered, delivered never).
- `Engine.liveStatus` and `Engine.recordedStatuses` decide which rows a
  status moves, with tests: live `COMPLETE`/`FAILED` as before, live
  `PENDING` unsettled; from the records only `COMPLETE`/`FAILED` (a recorded
  `PENDING` may be an async pay held for an offline recipient), plus the
  30-minute rule. Unknown statuses change nothing (they used to be written
  into the row). Only a payment or boost can become unsettled
  (`setStatus`), so a text's PENDING, if one ever came, would not take its
  Retry away. The CLI still prints what the server said.
- The app: "Boost of 21 sats not settled" under the message, or "Payment
  not settled" on a payment row, in secondary text with no action; "not
  settled" beside it in who-boosted. The boost still counts in the chip,
  as the official apps count it. The help text says the balance shows
  whether the sats moved.
- A row already stuck before this fix stays pending: its live `PENDING`
  has passed and `getTags` cannot tell it from a held async pay.

### Boost once (Tom, 2026-10-07)

- The message menu had both "Boost 21 sats" and "Boost…". Only the one-tap
  item stays (B); the amount is the Account's "Boost amount". The custom
  panel (`BoostPanel`) had no other way in and is deleted, with
  `AppModel.boost(_:tipMsat:)`, `boostCost` and `AmountLine`. The engine's
  `boost(messageID:amountMsat:confirmedMsat:)` stays for the CLI
  (`boost <id> <sats>`).
- No Boost on a message you have already boosted: the hover bar's bolt and
  the menu item go once you have a boost on it, pending, unsettled,
  delivered or failed (`ChatRow.canBoost`). A failed one offers Retry and
  Discard under the message instead (`/code-review`: offering both Boost
  and Retry invited paying twice); discarding it brings Boost back. A boost
  stuck pending from before this fix hides Boost on its message for good.
- The engine holds the rule too (`/simplify`): `quickBoost` ignores a tap
  (returns nil) when we have any boost on the message
  (`BoostSummary.hasOwnBoost` in the app, `Storage.lastOwnBoost` in the
  engine). That replaces the one-second double-click gap
  (`quickBoostGap`). The CLI says "already boosted"; `boost <id> <sats>`
  with an amount is unchanged.
- The official apps do offer Boost again (`isBoostActionAllowed` on Mac and
  iOS checks only incoming, not an invoice, payment or call link, with a
  uuid; `boostedByMe` only tints the icon) and sum repeated boosts in the
  chip. Hiding it in Peel changes nothing for colleagues: their apps and
  Peel's summary still show any number of boosts.

### Verified (local stack, 2026-10-07)

Broker 2789, mixer 8089 (`NO_LIGHTNING`, `TESTING_ONLY_ADD_TO_SENDER`),
tribes 8889; profiles `bs-alice`, `bs-bob`, `bs-carol`, deleted afterwards.

| Check | Result |
|---|---|
| Mixer `TIMEOUT_MS=1`, one-tap DM boost, Bob online, before the fix | `send PENDING`, row `PENDING` after reconnect too; Bob shows the boost, his balance unchanged |
| Same after the fix | Row `UNSETTLED` at once, still after a reconnect; Bob shows the boost, his balance unchanged (13 sats) |
| Same, DM payment and tribe boost, first version (live `PENDING` as delivered) | Both marked at once |
| Default window: one-tap DM boost, Bob online | `COMPLETE` live |
| Default window: boost with an amount (`boost <id> 1`), Bob online | `COMPLETE` live |
| Default window: one-tap DM boost, Bob offline, Alice disconnects | `PENDING` (held, no live status); Bob comes online and is paid; Alice's next connect `COMPLETE` by `getTags` |
| DM payment Bob online / offline | `COMPLETE` live / on Alice's next connect |
| Tribe boost (Alice on Bob's post), one-tap | `COMPLETE` live; Bob +1 sat |

Not checked by hand: the app's hover bar, menu and "not settled" lines
(this session cannot click in the app); production.

### Open

- A recipient's Peel counts a boost or payment as received (`msat` from
  the HTLC, `.moneyReceived`) before it settles, so in the missed-window
  case it shows sats that never arrived, as the official apps do.
- The mixer: a payment that misses the settle window is neither paid
  later nor failed (`pay_now` redeems the async pay first; "FIXME restore
  if send failed").

### Reviews

- **`/code-review high`.** Applied: a live PENDING is `UNSETTLED`, not
  delivered (no bolt for sats that may not have moved; a later FAILED can
  still land and offer Retry); Boost is hidden while a failed boost offers
  Retry; `.sendStatus` carries what the server said again; the records'
  final statuses are an explicit list; the `quickBoost` doc. Not applied:
  "fix it in the mixer" (outside this repo; recorded under Open).
- **`/simplify`.** Applied: the boost-once rule in the engine
  (`quickBoost`) as well as the view; `UNSETTLED` only for payments;
  `boostTotalMsat` private (its only caller is the engine now); simpler
  status appends. Not applied: sharing the test fixture helpers of
  `PaymentTests` (private to that struct), one caption view for "waiting"
  and "not settled" (two short views), a single status label on
  `BoostSummary.Boost`.

- **`/security-review`.** Nothing found. Checked: the new SQL clause uses
  only constants and bound parameters; an unsettled payment cannot be
  retried, discarded or synthesised failed (only a real FAILED moves it);
  only our mixer's status for our own tags reaches `setStatus`; the records
  never mark money moved on a PENDING; one-tap is stricter than before.

## Money architecture (2026-10-07, branch `phase4/payments`)

One money core, in layers; each layer reuses the ones under it and none has
a second copy of a shared piece.

| Layer | What | Where |
|---|---|---|
| 0. Balance | The mixer's ledger: `new_balance` from any core call, stored as `Setting.balanceMsat`, shown in the sidebar header only | `Engine.commit`, `Storage.balanceMsat` |
| 1. Keysend messages | Sats riding a chat message: direct payments (5), boosts (29), tribe prices, purchases of paid attachments (7) and their refunds (9) | `Engine.deliver` |
| 2. Payment history | The server's ledger (`fetch_payments`), paged and stored, joined to messages and invoices by payment hash | `PaymentRecord`, `Storage.paymentHistory` (`PaymentHistory.swift`) |
| 3. Invoices | Lightning: invoices made here (Receive, requests in a chat) and paid from here (Pay an invoice, a request's Pay) | `Invoice`, `InvoiceRecord`, `Engine.createInvoice` / `requestPayment` / `payInvoice` / `payRequest` |

The shared pieces, each in one place:

- **Amounts are msat end to end.** Sats only at the edges (CLI arguments,
  `Sats.msat`, the views' formatting). Every amount shown or paid for an
  invoice comes from the invoice (`parse_invoice`), never from a message's
  JSON; a received payment's amount is what arrived (`msat`, capped at what
  the server says arrived since 2026-10-09), never what was declared.
- **One confirmation rule:** `Engine.checkPayment` (balance, then the
  threshold, 100 sats by default, `confirmedMsat` naming the exact amount
  confirmed). Boosts, payments, retries, invoices, requests and purchases all
  go through it; the app's `PayButton` + `PaymentAttempt` arm on the
  engine's `needsConfirmation` and confirm only that amount. Invoices add a
  fee reserve to the balance check (`Engine.feeReserveMsat`: 1%, at least 10
  sats).
- **One in-flight tracker and status model:** a send's tag, `PENDING` until
  the server says `COMPLETE` or `FAILED`, statuses only moving forward
  (`Storage.setStatus`, now for messages and invoices we pay alike), and the
  `get_tags` check on connect (`checkPendingSends`, now including invoice
  payments, purchases and refunds; `MessageType.moneySends`). Anything that
  may have paid is never sent again until the server says it failed. An
  invoice payment's row is written with the core state before publishing
  and refused at the database if one is pending or paid
  (`Storage.insert(_:InvoiceRecord)`), plus an in-memory guard against a
  double click (`payingInvoices`).
- **One history:** the Payments screen, `peel history` and the request and
  purchase states all read the same tables (`payment`, `invoice`,
  `paymentPing`, `message`).

## Payments screen, invoices, requests and paid attachments (2026-10-07, branch `phase4/payments`)

Plan: `04-payments-screen-plan.md`. Boards: canvas "Peel layout directions",
row "Payments" (P1–P5).

### What the official apps and the core do (checked 2026-10-07)

- **History** (`TransactionsListViewController`): `fetch_payments(since:
  oldest ts − 1, limit: 50, reverse: true)`. Rows carry `amt_msat`, `ts` (ms),
  `rhash`, `remote`, `msg_idx` (incoming only: that is the only direction
  marker) and `error`. They are joined to messages by message index, then
  payment hash. `payments_total` counts the whole server, not the account.
- **Receive** in the official apps is `request_invoice` (the server's CLN
  makes it); its payment arrives only as a new balance. Peel used
  `make_invoice` at first; since 2026-10-08 it uses `request_invoice` too
  (see "Receive and requests made by the server"). `make_invoice` with 0 msat writes an
  invoice for 0, not one the payer fills in, and paying 0 sends nothing, so
  Receive requires an amount. Expiry was the core's fixed hour
  (`make_invoice`); the server's invoices last CLN's default week.
- **Paying:** `parse_invoice` takes the bare BOLT11 (the binding's argument
  is misnamed `invoiceJson`) and returns `value` (msat), `payee`,
  `payment_hash`, `description`, `expiry` (unix seconds) and `hop_hints`.
  The official app pays with `pay_invoice(overpay = the amount)`, falling back
  to `pay` (the server pays; no route needed here) when it has no route and
  the invoice has no hint. The outcome is a `sent_status` with the tag; no
  fee is reported. A send the asynchronous way also sends a 1-sat ping
  keysend: Peel records it (`paymentPing`) and shows it inside its payment.
- **Requests in chat:** type 2, `{"content": memo, "invoice": bolt11}`, no
  amount field. Paying a contact's request is `pay_contact_invoice`, which
  rides a type 3 (`{"paymentHash", "amount"}`) on the payment and a copy to
  self; it requires the invoice's payee to be a contact. The official apps
  make requests with `request_invoice`, whose payee is the server's node, so
  `pay_contact_invoice` cannot pay them: Peel pays such a request as a plain
  invoice and says on the card whom it pays.
- **Paid attachments** (Mac and iOS v2 alike): the price is `amt` in the media
  token's meta; nothing about the token is checked before paying. Before
  buying, the receiver sees a bundled, generic blurred placeholder (no
  preview exists in the message) with a lock and "Pay to Unlock", a bar
  with "N SAT" and "PAY"; iOS asks "Confirm Purchase", the Mac app does not
  ask. Buying sends type 7 `{"content":"", "mediaToken": token, "replyUuid":
  uuid}` with the price. The seller's app answers when it processes the
  purchase (so the seller must come online): if the sats cover the price
  less 3, type 8 with `mediaKey` and the same token; else type 9 refunding
  what came (Peel leaves an underpaid purchase unanswered; see Reviews). After type 8 the attachment downloads with the original token
  and the type 8 key. Labels: "Processing payment...", "Purchase
  Succeeded", "Purchase Denied" (the sender's own chip says "Purchase
  Succeeded" for a denial too, a bug in both apps). In a tribe the key stays
  in the message ("tribe admin will custodial it") and the seller's app does
  not answer. Paid text (`sphinx/text`) drops `content` and reads "Pay to
  unlock Message".

### Built

- **Engine:** `fetchPaymentHistory(before:)` (50 a page, newest first,
  stored), `createInvoice`, `requestPayment(from:amountMsat:memo:)`,
  `payInvoice(_:confirmedMsat:)`, `payRequest(messageID:confirmedMsat:)`,
  `buyAttachment(messageID:confirmedMsat:)`, `sendAttachment(priceSats:)` and
  the seller's automatic answer to a purchase (`answerPurchase`). Paying an
  invoice refuses: no amount, expired, this account's own (made here, or
  payee is us), pending, paid (here or, by the history, from another
  device), over the balance less the fee reserve, over the threshold
  unless confirmed. A request's amount and hash are read from its invoice
  on arrival; someone's type 3 counts only with the core's payment hash and
  at least the invoice's amount. An invoice made here turns paid on the
  server's settle answer (`settled_status` `COMPLETE`) only if what arrived
  covers it, else it is underpaid (the core settles any amount). Purchases are
  answered once, with the key; an underpaid one is left unanswered, never
  refunded automatically.
- **Storage (v13):** tables `payment` (the server's history), `invoice` (made
  or paid here), `paymentPing`; `Timeline.requests` and `Timeline.purchases`
  / `ChatThread.purchases`; `paymentHistory(limit:)` joins it all and adds
  ours the server has no row for yet (pending, failed, just made).
- **CLI:** `history [pages]`, `invoice`, `decode`, `pay-invoice`, `request`,
  `pay-request`, `buy`, `send-file --price`; `messages` prints request and
  purchase states.
- **App:** the Payments screen (`PaymentsView.swift`): one list grouped
  Today / Yesterday / Earlier this week / Earlier, "Amounts in sats" in the
  header, received "+500" in green, sent "−2,000" in the text colour (Tom's
  banking-app rule; a plain "2,000" until 2026-10-08), pending grey with
  "Pending", failed struck through with "Failed"; older pages load at the
  end of the list; the newest page again when the balance moves or the connection returns. Receive and Pay an invoice in the
  header; a payment's detail, Receive and Pay in a 360 pt pane on the right
  (Escape closes). Receive: amount (required, with why), memo, QR, Copy
  invoice, Copy QR image, a countdown bar, then Paid with what arrived and
  New invoice. Pay: paste or drop on the window; amount, who (a contact's
  name when the payee is one), memo, expiry; amber notes (never red) for no
  amount, expired, own, already paid (with Show that payment), pending, too
  little balance (with Receive sats); then Paying, then Paid with the fee
  once the history has it. In a DM the composer's bolt is "Send or request
  sats" (Send | Request); a request is a card with who asked, the amount,
  the memo and Pay (or Paid, Paying, Expired). Paid attachments: someone
  else's shows a soft veil (never the picture: nothing is fetched or
  decrypted before buying), a lock, "Paid photo/video/file", the price and
  Unlock; then "Unlocking: waiting for Bob to send the key", then the
  normal image or file; a refusal says the sats came back. Ours shows "For
  sale at 200 sats · bought once". The tray of files waiting in a composer
  has a price field ("Free" when empty). Every money button follows Tom's
  labels: one line, idle "Pay" / "Unlock" / "Send"; armed orange with
  "Click again to confirm" under it; the amount named on the button only
  where it does not already stand beside it (Tom, 2026-10-08: never
  "Unlock for 150 sats" next to "150 sats"). Copies use the shared
  `CopyButton`.

### Verified (local stack, 2026-10-07)

Broker, mixer (`NO_LIGHTNING`) and tribes on their own ports; profiles
`py-bank`, `py-alice`, `py-bob`, `py-carol`, contacts by key exchange, funded
with the mixer's own `TESTING_ONLY_ADD_TO_SENDER` (two accounts paying each
other their whole balance through Peel's normal checks), then the mixer
restarted without it for real accounting. Nothing in Peel was weakened to
fund them.

- History with DM payments both ways, a tribe boost, keysends (key-exchange
  sats), invoices paid and received, the 1-sat pings folded into their
  payment, a pending payment; paging with `history 2`.
- Receive → paid live: Bob made a 500-sat invoice, Alice paid it (first
  refused over the threshold, then confirmed); Bob's engine settled it and
  emitted `invoicePaid`; balances moved by 500 (+ a 1-sat ping on Alice's
  side). In the app: P3 waiting with QR and countdown, P3b paid with the
  row at the top of the list.
- Paying while the payee is offline: Alice's payment stayed pending; a second
  try was refused ("still on its way"); Bob came online, the mixer redeemed
  the async payment, both sides turned complete.
- Refusals: already paid, own invoice, expired (BOLT 11's test vector), over
  balance (Carol, 10 sats, for a 50-sat invoice).
- Request in chat: Alice asked Bob for 300; Bob paid it (`pay_contact_invoice`
  with the type 3); Alice's request flipped to Paid on settle, Bob's on the
  server's COMPLETE; a second pay was refused.
- Paid attachments: Bob sent a 200-sat image (key withheld); Alice's
  download was refused ("paid; opens once bought"); her first buy asked to
  confirm, the second paid; Bob's engine answered with the key; the
  download decrypted byte-identical to the original. In the app: locked,
  armed ("Click again to confirm"), unlocking, and
  unlocked live when Bob came online and answered from history; Bob's view
  shows "For sale … bought once".

### Not tested locally, and why

- **Invoices made by the server and paying over Lightning**: the local mixer
  runs `NO_LIGHTNING` (no CLN, LND or bitcoind here), so `request_invoice`
  fails ("CLN was skipped"), the `pay` fallback and real routing fees cannot
  run, and the fee shown after paying was only ever 0. Needed: a regtest
  bitcoind + CLN behind the mixer (the swarm setup in
  `sphinx/wasm/test/swarm`).
- Receiving a refund (type 9): Peel never sends one (see Reviews); a
  refund from an official app shows as "turned down", untested here.
- Paid attachments in tribes (the tribes server's custody of the key).
- The composer's price field: built, not clicked (no input automation in
  this session); the CLI's `send-file --price` was used.

### Open questions for Tom

- The official apps' requests use `request_invoice`, so `pay_contact_invoice`
  cannot pay them; Peel pays those as plain invoices and the card says, in
  amber, that they pay the server's node. Since 2026-10-08 Peel's own
  requests are made the same way, so every request now carries that note.
  Keep it, or word it as the normal case (the node of the requester's
  server)? Also: the official apps cannot pay any `request_invoice`
  request from the chat card (see below).
- Keysends from before this branch include old 1-sat pings with nothing to
  tie them to; they show as "Keysend".

### Reviews (2026-10-07/08)

`/code-review high`, applied:

- A seller gave a cheap paid attachment's key away (3-sat allowance against a
  1–3 sat price, and a purchase with no sats): the key now goes only when
  sats came and they cover the price less `min(3 sats, price / 10)`.
- Refunds for an underpaid purchase are no longer sent automatically: two of
  the account's devices online at once would each refund it. The seller
  sees a note instead (Peel differs from the official apps here).
- A refused paid file went back to the composer without its price and could
  then be sent free; the price now goes back with it, and an out-of-range
  price is refused in words.
- A payment's own hash could be recorded as its ping; filtered.
- Overflow when summing a huge pasted invoice with the fee reserve.
- History paging could leave a gap after a busy spell:
  `refreshPaymentHistory` now fetches back until it meets what is stored.
- Keys shortened the same way everywhere (6…4).

Not applied: buying a paid attachment in a tribe pays the price alone, not
price plus the tribe's per-message price (the official apps do the same;
tribes are untested here, see below).

`/simplify` (four angles), applied: one decoder for message fields (the two
single-field decoders folded into `BodyFields`), `AttachmentFields.ownKey`,
`Engine.invoiceProblem` (the one set of rules for paying an invoice, used by
`pay` and the Pay pane, which no longer copies them), `RunHeader`,
`DetailHeader` + `HeaderButton`, `Message.preview` and the shared
`CopyButton`/`Clipboard` in the panes, an invoice parse cache, dictionary
joins and one boosted-message query in the history, ping sums limited to the
page, indexes for the history and purchases, purchase state read once per
chat. Not applied (bigger than this change, noted for later): one send table
for messages and invoices; a per-type policy for resend and money; a
`mediaToken` column; one annotations map for timeline and thread (requests
show their state in a chat, not yet in a thread panel).

`/security-review`, applied: an invoice made here was marked Paid whatever
arrived (the core settles any amount for a known hash, and the server
cannot know the amount of an invoice made on the device), so 1 sat could
show a 50,000-sat request as Paid. It is now `UNDERPAID` ("Partly paid: 1
sat came; this invoice cannot take the rest") unless what arrived covers it.

### After #23 and #26 (2026-10-08)

Rebased onto main with read markers (v12) and boost status. An invoice we
pay follows `Delivery.unsettled`: the mixer's live PENDING makes it
`UNSETTLED` (never paid again, out of the connect-time check, still able
to settle or fail); purchases and refunds take unsettled too
(`moneySends`). v13 follows v12. Money buttons are one line and name the
amount only where it does not already stand beside them. Not applied from
the review: `invoiceProblem` and the attachment price are worked out in
the view body (cheap reads, but on the main thread).

### Tribe fees in the history (2026-10-08)

Tom's Payments screen listed many outgoing 3-, 1- and 21-sat rows as
"Keysend, sent, not tied to a chat". What was found:

- **Tribe message fees.** Every message posted to a tribe pays the tribe
  (`send` with `is_tribe`, at least 3 sats; the Mac app the same), and the
  mixer records it under the payment hash in the send's topic, which
  `send` returns in `msgs[0]` and Peel keeps on its row. The history only
  joined payment, boost, purchase and invoice messages, so a text or
  attachment's fee fell through to "Keysend". Now any message of ours in
  a tribe joins by hash and shows as a **message fee** ("Message fee in
  #hive"; "Joined #hive" for a join), its detail quoting the message. Only
  money messages are listed without a server row, so free messages never
  show.
- **No hash to join by.** The tribe forwards our own message back to us
  without sats, so a post or boost from another device (or from Peel
  before #16 kept the hash) has none. A tribe boost like that showed twice:
  once as the message (listed as ours with no row) and once as the
  server's 21-sat row. Outgoing rows with nothing by hash are now paired
  with our hashless tribe message within 3 s, only when each is the other's
  one candidate and any amount we know agrees; otherwise the row stays a
  keysend.
- **Old pings.** A 1-sat row beside a payment to a contact sent before #27
  recorded pings (`paymentPing`) is counted as that payment's ping when it
  is the one such row within 3 s of the one such payment.
- A pending payment, boost or purchase to a contact now says "Waiting for
  <name> to come online" (sats to a contact wait for their app), not
  "not confirmed by the server yet".

Still keysends: fees and pings that are ambiguous by time, and rows whose
message was never stored here.

`/code-review high`, applied: a hashless post pairs only with a row of the
tribe's price per message (a boost: what it declared, plus at most the
price), so an unrelated payment is never called a fee; a failed payment
takes no ping; time pairing is for outgoing rows only; a private tribe's
join request reads "Asked to join"; the "goes to a contact" rule lives once
in `PaymentItem.isToContact`. Not applied: pairing is judged per page, so
a pair at a page edge can change as more pages load (rare, and only
between "keysend" and the right label); a payment request posted in a
tribe keeps its invoice's hash, so its fee stays a keysend (Peel requests
in DMs); storing the inferred pairs instead of working them out on each
read (a wrong guess would then be permanent).

`/simplify` (four angles), applied: the boost-cost rule reused from
`Engine.boostTotalMsat`; the ping fold sets the one ping price; the detail
pane's quoted message is one block for a boost and a fee; `isToContact` is
a switch. Not applied: dropping the type filter from the hash join (it
would also join other messages that carry a hash, such as requests, and
call them fees); a sweep instead of `uniquePairs`' all-pairs check (the
lists are rows tied to nothing, a handful a page); reading tribe prices in
the candidate join instead of a second key lookup (one small query).

## Receive and requests made by the server (2026-10-08, branch `phase4/request-invoice`)

**Decided (Tom, 2026-10-08):** Receive uses the core's `request_invoice`,
as the official apps do, instead of `make_invoice`. The server's node is
paid, so it works while Peel is closed; the cost is that the payment
arrives only as a balance change, not as a payment to us. Requests in a
chat are made the same way, as the official apps' are.

### What the code does (checked 2026-10-08, against origin)

- **Official apps.** Mac (`SphinOnionManager+InvoicesExtension.createInvoice`)
  and iOS on origin (the local iOS checkout is older and still calls
  `makeInvoice`) call `requestInvoice(amtMsat, description)`, keep a
  callback and a 30 s timer, and take the answer from `rr.invoice`
  (`handleInvoiceGenerated`). Requests in a chat go through the same call
  and then `sendInvoiceMessage` (type 2). Their Receive screen
  (`DisplayInvoiceVC`) shows Paid only on `.sentInvoiceSettled`, which
  `processInvoicePaid` posts for a settle (`rr.settleTopic`) of a message
  carrying a payment hash: a payment to an invoice made on the device. For
  a server-made invoice nothing posts it: the official screen never turns
  to Paid; only the balance moves.
- **Core** (`sphinx/src/bindings/invoice.rs`, same at the commit
  `sphinx-rs` pins): `request_invoice` is a publish to
  `{root}/{pk}/0/req/{device}/invoice` with `{amt_msat, description}` and
  no state. The answer comes on `res/{device}/invoice`
  (`bindings/handler.rs`: `InvoiceRes` → `rr.invoice`); it names no
  request, and on failure the mixer sends nothing back (`mqtt.rs` only
  logs the error), so a client can only time out.
- **Mixer.** `handler.rs` `INVOICE`: CLN `invoice` with label
  `user:{scid}:{ts}` (CLN's default expiry, a week). Settlement:
  - paid over Lightning: `ln.rs` `process_invoice` (`waitanyinvoice`) →
    `incr_balance(scid)`, `add_incoming_pmt(scid, amount_received_msat,
    rhash, remote: true, msg_idx: 0)`, `notify_balance_change`;
  - paid from the same server (`pay` topic, payee = its own node):
    `handler.rs` `pay_local_invoice` → `shift_balance`, `mark_paid_rhash`,
    `add_outgoing_pmt` for the payer, `add_incoming_pmt(recipient, amt,
    rhash, false, 0)`, balance notices to both.
  The balance notice carries only the new balance. No tag, status or
  `settled_status` reaches the account that made the invoice.
- **So the signal is the history row**: `fetch_payments` gives an incoming
  row (`msg_idx` set, here 0) with `rhash` = the invoice's payment hash
  and the amount that arrived. It is server-side, so it is there however
  long Peel was closed, and it is matched by hash, never by a balance
  delta.
- **Paying one.** `pay_contact_invoice` needs the invoice's payee to be a
  contact (`state.get_contact(payee)`, "no invoice contact pubkey found"),
  so it can never pay a server-made invoice. An onion payment
  (`pay_invoice`) to the server's own node is one hop whose last layer is a
  receive, which the mixer refuses (`unwrap_onion`: "expected a forwarded
  onion"); the `pay` topic is what pays it (`pay_local_invoice`). The Mac
  app gets there by falling back to `pay` 60 s after a failed onion.
- **The official apps cannot pay a server-made request from the chat
  card**: their `finalizePayInvoiceMessage` calls only
  `payContactInvoice`, which throws, and the error is swallowed. That holds
  for their own requests as much as Peel's. They can pay one by pasting it
  into Pay invoice (`payInvoice`, falling back to `pay`), and their card
  never shows it paid (no type 3 comes with a plain payment).

### Built

- **Engine:** `createInvoice` (now async) and `requestPayment` ask the
  server (`serverInvoice`): one request at a time (the answer names none),
  30 s for the answer (`Failure.noInvoiceFromServer`), and the answer is
  checked (`checkServerInvoice`): payee is our server's node (from our
  contact info), exactly the amount and memo asked, not expired. A late
  answer to an earlier, different request is dropped and the wait goes
  on; an identical one is ours all the same. The record is stored OPEN as
  before; no migration (v13 tables unchanged).
- **Paid:** `commit` matches every history page against open invoices made
  here (`Storage.openInvoices(among:)`, `Engine.invoicePayments`: incoming,
  not failed, one row per hash) and feeds them through the existing
  `settling` / `settled` writes, so the amount rule (COMPLETE only if what
  arrived covers it, else UNDERPAID) and `.invoicePaid` are the same as
  before. `checkOpenInvoices` fetches the history (`refreshPaymentHistory`,
  back to what is stored) on coming online and whenever the balance goes
  up, only while an open invoice made here had not expired when the
  history was last brought up to date this session
  (`Storage.hasInvoicesAwaitingHistory(checkedAt:)`, 10 min margin). One
  check at a time; a trigger during one runs it once more after. A page
  fetch now waits for the one on its way instead of failing, so the app's
  paging and this check never refuse each other. History rows with
  `msg_idx` 0 (the server's invoices) name no message
  (`PaymentRecord.decode`), so they join their invoice by hash.
- **App:** expiries more than today away show the date ("15 Oct, 14:22"),
  the countdown only in its last hour; Receive says Peel may be closed.
- **Paying:** an invoice whose payee is our own server's node is paid with
  `pay` directly (before, `pay_invoice` built a one-hop onion the mixer
  refuses, and the `pay` fallback only ran when building the route threw).
  This covers our server's other users' requests, Peel's and the official
  apps' alike. Others are unchanged.
- **Removed:** `make_invoice` (nothing else used it). The settle path for
  invoices made on the device stays: it is generic (`settle_topic`), and
  open `make_invoice` invoices from before may still be paid within their
  hour.

### Not verified

Nothing here ran against a server: the local mixer runs `NO_LIGHTNING`, so
`request_invoice` gets no answer there (the mixer logs "CLN was skipped").
Unit-tested (`swift test`: all pass but main's known
`threadsListHasDirectMessagesWithLatestAndParticipants`, fixed in #35, and
the IPv6 known issue): the answer check, the history match, the storage
writes it drives and when the history is fetched. Unverified until Tom's run on the
throwaway profile: that production answers on `res/{device}/invoice` within
30 s; that the payee is the node in our contact info; that the history row
arrives with `msg_idx` 0 (for both paths); that `pay` settles a same-server
invoice and a server-made invoice from another server pays through
`pay_invoice` or its fallback; and how the official apps show Peel's
requests.

### Reviews

`/code-review high`, applied: a late, different answer is dropped and the
wait goes on; history checks coalesce into one background task (cancelled on
disconnect), run only when the balance goes up or on coming online, and only
while an open invoice was unexpired at the last full fetch; a page fetch
waits for the one on its way instead of failing the app's paging; `msg_idx`
0 names no message; expiries a week out show their date. Not applied: our
own server-made invoice pasted from another device (or after a restore) is
not caught as ours before paying, since its payee is the server's node; the
mixer refuses it ("cannot pay your own invoice"), so nothing moves.

`/simplify`, applied: one rule when busy (an invoice request now waits, as a
history page does); one parser of `pubkey_lsp_scid` in the engine
(`contactInfoParts`, also used by `addContact`; `AppModel.myPubkey` left
alone, the file is being edited elsewhere); the countdown reads the expiry
directly. Not applied: caching the balance to skip a settings read per
balance notice (small, and a second copy could drift); one in-flight task
shared by concurrent history refreshes (they now queue instead); a general
primitive for uncorrelated server answers (the real fix is a request id in
the core's answers); folding the own-server `pay` branch into a fallback on
a server-reported onion refusal.

`/security-review`: nothing at 8/10 or above. Checked: a contact cannot
fill `rr.invoice` or forge an incoming history row for our hash; checks and
confirmation run before the own-server `pay`; queries are bound; no secrets
in the new errors.

## Whole sats everywhere (2026-10-08, branch `refactor/sats-format`)

Tom's rule (2026-10-08): amounts show as whole sats, never decimals. Refactor
plan row 5 of `docs/reviews/2026-10-08-architecture.md`.

- One formatter in PeelCore, `Sats` (`Sats.swift`): `format(msat:)` ("1 sat",
  "21 sats", "1,210 sats"), `number(msat:)` for chips and lists, and
  `format(msat:of:)` for "1 of 2 sats" (an underpaid invoice, a short
  attachment purchase), which falls back to msat for both where dropping the
  rest of a sat would hide a shortfall. Negatives read as 0. `Sats.msat` and
  `Sats.parse` (was the free `amount(_:unit:of:)`) sit beside it.
- Rounding is the official apps': the rest of a sat dropped (`amount / 1000`
  in sphinx-mac-v2 `UserData.getBalanceSats`, `SphinxOnionManager+ChatExtension`
  message amounts, `PaymentTransaction`, the tribe price labels; same in
  sphinx-ios-v2). So 1,999 msat is "1 sat" and anything under a sat "0 sats".
- Used by the app (the `Formatting.sats` overloads and `satsNumber` are gone),
  `Engine.Failure.needsConfirmation`, the attachment purchase notice, the
  underpaid note in `PaymentHistory`, and every amount the CLI prints. The
  payment detail still shows the exact msat beside the sats; the CLI keeps
  "(N msat)" where it printed it.
- Display only: nothing sent, charged or confirmed changed. The tribe settings
  form still edits prices as typed decimals (it is an input, and must
  round-trip exactly).
- Reviews: `/code-review` flagged that truncation makes armed Pay buttons,
  sub-sat routing fees and attachment prices read low ("0 sats" next to
  "None"), and the insufficient-balance sum can look enough; these follow the
  rule and the official apps, left as is. Applied: the invoice row's partly
  paid footer uses `format(msat:of:)`. `/simplify`: one truncation helper;
  skipped renaming `Sats.parse` (also parses hours) and merging it with
  `Sats.msat`. `/security-review`: no findings.

## Sats received (2026-10-08, branch `feat/money-received`)

Tom: when sats arrive (an invoice paid while Peel was closed or open, a
payment or boost to him) nothing shows it; the balance and the Payments
row change silently. Done means: the header balance counts up, the
Payments row shows what is unseen and lights the new rows once, one
system notification per arrival, several payments at once summed into one,
for every case below.

### Which events fire (checked on the local stack, and in the code)

| Case | Events, in order | Verified |
|---|---|---|
| Direct payment, Peel open | `.message` (type 5), `.moneyReceived`, then `.balance` about 16 ms later (the mixer's `notify_balance_change`) | local, CLI `listen` and the app |
| Boost on our message, Peel open | `.message` (type 29), `.moneyReceived`, `.balance` | local |
| Payments while Peel was closed | On connect: `.balance` (unchanged: the async pays are not settled yet), then each held async pay arrives live, each `.message`, `.moneyReceived`, `.balance` up, all within about 80 ms | local, three payments |
| A message payment missed entirely (history page) | `.message(_, .history)`, `.moneyReceived` (past the read marker only) | code: same `received` rule |
| `request_invoice` paid while open | `.balance` up → `checkInvoices` fetches the history → the row with the invoice's hash → `.invoicePaid`; no `.moneyReceived` (no message) | code only: the local mixer runs `NO_LIGHTNING` |
| `request_invoice` paid while closed | On connect `.balance` (raised), then the history check (on coming online, and the rise) → `.invoicePaid` | code only, as above |
| A request paid with `pay_contact_invoice` (an old `make_invoice` one) | `.moneyReceived` for the type 3 and `.invoicePaid` on settle, same payment hash | code; the engine sends only `.moneyReceived` for it |
| Restore | Nothing: `.moneyReceived` is no longer sent for a restore (`Engine.commit`, one line); a restore has no open invoices | code |

### Built

- **Engine:** `.moneyReceived` not sent in a restore. `.invoicePaid` now
  carries the stored `InvoiceRecord` (was the hash), is sent only for an
  invoice this commit moved from OPEN (a repeated settle is not news), and
  also for an underpaid one, with what arrived in `paidMsat`; not for a
  hash this commit already told as `.moneyReceived` (a type 3), so each
  payment is one event.
- **`MoneyArrivals` (app):** one `Receipt` per payment event; payments within 0.7 s
  (at most 3 s from the first) are one arrival. The header's balance
  (`shownMsat`) holds a rise back 1.5 s so the payment and its balance,
  whichever comes first, roll as one; a balance up to 5 s after an
  arrival rolls at once. A paid invoice told more than 1.5 s after its
  balance glows, badges and notifies without a roll. Anything else (first
  balance, restore, falls, keysends with no message) just changes.
  VoiceOver hears "Received +350 sats · 3 payments", not while locked.
- **Header:** `BalanceLabel`, a `numericText` roll in tabular digits with
  the final width reserved from the start; the connection bolt glows green
  for a moment (`receivedGlow`). No pill (Tom's feedback on the first
  build: the pill wrapped the balance and moved it).
- **Payments row:** "+350" in the badge slot (`ReceivedBadge`, the green of
  received amounts, `Theme.confirmed`; no new colour token), popping in with
  scale and fade, summing what follows, cleared once Payments is on screen
  with the window in front, which also takes away the money notifications
  and lights the matching rows (by payment hash or message row; checked
  that history rows' `rhash` equals the message's `paymentHash`).
- **Notifications** (`Notifier.moneyReceived`): one per arrival, title
  "+21 sats" or "+350 sats · 3 payments", body "From MrAlice: lunch",
  "Boost from Bob in #Tribe", "Invoice paid: memo", "Bob paid your
  request" or "From Bob, Carol, and an invoice"; the note only when
  notifications may show text; "Sats received" while locked. A payment or
  boost in a chat notifies only at the chat's "all" level and not for the
  chat open in front of you; a paid invoice (a request in a chat too)
  always notifies when notifications are allowed; nothing while Payments
  is open in front of you. Not held back by the first history of a
  session, since the engine's read-marker rule already keeps what was seen
  quiet. A click opens Payments.
- Reduce Motion: no roll, no pop.

### Verified (local stack, 2026-10-08)

Broker and mixer (`NO_LIGHTNING`, `TESTING_ONLY_ADD_TO_SENDER`) on their
own ports, profiles `mr-alice` and `mr-bob`, funded by paying whole
balances back and forth; the test bundle on `mr-bob`, captured window by
window.

- Live 100-sat payment: balance rolled 875 → 975, no layout shift.
- Three payments while closed, then launch: 2,025 rolled to 2,375 in one
  roll, the bolt glowed, the Payments row popped in "+350"; a fourth live
  payment of 70 rolled it to "+420".
- Not exercised: clicking Payments (no input automation in this session),
  so the row flash was checked only through the hash join in the
  database; the notifications themselves (no view of Notification
  Center); Reduce Motion; invoices (no Lightning locally).

### Reviews

`/code-review high`, applied: `.invoicePaid` once per invoice (only an
invoice this commit moved from OPEN) and carrying its record, so the app
reads nothing back and `Storage.invoice` stays internal; underpaid invoices
count what arrived; the hold compares with the last real balance, not what
is shown, so a send during a held rise is never rolled as received, and the
30 s rise memory and its replay are gone; no VoiceOver amount while locked;
a request paid in a chat names the payer; no notification while Payments is
in front, and the unseen sum clears only once the window is in front; the
glow follows a change of arrival rather than a clock check; one naming
helper in `Notifier`.

`/simplify` (four angles), applied: the engine drops `.invoicePaid` for a
hash its `.moneyReceived` already told, so the app's dedupe set and receipt
key are gone; `AppModel.balanceMsat` feeds `MoneyArrivals` from a `didSet`;
an arrival counter instead of a struct; the Payments row is its own view
(an arrival no longer redraws the whole sidebar) and uses `UnreadBadge`
(now taking text and colours) with `SignedAmount.text` for "+350"; one
pass to light rows, run from the history updates rather than an
`onChange` over the whole list; an ordered de-dup with a set.

Not applied, with why:
- One extra read in `commit` for the hashes it settles
  (`openInvoices(among:)`, none when nothing settles) plus one per paid
  invoice: rare, and a batch would widen the Engine hunk others are editing.
- `Receipt` (kind, amount) and a single `.received` event in PeelCore, and
  the balance carried on it instead of the hold timers: the right home for
  an agent, but the mixer's balance arrives as its own message after the
  payment (16 ms locally), so the engine cannot pair them either without the
  same wait; left for the engine refactor.
- A `destination` key in the notification instead of the `payments` thread
  sentinel: a chat key is a 66-character node key and cannot be
  "payments"; worth doing with the next non-chat notification.
- The restore rule inside `Storage.apply`: the engine guard sits beside the
  same guard for purchases; moving both is a separate change.
- One `shouldNotify` for messages and money: their rules differ (mentions
  pass for messages, not for money).
- Shared flash timing with the message list (`MessageViews.swift`, edited
  elsewhere) and `CopyFeedback.enter` for the badge (Tom asked for no
  cross-fade under Reduce Motion; the badge spring is slower on purpose).
- `invoice.paidMsat ?? amountMsat` without the status check: an underpaid
  invoice with an unknown amount must count 0, not what it asked.

### Money sends in one place (cleanup batch 9, 2026-10-08)

The second review's 2.1, 2.2 and 4.3's ad-hoc errors.
- **One read and one rule.** `Storage.pendingSendTags(textBefore:)` reads
  the three tables that track a send by tag (our messages, invoices we pay,
  invites' funding payments) for `checkPendingSends`. `Storage.applyStatus`
  moves each by one forward-only rule (`statuses(movingTo:)`), invites
  through `inviteStatus`.
- **Q2 (Tom):** an unsettled funding payment is still pending. The invite
  stays sending and is asked about on every connect.
- **Behaviour.** A failed invite the server confirms after all is ready,
  like a failed payment that was delivered. A payment or boost whose
  publish never left with the transport still set is failed and can be sent
  again. Before, `deliver` read `transport == nil` first, so it stayed pending.
- **`commitAndPublish`** commits a send, publishes it and returns
  `.all`, `.none` (`complete`'s `notConnected`: nothing left) or `.unknown`.
  `deliver`, `pay` and `makeInvite` map only `.none` to failed, and say
  `mayHaveGone` (one sentence) for `.unknown`.
- **`Failure.coreReturnedNothing`** replaces "the core made no invite" and
  "the core gave the payment no tag". "The attachment was not stored" is a
  storage refusal, not the core's, and stays.
- **Not changed:** `checkPayment` compares the amount only, while a keysend
  costs the sender 1 sat more (integration finding 1, Tom's call).

## Payments review, first set (2026-10-09, branch `fix/payments-first-set`)

The first fixes from `../reviews/2026-10-09-payments-correctness.md` (its
Status table has each finding). Done means: a received amount is never
more than arrived; what waits for someone offline counts as spent and
says so; key exchange sats and unsettled payments read right in Payments.

- **Real amounts (F3).** `Engine.run` caps every received `msat` at what
  the server says arrived for that message index (`cappedToArrived`), or
  drops it when the server named nothing: the topic's last field for a
  live `msg`/`msgs`/`stream`, the 8 bytes before each payment onion's hash
  on a `batch` page (`StateCodec.paymentAmounts`, `encode_onion`'s
  layout). Everything that decides something was paid reads `msat` after
  that: `answerPurchase` (the key), `isMoneyForMe` and `.moneyReceived`,
  the type 3 a request counts, an invoice settled on the device, received
  rows. Our own messages are left alone.
- **Waiting counts (F1).** `Storage.waitingMsat` sums our PENDING payments,
  boosts and purchases to people (not tribes; unsettled and failed ones
  are done); `spendableMsat` is the balance less that, used by
  `checkPayment` and `invoiceProblem`. The app follows it live
  (`waitingUpdates`): the header "4,996 sats · ◷ 4,000" (`ViewThatFits`
  drops the amount where the header is short), "Amounts in sats · 4,000
  waiting" on Payments, "Balance 4,996 sats · 4,000 waiting" under the pay
  forms and in Account. A DM payment or boost unconfirmed after 30 s reads
  "Payment waiting for Bob to come online", "Waiting" in Payments.
- **Key exchange (F6).** `PaymentItem.Kind.keyExchange`: the other side's
  type 10 or 11 joins its incoming row by hash, our hashless 5-sat or
  3-sat row pairs with it by time (3 s) and amount in `pairedByTime`, and
  the ping folds in as for payments. "Contact added" / "Added you" with the
  name; the detail says why ("Adding Bob cost 5 sats; their app paid 3
  sats back"). `Engine.priceToMeetMsat` is the core's `PRICE_TO_MEET`.
- **Unsettled (F7).** `PaymentItem.Status.unsettled`: "Not settled" in the
  list, the detail and the CLI, as in the chat.
- **Tests.** Unit: the batch reader, the topic and the cap; waiting and
  spendable (pending, unsettled, failed, tribe); key exchange labels and
  pairing; unsettled status. Integration: journey 1
  (`Payments.paymentsToAnOfflineContact`) and journey 3's −3 / +1 and
  labels in `Contacts.keyExchangeByContactInfo`.
- **Not done here.** F10 is not cheap (no tag or hash to track a join);
  F2, F4, F5, F8, F9, F11 and F3's core half wait for later PRs. The
  waiting sum leaves out the key exchange's 5 sats to someone offline
  (no row) and invoices paid the async way by route hint. The adder's
  ping stays a keysend when the contact was offline, since it left long
  before the 5 sats were taken.
- **Reviews.**
  - `/security-review`, applied: the cap ran for every core call with an
    empty map by default; it now runs only on what the server sent
    (`receive`), and caps messages the core calls ours too, since the
    core also calls a message ours when its date decrypts with the
    sender's own shared secret (`dec_ts_matches`), which any sender can
    arrange. That would have let a spoofed "ours" payment settle an
    invoice made on the device at its claimed amount. Checked and sound:
    every received payment reaches Peel through `receive` (the one
    `Sphinxrs.handle`); `msg`, `msgs` and `stream` all use the mixer's
    `stream_res_topic`, so the topic's amount is always there for a
    payment; the page reader checks every length against what is left,
    refuses trailing bytes, never indexes outside a 1430-byte item, and
    gives up at once on lengths larger than the page (fuzzed in a test);
    spendable never goes below 0 and the sum adds only non-negative
    amounts.
  - Not applied: a payment row stuck PENDING from before #26 (a live
    PENDING then stayed pending) now counts as waiting for good, so it
    holds back that many sats in the gate and shows as waiting. It errs on
    refusing, never on paying twice; it goes once F5 can resolve such
    rows. SQLite's `SUM` throws on overflow rather than wrap, so an absurd
    total refuses the payment with a storage error.
  - `/code-review`: no correctness finding beyond the above.
  - `/simplify`, applied: `Engine.priceToMeetMsat` beside
    `keyExchangeMsat` (was in `Storage`); one key exchange type list for
    both queries; `waitingMsat` internal (the app follows `waitingUpdates`).
- **Rendered** on a copy of dev profile `b14c` with rows written into it,
  offline, deleted afterwards: the chat's waiting and not-settled lines,
  the header, Payments with key exchange rows and the two details.

## Idle CPU: a timeline redrawing every frame (2026-10-09, branch `idle/timeline-past-dates`)

Tom's Peel, idle, used 25–30% CPU without a break. Cause: `redrawing(at:)`
(#110) put `.now` before the date, and a date already passed made the
entries go back in time (`[now, past]`). A `TimelineView` on such a
schedule updates on every frame for as long as it is on screen. Three
views use it: a payment waiting for someone to come online
(`WaitingForServer`), a message of yours still pending past its 30
seconds (`MessageRow`), and an invoice past its expiry (`UntilExpiry`,
an old request in a chat). A waiting payment in the open chat was enough.

Fix: a date already passed is left out; the timeline draws once, with
now, which is what it drew before. Nothing else changes.

Measured on a fresh development profile on the local stack (6 accounts,
4 tribes, 7,000 messages, one payment waiting for Dan), the app launched
hidden with its window off the screens, Dan's chat open, 15 minutes idle:

| | before | after |
|---|---|---|
| CPU, 15-minute average | 19.6% (34% in a quieter minute) | 0.08% |
| Energy impact (`top`) | 15–20 | 0.0–0.3 |
| Footprint after 15 minutes | 50 MB, flat | 50 MB, flat |
| `leaks` | 3 leaks, 112 bytes (system) | the same |

`sample` before: the main thread in `NSHostingView.layout` and
`TimelineView.UpdateFilter.updateValue` on every display cycle, with no
view body run.

## Payments review, reconciliation (2026-10-09, branch `fix/payments-reconcile`)

F2, F4 and F8 from `../reviews/2026-10-09-payments-correctness.md`, and
the rows left pending by older builds (Tom's "21 waiting", the first set's
"Not applied"). Done means: a received payment counts once the server's
history has it, and never when it does not; a restored send says what the
server says of it; a request of ours paid before a restore reads Paid; a
pending send the history settled is settled.

- **Premises, checked on the local stack first** (throwaway journey, then
  kept as `Payments.twoDevicesPayAnOfflineContact`). Two devices of Alice's
  each paid offline Bob 3,748 sats (each device's gate knows only its own
  waiting payment, so F1's refusal does not stop the second). When Bob came
  online both messages reached him, each with `msat` 3,748,000; his history
  had one incoming row, by message index; Payments listed both as received.
  The mixer delivers the onion before it moves the sats and `move_funds`
  failed for the second, leaving no history row on either side, only the
  send record (FAILED) under Alice's tag. A device restored afterwards
  stored both of Alice's sends with their tags, no payment hash, no status,
  and Payments read both as sent.
- **One reconciliation** (`Engine.reconcileInBackground`, which
  `checkInvoicesInBackground` became): on coming online, at the end of each
  catch-up or restore, when the balance rises and when someone's payment
  is stored, refresh the history (`refreshPaymentHistory`, the path Payments
  pages from) and page back (at most 10 pages, 30 days) to the oldest send
  of ours still open. Each page is applied by `Storage.reconcile`.
- **Received (F2).** `message.arrived` (v21, with an index on
  `serverIndex`): 1 once an incoming row names the message by index, also
  when the row was stored before the message came; a row with no index
  only a message with none, by hash (every delivered message has an
  index). 0 once a complete refresh reached back past the message's time
  without a row (`markNotArrived`), judged only for rows stored before the
  previous refresh began so each has had a whole refresh for its row to
  land; a row that turns up later still makes it 1. `.moneyReceived`
  (notification, count-up, "+350") now comes with the 1, not the message,
  for what was news when it was stored (`Applied.announceable`, held in
  `MoneyWork.untold`): past the read marker then, so the open chat marking
  it read meanwhile does not silence it; nothing from a launch or a
  restore. The newest history page is asked from past any time, not this
  Mac's clock. "Not received" in the chat, in Payments (struck, its own
  detail words) and nothing in boost totals. Rows from before v21 stay
  unknown until a refresh covers them.
- **Restored sends (F4).** History cannot do it (no hash on the row, no row
  for the failure), so `pendingSendTags` also returns our money rows with no
  status, newest 200, and `checkPendingSends` runs after a restore as well
  as on each connect. Only the server's COMPLETE or FAILED moves them; no
  record fails nothing (they are never in the 30-minute "unrecorded" set).
  A live status already reaches every device by tag (seen on the stack).
- **Retry only from the device that sent it.** A failed payment or boost
  is retryable only with the sats it sent kept (`msat`, set only by a send
  from this Mac); the chat offers no Retry or Discard otherwise. Found by
  `/security-review`: asking the server about every status-less row of
  ours would let a message the core merely takes for ours (the
  `dec_ts_matches` case in the first set) carry the tag of a failed send of
  ours, turn failed, and offer Retry paying the amount its body declares.
- **Requests (F8).** `requests(in:)` takes an incoming history row with the
  request's hash: Paid, or "partly paid" for less.
- **Stale pending sends.** `Storage.reconcile` settles our pending,
  unsettled or failed money rows by payment hash: an outgoing row with no
  error → COMPLETE; only failed rows → FAILED (from pending or unsettled
  only; a success is never undone). Rule for one the server never settles:
  it stays pending (never offered again) but counts as waiting only for
  `Message.waitingLimit`, a week; after that it no longer holds sats back in
  the gate or the header. Erring this way risks at worst a later payment
  failing for want of balance, never a second payment. Tom's row is fixed
  on the first connect after the update by the same refresh, or by the
  week. Not tested against his account; reproduced on the stack by setting
  a sent payment back to PENDING under an unknown tag
  (`Payments.keysendBothWays`).
- **Removed:** `hasInvoicesAwaitingHistory` and `historyCheckedAt`: the
  history is now refreshed on each trigger, one page in the usual case.
- **Tests.** Unit: arrival confirmed by index and told once, not arrived by
  window and stored-through, a late row, Payments and boost totals
  (`PaymentTests`); restored rows asked about by tag; history settling a
  stale pending row, a failed row, a later success, the week rule
  (`MoneyRefusalTests`); a request paid by the history (`InvoiceTests`).
  Integration: journey 1 now checks Bob's received total;
  `twoDevicesPayAnOfflineContact` (F2, and review journey 2 for F4);
  the stale row in `keysendBothWays`.
- **Reviews.** `/code-review`: confirm by the row's message index, not
  only its hash (applied; a hash in a message's JSON is the sender's word on
  a history page). `/simplify`: one history path (`refreshPaymentHistory`)
  for Payments, invoices and the reconciliation; `inHistory` serves both
  directions for requests; the invoice-only predicate went. `/security-review`:
  the Retry rule above (applied); the SQL is bound, `arrived` only ever
  lowers what counts as received, and statuses only move forward as before.
  Not applied: `.moneyReceived` now comes a history round trip after the
  balance, so on a slow server the header's count-up can miss its 1.5 s
  hold and the amount simply appears (`MoneyArrivals`, as for invoices).
- **Left for later.** A paid attachment's key is still sent on the purchase
  message's `msat`, before the history confirms it (the same race could
  hand a key for sats that never came). On a restored device the history's
  outgoing row for a restored payment shows as a separate "Keysend" (the
  restored row has no hash to join on). F1 on a second device: its gate
  does not know the other device's waiting payments. Upstream: the mixer's
  payment key is scid, time and amount (`pmt_key`), so two payments of the
  same amount in the same millisecond share one row. F5, F9, F10, F11 and
  F3's core half as before.
- **Independent review** (merge after fixes; nothing pays twice, the week
  and Retry rules hold), applied: F-A the open chat's payments were never
  told (announceability decided at store time); F-B the newest page asked
  from this Mac's clock; F-C a table scan per history row (index, the OR
  split) and a reconcile per restore page; F-D a hash-only row vouching for
  any message with that hash (now only one with no index); F-F a message
  stored after its row was fetched never confirmed. Left: the paid
  attachment's key and the mixer's key collision, above.

- **The two-device journey reaches Not received** (2026-10-10, tests
  only). The independent review found `twoDevicesPayAnOfflineContact`
  passing on one message at Bob, which leaves F2 unchecked. The mixer
  fails the second send one of two ways: refused for the balance before
  it stores the onion (it never reaches Bob; Alice's history keeps the
  refusal), or delivered, settled by Bob, and then not paid. The journey
  now waits for one of the two before counting Bob's messages, tries the
  setup up to five times for two, then asserts `[arrived true, false]`,
  "Not received" on the second and Payments counting one; five tries
  with one message each is a known issue (`withKnownIssue`), not a pass.
  On the local stack about 6 of 23 tries got both messages (6 of 8 runs
  reached Not received, 2 ended in the known issue).

## Payments review, waiting words and the async pay (2026-10-10, branch `payments-f5-f9-f11`)

F5 (the words only), F9 and F11 from
`../reviews/2026-10-09-payments-correctness.md`. Done means: a payment to
someone offline says it waits, may pay much later and cannot be
cancelled; the ping goes only once the server holds the async pay; the
small edges that need no decision are closed.

- **Premises, checked in the code first.** F5: `recordedStatuses` never
  fails a send the server records as PENDING, and the mixer's ASYNCPAY
  table has no expiry and no cancel (`mixer/src/db/asyncpay.rs`). F9: the
  core puts the async pay's tag on the result's msgs, the mixer answers
  ASYNC_PAY with that tag on `res/<device>/asyncpay` (nothing on error),
  and Peel published the async pay, ping and self copy back to back,
  ignoring `asyncpayTag`; the TypeScript client and the Mac app wait for
  the tag or 10 s. F11: invites live only in the local table; invoices
  were reconciled only when the balance rose; on another device our own
  server-made request has no invoice record and the payee is the server.
- **F5.** The chat row: "Payment waiting for Bob to come online · can't
  be cancelled from here"; its help and Payments' detail: "It should pay
  when Bob next opens Sphinx, however long that takes. It can't be
  cancelled from here", one owner (`WaitingForServer.waitsForPerson`).
  Hedged on purpose: a ping that never left wakes nothing, and a send the
  server never recorded fails later. The help adds that for 7 days
  (`Message.waitingLimit`) it is kept out of what can be spent, and after
  that may still go through if the balance covers it. No cancel: that
  needs the mixer.
- **F9.** `publishPlan` returns `afterPay`, everything after the async pay.
  `publish` lists the result's tags in `MoneyWork.asyncPays` before the
  pay goes, `commit` marks one answered by `asyncpayTag`, and
  `waitForAsyncPay` holds `afterPay` until then or `asyncPaySettle` (10 s),
  after which the rest goes all the same. Not while handling an inbound
  message (`@TaskLocal handlingInbound`, set by the listener): the answer
  would wait behind it in the same serial queue, so a key exchange's
  answer still goes back to back. The engine's own background tasks
  (the history check, the tribes refresh, a reconnect's resends) start
  through `Engine.background`, which clears the flag, so a task started
  while an inbound message is handled does not inherit it.
- **F11.** The invite form says only this Mac keeps the invite, so only
  here can it be cancelled. Any balance change while an invoice made here
  is open and unexpired reconciles (`Engine.balanceCallsForReconcile`,
  `Storage.hasOpenInvoice`; no expiry counts as BOLT 11's hour,
  `Invoice.defaultExpiry`). `invoiceProblem` refuses an invoice our own
  server made when one of our requests (type 2) carries it
  (`Storage.isOurRequest`), after `paidState`. Only a request ours by its
  tag counts: the core sets one only when the message's encrypted tag
  opens with our own key (`dec_tag`), as every send of ours carries, and
  none for one taken for ours by its date alone (`dec_ts_matches`), which
  a contact on our server could forge. A Receive invoice made on
  the other device still cannot be told. Left, needs Tom: a tribe text's
  Retry after 30 s pays the price again if the first went; every tribe
  text carries sats, so treating it like a payment would take Retry away
  from every tribe message.
- **Verified.** Unit: the plan's split, tag marking, the reconcile rule
  and open invoices, our request refusing only our server's invoice
  (`PublishPlanTests`, `InvoiceTests`). Local stack: all 22 journeys pass;
  with temporary logging every wait was ended by its tag in 9–28 ms, and
  `paymentsToAnOfflineContact` now asserts the send returns well inside
  10 s. Offscreen check on a new development profile funded by the stack's
  bank, contact offline: the chat caption and Payments' "Waiting" and
  "1,000 waiting" (a `payments` drive step added); the detail pane was not
  reached by the drive.
- **Reviews.** `/code-review`: the inbound rule was inferred from
  `arrived == nil` (now the TaskLocal); the own-request check moved out of
  `paidState` and limited to our server's invoices, since a message the
  core only takes for ours could otherwise block paying any invoice and
  hide a real pending or paid state; no-expiry invoices no longer open for
  ever; wording ("when them opens", overclaiming). Not applied: the wait
  does not end early on a dropped connection (at most 10 s, same outcome);
  all the result's tags are matched, as the reference clients do.
  `/simplify`: `ownKeys` read once, one Text chain, the week from the
  constant, the expiry constant. Skipped: publishing `afterPay` in its own
  task so the inbound path also waits (larger), and writing an invoice
  record from our history requests (the forged-fromMe concern).
  `/security-review`: no findings.
- **Known gaps.** A connection that drops during the wait leaves the pay
  held and the ping unsent: pending, F5's limbo, as before. A key
  exchange's answer from `receive` still sends its async pay and ping back
  to back. Each waiting payment's 1-sat ping shows in Payments as an
  unexplained "Keysend, sent, not tied to a chat".
- **Independent review** (merge after fixes), applied: the F5 words
  hedged (above); the 7-day help says what happens after; the background
  tasks clear `handlingInbound`; the own-request check takes only a
  request ours by its tag (security S1, a forged request from a contact on
  our server blocked paying their invoice with "your own invoice");
  the review doc's rows synced. Tracked, not built: re-sending the ping
  for our pending async pays on the next connect, for a ping that never
  left.

## Who may write "ours" (2026-10-11, branch `fix/forged-from-me`)

The forged request (Payments review F11's S1, and the branch on the hash a
request keeps) was one reader of a wider hole. Checked against the core
(`sphinx` at `caa76a12`, and again at `bd9e140`, the core Peel links)
and the tribes server before any code.

**The premise holds.** The core sets `fromMe` when a message's
`encrypted_tag` opens with our account key (`dec_tag`) or its
`encrypted_date` opens with the secret the signer shares with our key and
matches the date (`dec_ts_matches`), both in `bindings/handle_msg.rs` and
`handle_batch.rs`. Every message we send carries the tag, sealed under our
key alone and bound to nothing else (`create_sphinx_msg`), so the
recipient holds it; and any contact can make the date secret. `sentTo`
comes from the key index the onion reached (`add_sent_to`), not from the
signer, and `parse_sphinx_msg` takes the uuid from the bytes unchecked.
So a contact (with their own key or any throwaway) can get a message
stored as ours in their chat, with our uuids or new ones; a member of a
tribe can do the same through the tribe's forward. The one fact nobody
can forge is the signer: `parse_sphinx_msg` recovers `sender.pubkey` from
the signature.

**Who really signs ours**, every path checked:

| Path | Signer |
|---|---|
| Our DM send, its copy to self, the server's echo to our other devices, the same in history (`send`, `make_msg` sets child index 0) | our account key (index 0) |
| Our key exchange (`make_keyx_msg`), tribe join (`make_tribe_join_msg`) | our account key |
| Our tribe message forwarded back by the tribe, live and in history (`mutate_msg_to_forward`) | the tribe |
| A purchase answer the tribes server makes for the seller, the owner's notices from `manager.rs` (the date path, `create_sphinx_msg_with_enc_ts`) | the tribe |
| Our contact record (type 33) from another device | our key; the core returns it without `sentTo` (and `fromMe: false` when it overwrites), so it is never stored as ours |

So "ours" can be genuine only when signed by our account key, or by the
tribe whose chat it is. A copy the core calls ours with any other signer
is forged; signed by the person whose chat it is, it is theirs. Signed by
us is necessary, not enough: see the replay under Residual.

**What a forged row did, reader by reader** (DM unless said):

| Reader | Abuse |
|---|---|
| `PaymentHistory` (`moneyMessagesSQL`, `unlisted`) | A payment or boost of "ours" with any declared amount listed as sent; with a real hash of ours it could pair with our payment row. Balance untouched. |
| `Storage.reconcile`, statuses by tag (`applyStatus`), `pendingSendTags` | A copy with our replayed tag or hash moves with our send: a status of ours, or a server record, makes it COMPLETE, PENDING or FAILED. |
| `waiting()` / `spendableMsat` | A forged money send moved to PENDING holds its declared amount (any figure) back from what can be spent for a week: our payments refused. |
| `undeliveredSends`, Retry | A forged text moved to PENDING or FAILED could be sent again by a reconnect as ours. |
| `newestOwnPhotoURL` + `recoverOwnPhoto` | On a restore, the newest "ours" names our photo: a contact's forged copy sets our profile photo, which then goes out on every message. |
| `Storage+Threads` (threads you are in), `boostedByMe`, `isOurRequest` | A reply or boost of "ours" puts a thread in the list, marks a message boosted, and (fixed separately) blocks paying an invoice. |
| Timeline, notifications, unread | Their words shown as ours, never notified. |
| Upsert by uuid | A copy with one of our uuids in the same chat fills in its index, time, sats and hash (the request branch's case). |
| Tribes: `membership`, `echoedAliases`, the tribe readers above | Only through a tribe's forward: see the tag-replay branch. |

**A second finding, in the core.** The core adds the signer of a message
as a contact at the child index the onion reached, whoever that index
belongs to: live for a message not ours at a non-zero index
(`sync_incoming_contact`), in history for any signer but us (`save_them`),
with the contact key only if the sender names one. So a contact can mint
core contacts at their own index, with no contact key: shaped like a
tribe (`isPerson` false). In history the minted contact is also what
`add_sent_to` finds for the index (the page's new state is read last), so
a forged "ours" there is filed under the minted key. "A core contact with
no contact key" is therefore no proof of a tribe. To raise with the core
(Peel cannot undo it: the state is the core's).

**A third, in the core Peel links.** At `bd9e140` the live
`ContactKeyRecord` arm has no `sent_by_me` check (`caa76a12` added one):
anyone who can reach one of our keys can rewrite a contact's index, LSP
and contact key through a type 33 record. AGENTS.md said otherwise; it
is corrected. Not this branch's to fix (the signer rule still keeps such
a row out of the chats), but it outranks it: tracked separately.

**Rule.** One check where messages come in, so every reader is covered
rather than each patched. A copy the core calls ours is kept only when
**its signer is this account's key** (`Sphinxrs.pubkeyFromSeed(idx: 0)`,
kept as `Engine.accountKey`), **or its signer is the chat it is filed in
and that chat is a tribe Peel knows**, counting one this very message
introduces (`discoveredTribe`, our own join forwarded back with the
tribe's host). Anything else is dropped unstored, as a message from an
unknown sender already is. `Engine.message(from:)` checks the signer
before tribe discovery (so a copy signed by someone else cannot introduce
a tribe either); `commit` checks the tribe after it. Checked against:

- restore and history: our DM history is signed by us; our tribe history
  by the tribe, and our join, oldest first, introduces it;
- other devices: the server's echo is our own signed send (a copy we
  signed is kept in any chat, known tribe or not);
- tribe forwards and the tribes server's date-path notices: signed by the
  tribe, filed in the tribe's chat;
- type 33 records: `fromMe` false, not touched by the rule;
- not-ours copies: unchanged (`trustSender` already needs the signer).

**Residual, documented not built:**

- Our own signed bytes, replayed. The signature covers the message but
  not its uuid (read unchecked after it) nor whom it went to, and every
  contact holds the bytes of what we sent them. So a contact can send one
  back to us under another uuid (a second "sent" row with our real tag
  and declared amount, or our uuid of another row in their chat, whose
  index, time, sats and hash the upsert then fills in), or at another
  contact's index (filed in that chat). It is signed by `accountKey`, so
  this rule keeps it, as before. The rule of the tag-replay branch closes
  it in DMs too: a copy whose tag we already hold under another uuid is a
  replay. The core should check the uuid (`uuid == lightning_hash(msg)`
  in `parse_sphinx_msg`); raise with the minted-contact finding.
- A tribe's forward is signed by the tribe whoever wrote it, so a member
  who replays our tag still gets an "ours" row in that tribe. That is the
  tag-replay branch (`fix/tribe-fromme-replay`), not this one.
- Tribe discovery itself: a minted, tribe-shaped contact that signs a
  join with a host (as theirs, or as ours) is taken for a tribe, as it
  was before this change; from then on its chat counts as a tribe here
  too. Telling a real tribe needs the registry or the core.
- A tribe joined live on another device. The join sends no contact
  record to our other devices, so this device's core has no contact for
  the tribe when our forwarded join arrives: no `sentTo`, dropped (as
  before). Members' posts then make the core sync the tribe as a contact
  without a key, and Peel files them under it with no tribe record (as
  before; not yet a conversation). Our own posts from the other device,
  signed by the tribe, are now dropped: before they were stored. They
  stay missing once someone's join or approval (which carry the host)
  introduces the tribe. A restore is unaffected (history syncs the tribe
  from our join). Follow-up for Tom: accept a keyless chat as a tribe
  once our own tribes host's registry knows it (`TribeInfo.fetch`; the
  server makes tribe keys itself, so a throwaway cannot be registered),
  which would also close the next item. No journey covers two devices
  live in a tribe.
- A contact we added who never confirmed has no contact key either, so
  `discoveredTribe` takes their chat for a tribe when their own message
  names a host; from then on their forged "ours" (by the date) is kept
  there, and a role-0 join makes us its owner. As before this change;
  the doc first named only minted contacts.
- Our own tribe messages that a restore meets before anything introduces
  the tribe are dropped. History comes oldest first and we join before we
  post, so only a history cut short of our join loses them, or a tribes
  server run without `HOST` (its joins then name no host). Before this
  change they were stored, under a chat with no tribe record. Accepted:
  a fallback on "no contact key" would let minted contacts back in.
- Rows stored before this change stay (no cleanup migration: a migration
  cannot know the account key, and the real account is days old).
- A dropped copy does not move the history cursor, like any other drop;
  a newest forged copy is fetched again and dropped again on catch-up.

**Done looks like:** the rule in `Engine.message(from:)` and `commit`,
with `accountKey`; unit tests through `commit` for our copy, a known
tribe's forward, our join introducing a tribe, a copy signed by the
chat's person, by another key in a DM and in a tribe, in a minted
tribe-shaped contact, and someone else's message unchanged; full `swift
test`; the message, tribe, payment and history journeys on the local
stack.

**Built.** `Engine.accountKey` (index 0, derived once in `init`; the memes
sign-in and the preferences file's name use it too, in place of
`memesPubkey`, which derived it again on each call). `message(from:)` drops a copy of ours signed by
neither our key nor its chat, and returns `signedByChat`; `commit` drops
one signed by its chat unless, after `discoveredTribe`, the chat is a
known tribe. `OursTests` (in `EngineTests`) runs each case through
`commit`, through `TestSupport`'s `coreResult` (now with messages and
state changes).

**Verified.** Unit: full `swift test` (the one known issue is older);
without the rule the drop tests fail. Local stack: all 22 journeys
pass, among them the restore in `HistoryJourneys`, which checks our own
DM history comes back as ours (so `accountKey` matches the signer the
core recovers) and our tribe post comes back as ours once our join
introduces the tribe. After the rebase and review fixes, two more full
runs on a machine running other sessions' stacks failed 4 journeys each,
different ones each time, all on timeouts, registration or connect
(attachments, invites, payments, history, tribes); every journey passed
in at least one of the three runs. Rebased on the preferences sync
(#145): 582 unit tests pass; 29 of 30 journeys pass, the preferences
ones among them (they use `accountKey` now); the one failure,
`twoDevicesPayAnOfflineContact`, timed out in its setup (the bank's key
exchange) and passed in the third run.

**Reviews.** `/code-review`: the signer was decoded twice (now a flag
from `message(from:)`); our tribe messages before the tribe is known are
dropped (accepted, under Residual, with the tribes server's `HOST`).
Not applied: one check instead of two (the signer must be checked before
discovery, the tribe after), a unit test of the key's format (the
restore journey covers it). `/simplify`: the shared `coreResult` instead of
a second `RunReturn` builder, the engine's own key in the tests and the memes sign-in, fewer
comments. Not applied: narrowing `discoveredTribe` to `trustSender`
(our own key's join may carry a host; out of scope), `ownKeys` in
`Engine+Payments` (the request branch is changing it).
Independent review (merge after fixes), applied: the live other-device
tribe case and the unconfirmed contact (both under Residual), the type 33
claim checked against `bd9e140`, the wording on which signers the core
files, two more tests (our copy in a tribe-shaped chat Peel does not
know is kept; a copy with no sender is dropped), the join test asserts
the tribe it introduces. Not applied: a cleanup of rows stored before
(Residual), the registry check (follow-up above).
`/security-review`: one finding, older than this change and not closed
by it, the replay of our own signed bytes (under Residual).
