# The app wallet: strut apps pay with your sats

Status (2026-11-04): built on `feature/app-wallet`, not merged. The engine,
the host core and both bridges are in; the Mac and iPhone apps build; the
tests below pass. Nothing has been tried on a device or with real sats.

The contract is strut's: specs/WALLET.md, its types and checks in
`kit/src/wallet/protocol.ts`, its conformance vectors in
`kit/src/wallet/vectors.json` (stakwork/strut#484). The design and its
reasons are strut's plans/app-payments.md; its rulings R1, R2, R3 and R5
are what this builds. Peel as an NWC wallet service (R4) is later.

## What the person sees

- An app that asks for a wallet (`wallet:` in its `app.yaml`) asks to
  connect the first time it needs one, right after you click or tap in it.
  The sheet says who asks (the app, its version and where it lives, from
  what Peel opened, never from the page), what it may do, its spending
  limit and how it renews, and what happens over the limit: ask me (the
  default) or refuse. You can lower the limit there.
- Inside the limit the app pays without asking. Over it, a payment sheet
  shows the amount Peel decoded, who it pays (their name when they are a
  contact), the memo or message, the fee, and the app's own words marked
  as its; Pay takes a second click (the iPhone's touch-safe second tap).
  Your "confirm payments over" amount is not asked for an app: over the
  limit an app's payment is always asked, inside it never.
- Connected apps (Account › Payments on the Mac, You on the iPhone) lists
  each connection, its limit and what it spent this period, what happens
  over it; change the limit, or Disconnect.
- On the Mac a connection is one app (`@acme`'s Shop, or one of yours). On
  the iPhone it is the org: every app of that org shares it, since the
  page there is the org's own code (R5).

## How it works

```
app frame ──strut/wallet/*──▶ strut's UI (relay) ──messageHandlers.strutWallet──▶ bridge ──▶ WalletHost ──▶ EngineWallet ──▶ Engine
app frame ◀─notification──── strut's UI ◀── window.strutWallet.notify(message) ── bridge ◀── WalletHost ◀── Storage (walletRecordUpdates)
```

- **The bridge** (`Apps/Shared/StrutWallet.swift`; the Mac's
  `StrutWalletBridge`, the iPhone's `OrgWalletBridge`) is Peel's one
  JavaScript-to-native handler. It answers only `frameInfo.isMainFrame` at
  the origin Peel loaded (the Mac's own strut, `MemoryServer.base`; the
  org's base URL), from the web view it was installed on; anything else
  gets a rejected promise and learns nothing. On the Mac the app is the one
  the web view's own address names (`MemoryServer.appLink`), and the
  message must name the same (`WalletHost.handle`). A notification is
  pushed with `callAsyncJavaScript`, the message an argument to strut's own
  function, never spliced into script text (sphinx-bridge broke on an
  apostrophe that way). The handler is on the detail column's app page,
  an app's own window and an app deliverable in the web pane; never on a
  page of the web, a tribe's app or an HTML attachment.
- **The host** (`WalletHost`, PeelCore, no UI) decides everything, in this
  order: the params checked again (`WalletProtocol.checkParams`, a port of
  strut's), what Peel offers (`NOT_IMPLEMENTED`), the connection
  (`UNAUTHORIZED` with none, expired or revoked; `RESTRICTED` for a method
  it does not grant), the payment decoded (an invoice's amount from the
  invoice, never the app), what the wallet refuses before anyone is asked
  (balance, an expired or paid invoice), the limit, then a sheet. A sheet
  needs the person's click or tap within five seconds
  (`InputWebView.acted(within:)`, `TouchWebView.acted(within:)`, native
  events no script makes; `RESTRICTED` otherwise), opens one at a time
  (`RATE_LIMITED` beside one), and is taken down unanswered after nine
  minutes (`RESTRICTED`), before the page's own ten, so a late yes never
  pays for a page that has stopped waiting.
- **The limit** is counted from the connection's own payments, never kept
  as a number that could drift: pending counts its amount, settled its
  amount and fees, failed nothing (the refund) (`WalletRecord.entry`,
  `WalletBudget`). The count and the payment are one database write: the
  commit that writes the keysend or invoice checks it first
  (`Storage.Commit.walletBudget`) and refuses, writing and sending nothing,
  when it does not fit. A payment the person approved on its own sheet is
  counted with no limit. Renewal counts from the connection's creation:
  days and weeks by seconds, months and years by the UTC calendar.
- **The engine** (`Engine+Wallet.swift`): `keysend(to:amountMsat:routeHint:data:for:)`
  over the core's raw `keysend`, to any node or Sphinx address (a route
  hint `<lsp>_<scid>` makes it asynchronous, held at the LSP until the
  payee is online, with its 1-sat ping); `payInvoice(_:for:)` and
  `createInvoice(amountMsat:memo:for:)` for an app. Each is checked against
  the balance less what waits (with a fee reserve, and the ping) but not
  the person's threshold, written pending before anything is published
  (`commitAndPublish`: only `.none` fails it), and tagged with its
  connection and app (`invoice.connection`, `invoice.app`, the `keysend`
  table, v33). A keysend is tracked like every send of ours: the live
  `sent_status`, `get_tags` on connect, the history (`Storage.reconcile`),
  and it holds sats back while it waits (`waiting`). The mixer's preimage
  on a COMPLETE is kept on the keysend or invoice we paid, only when it
  hashes to the payment's hash (`Storage.keepPreimage`).
- **The state stream** is a live query over the tagged rows
  (`Storage.walletRecordUpdates`): `EngineWallet.updates` emits each move
  to settled or failed, whichever way it came. The host turns it into
  `payment_sent`, `payment_failed` or `payment_received`, only for the
  connection's own transactions and the types it asked for, once, and
  never before the pay call's own answer.

## Decided here (not in the contract or the rulings)

- **Where connections live:** a table in the account's database
  (`walletConnection`, v33), on this device, not the synced preferences
  file: the limit must be counted in the same write as the payment, the
  Mac and the iPhone key connections differently, and two devices sharing
  one grant would each spend the whole limit.
- **`transaction_id` is the payment hash.** A keysend's is made fresh by
  the core each time, and an invoice is never paid twice.
- **A pay call waits up to five seconds** for the server's word
  (`EngineWallet.settleWait`), so a payment to someone online answers
  settled with its preimage; after that it answers pending and is notified.
- **A settled payment without its preimage.** The mixer's records
  (`get_tags`) and its history carry none, so a payment that settled while
  Peel was not listening has none. A pay method's answer then says
  `pending` (a `Payment` must carry the preimage when settled);
  `lookup_payment`, `list_transactions` and the notification say
  `settled` without one, which their shapes allow. WALLET.md §3 says
  "always when settled": for Sphinx that cannot hold.
- **Fees** are known only from the history: what left beyond the amount,
  plus the 1-sat ping for an asynchronous keysend. The core drops the
  mixer's `amt_paid_msat`. Until the history has the row, a settled
  payment counts no fee.
- **Record 13377331.** The core sends it as base64 of its `data`, so a
  `tlv_records` entry of that type must hold base64 text (as hex bytes);
  Peel sends what it decodes to. Any other type, or a value that is not
  base64 text, is `NOT_IMPLEMENTED`.
- **Route hints:** one route of one hop with a decimal channel id, as
  strut's `sphinxRouteHint`; the hop's fee and CLTV fields are not used
  (the core has no place for them). Anything else is `NOT_IMPLEMENTED`.
- **Not offered:** `pay_lightning_address`; `pay_keysend`'s `preimage`; an
  invoice that names no amount (`NOT_IMPLEMENTED`); `make_invoice`'s
  `description_hash`. `make_invoice`'s `expiry` is ignored (the server's
  node sets it; `expires_at` says what it is), and its description is at
  most 300 bytes (`BAD_REQUEST`).
- **`connect` again** shows the sheet only when the version asks for a
  method or notification type the connection does not hold; then the new
  grant keeps what was held, and the limit held when the request names
  none. Optional methods declined once are not asked again.
- **One sheet at a time in all of Peel**, not per page: Peel draws one.
- **`get_info`** never says the alias or the pubkey.
- **An underpaid invoice made for an app** reads as `failed`: it can never
  take the rest.
- **Messages the host does not read** (no `v: 1`, no app) are
  `BAD_REQUEST`; a capability for an app with no request is `RESTRICTED`
  (no wallet for the page); a method name Peel does not know is
  `NOT_IMPLEMENTED`.

## The vectors

`Tests/PeelCoreTests/WalletVectors/vectors.json` is a copy of strut's
`kit/src/wallet/vectors.json` at stakwork/strut 30d4c8b (the merge of
#484), byte for byte. When strut changes the contract, copy it again from
the commit `Vendor/strut.lock` pins and say so here. `WalletProtocolTests`
runs the `params`, `results`, `notifications`, `connection_requests` and
`preimages` lists; `WalletHostTests.strutsScenario` replays all ten
`scenarios` against a scripted wallet and a scripted person, with real
storage.

## Tests

- `WalletProtocolTests`: the vectors, Sphinx addresses, error bodies.
- `WalletHostTests`: the scenarios, and beyond them: no sheet without the
  person, one sheet at a time and none for ever, an approved payment over
  the limit counted, an invoice's amount the decoded one, what the wallet
  refuses asks nobody, what the core cannot send, isolation between
  connections, refusals outright, connecting again, expiry, an org as one
  connection, the answer before the notification, renewal periods, what a
  budget counts.
- `WalletEngineTests`: the preimage kept only when it proves the payment;
  a keysend moved by the server's word, settled or failed by the history,
  waiting while held; the limit counted in the payment's own write; a
  keysend through the real core; refusals before anything moves; one that
  never left failed and refunded; an app's invoice paid without the
  threshold; the state stream.
- Not tested: the bridges themselves (WebKit) and the sheets, which need
  the app; a payment through a real mixer (the integration journeys could
  take a keysend journey).

## Open questions

1. **Keysend to a node that is not a Sphinx account.** The core builds
   the route through the LSP's graph; whether that reaches any node, or
   needs `concat_route` through a router, is strut's plan's open question
   too.
2. **Should the mixer's tag records carry the preimage?** Then every
   settled payment could prove itself (sphinx `get_tags`, `TagRes`).
3. **Should the core return a keysend's preimage** (it makes it), so Peel
   could keep it at send time and reveal it on settlement?
4. **Which payments should the limit's fees count?** Today the ping of an
   asynchronous keysend counts once it settles, not when it fails.
5. **Connections across devices.** A limit per device means two devices
   could each spend it; a synced grant would need a shared count.
