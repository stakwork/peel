import Foundation
import GRDB

/// A keysend this account sent for an app (docs/app-wallet.md): a payment to
/// any node or Sphinx address over the core's raw `keysend`, tracked like
/// every send of ours by the tag the server confirms, with the same
/// forward-only statuses (`Storage.applyStatus`). Its preimage is the
/// mixer's on COMPLETE, kept only when it hashes to the payment hash.
public struct KeysendRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "keysend"

    public var paymentHash: String
    public var tag: String
    /// The node paid.
    public var pubkey: String
    /// The core's route hint, `<lsp_pubkey>_<scid>`; nil for none.
    public var routeHint: String?
    /// Sent the asynchronous way (a non-legacy route hint): the server holds
    /// it until the payee comes online, and a 1-sat ping went with it.
    public var async: Bool
    public var amountMsat: Int64
    /// Milliseconds since 1970.
    public var createdAt: Int64
    public var status: InvoiceRecord.Status
    /// When it settled, in milliseconds.
    public var paidAt: Int64?
    public var preimage: String?
    /// Why it failed, as the server put it.
    public var error: String?
    /// The wallet connection it was made through (`WalletConnection.key`).
    public var connection: String?
    /// The app it was made for, as strut names it (`<peer>/<name>`).
    public var app: String?
}

/// One of an app's transactions as the wallet host reads it: a keysend or
/// an invoice paid (outgoing), or an invoice made (incoming), with the
/// connection and app it was made for. The wallet contract's shapes are
/// made from it (`payment`, `transaction`, `lookup`), and the budget counts
/// it (`entry`).
public struct WalletRecord: Sendable, Equatable {
    public enum Direction: String, Sendable { case incoming, outgoing }
    public enum PaymentType: String, Sendable { case bolt11, keysend }
    public enum State: String, Sendable { case pending, settled, failed, expired }

    /// The host's id: unique per connection, stable across lookups and
    /// notifications. Peel's is the payment hash.
    public var transactionID: String
    public var direction: Direction
    public var paymentType: PaymentType
    public var state: State
    public var paymentHash: String
    /// msat: what was paid out, or what an invoice made received (else asked).
    public var amountMsat: Int64
    /// Known only once settled, if at all.
    public var feesMsat: Int64?
    /// Only a verified one, and only once settled.
    public var preimage: String?
    /// Unix seconds.
    public var createdAt: Int64
    public var settledAt: Int64?
    public var expiresAt: Int64?
    public var failureReason: String?
    public var invoice: String?
    public var description: String?
    /// A keysend's payee.
    public var pubkey: String?
    public var connection: String
    /// `<peer>/<name>`, as strut names the app (`nativeAppKey`).
    public var app: String

    public init(
        transactionID: String, direction: Direction, paymentType: PaymentType, state: State, paymentHash: String,
        amountMsat: Int64, feesMsat: Int64? = nil, preimage: String? = nil, createdAt: Int64, settledAt: Int64? = nil,
        expiresAt: Int64? = nil, failureReason: String? = nil, invoice: String? = nil, description: String? = nil,
        pubkey: String? = nil, connection: String, app: String
    ) {
        self.transactionID = transactionID
        self.direction = direction
        self.paymentType = paymentType
        self.state = state
        self.paymentHash = paymentHash
        self.amountMsat = amountMsat
        self.feesMsat = feesMsat
        self.preimage = preimage
        self.createdAt = createdAt
        self.settledAt = settledAt
        self.expiresAt = expiresAt
        self.failureReason = failureReason
        self.invoice = invoice
        self.description = description
        self.pubkey = pubkey
        self.connection = connection
        self.app = app
    }

    /// Settled with its proof: the only settled a pay method answers
    /// (`payment`). The mixer's records and its history carry no preimage, so
    /// a payment that settled while Peel was not listening has none.
    public var provenSettled: Bool { state == .settled && preimage != nil }

    /// A pay method's answer (`Payment`): settled only with its preimage,
    /// and pending otherwise until a notification or a lookup says more;
    /// the preimage only once settled; the reason only on failure.
    public var payment: JSONValue {
        var out: [String: JSONValue] = [
            "transaction_id": .string(transactionID), "payment_hash": .string(paymentHash),
            "amount": .int(amountMsat), "created_at": .int(createdAt),
        ]
        switch state {
        case .settled where preimage != nil:
            out["state"] = .string("settled")
            out["preimage"] = preimage.map(JSONValue.string)
            out["settled_at"] = .int(settledAt ?? createdAt)
            if let feesMsat { out["fees_paid"] = .int(feesMsat) }
        case .failed:
            out["state"] = .string("failed")
            if let failureReason { out["failure_reason"] = .string(failureReason) }
        default:
            out["state"] = .string("pending")
        }
        return .object(out)
    }

    /// NWC's transaction (`lookup_invoice`, `list_transactions`, a
    /// notification's payload).
    public var transaction: JSONValue {
        var out: [String: JSONValue] = [
            "type": .string(direction.rawValue), "state": .string(state.rawValue),
            "transaction_id": .string(transactionID), "payment_hash": .string(paymentHash),
            "amount": .int(amountMsat), "created_at": .int(createdAt),
        ]
        if state == .settled {
            if let preimage { out["preimage"] = .string(preimage) }
            if let settledAt { out["settled_at"] = .int(settledAt) }
            if let feesMsat { out["fees_paid"] = .int(feesMsat) }
        }
        if state == .failed, let failureReason { out["failure_reason"] = .string(failureReason) }
        if let invoice { out["invoice"] = .string(invoice) }
        if let description { out["description"] = .string(description) }
        if let expiresAt { out["expires_at"] = .int(expiresAt) }
        return .object(out)
    }

    /// NWC-09's lookup (`lookup_payment`), with strut's `keysend` type.
    public var lookup: JSONValue {
        var details: [String: JSONValue] = ["payment_hash": .string(paymentHash)]
        if state == .settled, let preimage { details["preimage"] = .string(preimage) }
        if paymentType == .keysend {
            if let pubkey { details["pubkey"] = .string(pubkey) }
        } else {
            if let invoice { details["invoice"] = .string(invoice) }
            if let description { details["description"] = .string(description) }
        }
        var out: [String: JSONValue] = [
            "transaction_id": .string(transactionID), "type": .string(direction.rawValue),
            "state": .string(state.rawValue), "payment_type": .string(paymentType.rawValue),
            "amount": .int(amountMsat), "created_at": .int(createdAt), "details": .object(details),
        ]
        if state == .settled {
            if let settledAt { out["settled_at"] = .int(settledAt) }
            if let feesMsat { out["fees_paid"] = .int(feesMsat) }
        }
        if state == .failed, let failureReason { out["failure_reason"] = .string(failureReason) }
        if let expiresAt { out["expires_at"] = .int(expiresAt) }
        return .object(out)
    }

    /// What a budget counts of it: an outgoing payment's amount while it is
    /// pending, with its fees once settled, nothing once it failed.
    public var entry: WalletBudget.Entry? {
        guard direction == .outgoing else { return nil }
        let counted: Int64
        switch state {
        case .pending: counted = amountMsat
        case .settled: counted = amountMsat + max(feesMsat ?? 0, 0)
        case .failed, .expired: counted = 0
        }
        return WalletBudget.Entry(countedMsat: max(counted, 0), createdAt: createdAt)
    }

    /// Read back from a contract `Payment` or transaction (a scripted
    /// wallet's answer in the tests, or a notification's payload): nil when
    /// it is not one.
    public init?(payment json: JSONValue, direction: Direction = .outgoing, paymentType: PaymentType = .keysend,
                 connection: String, app: String) {
        guard case .object(let o) = json, let id = o["transaction_id"]?.string, let hash = o["payment_hash"]?.string,
              let amount = WalletProtocol.integer(o["amount"]), let created = WalletProtocol.integer(o["created_at"]),
              let state = o["state"]?.string.flatMap(State.init) else { return nil }
        self.init(
            transactionID: id, direction: direction, paymentType: paymentType, state: state, paymentHash: hash,
            amountMsat: amount, feesMsat: WalletProtocol.integer(o["fees_paid"]), preimage: o["preimage"]?.string,
            createdAt: created, settledAt: WalletProtocol.integer(o["settled_at"]),
            expiresAt: WalletProtocol.integer(o["expires_at"]), failureReason: o["failure_reason"]?.string,
            invoice: o["invoice"]?.string, description: o["description"]?.string, connection: connection, app: app
        )
    }
}

/// A connection's budget (strut's specs/WALLET.md §5.3), counted from its
/// transactions so it can never drift from what moved: a pending payment
/// counts its amount, a settled one its amount and fees, a failed one
/// nothing (the refund). Counted in the same database transaction as the
/// payment it lets through (`Storage.Commit.walletBudget`).
public enum WalletBudget {
    public struct Entry: Sendable, Equatable {
        public var countedMsat: Int64
        /// Unix seconds.
        public var createdAt: Int64

        public init(countedMsat: Int64, createdAt: Int64) {
            self.countedMsat = countedMsat
            self.createdAt = createdAt
        }
    }

    /// What a payment through a connection must fit in, checked inside the
    /// commit that writes it: nothing is published when it does not.
    public struct Guard: Sendable, Equatable {
        /// The most the period may count, the payment included; nil when the
        /// person approved this payment on its own sheet (it is counted, not
        /// limited).
        public var limitMsat: UInt64?
        /// The period's start, unix seconds: earlier payments do not count.
        public var since: Int64

        public init(limitMsat: UInt64?, since: Int64) {
            self.limitMsat = limitMsat
            self.since = since
        }

        /// Whether `amountMsat` fits beside what `entries` already count.
        public func admits(_ amountMsat: UInt64, beside entries: [Entry]) -> Bool {
            guard let limitMsat else { return true }
            let (total, overflow) = WalletBudget.used(entries, since: since).addingReportingOverflow(amountMsat)
            return !overflow && total <= limitMsat
        }
    }

    /// What the period starting at `since` (unix seconds) counts.
    public static func used(_ entries: [Entry], since: Int64) -> UInt64 {
        entries.reduce(UInt64(0)) { sum, entry in
            entry.createdAt >= since ? sum &+ UInt64(max(entry.countedMsat, 0)) : sum
        }
    }

    /// The current period of a budget renewed every `renewal` from
    /// `created` (all unix seconds): its start, and when it renews (nil for
    /// `never`). Months and years are calendar ones in UTC, a short month
    /// ending them early (a budget made on the 31st renews on the 30th).
    public static func period(created: Int64, renewal: WalletRenewal, now: Int64) -> (start: Int64, renewsAt: Int64?) {
        guard renewal != .never, now >= created else { return (created, nil) }
        let step: Int64
        switch renewal {
        case .daily: step = 86_400
        case .weekly: step = 7 * 86_400
        case .monthly, .yearly, .never:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let origin = Date(timeIntervalSince1970: TimeInterval(created))
            let unit: Calendar.Component = renewal == .monthly ? .month : .year
            let target = Date(timeIntervalSince1970: TimeInterval(now))
            var n = max(calendar.dateComponents([unit], from: origin, to: target).value(for: unit) ?? 0, 0)
            func boundary(_ k: Int) -> Int64 {
                Int64(calendar.date(byAdding: unit, value: k, to: origin)!.timeIntervalSince1970)
            }
            while boundary(n + 1) <= now { n += 1 }
            while n > 0, boundary(n) > now { n -= 1 }
            return (boundary(n), boundary(n + 1))
        }
        let k = (now - created) / step
        return (created + k * step, created + (k + 1) * step)
    }
}
