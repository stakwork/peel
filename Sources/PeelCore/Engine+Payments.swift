import Foundation
import Sphinxrs

extension Engine {
    // MARK: - Payments and boosts

    /// Payments and boosts over this many msat need the person's confirmation
    /// (`Failure.needsConfirmation`); the app asks before calling again.
    /// 100 sats unless the person chose otherwise (Tom, 2026-10-07); 0 asks
    /// for every payment.
    public static let defaultPaymentConfirmationMsat: UInt64 = 100_000

    public func paymentConfirmationMsat() throws -> UInt64 {
        try storage.value(for: .paymentConfirmationMsat).flatMap { UInt64($0) } ?? Self.defaultPaymentConfirmationMsat
    }

    public func setPaymentConfirmation(msat: UInt64) throws {
        try storage.set(String(msat), for: .paymentConfirmationMsat)
    }

    /// The balance the server last reported, in msat; nil until it has.
    public func balanceMsat() throws -> UInt64? {
        try storage.balanceMsat()
    }

    /// Boosts someone else's delivered message, as the Mac app does: type 29
    /// naming it by `replyUuid`. In a tribe the boost also pays the tribe's
    /// price per message and escrow, so the total is that plus `amountMsat`;
    /// the tribes server passes all of it to the message's author. Like
    /// `sendText`, a failure to deliver is reported through events, not
    /// thrown. Returns the tag the server will confirm.
    @discardableResult
    public func boost(messageID: Int64, amountMsat: UInt64, confirmedMsat: UInt64? = nil) async throws -> String? {
        try await boost(messageID: messageID, amountMsat: amountMsat, confirmation: .threshold(confirmedMsat))
    }

    /// Whether a payment is held to the confirmation threshold, and the
    /// amount the person confirmed if asked; or sent unasked (one-tap boost).
    enum Confirmation {
        case threshold(UInt64?)
        case unasked
    }

    private func boost(messageID: Int64, amountMsat: UInt64, confirmation: Confirmation) async throws -> String? {
        guard amountMsat > 0 else { throw Failure.invalidAmount }
        let (message, uuid) = try boostTarget(try storage.message(id: messageID))
        guard let total = Self.boostTotalMsat(tipMsat: amountMsat, in: try openTribe(message.chat)) else {
            throw Failure.insufficientBalance
        }
        try checkPayment(total, confirmation)
        let body = try Self.json(["content": "", "replyUuid": uuid])
        return try await deliver(body: body, to: message.chat, type: MessageType.boost, amountMsat: total, replacing: nil)
    }

    /// The official apps' one-tap boost (Tom, 2026-10-07: the same UX): the
    /// account's boost amount (`boostAmountMsat`) plus, in a tribe, its price
    /// and escrow, sent at once with no confirmation of any kind; the
    /// threshold, "Always confirm" included, is for a boost with an amount
    /// (`boost`, the CLI's), payments and invoices. The boost amount itself
    /// was approved when it was saved (`setBoostAmount`). Only the balance is
    /// checked. A message is boosted once this way (Tom, 2026-10-07): with
    /// any boost of ours on it, failed ones included (those offer Retry), a
    /// tap is ignored and returns nil, which also covers a double click.
    @discardableResult
    public func quickBoost(messageID: Int64) async throws -> String? {
        if let message = try storage.message(id: messageID), let uuid = message.uuid,
           try storage.lastOwnBoost(on: uuid, in: message.chat) != nil {
            return nil
        }
        return try await boost(messageID: messageID, amountMsat: try boostAmountMsat(), confirmation: .unasked)
    }

    /// The official apps' default tip, 100 sats ("Default tip amount").
    public static let defaultBoostAmountMsat: UInt64 = 100_000

    public func boostAmountMsat() throws -> UInt64 {
        try storage.value(for: .boostAmountMsat).flatMap { UInt64($0) }.flatMap { $0 > 0 ? $0 : nil }
            ?? Self.defaultBoostAmountMsat
    }

    /// Every later one-tap boost sends this amount unasked, so one over the
    /// confirmation threshold must be confirmed (`confirmedMsat`) like a payment.
    public func setBoostAmount(msat: UInt64, confirmedMsat: UInt64? = nil) throws {
        guard msat > 0 else { throw Failure.invalidAmount }
        if Self.needsConfirmation(msat, confirmedMsat: confirmedMsat, thresholdMsat: try paymentConfirmationMsat()) {
            throw Failure.needsConfirmation(amountMsat: msat)
        }
        try storage.set(String(msat), for: .boostAmountMsat)
    }

    /// Whether `amountMsat` must be confirmed first: over the threshold (0
    /// asks for everything) and not confirmed for exactly this amount.
    static func needsConfirmation(_ amountMsat: UInt64, confirmedMsat: UInt64?, thresholdMsat: UInt64) -> Bool {
        confirmedMsat != amountMsat && amountMsat > thresholdMsat
    }

    /// What a boost with this tip pays: in a tribe its price per message and
    /// escrow (`Tribe.paymentPriceMsat`) plus the tip, else the tip; nil if
    /// it cannot be counted.
    static func boostTotalMsat(tipMsat: UInt64, in tribe: Tribe?) -> UInt64? {
        let (total, overflow) = (tribe?.paymentPriceMsat ?? 0).addingReportingOverflow(tipMsat)
        return overflow ? nil : total
    }

    /// The message a boost is for, and its uuid, if it may be boosted
    /// (`Message.isBoostable`), for a new boost and a retry alike.
    func boostTarget(_ message: Message?) throws -> (Message, String) {
        guard let message, message.isBoostable, let uuid = message.uuid, MessageUUID.isValid(uuid) else {
            throw Failure.notBoostable
        }
        return (message, uuid)
    }

    /// Sends sats to a contact in their chat with an optional note (type 5),
    /// as the Mac app's payment does. Only to a person: in a tribe it would
    /// pay the tribes server. Delivery is reported as for `sendText`.
    @discardableResult
    public func sendPayment(
        to pubkey: String, amountMsat: UInt64, text: String = "", confirmedMsat: UInt64? = nil
    ) async throws -> String? {
        guard amountMsat > 0 else { throw Failure.invalidAmount }
        guard tribes[pubkey] == nil else { throw Failure.paymentToTribe }
        guard Self.isPerson(pubkey, in: state) == true else { throw Failure.notAContact }
        try checkPayment(amountMsat, .threshold(confirmedMsat))
        let body = try Self.json(["content": text])
        return try await deliver(
            body: body, to: pubkey, type: MessageType.directPayment, amountMsat: amountMsat, replacing: nil
        )
    }

    /// Refuses an amount over the last balance the server reported (less
    /// `reserveMsat` kept back for routing fees), or over the confirmation
    /// threshold unless the person confirmed exactly this amount (a
    /// confirmation never covers a total that changed since, such as a tribe
    /// raising its price between the two clicks). A one-tap boost
    /// (`.unasked`) is checked against the balance only.
    func checkPayment(_ amountMsat: UInt64, _ confirmation: Confirmation, reserveMsat: UInt64 = 0) throws {
        guard let balance = try balanceMsat() else { throw Failure.balanceUnknown }
        let (needed, overflow) = amountMsat.addingReportingOverflow(reserveMsat)
        guard !overflow, needed <= balance else { throw Failure.insufficientBalance }
        if case .threshold(let confirmedMsat) = confirmation,
           Self.needsConfirmation(amountMsat, confirmedMsat: confirmedMsat, thresholdMsat: try paymentConfirmationMsat()) {
            throw Failure.needsConfirmation(amountMsat: amountMsat)
        }
    }

    // MARK: - Invoices and payment history

    /// What paying an invoice keeps back for routing fees when checking the
    /// balance: 1%, at least 10 sats. The fee itself is known only after.
    public static func feeReserveMsat(for amountMsat: UInt64) -> UInt64 {
        max(amountMsat / 100, 10_000)
    }

    /// Fetches a page of the server's payment history, newest first, older
    /// than `before` (milliseconds; nil for the newest), and stores it.
    /// Returns how many rows came: fewer than a page means the end.
    @discardableResult
    public func fetchPaymentHistory(before: Int64? = nil) async throws -> Int {
        try await fetchPaymentPage(before: before).count
    }

    /// Fetches what is new since the history was last fetched: the newest
    /// page, and older ones until they reach what is stored, so a busy spell
    /// leaves no gap that paging back would skip. At most 20 pages a time.
    public func refreshPaymentHistory() async throws {
        let started = Date().millisecondsSince1970
        let newestStored = try storage.newestPaymentTimestamp()
        var before: Int64?
        for _ in 0..<20 {
            let page = try await fetchPaymentPage(before: before)
            guard page.count >= Int(Self.paymentPageSize), let newestStored, let oldest = page.map(\.ts).min(),
                  oldest > newestStored else {
                historyCheckedAt = started
                return
            }
            before = oldest
        }
    }

    /// One page at a time: a fetch waits for the one on its way (the
    /// server's answer names no request).
    private func fetchPaymentPage(before: Int64?) async throws -> [PaymentRecord] {
        try await poll(timeout: .seconds(30), failure: .serverTimedOut) { awaitingPayments ? nil : () }
        guard transport != nil else { throw Failure.notConnected }
        awaitingPayments = true
        paymentPage = nil
        defer {
            awaitingPayments = false
            paymentPage = nil
        }
        let since = before.map { UInt64(max($0 - 1, 0)) } ?? UInt64(Date().millisecondsSince1970)
        try await run { time, state in
            try Sphinxrs.fetchPayments(
                seed: seed, uniqueTime: time, state: state, since: since, limit: Self.paymentPageSize,
                scid: nil, remoteOnly: false, minMsat: 0, reverse: true
            )
        }
        return try await poll(timeout: .seconds(15), failure: .serverTimedOut) { paymentPage }
    }

    public static let paymentPageSize: UInt32 = 50

    /// Makes an invoice to receive `amountMsat`, as the official apps do:
    /// the server's Lightning node makes it (`request_invoice`) and credits
    /// this account when it is paid, so it is paid even while Peel is
    /// closed. The payment shows only as a balance change and a row in the
    /// server's history, which marks the invoice paid (see
    /// `checkOpenInvoices`). An amount is required.
    public func createInvoice(amountMsat: UInt64, memo: String = "") async throws -> InvoiceRecord {
        try await serverInvoice(amountMsat: amountMsat, memo: memo, chat: nil)
    }

    private func serverInvoice(amountMsat: UInt64, memo: String, chat: String?) async throws -> InvoiceRecord {
        guard amountMsat > 0 else { throw Failure.invalidAmount }
        guard isRegistered, transport != nil, let server = try ownKeys()?.server else { throw Failure.notConnected }
        let memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard memo.utf8.count <= 300 else { throw Failure.memoTooLong }
        // The server's answer names no request, so one at a time: wait for
        // the one on its way, as a history page does.
        try await poll(timeout: .seconds(30), failure: .serverTimedOut) { awaitingInvoice ? nil : () }
        awaitingInvoice = true
        answeredInvoice = nil
        defer {
            awaitingInvoice = false
            answeredInvoice = nil
        }
        try await run { time, state in
            try Sphinxrs.requestInvoice(seed: seed, uniqueTime: time, state: state, amtMsat: amountMsat, description: memo)
        }
        // The server sends nothing back when it cannot make one (no Lightning
        // node). A late answer to an earlier request that differs is dropped.
        let invoice = try await poll(timeout: .seconds(30), failure: .noInvoiceFromServer) { () -> Invoice? in
            guard let bolt11 = answeredInvoice else { return nil }
            answeredInvoice = nil
            return try? Self.checkServerInvoice(bolt11, amountMsat: amountMsat, memo: memo, server: server)
        }
        let record = InvoiceRecord(
            paymentHash: invoice.paymentHash, incoming: true, bolt11: invoice.bolt11,
            amountMsat: Int64(clamping: amountMsat), memo: invoice.memo, payee: invoice.payee,
            createdAt: Date().millisecondsSince1970, expiresAt: invoice.expiresAt?.millisecondsSince1970,
            status: .open, chat: chat
        )
        _ = try storage.apply(Storage.Commit(invoices: [record]))
        return record
    }

    /// The server's answer to `request_invoice`, checked against what was
    /// asked: its node is the payee, for exactly the amount and memo, and
    /// not expired. Refuses a late answer to an earlier request that differs.
    static func checkServerInvoice(
        _ bolt11: String, amountMsat: UInt64, memo: String, server: String, now: Date = .now
    ) throws -> Invoice {
        let invoice = try Invoice(bolt11)
        guard invoice.payee == server, invoice.amountMsat == amountMsat, invoice.memo == memo,
              !invoice.isExpired(now: now) else {
            throw Failure.invoiceMismatch
        }
        return invoice
    }

    /// This account's pubkey and its server's node, from the contact info
    /// the core reports (`pubkey_lsp_scid`); nil before registering.
    private nonisolated func ownKeys() throws -> (pubkey: String, server: String)? {
        try storage.value(for: .contactInfo).flatMap(Self.contactInfoParts).map { ($0[0], $0[1]) }
    }

    /// `pubkey_lsp_scid` split in three, or nil when it is not that.
    static func contactInfoParts(_ contactInfo: String) -> [String]? {
        let parts = contactInfo.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 && parts[0].count == 66 ? parts : nil
    }

    /// Looks in the server's history for payments to invoices made here,
    /// which arrive only as a balance change and a history row (`commit`
    /// matches the row by payment hash): on coming online, as Peel may have
    /// been closed when one was paid, and whenever the balance goes up. Only
    /// while an invoice made here was open and unexpired when the history
    /// was last brought up to date. One check at a time; a call during one
    /// runs it again after. Stopped by `disconnect`.
    func checkInvoicesInBackground() {
        guard !closed else { return }
        invoicesNeedCheck = true
        guard invoiceCheck == nil else { return }
        invoiceCheck = Task { [weak self] in await self?.checkOpenInvoices() }
    }

    private func checkOpenInvoices() async {
        while invoicesNeedCheck, !Task.isCancelled {
            invoicesNeedCheck = false
            do {
                guard try storage.hasInvoicesAwaitingHistory(checkedAt: historyCheckedAt) else { break }
                try await refreshPaymentHistory()
            } catch {
                if !Task.isCancelled {
                    emit.yield(.coreError("checking invoices for payments: \(PeelError.readable(error))"))
                }
                break
            }
        }
        // A cancelled check has already been replaced or stopped.
        if !Task.isCancelled { invoiceCheck = nil }
    }

    /// Asks a contact for sats in their chat (type 2), with an invoice the
    /// server makes for this account, as the official apps do. Returns the
    /// invoice; the message's delivery is reported as for `sendText`.
    @discardableResult
    public func requestPayment(from pubkey: String, amountMsat: UInt64, memo: String = "") async throws -> InvoiceRecord {
        guard tribes[pubkey] == nil else { throw Failure.requestToTribe }
        guard Self.isPerson(pubkey, in: state) == true else { throw Failure.notAContact }
        let record = try await serverInvoice(amountMsat: amountMsat, memo: memo, chat: pubkey)
        let body = try Self.json(["content": record.memo, "invoice": record.bolt11])
        try await deliver(body: body, to: pubkey, type: MessageType.invoice, replacing: nil)
        return record
    }

    /// Pays a pasted invoice. Refuses one that is expired, names no amount,
    /// is this account's own, was paid before (here, or by any device the
    /// server's history shows) or is being paid; over the balance less a
    /// fee reserve; and over the confirmation threshold unless confirmed.
    /// The payment is recorded as pending before anything is published, and
    /// stays so, never to be paid again, until the server says how it went.
    @discardableResult
    public func payInvoice(_ bolt11: String, confirmedMsat: UInt64? = nil) async throws -> InvoiceRecord {
        try await pay(Invoice(bolt11), chat: nil, confirmedMsat: confirmedMsat)
    }

    /// Pays someone's payment request in their chat. When the invoice pays
    /// them, the payment carries the type 3 message that tells their app,
    /// as the official apps do; otherwise it pays the invoice as pasted.
    @discardableResult
    public func payRequest(messageID: Int64, confirmedMsat: UInt64? = nil) async throws -> InvoiceRecord {
        guard let message = try storage.message(id: messageID), message.type == MessageType.invoice, !message.fromMe,
              let bolt11 = BodyFields.decode(message.body)?.invoice else {
            throw Failure.notAPaymentRequest
        }
        return try await pay(Invoice(bolt11), chat: message.chat, confirmedMsat: confirmedMsat)
    }

    /// What stops paying this invoice from here, as paying it checks (the
    /// confirmation threshold aside): no amount, expired, this account's
    /// own, pending or paid (here or, by the history, from another device),
    /// or more than the balance less the fee reserve. Nil when nothing does.
    /// Reads only storage, so an app can ask before offering Pay.
    public nonisolated func invoiceProblem(_ invoice: Invoice) throws -> Failure? {
        guard invoice.amountMsat > 0 else { return .invoiceWithoutAmount }
        guard !invoice.isExpired() else { return .invoiceExpired }
        if invoice.payee == (try ownKeys())?.pubkey { return .ownInvoice }
        switch try storage.paidState(paymentHash: invoice.paymentHash) {
        case .own?: return .ownInvoice
        case .pending?: return .invoicePending
        case .paid?: return .invoiceAlreadyPaid
        case nil: break
        }
        guard let balance = try storage.balanceMsat() else { return .balanceUnknown }
        let (needed, overflow) = invoice.amountMsat.addingReportingOverflow(Self.feeReserveMsat(for: invoice.amountMsat))
        return overflow || needed > balance ? .insufficientBalance : nil
    }

    private func pay(_ invoice: Invoice, chat: String?, confirmedMsat: UInt64?) async throws -> InvoiceRecord {
        let hash = invoice.paymentHash
        if let problem = try invoiceProblem(invoice) { throw problem }
        // The balance and fee reserve are `invoiceProblem`'s; this asks the threshold.
        try checkPayment(invoice.amountMsat, .threshold(confirmedMsat))
        guard transport != nil else { throw Failure.notConnected }
        guard payingInvoices.insert(hash).inserted else { throw Failure.invoicePending }
        defer { payingInvoices.remove(hash) }

        let toContact = chat.map { invoice.payee == $0 && Self.isPerson($0, in: state) == true } ?? false
        var time = clock.next()
        let result: RunReturn
        if toContact {
            result = try Sphinxrs.payContactInvoice(
                seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11,
                myAlias: alias, myImg: photoURL, isTribe: false
            )
        } else if invoice.payee == (try ownKeys())?.server {
            // Made by our own server's node (`request_invoice`, as Receive and
            // requests in a chat are): the server moves the sats between its
            // accounts (`pay_local_invoice`). An onion ending at its own node
            // it refuses ("expected a forwarded onion").
            result = try Sphinxrs.pay(seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11)
        } else {
            do {
                result = try Sphinxrs.payInvoice(
                    seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11,
                    overpayMsat: invoice.amountMsat
                )
            } catch where invoice.hopHints.isEmpty {
                // No route this account can build: the server pays it (its
                // own node finds the route), as the official apps fall back.
                time = clock.next()
                result = try Sphinxrs.pay(seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11)
            }
        }
        guard let tag = (result.msgs.first { $0.paymentHash == hash } ?? result.msgs.first)?.tag else {
            throw PeelError("the core gave the payment no tag")
        }
        let record = InvoiceRecord(
            paymentHash: hash, incoming: false, bolt11: invoice.bolt11, amountMsat: Int64(clamping: invoice.amountMsat),
            memo: invoice.memo, payee: invoice.payee, createdAt: Date().millisecondsSince1970,
            expiresAt: invoice.expiresAt?.millisecondsSince1970, status: .pending, tag: tag, chat: chat
        )
        // Written with the state before publishing; refused (and nothing
        // published) if the invoice is already being paid or paid.
        let followUps = try commit(result, time: time, expectedSender: nil, invoices: [record])
        let unsent = transport == nil
        do {
            try await complete(result, followUps)
        } catch {
            guard unsent else {
                let message = "The connection failed while paying; the payment may have gone. "
                    + "It stays unconfirmed until the server says (\(PeelError.readable(error)))"
                if let chat { emit.yield(.conversationError(chat: chat, message: message)) } else { emit.yield(.coreError(message)) }
                return record
            }
            try storage.setStatus(.failed, tag: tag, error: "not connected")
            emit.yield(.sendStatus(tag: tag, status: Message.Delivery.failed.rawValue))
            throw error
        }
        return record
    }

    /// A payment request's invoice, from its JSON; nil when it cannot be read.
    static func requestInvoice(_ body: String?) -> Invoice? {
        BodyFields.decode(body)?.invoice.flatMap { try? Invoice($0) }
    }

    /// Whether the bindings would split this JSON into type 34 fragments
    /// (`should_chunk_for_send` in `sphinx-ffi/src/chunk.rs`): each fragment
    /// carries the whole amount, so a payment must never be split. The same
    /// sum, with a margin.
    static func wouldBeSplit(_ body: String, alias: String, photoURL: String) -> Bool {
        // chunk.rs: MAX_MSG_LEN, FIXED_PROTOCOL_OVERHEAD_BYTES, ROUTE_HINT_OVERHEAD_ALLOWANCE_BYTES.
        let maxMessage = 869, protocolOverhead = 250, routeHint = 50, margin = 32
        struct Sender: Encodable { let alias: String; let img: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Two strings always encode.
        let sender = try! encoder.encode(Sender(alias: alias, img: photoURL)).count
        return body.utf8.count + margin > maxMessage - protocolOverhead - routeHint - sender
    }

    /// A payment's body and photo URL as they fit in one message: without the
    /// time-zone offset, then without the photo, rather than not at all. The
    /// photo only decorates the payment, and the official apps (like Peel)
    /// keep a contact's photo when a message comes without one. What still
    /// does not fit is the name's fault when it would not fit alone, else the note's.
    static func fittingPayment(_ body: String, alias: String, photoURL: String) throws -> (String, String) {
        guard wouldBeSplit(body, alias: alias, photoURL: photoURL) else { return (body, photoURL) }
        let body = try TimeZoneOffset.setting(nil, in: body)
        if !wouldBeSplit(body, alias: alias, photoURL: photoURL) { return (body, photoURL) }
        if !wouldBeSplit(body, alias: alias, photoURL: "") { return (body, "") }
        throw wouldBeSplit("{}", alias: alias, photoURL: "") ? Failure.nameTooLong : Failure.noteTooLong
    }
}
