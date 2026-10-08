import Foundation
import GRDB

/// Where a paid attachment stands for this account, as the official apps
/// tell it from the purchase messages that name its media token (types 7,
/// 8 and 9).
public enum PurchaseState: Sendable, Equatable {
    /// Someone else's, not bought: nothing of it is fetched or decrypted.
    case locked
    /// Our purchase is on its way or paid, with no answer yet.
    case processing
    /// Our purchase failed: nothing was paid, so it may be bought again.
    case failed
    /// The seller sent the key: it downloads and decrypts as any attachment.
    case unlocked
    /// The seller refused and sent the sats back.
    case denied
    /// Ours, for sale: how many purchases have come in.
    case forSale(purchases: Int)
}

/// A payment request in a chat (type 2), read from its invoice.
public struct PaymentRequest: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Not paid; check `invoice.isExpired()` before offering Pay.
        case open
        /// Our payment of it is on its way: it may have paid, so it is never
        /// paid again until the server says.
        case paying
        case paid(at: Date?)
        /// Ours, settled for less than it asked: what came.
        case underpaid(msat: Int64?)
        /// Our payment of it failed; nothing moved, so it may be paid again.
        case failed(String?)
    }

    /// Nil when the message's invoice cannot be read: it can never be paid.
    public var invoice: Invoice?
    public var state: State
    /// Whether paying goes to the person who asked rather than to some other
    /// node: their own invoice, or one their server or ours made for them.
    public var paysRequester: Bool
}

/// One line of the Payments screen: a row of the server's history joined to
/// what this account knows about it, or a payment of ours the server has no
/// row for yet.
public struct PaymentItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Sats sent in a chat (type 5).
        case payment
        case boost
        /// An invoice: made here and paid, paid by us, or a request in a chat.
        case invoice
        /// Sats with nothing this account can tie them to.
        case keysend
        /// Buying or selling a paid attachment (type 7), or its refund (type 9).
        case purchase
        /// What a tribe charged for a message we posted there (its price per
        /// message and escrow, at least 3 sats), or for joining it.
        case messageFee
    }

    public enum Status: Sendable, Equatable { case pending, complete, failed }

    public var id: String
    public var kind: Kind
    public var incoming: Bool
    public var amountMsat: Int64
    /// Milliseconds since 1970.
    public var timestamp: Int64
    public var status: Status
    public var error: String?
    public var paymentHash: String?
    /// The chat it belongs to, its name, and whether it is a tribe.
    public var chat: String?
    public var chatName: String?
    public var isTribe = false
    /// Who paid or was paid: the contact, or for a tribe boost the member.
    /// Nil when nobody is known (a keysend, an invoice).
    public var counterpart: String?
    public var counterpartPhotoURL: String?
    /// A payment's note or an invoice's memo.
    public var note: String?
    /// The payment, boost, invoice payment or (for a fee) posted message, when stored.
    public var message: Message?
    /// For a boost: the message boosted, when stored.
    public var boosted: Message?
    public var invoice: InvoiceRecord?
    /// For an invoice we paid: what the server recorded beyond its amount.
    public var feeMsat: Int64?
    /// For a payment of ours sent the asynchronous way: the ping that went
    /// with it to reach the other side (1 sat), counted here rather than
    /// listed as a keysend of its own.
    public var pingMsat: Int64?

    public var date: Date { Date(millisecondsSince1970: timestamp) }

    /// Sats of ours to a contact, which go the asynchronous way: they wait
    /// for the contact's app to come online, with a ping to wake it.
    public var isToContact: Bool {
        guard !incoming, !isTribe, chat != nil else { return false }
        switch kind {
        case .payment, .boost, .purchase: return true
        case .invoice, .keysend, .messageFee: return false
        }
    }
}

/// What stops paying an invoice again: our payment of it on its way or
/// done, a successful payment of it in the server's history (from any
/// device), or it being this account's own.
public enum InvoicePaidState: Sendable, Equatable {
    case pending
    case paid(at: Date?)
    case own
}

extension Storage {
    /// The newest `limit` rows of the server's history fetched so far,
    /// joined, plus our payments it has no row for yet (pending, failed, or
    /// newer than the last fetch), newest first; re-emitted whenever any of
    /// it changes.
    public func paymentHistory(limit: Int) -> some AsyncSequence<[PaymentItem], any Error> {
        ValueObservation
            .tracking { db in try Self.paymentItems(limit: limit, db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// The oldest history row fetched, in milliseconds: where the next page starts.
    public func oldestPaymentTimestamp() throws -> Int64? {
        try pool.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM payment") }
    }

    /// The newest history row fetched, in milliseconds.
    func newestPaymentTimestamp() throws -> Int64? {
        try pool.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM payment") }
    }

    /// An invoice made here (`incoming`) or paid from here.
    func invoice(paymentHash: String, incoming: Bool) throws -> InvoiceRecord? {
        try pool.read { db in try Self.invoice(paymentHash, incoming: incoming, db) }
    }

    /// One invoice, re-emitted whenever it changes: Receive watches its own for "Paid".
    public func invoiceUpdates(paymentHash: String, incoming: Bool) -> some AsyncSequence<InvoiceRecord?, any Error> {
        ValueObservation
            .trackingConstantRegion { db in try Self.invoice(paymentHash, incoming: incoming, db) }
            .removeDuplicates()
            .values(in: pool)
    }

    public func paidState(paymentHash: String) throws -> InvoicePaidState? {
        try pool.read { db in
            if try Self.invoice(paymentHash, incoming: true, db) != nil { return .own }
            switch try Self.ourPayment(of: paymentHash, db) {
            case .paying?: return .pending
            case .paid(let at)?: return .paid(at: at)
            case .failed?, .open?, .underpaid?, nil: return nil
            }
        }
    }

    /// Payments of invoices the server has not confirmed or refused, newest
    /// first, at most 200.
    func pendingInvoicePayments() throws -> [InvoiceRecord] {
        try pool.read { db in
            try InvoiceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM invoice WHERE incoming = 0 AND status = 'PENDING' AND tag IS NOT NULL
                    ORDER BY createdAt DESC LIMIT 200
                    """
            )
        }
    }

    private static func invoice(_ hash: String, incoming: Bool, _ db: Database) throws -> InvoiceRecord? {
        try InvoiceRecord.fetchOne(db, key: ["paymentHash": hash, "incoming": incoming])
    }

    /// The state of each payment request among `messages`. Ours is paid once
    /// the invoice we made settled, or another device saw the payer's
    /// payment (type 3) bring at least its amount; theirs follows our
    /// payment of it, or a successful payment of it in the history.
    /// `requesterNodes` are the chat's (`requesterNodes(_:)`).
    static func requests(
        in messages: [Message], requesterNodes: Set<String>, _ db: Database
    ) throws -> [Int64: PaymentRequest] {
        var requests: [Int64: PaymentRequest] = [:]
        for message in messages where message.type == MessageType.invoice {
            guard let id = message.id else { continue }
            let invoice = BodyFields.decode(message.body)?.invoice.flatMap { try? Invoice($0) }
            var request = PaymentRequest(
                invoice: invoice, state: .open,
                paysRequester: !message.fromMe && invoice.map { requesterNodes.contains($0.payee) } ?? false
            )
            if let invoice {
                request.state = message.fromMe
                    ? try requestOfOursState(invoice, chat: message.chat, db)
                    : try ourPayment(of: invoice.paymentHash, db) ?? .open
            }
            requests[id] = request
        }
        return requests
    }

    /// The nodes whose invoices pay the person in `chat`: their own, and the
    /// server nodes that make invoices for an account (`request_invoice`, as
    /// Peel and the official apps request): theirs, from the core's record
    /// of them, and ours. A server node makes them for every account it
    /// holds, so this cannot tell the requester's from another's there. Only
    /// a person (a contact key) has them; in a tribe anyone may ask.
    func requesterNodes(_ chat: String) throws -> Set<String> {
        let key = "c/\(chat)"
        let record = try pool.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM coreState WHERE key = ?", arguments: [key])
        }
        guard let record, let contact = Engine.contact(chat, in: [key: record]), contact.contactKey != nil else {
            return [chat]
        }
        var nodes: Set<String> = [chat]
        if let theirs = contact.lsp { nodes.insert(theirs) }
        if let ours = try value(for: .contactInfo).flatMap(Engine.contactInfoParts)?[1] { nodes.insert(ours) }
        return nodes
    }

    private static func requestOfOursState(_ invoice: Invoice, chat: String, _ db: Database) throws -> PaymentRequest.State {
        if let made = try Self.invoice(invoice.paymentHash, incoming: true, db) {
            if made.status == .paid { return .paid(at: made.paid) }
            if made.status == .underpaid { return .underpaid(msat: made.paidMsat) }
        }
        // The payer's message proves the sats came only with the payment it rode on.
        let payment = try Message.fetchOne(
            db,
            sql: """
                SELECT * FROM message WHERE chat = ? AND fromMe = 0 AND type = \(MessageType.invoicePayment)
                    AND paymentHash = ? AND msat >= ? ORDER BY timestamp LIMIT 1
                """,
            arguments: [chat, invoice.paymentHash, Int64(clamping: invoice.amountMsat)]
        )
        return payment.map { .paid(at: $0.date) } ?? .open
    }

    /// Our payment of someone else's invoice, as a request's state; nil when
    /// there is none.
    private static func ourPayment(of hash: String, _ db: Database) throws -> PaymentRequest.State? {
        if let ours = try Self.invoice(hash, incoming: false, db) {
            switch ours.status {
            // An invoice we pay is never underpaid; that is only ours received.
            case .pending, .open, .underpaid, .unsettled: return .paying
            case .paid: return .paid(at: ours.paid)
            case .failed:
                // Another device may have paid it since.
                if let at = try sentInHistory(hash, db) { return .paid(at: at) }
                return .failed(ours.error)
            }
        }
        return try sentInHistory(hash, db).map { .paid(at: $0) }
    }

    private static func sentInHistory(_ hash: String, _ db: Database) throws -> Date? {
        try Int64.fetchOne(
            db,
            sql: "SELECT MAX(ts) FROM payment WHERE rhash = ? AND incoming = 0 AND IFNULL(error, '') = ''",
            arguments: [hash]
        ).map(Date.init(millisecondsSince1970:))
    }

    // MARK: Paid attachments

    /// The state of each paid attachment among `messages`, by row id.
    /// One read of each chat's purchase messages, grouped by token, for all of them.
    static func purchases(in messages: [Message], _ db: Database) throws -> [Int64: PurchaseState] {
        let paid = messages.compactMap { message -> (Int64, Message, String)? in
            guard let id = message.id, message.attachmentPriceMsat != nil,
                  let token = AttachmentFields.decode(message.body)?.mediaToken else { return nil }
            return (id, message, token)
        }
        guard !paid.isEmpty else { return [:] }
        var related: [String: [String: [Message]]] = [:]
        for chat in Set(paid.map(\.1.chat)) {
            related[chat] = Dictionary(grouping: try purchaseMessages(in: chat, db)) {
                AttachmentFields.decode($0.body)?.mediaToken ?? ""
            }
        }
        var states: [Int64: PurchaseState] = [:]
        for (id, message, token) in paid {
            states[id] = purchaseState(of: message, related: related[message.chat]?[token] ?? [])
        }
        return states
    }

    public func purchaseState(of attachment: Message) throws -> PurchaseState? {
        guard attachment.attachmentPriceMsat != nil else { return nil }
        return try pool.read { db in try Self.purchaseState(of: attachment, db) }
    }

    /// The purchase messages of one chat, oldest first (`message_purchase`).
    private static func purchaseMessages(in chat: String, _ db: Database) throws -> [Message] {
        try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM message WHERE chat = ? AND deleted = 0
                    AND type IN (\(MessageType.purchase), \(MessageType.purchaseAccept), \(MessageType.purchaseDeny))
                ORDER BY timestamp, id
                """,
            arguments: [chat]
        )
    }

    /// The purchase messages of one chat that name this media token.
    private static func purchaseMessages(token: String, chat: String, _ db: Database) throws -> [Message] {
        try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM message WHERE chat = ? AND deleted = 0
                    AND type IN (\(MessageType.purchase), \(MessageType.purchaseAccept), \(MessageType.purchaseDeny))
                    AND json_valid(body) AND json_extract(body, '$.mediaToken') = ?
                ORDER BY timestamp, id
                """,
            arguments: [chat, token]
        )
    }

    static func purchaseState(of attachment: Message, _ db: Database) throws -> PurchaseState {
        guard let token = AttachmentFields.decode(attachment.body)?.mediaToken else { return .locked }
        return purchaseState(of: attachment, related: try purchaseMessages(token: token, chat: attachment.chat, db))
    }

    /// From the purchase messages naming its token, oldest first.
    private static func purchaseState(of attachment: Message, related: [Message]) -> PurchaseState {
        if attachment.fromMe {
            return .forSale(purchases: related.filter { !$0.fromMe && $0.type == MessageType.purchase }.count)
        }
        // Only the seller's side of the chat answers; the key decides.
        if related.contains(where: { !$0.fromMe && $0.type == MessageType.purchaseAccept && $0.hasMediaKey }) {
            return .unlocked
        }
        guard let ours = related.last(where: { $0.fromMe && $0.type == MessageType.purchase }) else { return .locked }
        if related.contains(where: { !$0.fromMe && $0.type == MessageType.purchaseDeny && $0.date >= ours.date }) {
            return .denied
        }
        return ours.delivery == .failed ? .failed : .processing
    }

    /// The seller's answer with the key for an attachment bought here: the
    /// key and the token it is for.
    func purchasedKey(for attachment: Message) throws -> String? {
        guard let token = AttachmentFields.decode(attachment.body)?.mediaToken else { return nil }
        return try pool.read { db in
            try Self.purchaseMessages(token: token, chat: attachment.chat, db)
                .last { !$0.fromMe && $0.type == MessageType.purchaseAccept && $0.hasMediaKey }
                .flatMap { AttachmentFields.decode($0.body)?.mediaKey }
        }
    }

    /// Whether a purchase of ours has had its answer from here, or another
    /// device: a key sent for that token after it, or a refund after it.
    func isAnswered(purchase: Message, token: String) throws -> Bool {
        try pool.read { db in
            try Self.purchaseMessages(token: token, chat: purchase.chat, db).contains {
                $0.fromMe && ($0.type == MessageType.purchaseAccept
                    || ($0.type == MessageType.purchaseDeny && $0.date >= purchase.date))
            }
        }
    }

    /// One of our own paid attachments in a chat, by its media token.
    func ownAttachment(token: String, in chat: String) throws -> Message? {
        try pool.read { db in
            try Message.fetchOne(
                db,
                sql: """
                    SELECT * FROM message WHERE chat = ? AND fromMe = 1 AND type = \(MessageType.attachment)
                        AND deleted = 0 AND json_valid(body) AND json_extract(body, '$.mediaToken') = ?
                    LIMIT 1
                    """,
                arguments: [chat, token]
            )
        }
    }

    /// Payments and boosts of ours, and anyone's that brought this account
    /// sats, as the history shows them. Requests are not payments, and our
    /// own copy of an invoice payment (type 3) is the invoice's row.
    private static let moneyMessagesSQL = """
        type IN (\(MessageType.sqlList(MessageType.moneySends + [MessageType.invoicePayment])))
            AND ((fromMe = 1 AND type != \(MessageType.invoicePayment)) OR (fromMe = 0 AND msat > 0))
        """

    /// Anything of ours posted to a tribe: every tribe message pays the
    /// tribe (`Engine.deliver`), so the server has a row for it. Free
    /// messages never match a row, so they never show.
    private static let tribeMessagesSQL = "fromMe = 1 AND chat IN (SELECT pubkey FROM tribe)"

    /// How far apart a payment's server row and its message may be when
    /// they are paired by time rather than by hash.
    static let pairingWindowMsat: Int64 = 3_000

    /// The core's price of a ping (`PING_PRICE` in `ping/asyncpay.rs`).
    static let pingPriceMsat: Int64 = 1000

    static func paymentItems(limit: Int, _ db: Database) throws -> [PaymentItem] {
        // A payment's ping is part of its cost, not a line of its own.
        let server = try PaymentRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM payment WHERE rhash NOT IN (SELECT rhash FROM paymentPing)
                ORDER BY ts DESC, rhash LIMIT ?
                """,
            arguments: [limit]
        )
        // Our own rows older than a full page wait for that page.
        let floor = server.count >= limit ? server.last?.ts ?? 0 : 0
        let hashes = Array(Set(server.map(\.rhash)))
        let indexes = Array(Set(server.compactMap(\.msgIndex)))

        // What the server's rows are about.
        let joined = try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM message WHERE ((\(moneyMessagesSQL)) OR (\(tribeMessagesSQL))) AND (
                    paymentHash IN (SELECT value FROM json_each(?))
                    OR (fromMe = 0 AND serverIndex IN (SELECT value FROM json_each(?))))
                """,
            arguments: [json(hashes), json(indexes)]
        )
        let joinedInvoices = try InvoiceRecord.fetchAll(
            db, sql: "SELECT * FROM invoice WHERE paymentHash IN (SELECT value FROM json_each(?))",
            arguments: [json(hashes)]
        )

        // Ours the server has no row for yet.
        let unlisted = try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM message m WHERE \(moneyMessagesSQL) AND IFNULL(timestamp, 0) >= ?
                    AND NOT EXISTS (SELECT 1 FROM payment p WHERE p.rhash = m.paymentHash)
                    AND NOT (m.fromMe = 0 AND EXISTS (SELECT 1 FROM payment p WHERE p.msgIndex = m.serverIndex))
                ORDER BY timestamp DESC LIMIT ?
                """,
            arguments: [floor, limit]
        )
        let unlistedInvoices = try InvoiceRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM invoice i WHERE (incoming = 0 OR status IN ('COMPLETE', 'UNDERPAID'))
                    AND COALESCE(paidAt, createdAt) >= ?
                    AND NOT EXISTS (SELECT 1 FROM payment p WHERE p.rhash = i.paymentHash AND p.incoming = i.incoming)
                ORDER BY COALESCE(paidAt, createdAt) DESC LIMIT ?
                """,
            arguments: [floor, limit]
        )

        // Looked up by index (theirs), payment hash and direction.
        let byIndex = Dictionary(
            joined.compactMap { m in m.fromMe ? nil : m.serverIndex.map { ($0, m) } }, uniquingKeysWith: { a, _ in a }
        )
        let byHash = Dictionary(
            joined.compactMap { m in m.paymentHash.map { (MoneyKey($0, m.fromMe), m) } }, uniquingKeysWith: { a, _ in a }
        )
        let invoices = Dictionary(
            joinedInvoices.map { (MoneyKey($0.paymentHash, !$0.incoming), $0) }, uniquingKeysWith: { a, _ in a }
        )
        let paired = try pairedByTime(
            server.filter { row in
                let key = MoneyKey(row.rhash, !row.incoming)
                return !row.incoming && byHash[key] == nil && invoices[key] == nil
            },
            db
        )
        let pairedIDs = Set(paired.values.compactMap(\.id))
        let context = try HistoryContext(
            messages: joined + unlisted + paired.values, invoices: joinedInvoices + unlistedInvoices, db
        )
        // A payment's 1-sat ping is counted with it, for this page only.
        var pings: [String: Int64] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT g.forHash, SUM(p.amountMsat) AS amount FROM paymentPing g
                JOIN payment p ON p.rhash = g.rhash AND p.incoming = 0 AND IFNULL(p.error, '') = ''
                WHERE g.forHash IN (SELECT value FROM json_each(?))
                GROUP BY g.forHash
                """,
            arguments: [json(hashes + unlisted.compactMap(\.paymentHash) + unlistedInvoices.map(\.paymentHash))]
        ) {
            pings[row["forHash"]] = row["amount"]
        }
        var items: [PaymentItem] = []
        for row in server {
            let key = MoneyKey(row.rhash, !row.incoming)
            let message = row.incoming
                ? row.msgIndex.flatMap { byIndex[$0] } ?? byHash[key]
                : byHash[key] ?? paired[PaymentKey(row)]
            let invoice = invoices[key]
            var item = context.item(
                id: "server/\(row.rhash)/\(row.incoming)/\(row.ts)", message: message, invoice: invoice,
                incoming: row.incoming, amountMsat: row.amountMsat, timestamp: row.ts, paymentHash: row.rhash
            )
            // The server's word on how it went wins; ours only while it is on its way.
            if row.failed {
                item.status = .failed
                item.error = row.error
            } else if item.status == .failed {
                item.status = .complete
                item.error = nil
            }
            if let invoice, !invoice.incoming, row.amountMsat >= invoice.amountMsat {
                item.feeMsat = row.amountMsat - invoice.amountMsat
            }
            items.append(item)
        }
        // An invoice's payment and its type 3 message are one payment.
        var shown = Set<String>()
        let unlistedByHash = Dictionary(
            unlisted.compactMap { m in m.paymentHash.map { (MoneyKey($0, m.fromMe), m) } }, uniquingKeysWith: { a, _ in a }
        )
        for invoice in unlistedInvoices {
            shown.insert(invoice.paymentHash)
            let message = unlistedByHash[MoneyKey(invoice.paymentHash, !invoice.incoming)]
            items.append(context.item(
                id: "invoice/\(invoice.id)", message: message, invoice: invoice, incoming: invoice.incoming,
                amountMsat: invoice.incoming ? invoice.paidMsat ?? invoice.amountMsat : invoice.amountMsat,
                timestamp: invoice.paidAt ?? invoice.createdAt, paymentHash: invoice.paymentHash
            ))
        }
        for message in unlisted where !(message.paymentHash.map(shown.contains) ?? false)
            && !(message.id.map(pairedIDs.contains) ?? false) {
            items.append(context.item(
                id: "message/\(message.id ?? 0)", message: message, invoice: nil, incoming: !message.fromMe,
                amountMsat: message.amountMsat ?? message.msat ?? 0, timestamp: message.timestamp ?? 0,
                paymentHash: message.paymentHash
            ))
        }
        for index in items.indices where !items[index].incoming {
            items[index].pingMsat = items[index].paymentHash.flatMap { pings[$0] }
        }
        foldUnrecordedPings(&items)
        return items.sorted { ($0.timestamp, $0.id) > ($1.timestamp, $1.id) }
    }

    /// One outgoing row of the server's history.
    private struct PaymentKey: Hashable {
        let rhash: String
        let ts: Int64
        init(_ row: PaymentRecord) { (rhash, ts) = (row.rhash, row.ts) }
    }

    /// Outgoing rows with no message by hash, paired with what we posted to
    /// a tribe at the same moment that has no payment hash: sent from another
    /// device (the tribe's copy carries no payment) or by Peel before it kept
    /// the hash. Only a pair that is the one candidate on both sides counts,
    /// and the amount must be what it cost: the msat stored, else the
    /// tribe's price for a message, or for a payment what it declared plus
    /// at most that price.
    private static func pairedByTime(_ rows: [PaymentRecord], _ db: Database) throws -> [PaymentKey: Message] {
        guard !rows.isEmpty else { return [:] }
        let candidates = try Message.fetchAll(
            db,
            sql: """
                SELECT DISTINCT m.* FROM json_each(?) j JOIN tribe t JOIN message m
                    ON m.chat = t.pubkey AND m.timestamp BETWEEN j.value - ? AND j.value + ?
                WHERE m.fromMe = 1 AND m.paymentHash IS NULL
                """,
            arguments: [json(rows.map(\.ts)), pairingWindowMsat, pairingWindowMsat]
        )
        guard !candidates.isEmpty else { return [:] }
        let tribes = Dictionary(
            try Tribe.fetchAll(db, keys: Set(candidates.map(\.chat))).map { ($0.pubkey, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var paired: [PaymentKey: Message] = [:]
        for (row, message) in uniquePairs(rows, candidates, matching: { row, message in
            guard let at = message.timestamp, abs(at - row.ts) <= pairingWindowMsat,
                  let tribe = tribes[message.chat] else { return false }
            if let msat = message.msat { return msat == row.amountMsat }
            guard MessageType.moneySends.contains(message.type) else {
                return row.amountMsat == Int64(clamping: tribe.messageAmountMsat)
            }
            let declared = UInt64(clamping: message.amountMsat ?? 0)
            guard let most = Engine.boostTotalMsat(tipMsat: declared, in: tribe) else { return false }
            return (declared...most).contains(UInt64(clamping: row.amountMsat))
        }) {
            paired[PaymentKey(row)] = message
        }
        return paired
    }

    /// The 1-sat ping an asynchronous payment (to a contact, never a tribe)
    /// sent before Peel recorded pings: an outgoing 1-sat row tied to nothing,
    /// sent with exactly one such payment of ours and it with exactly one
    /// such row, is counted in that payment.
    private static func foldUnrecordedPings(_ items: inout [PaymentItem]) {
        let loose = items.filter {
            $0.kind == .keysend && !$0.incoming && $0.status == .complete && $0.amountMsat == pingPriceMsat
        }
        let payments = items.filter { $0.isToContact && $0.status != .failed && $0.pingMsat == nil }
        let pairs = uniquePairs(loose, payments) { ping, payment in
            guard let sent = payment.message?.timestamp else { return false }
            return abs(sent - ping.timestamp) <= pairingWindowMsat
        }
        guard !pairs.isEmpty else { return }
        let folded = Set(pairs.map(\.0.id))
        let pinged = Set(pairs.map(\.1.id))
        items.removeAll { folded.contains($0.id) }
        for index in items.indices where pinged.contains(items[index].id) {
            items[index].pingMsat = pingPriceMsat
        }
    }

    /// The pairs where each side matches only the other.
    static func uniquePairs<A, B>(_ a: [A], _ b: [B], matching: (A, B) -> Bool) -> [(A, B)] {
        let matches = a.map { x in b.indices.filter { matching(x, b[$0]) } }
        var counts = [Int](repeating: 0, count: b.count)
        for list in matches { for j in list { counts[j] += 1 } }
        return a.indices.compactMap { i in
            guard matches[i].count == 1, let j = matches[i].first, counts[j] == 1 else { return nil }
            return (a[i], b[j])
        }
    }

    /// A payment hash and whether it went out from here.
    private struct MoneyKey: Hashable {
        let hash: String
        let outgoing: Bool
        init(_ hash: String, _ outgoing: Bool) { (self.hash, self.outgoing) = (hash, outgoing) }
    }

    private static func json(_ values: [some Encodable]) -> String {
        (try? String(decoding: JSONEncoder().encode(values), as: UTF8.self)) ?? "[]"
    }

    /// Names, tribes and boosted messages for a page of history, read once.
    private struct HistoryContext {
        var contacts: [String: (alias: String?, photoURL: String?)] = [:]
        var tribes: [String: Tribe] = [:]
        var boosted: [String: Message] = [:]

        init(messages: [Message], invoices: [InvoiceRecord], _ db: Database) throws {
            let chats = Array(Set(messages.map(\.chat) + invoices.compactMap(\.chat)))
            guard !chats.isEmpty else { return }
            let list = Storage.json(chats)
            for row in try Row.fetchAll(
                db, sql: "SELECT pubkey, alias, photoURL FROM contact WHERE pubkey IN (SELECT value FROM json_each(?))",
                arguments: [list]
            ) {
                let photo: String? = row["photoURL"]
                contacts[row["pubkey"]] = (row["alias"], photo?.httpsOnly)
            }
            for tribe in try Tribe.fetchAll(
                db, sql: "SELECT * FROM tribe WHERE pubkey IN (SELECT value FROM json_each(?))", arguments: [list]
            ) {
                tribes[tribe.pubkey] = tribe
            }
            let boostedUUIDs = messages.filter { $0.type == MessageType.boost }.compactMap(\.replyUUID)
            if !boostedUUIDs.isEmpty {
                for parent in try Message.fetchAll(
                    db, sql: "SELECT * FROM message WHERE uuid IN (SELECT value FROM json_each(?))",
                    arguments: [Storage.json(boostedUUIDs)]
                ) where messages.contains(where: { $0.replyUUID == parent.uuid && $0.chat == parent.chat }) {
                    if let uuid = parent.uuid { boosted[uuid] = parent }
                }
            }
        }

        func item(
            id: String, message: Message?, invoice: InvoiceRecord?, incoming: Bool, amountMsat: Int64,
            timestamp: Int64, paymentHash: String?
        ) -> PaymentItem {
            var item = PaymentItem(
                id: id, kind: .keysend, incoming: incoming, amountMsat: amountMsat, timestamp: timestamp,
                status: .complete, paymentHash: paymentHash, message: message, invoice: invoice
            )
            if let invoice {
                item.kind = .invoice
                item.note = invoice.memo.nilIfEmpty
                item.chat = invoice.chat
                switch invoice.status {
                case .pending, .open, .unsettled: item.status = .pending
                case .failed: item.status = .failed; item.error = invoice.error
                case .paid: break
                case .underpaid:
                    item.note = "Partly paid: " + (invoice.paidMsat.map { Sats.format(msat: $0, of: invoice.amountMsat) }
                        ?? "an unknown amount of \(Sats.format(msat: invoice.amountMsat))")
                }
            }
            if let message {
                switch message.type {
                case MessageType.boost: item.kind = .boost
                case MessageType.directPayment: item.kind = .payment
                case MessageType.purchase, MessageType.purchaseDeny: item.kind = .purchase
                case MessageType.invoice, MessageType.invoicePayment: item.kind = .invoice
                // Anything else ours in a tribe: what posting it cost.
                default: item.kind = .messageFee
                }
                item.chat = message.chat
                // A fee's message is shown whole, not as a note.
                if message.type != MessageType.invoicePayment, item.kind != .messageFee {
                    item.note = message.content?.nilIfEmpty
                }
                if invoice == nil, message.fromMe {
                    switch message.delivery {
                    case .pending, .unsettled: item.status = .pending
                    case .failed: item.status = .failed
                    case .delivered, nil: break
                    }
                }
                item.boosted = message.replyUUID.flatMap { boosted[$0] }
            }
            guard let chat = item.chat else { return item }
            if let tribe = tribes[chat] {
                item.isTribe = true
                item.chatName = tribe.displayName
                // In a tribe the sender key is the tribe's: name the member,
                // who sent it, or wrote the message we boosted.
                let member = message?.fromMe == false ? message : item.boosted
                if member?.fromMe == false {
                    item.counterpart = member?.senderAlias
                    item.counterpartPhotoURL = member?.senderPhotoURL
                }
            } else {
                let contact = contacts[chat]
                item.chatName = contact?.alias?.nilIfEmpty ?? String(chat.prefix(12))
                item.counterpart = item.chatName
                item.counterpartPhotoURL = contact?.photoURL
            }
            return item
        }
    }
}
