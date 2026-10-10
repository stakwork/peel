import Foundation
import GRDB
import Sphinxrs
import Synchronization

/// A Lightning invoice as the core reads it (`parse_invoice`). Every amount
/// Peel shows or pays for an invoice comes from here, never from what a
/// message says about it.
public struct Invoice: Sendable, Equatable {
    public let bolt11: String
    public let paymentHash: String
    /// What it asks for; 0 when it names no amount.
    public let amountMsat: UInt64
    /// The node that gets paid.
    public let payee: String
    public let memo: String
    /// Nil when the invoice does not say.
    public let expiresAt: Date?
    /// `pubkey_scid` route hints, the last nearest the payee.
    public let hopHints: [String]

    /// Reads a pasted or received invoice: surrounding space, a `lightning:`
    /// prefix and upper case are tolerated.
    public init(_ text: String) throws {
        var bolt11 = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if bolt11.hasPrefix("lightning:") { bolt11.removeFirst("lightning:".count) }
        guard bolt11.hasPrefix("ln"), bolt11.count < 4096 else { throw Engine.Failure.notAnInvoice }
        let parsed = try Self.parse(bolt11)
        self.bolt11 = bolt11
        paymentHash = parsed.paymentHash
        amountMsat = parsed.value ?? 0
        payee = parsed.pubkey
        memo = parsed.description ?? ""
        expiresAt = parsed.expiry.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        hopHints = parsed.hopHints ?? []
    }

    /// BOLT 11's expiry for an invoice that names none, in seconds.
    static let defaultExpiry: TimeInterval = 3600

    public func isExpired(now: Date = .now) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// Invoices already read, by bolt11: a chat's requests are read again
    /// each time its timeline changes, and the core's parse is not free.
    private static let parsed = Mutex<[String: Parsed]>([:])

    private static func parse(_ bolt11: String) throws -> Parsed {
        if let known = parsed.withLock({ $0[bolt11] }) { return known }
        guard let json = try? Sphinxrs.parseInvoice(invoiceJson: bolt11),
              let read = JSON.decode(Parsed.self, from: json), read.paymentHash.isHash else {
            throw Engine.Failure.unreadableInvoice
        }
        parsed.withLock { cache in
            if cache.count >= 512 { cache.removeAll() }
            cache[bolt11] = read
        }
        return read
    }

    private struct Parsed: Decodable, Sendable {
        let pubkey: String
        let value: UInt64?
        let paymentHash: String
        let description: String?
        let expiry: UInt64?
        let hopHints: [String]?

        enum CodingKeys: String, CodingKey {
            case pubkey, value, description, expiry
            case paymentHash = "payment_hash"
            case hopHints = "hop_hints"
        }
    }
}

/// An invoice this account made (to receive) or paid, with where it stands.
/// Paying one is tracked like any other send of ours: by the tag the server
/// confirms, with the same statuses (`Message.Delivery`) that only move
/// forward, and asked about again on connect.
public struct InvoiceRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "invoice"

    public enum Status: String, Codable, Sendable {
        /// Made here and not paid yet.
        case open = "OPEN"
        /// Ours, on its way: it may have paid, so it is never paid again until the server says.
        case pending = "PENDING"
        /// Paid: to us (settled) or by us (the server confirmed).
        case paid = "COMPLETE"
        /// Ours, refused or never sent: nothing moved, so it may be paid again.
        case failed = "FAILED"
        /// Made here, and settled for less than it asked (the core settles
        /// whatever arrives for a known hash), or for an amount not known.
        /// Never shown as paid; the invoice cannot take the rest.
        case underpaid = "UNDERPAID"
        /// Ours: the server holds it and has not settled it, and may never
        /// (`Message.Delivery.unsettled`). Never paid again; not asked about
        /// on connect.
        case unsettled = "UNSETTLED"
    }

    public var paymentHash: String
    /// True for an invoice this account made, false for one it pays.
    public var incoming: Bool
    public var bolt11: String
    public var amountMsat: Int64
    public var memo: String
    public var payee: String
    /// Milliseconds since 1970.
    public var createdAt: Int64
    public var expiresAt: Int64?
    public var status: Status
    /// When it was paid, in milliseconds.
    public var paidAt: Int64?
    /// For one made here: what actually arrived, which the payer chose
    /// (the core settles whatever comes for a known hash).
    public var paidMsat: Int64?
    /// The send's tag, for one we pay.
    public var tag: String?
    /// The chat a payment request went to or came from; its request
    /// message (type 2) carries the same payment hash.
    public var chat: String?
    /// Why paying it failed, as the server put it.
    public var error: String?

    public var id: String { "\(incoming ? "in" : "out")/\(paymentHash)" }
    public var created: Date { Date(millisecondsSince1970: createdAt) }
    public var expires: Date? { expiresAt.map(Date.init(millisecondsSince1970:)) }
    public var paid: Date? { paidAt.map(Date.init(millisecondsSince1970:)) }
}

/// One row of the server's payment history (`fetch_payments`). Rows carry
/// no direction field: only incoming ones have a message index.
public struct PaymentRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "payment"

    public var rhash: String
    /// Milliseconds since 1970.
    public var ts: Int64
    public var amountMsat: Int64
    public var incoming: Bool
    /// The server index of the message that came with it, incoming only.
    public var msgIndex: Int64?
    /// True when it crossed the Lightning network rather than this server.
    public var remote: Bool
    public var error: String?

    public var failed: Bool { !(error ?? "").isEmpty }

    /// The server's JSON, checked: anything unreadable or out of range
    /// leaves the row out rather than showing a wrong amount.
    static func decode(_ json: String) -> [PaymentRecord] {
        struct Row: Decodable {
            let rhash: String?
            let ts: UInt64?
            let amtMsat: UInt64?
            let remote: Bool?
            let msgIdx: UInt64?
            let error: String?

            enum CodingKeys: String, CodingKey {
                case rhash, ts, remote, error
                case amtMsat = "amt_msat"
                case msgIdx = "msg_idx"
            }
        }
        guard let rows = JSON.decode([FailableDecodable<Row>].self, from: json) else { return [] }
        return rows.compactMap(\.value).compactMap { row in
            guard let rhash = row.rhash?.lowercased(), rhash.isHash, let ts = row.ts.flatMap(Int64.init(exactly:)),
                  let amount = row.amtMsat.flatMap(Int64.init(exactly:)) else { return nil }
            // A payment to an invoice the server made for us comes with index 0: no message.
            return PaymentRecord(
                rhash: rhash, ts: ts, amountMsat: amount, incoming: row.msgIdx != nil,
                msgIndex: row.msgIdx.flatMap { $0 == 0 ? nil : Int64(exactly: $0) }, remote: row.remote ?? false,
                error: row.error?.nilIfEmpty
            )
        }
    }
}

/// One element of an array that may not decode, so one bad row cannot cost the rest.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension String {
    /// 32 bytes as lowercase hex, as payment hashes and tags are written.
    var isHash: Bool { MessageUUID.isValid(self) }
}
