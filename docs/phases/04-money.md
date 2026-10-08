# Phase 4 — Money

Status: started 2026-10-07. Boosts and in-chat payments are built in the
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
  peels it against the real HTLC amount and reports `msat` (never more than
  what arrived) and `paymentHash`. A live "stream" payment is settled by the
  core (`settle_topic`). History (`fetchMsgsBatch`) returns the same `msat`.
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
  fragment's async pay survives the merge.
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
- Storage migration `v11` (main is at v8; `phase3/attachments` adds v9
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
  feedback) opening a Peel
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
