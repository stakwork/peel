import Foundation
import GRDB

/// What the person granted an app, or on the iPhone an org (strut's
/// specs/WALLET.md §5): the methods, the notification types, a budget and
/// its renewal, an expiry, and what to do over budget. Kept on this device
/// in the account's database, beside the payments its budget counts, so the
/// count and the payment are one write (docs/app-wallet.md, "Decided").
public struct WalletConnection: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "walletConnection"

    public enum OverBudget: String, Codable, Sendable, CaseIterable {
        /// A payment sheet for each payment over budget (the default).
        case ask
        /// `QUOTA_EXCEEDED`, and the wallet is never asked.
        case refuse
    }

    /// `WalletScope.key`: `app:<peer>/<name>` on the Mac, `org:<peer>` on
    /// the iPhone; a stranger's public app by its seller and name on the
    /// Mac, by the origin Peel loaded on the iPhone.
    public var key: String
    /// The app as strut names it (`<peer>/<name>`), when it was granted.
    public var app: String
    /// The title shown for it in Connected apps.
    public var title: String
    /// Where it lives, as the person reads it: "Yours", "@acme", an org.
    public var place: String
    public var methods: [WalletMethod]
    public var notificationTypes: [WalletNotificationType]
    /// msat per period, fees included; nil asks for every payment.
    public var maxAmountMsat: Int64?
    public var renewal: WalletRenewal
    /// Unix seconds; nil for none.
    public var expiresAt: Int64?
    public var overBudget: OverBudget
    /// Unix seconds: a renewal is counted from here.
    public var createdAt: Int64
    /// The key the person let it sign them in with, to a public app on a box
    /// Peel is not paired with; nil for none. It only signs in: payments
    /// still come from the account.
    public var signIn: SignInKey?

    public var id: String { key }

    public init(
        key: String, app: String, title: String, place: String, methods: [WalletMethod],
        notificationTypes: [WalletNotificationType], maxAmountMsat: Int64?, renewal: WalletRenewal, expiresAt: Int64?,
        overBudget: OverBudget, createdAt: Int64, signIn: SignInKey? = nil
    ) {
        self.key = key
        self.app = app
        self.title = title
        self.place = place
        self.methods = methods
        self.notificationTypes = notificationTypes
        self.maxAmountMsat = maxAmountMsat
        self.renewal = renewal
        self.expiresAt = expiresAt
        self.overBudget = overBudget
        self.createdAt = createdAt
        self.signIn = signIn
    }

    public func isExpired(now: Int64) -> Bool { expiresAt.map { $0 <= now } ?? false }

    /// What `connect` answers: the grant as the contract shapes it.
    public var granted: JSONValue {
        var out: [String: JSONValue] = [
            "methods": .array(methods.map { .string($0.rawValue) }),
            "notification_types": .array(notificationTypes.map { .string($0.rawValue) }),
        ]
        if let maxAmountMsat {
            out["max_amount"] = .int(maxAmountMsat)
            out["renewal_period"] = .string(renewal.rawValue)
        }
        if let expiresAt { out["expires_at"] = .int(expiresAt) }
        return .object(out)
    }
}

extension Storage {
    // MARK: Connections

    public func walletConnection(key: String) throws -> WalletConnection? {
        try pool.read { db in try WalletConnection.fetchOne(db, key: key) }
    }

    public func walletConnections() throws -> [WalletConnection] {
        try pool.read { db in try WalletConnection.order(Column("createdAt")).fetchAll(db) }
    }

    /// Every connection, oldest first, re-emitted whenever one changes:
    /// Connected apps.
    public func walletConnectionUpdates() -> some AsyncSequence<[WalletConnection], any Error> {
        ValueObservation
            .tracking { db in try WalletConnection.order(Column("createdAt")).fetchAll(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    public func saveWalletConnection(_ connection: WalletConnection) throws {
        try pool.write { db in try connection.save(db) }
    }

    /// Revoked: the app must `connect` again, and ask again to sign the
    /// person in. Its payments stay in history.
    public func deleteWalletConnection(key: String) throws {
        _ = try pool.write { db in try WalletConnection.deleteOne(db, key: key) }
    }

    // MARK: Transactions

    /// What a connection's budget counts, read in `db`: its outgoing
    /// payments (`WalletRecord.entry`).
    static func walletEntries(connection: String, _ db: Database) throws -> [WalletBudget.Entry] {
        try walletRecords(connection: connection, db).compactMap(\.entry)
    }

    /// A connection's transactions, newest first; with nil, every app's.
    public func walletRecords(connection: String?) throws -> [WalletRecord] {
        try pool.read { db in try Self.walletRecords(connection: connection, db) }
    }

    /// Every app's transactions, re-emitted whenever one changes: what
    /// the wallet host's notifications come from (`EngineWallet.updates`),
    /// whichever way a payment moved (the server's live word, its records,
    /// its history).
    public func walletRecordUpdates() -> some AsyncSequence<[WalletRecord], any Error> {
        ValueObservation
            .tracking { db in try Self.walletRecords(connection: nil, db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// The keysends and invoices tagged with a connection (all of them for
    /// nil), as the wallet host reads them. A fee is known once a settled
    /// payment's history row says what left: what it paid beyond its
    /// amount, and for a keysend sent the asynchronous way its 1-sat ping.
    static func walletRecords(connection: String?, _ db: Database, now: Date = .now) throws -> [WalletRecord] {
        let filter = connection == nil ? "connection IS NOT NULL" : "connection = ?"
        let arguments: StatementArguments = connection.map { [$0] } ?? []
        let paid = """
            (SELECT MAX(p.amountMsat) FROM payment p
             WHERE p.rhash = paymentHash AND p.incoming = 0 AND IFNULL(p.error, '') = '')
            """
        var records: [WalletRecord] = []
        for row in try Row.fetchAll(db, sql: "SELECT *, \(paid) AS paidOut FROM keysend WHERE \(filter)", arguments: arguments) {
            let status = InvoiceRecord.Status(rawValue: row["status"]) ?? .pending
            let amount: Int64 = row["amountMsat"]
            let state = Self.walletState(status)
            var fees: Int64?
            if state == .settled {
                let routed = (row["paidOut"] as Int64?).map { max($0 - amount, 0) } ?? 0
                fees = routed + ((row["async"] as Bool? ?? false) ? pingPriceMsat : 0)
            }
            let hash: String = row["paymentHash"]
            records.append(WalletRecord(
                transactionID: hash, direction: .outgoing, paymentType: .keysend, state: state, paymentHash: hash,
                amountMsat: amount, feesMsat: fees, preimage: state == .settled ? (row["preimage"] as String?) : nil,
                createdAt: (row["createdAt"] as Int64) / 1000, settledAt: (row["paidAt"] as Int64?).map { $0 / 1000 },
                failureReason: state == .failed ? (row["error"] as String?)?.nilIfEmpty : nil,
                pubkey: row["pubkey"] as String?, connection: row["connection"] as String, app: (row["app"] as String?) ?? ""
            ))
        }
        for row in try Row.fetchAll(db, sql: "SELECT *, \(paid) AS paidOut FROM invoice WHERE \(filter)", arguments: arguments) {
            let status = InvoiceRecord.Status(rawValue: row["status"]) ?? .pending
            let incoming: Bool = row["incoming"]
            let amount: Int64 = row["amountMsat"]
            let expiresAt: Int64? = row["expiresAt"]
            var state = Self.walletState(status)
            if incoming, status == .open, expiresAt.map({ $0 <= now.millisecondsSince1970 }) == true { state = .expired }
            if incoming, status == .underpaid { state = .failed }
            var fees: Int64?
            if !incoming, state == .settled { fees = (row["paidOut"] as Int64?).map { max($0 - amount, 0) } }
            let hash: String = row["paymentHash"]
            records.append(WalletRecord(
                transactionID: hash, direction: incoming ? .incoming : .outgoing, paymentType: .bolt11, state: state,
                paymentHash: hash, amountMsat: incoming && state == .settled ? ((row["paidMsat"] as Int64?) ?? amount) : amount,
                feesMsat: fees, preimage: !incoming && state == .settled ? (row["preimage"] as String?) : nil,
                createdAt: (row["createdAt"] as Int64) / 1000, settledAt: (row["paidAt"] as Int64?).map { $0 / 1000 },
                expiresAt: expiresAt.map { $0 / 1000 },
                failureReason: !incoming && state == .failed ? (row["error"] as String?)?.nilIfEmpty : nil,
                invoice: row["bolt11"] as String?, description: (row["memo"] as String?)?.nilIfEmpty,
                connection: row["connection"] as String, app: (row["app"] as String?) ?? ""
            ))
        }
        return records.sorted { ($0.createdAt, $0.transactionID) > ($1.createdAt, $1.transactionID) }
    }

    private static func walletState(_ status: InvoiceRecord.Status) -> WalletRecord.State {
        switch status {
        case .open, .pending, .unsettled: .pending
        case .paid: .settled
        case .failed, .underpaid: .failed
        }
    }

    /// One keysend by its send's tag.
    public func keysend(tag: String) throws -> KeysendRecord? {
        try pool.read { db in try KeysendRecord.filter(Column("tag") == tag).fetchOne(db) }
    }

    /// One keysend by its payment hash.
    public func keysend(paymentHash: String) throws -> KeysendRecord? {
        try pool.read { db in try KeysendRecord.fetchOne(db, key: paymentHash) }
    }

    /// Writes a keysend about to be published; one with the same payment
    /// hash or tag (which the core never repeats) refuses, and with it the
    /// whole commit.
    static func insert(_ keysend: KeysendRecord, _ db: Database) throws {
        try keysend.insert(db)
    }

    /// Keeps the preimage the server sent with a send's COMPLETE, on the
    /// keysend or invoice we pay that `tag` names, only when it hashes to
    /// that payment's hash: a page is never handed a preimage that proves
    /// nothing. One kept is never written over.
    static func keepPreimage(_ preimage: String, tag: String, _ db: Database) throws {
        let preimage = preimage.lowercased()
        if let hash = try String.fetchOne(db, sql: "SELECT paymentHash FROM keysend WHERE tag = ?", arguments: [tag]),
           WalletProtocol.verifyPreimage(preimage, paymentHash: hash) {
            try db.execute(
                sql: "UPDATE keysend SET preimage = ? WHERE tag = ? AND preimage IS NULL", arguments: [preimage, tag]
            )
        }
        for hash in try String.fetchAll(
            db, sql: "SELECT paymentHash FROM invoice WHERE tag = ? AND incoming = 0", arguments: [tag]
        ) where WalletProtocol.verifyPreimage(preimage, paymentHash: hash) {
            try db.execute(
                sql: "UPDATE invoice SET preimage = ? WHERE tag = ? AND incoming = 0 AND preimage IS NULL",
                arguments: [preimage, tag]
            )
        }
    }
}
