# Phase 4 — Money

Status: planned. Scope agreed 2026-10-05: send sats in chat, pay an invoice,
request payment, boosts, a Receive screen, transaction history, paid messages
and payment templates.

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
