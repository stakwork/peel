# Phase 4 plan — the Payments screen and invoices

Status: designed, not started. Parked on 2026-10-07 so another session can pick
it up later. Boosts and in-chat payments (type 29, type 5) are a separate piece
of work (PR #16 and its UI); this plan covers what comes after them: the
Payments screen, receiving with an invoice, paying an invoice, and payment
requests in chat.

Read first: `04-money.md` (conventions for amounts, boosts, direct payments,
status and retries), `docs/design/README.md` (flat rows, system font, PeelMenu
two-click items, peelPopover panels, the S2 sidebar) and `AGENTS.md` (never
touch the app's `default` profile; local stack only).

## Design

Boards on the design canvas https://claude.ai/artifact/6CKt7Wcfnov9w2iSZxWvnw,
row "Payments" (revised after Tom's feedback on 2026-10-07):

| Board | What it shows |
|---|---|
| P1 Payments | The list |
| P2 A payment's detail | Right-hand pane for a selected payment |
| P3 / P3b Receive | Invoice waiting, then paid |
| P4 / P4b Pay an invoice | Second click to pay; can't pay (expired, already paid, over balance) |
| P5 Payment requests in a DM | Request row with Pay, and its paid state |

Tom's decisions:

- No balance on the Payments screen or in a payment request; the balance lives
  only in the sidebar header.
- No All / Received / Sent tabs and no table chrome. A plain list grouped by
  relative time: Today, Yesterday, Earlier this week, Earlier.
- Each row: avatar (or a keysend mark for a non-contact), name, one line of
  note, amount with arrow and sign (direction never by colour alone), time.
  Pending rows greyed, failed rows struck through, neither red.
- Header: "Payments" with two small buttons, Receive and Pay an invoice.
- Clicking a payment opens its detail in the right-hand pane (Tom liked this);
  Receive and Pay use the same pane.
- The sidebar rows Threads, Mentions and Payments stay plain: no subtext, no
  icons, no balance.
- A payment request in a DM shows who requested, the amount, the memo and a Pay
  button only.
- The payment confirmation threshold defaults to **100 sats** for every user
  (shared with boosts and direct payments). Above it, paying is a two-click
  confirm showing the amount. The user can change it on the Account screen; no
  hard maximum beyond refusing more than the balance.

Recommended answers to the open design questions (not yet confirmed by Tom):

- v1: history + detail, Receive, Pay an invoice. Then in-chat requests
  (types 2 and 3) and the can't-pay states.
- Fees: show the actual fee after paying; an estimate before paying needs a
  route lookup, so later.
- Sending to a contact stays in the chat's bolt button, not on this screen.
- History loads older pages as you scroll; no cap.
- Check whether `makeInvoice` with 0 msat gives an invoice the payer can fill
  in; if not, the Receive amount is required.

## Engine work

None of this exists in Peel yet; the Sphinxrs bindings already expose the calls.

- History: `fetchPayments(since:limit:reverse:)` with paging. Rows carry only
  `amt_msat`, `ts`, `rhash`, `msg_idx` (incoming only) and `error`. Join them
  to stored messages by payment hash to get the counterpart, chat, note and
  boosted message, as the official app does. Bare keysends (no type, no
  sender) only ever appear here.
- In-flight state: the core rows have no pending field. Track payments in
  flight in Peel (the official app uses `setupInvoicePaymentTimerFor` /
  `onPaymentStatusReceivedFor`).
- Receive: `makeInvoice` / `requestInvoice` return the invoice in
  `RunReturn.invoice` (the official app gives up after 30 s). The live "Paid"
  state needs the settled event (`processInvoicePaid`) matched to the open
  invoice. QR via CoreImage (the Account screen already draws one).
- Pay: `parseInvoice` (amount, payee key, memo, expiry, route hints), then
  `payInvoice(bolt11:overpayMsat:)`. The official app looks up a route first
  and falls back to the LSP without a route hint (`payInvoiceFromLSP`).
  "Already paid" needs a payment-hash lookup against history; "over balance"
  needs a fee margin.
- In chat: send type 2 invoice messages, render incoming ones with Pay
  (`payContactInvoice`), apply the type 3 paid update so the request flips to
  Paid.
- Throughout: msat end to end; the shared confirmation threshold; a Retry must
  never pay twice (see `04-money.md` on status and `getTags`).

## How to ship it

Same chain as everything else (`AGENTS.md`): its own worktree and branch,
engine and storage first with CLI commands for headless checks, then the UI
from the boards; verify on a local stack with real balance accounting (see how
`04-money.md` funded test accounts); `/code-review high`, `/simplify`,
`/security-review` before the PR. Take the next free migration number on
`main` at the time.
