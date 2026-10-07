import Foundation
import GRDB

/// A tribe this account has joined, created or left. The tribe itself is a
/// contact in core state (its pubkey and route, no contact key); everything
/// here comes from the tribes server's registry or from the join.
public struct Tribe: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var pubkey: String
    public var name: String?
    public var photoURL: String?
    public var summary: String?
    /// The tribes server that lists this tribe, as `host[:port]`.
    public var host: String?
    /// Charged by the tribe on every message, in msat.
    public var pricePerMessageMsat: Int64
    /// Staked with every message and paid back later, in msat.
    public var escrowMsat: Int64
    public var isPrivate: Bool
    /// Only the owner can ask the tribes server for the member list.
    public var isOwner: Bool
    /// Leaving does not remove the member on the server, so a left tribe's
    /// messages keep arriving; they are dropped.
    public var left: Bool
    /// Where this account stands in the tribe, as the tribe last told it.
    public var status: Status
    /// The uuid of the message the owner pinned, from the registry.
    public var pin: String?

    /// Where this account stands in a tribe. The first three are the official
    /// apps' chat statuses; the tribe tells a member each change with a
    /// message (approve 20, reject 21, kick 16, delete 22).
    public enum Status: Int, Codable, Sendable {
        case active = 0
        /// Asked to join a private tribe; the owner has not answered.
        case pending = 1
        /// The owner declined the request to join.
        case rejected = 2
        /// The owner removed this account.
        case removed = 3
        /// The owner deleted the tribe.
        case deleted = 4
    }

    /// Whether this account can post: in the tribe and accepted.
    public var canPost: Bool { !left && status == .active }

    /// Whether this account can run the tribe: its owner, and still in it.
    public var canManage: Bool { isOwner && canPost }

    public var id: String { pubkey }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return String(pubkey.prefix(12))
    }

    /// What each message costs to send: the official apps send at least
    /// 3 sats, or the price per message plus the escrow if higher.
    public var messageAmountMsat: UInt64 {
        Self.messageAmount(pricePerMessage: pricePerMessageMsat, escrow: escrowMsat)
    }

    /// Prices come from the tribes server, so the sum saturates rather than overflows.
    static func messageAmount(pricePerMessage: Int64, escrow: Int64) -> UInt64 {
        let (sum, overflow) = max(pricePerMessage, 0).addingReportingOverflow(max(escrow, 0))
        return UInt64(max(overflow ? Int64.max : sum, 3000))
    }

    public static let databaseTableName = "tribe"

    public init(
        pubkey: String, name: String? = nil, photoURL: String? = nil, summary: String? = nil, host: String? = nil,
        pricePerMessageMsat: Int64 = 0, escrowMsat: Int64 = 0, isPrivate: Bool = false,
        isOwner: Bool = false, left: Bool = false, status: Status = .active, pin: String? = nil
    ) {
        self.pubkey = pubkey
        self.name = name
        self.photoURL = photoURL
        self.summary = summary
        self.host = host
        self.pricePerMessageMsat = pricePerMessageMsat
        self.escrowMsat = escrowMsat
        self.isPrivate = isPrivate
        self.isOwner = isOwner
        self.left = left
        self.status = status
        self.pin = pin
    }

    /// A shareable link in the official apps' format.
    public var link: String? {
        host.map { "sphinx.chat://?action=tribeV2&pubkey=\(pubkey)&host=\($0)" }
    }
}

/// Someone in a tribe. Only the owner gets the full list from the tribes
/// server; everyone else sees the people who have posted.
public struct TribeMember: Sendable, Identifiable, Equatable {
    public var alias: String
    public var photoURL: String?
    /// Known only on the owner's list.
    public var pubkey: String?
    /// Waiting for the owner's approval in a private tribe.
    public var pending: Bool

    public var id: String { pubkey ?? alias }
}

public struct TribeMembers: Sendable, Equatable {
    public var members: [TribeMember]
    /// True for the tribes server's list; false when the list is only the
    /// people seen posting.
    public var complete: Bool

    /// The tribes server's answer to `listTribeMembers` (`MemberList` in the core).
    struct List: Decodable {
        struct Entry: Decodable {
            let pubkey: String
            let alias: String
        }

        let pubkey: String
        let confirmed: [Entry]
        let pending: [Entry]
    }
}

/// What a tribe is created or edited with, as the official apps send it
/// (`getNewGroupParams` in the Mac app). Prices are in msat and the escrow
/// time in milliseconds, as the tribes server keeps them.
public struct TribeSettings: Codable, Sendable, Equatable {
    public var name: String
    public var summary: String?
    /// An https image URL.
    public var photoURL: String?
    public var pricePerMessageMsat: UInt64
    public var priceToJoinMsat: UInt64
    /// Staked with every message and paid back after `escrowMillis`.
    public var escrowMsat: UInt64
    public var escrowMillis: UInt64
    /// Members need the owner's approval.
    public var isPrivate: Bool
    /// Not shown in the tribes server's public listing.
    public var unlisted: Bool

    public init(
        name: String, summary: String? = nil, photoURL: String? = nil, pricePerMessageMsat: UInt64 = 0,
        priceToJoinMsat: UInt64 = 0, escrowMsat: UInt64 = 0, escrowMillis: UInt64 = 0,
        isPrivate: Bool = false, unlisted: Bool = false
    ) {
        self.name = name
        self.summary = summary
        self.photoURL = photoURL
        self.pricePerMessageMsat = pricePerMessageMsat
        self.priceToJoinMsat = priceToJoinMsat
        self.escrowMsat = escrowMsat
        self.escrowMillis = escrowMillis
        self.isPrivate = isPrivate
        self.unlisted = unlisted
    }

    /// Trimmed, with a name, an https image or none, and amounts the tribes
    /// server can hold (it keeps them as signed 64-bit numbers). An image
    /// the tribe already has (`currentImage`) is kept whatever its scheme, so
    /// a tribe another client gave an http image can still be edited.
    func validated(currentImage: String? = nil) throws -> TribeSettings {
        var settings = self
        settings.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        settings.photoURL = photoURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !settings.name.isEmpty else { throw PeelError("a tribe needs a name") }
        if let photo = settings.photoURL, photo != currentImage, photo.httpsOnly == nil {
            throw PeelError("the image must be an https link")
        }
        guard [pricePerMessageMsat, priceToJoinMsat, escrowMsat, escrowMillis].allSatisfy({ $0 <= UInt64(Int64.max) })
        else { throw PeelError("an amount is too large") }
        return settings
    }

    /// These settings as JSON fields, laid over `record`. The tribes server
    /// replaces a tribe's whole record on an update, so whatever Peel does
    /// not edit (tags, feeds, the pin, the owner's alias) must go back as it
    /// was. A cleared description or image is sent as null.
    func fields(over record: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PeelError("could not encode the tribe")
        }
        for key in [CodingKeys.summary, .photoURL] where fields[key.rawValue] == nil {
            fields[key.rawValue] = NSNull()
        }
        return record.merging(fields) { _, new in new }
    }

    enum CodingKeys: String, CodingKey {
        case name, unlisted
        case summary = "description"
        case photoURL = "img"
        case pricePerMessageMsat = "price_per_message"
        case priceToJoinMsat = "price_to_join"
        case escrowMsat = "escrow_amount"
        case escrowMillis = "escrow_millis"
        case isPrivate = "private"
    }
}

/// A tribe link: `sphinx.chat://?action=tribeV2&pubkey=<pubkey>&host=<host>`.
public struct TribeLink: Sendable, Equatable {
    public let pubkey: String
    public let host: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme == "sphinx.chat" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("action") == "tribeV2",
              let pubkey = value("pubkey"), pubkey.isPubkey,
              let host = value("host"), TribeLink.isPlainHost(host) else { return nil }
        self.pubkey = pubkey.lowercased()
        self.host = host
    }

    /// `name[:port]` and nothing else, so a link cannot smuggle a path or credentials.
    static func isPlainHost(_ host: String) -> Bool {
        !host.isEmpty && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }
    }
}

/// The tribes server's public registry: `GET /tribes/<pubkey>`.
public struct TribeInfo: Decodable, Sendable, Equatable {
    public let pubkey: String
    public let routeHint: String?
    public let name: String
    public let summary: String?
    public let img: String?
    public let pricePerMessage: Int64?
    public let priceToJoin: Int64?
    public let escrowAmount: Int64?
    public let isPrivate: Bool?
    public let deleted: Bool?
    public let escrowMillis: Int64?
    public let unlisted: Bool?
    /// The uuid of the message the owner pinned.
    public let pin: String?

    enum CodingKeys: String, CodingKey {
        case pubkey, name, img, deleted, unlisted, pin
        case routeHint = "route_hint"
        case escrowMillis = "escrow_millis"
        case summary = "description"
        case pricePerMessage = "price_per_message"
        case priceToJoin = "price_to_join"
        case escrowAmount = "escrow_amount"
        case isPrivate = "private"
    }

    /// What joining costs: the price to join, or 1 sat as the official apps send.
    public var joinAmountMsat: UInt64 {
        let price = priceToJoin ?? 0
        return price > 0 ? UInt64(price) : 1000
    }

    /// What each message will cost once joined; see `Tribe.messageAmountMsat`.
    public var messageAmountMsat: UInt64 {
        Tribe.messageAmount(pricePerMessage: pricePerMessage ?? 0, escrow: escrowAmount ?? 0)
    }

    /// What the tribe is set to, to start an edit from.
    public var settings: TribeSettings {
        func amount(_ value: Int64?) -> UInt64 { UInt64(max(value ?? 0, 0)) }
        return TribeSettings(
            name: name, summary: summary?.nilIfEmpty, photoURL: img?.nilIfEmpty,
            pricePerMessageMsat: amount(pricePerMessage), priceToJoinMsat: amount(priceToJoin),
            escrowMsat: amount(escrowAmount), escrowMillis: amount(escrowMillis),
            isPrivate: isPrivate ?? false, unlisted: unlisted ?? false
        )
    }

    public static func fetch(pubkey: String, host: String) async throws -> TribeInfo {
        let info = try JSONDecoder().decode(TribeInfo.self, from: try await record(pubkey: pubkey, host: host))
        guard info.pubkey == pubkey else { throw PeelError("the tribes server answered for a different tribe") }
        return info
    }

    /// `GET /tribes/<pubkey>`, as the server sent it. Plain http only for a
    /// loopback host, as for the MQTT server.
    static func record(pubkey: String, host: String) async throws -> Data {
        guard TribeLink.isPlainHost(host) else { throw PeelError("unreadable tribes host \(host)") }
        let scheme = ServerAddress.isLoopback(host: host.split(separator: ":").first.map(String.init) ?? host)
            ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)/tribes/\(pubkey)") else {
            throw PeelError("unreadable tribes host \(host)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NotServed(status: status) }
        return data
    }

    /// The registry answered without the tribe. A deleted or unknown tribe
    /// is answered with 404, or 500 by the current tribes server (its
    /// "not found" has no handler).
    struct NotServed: Error, CustomStringConvertible {
        let status: Int
        var isGone: Bool { status == 404 || status == 500 }
        var description: String { "the tribes server does not know this tribe" }
    }
}

extension Tribe {
    /// Takes what the registry says, keeping what only this account knows.
    mutating func update(from info: TribeInfo) {
        name = info.name
        photoURL = info.img?.httpsOnly
        summary = info.summary
        pricePerMessageMsat = max(info.pricePerMessage ?? 0, 0)
        escrowMsat = max(info.escrowAmount ?? 0, 0)
        isPrivate = info.isPrivate ?? false
        pin = info.pin?.nilIfEmpty
    }
}

/// An amount someone typed, in a unit bigger than the one sent: sats for
/// msat (1000), hours for milliseconds (3,600,000). Decimals are fine as long
/// as the result is a whole number of the smaller unit ("1.5" sats is
/// 1500 msat); blank is zero. Capped at what the tribes server can hold.
public func amount(_ text: String, unit: UInt64, of what: String) throws -> UInt64 {
    let text = text.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return 0 }
    guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), text.filter({ $0 == "." }).count <= 1,
          let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
        throw PeelError("the \(what) must be a number")
    }
    let scaled = value * Decimal(unit)
    guard scaled <= Decimal(Int64.max) else { throw PeelError("the \(what) is too large") }
    var whole = Decimal()
    var copy = scaled
    NSDecimalRound(&whole, &copy, 0, .plain)
    guard whole == scaled else { throw PeelError("the \(what) is finer than the network can carry") }
    return UInt64(truncating: whole as NSDecimalNumber)
}

/// A mention is `@alias` written as its own word in a tribe message; no
/// other field marks it. The tribes server splits the text on spaces and
/// matches member aliases exactly (`detect_mentions`) to decide who gets a
/// push, so Peel reads mentions the same way.
public func mentions(_ text: String, alias: String) -> Bool {
    let tag = "@" + alias
    return text.contains(tag) && text.split(whereSeparator: \.isWhitespace).contains { $0 == tag }
}

extension String {
    /// A compressed public key in hex, as Sphinx names accounts and tribes.
    public var isPubkey: Bool { count == 66 && allSatisfy(\.isHexDigit) }
}

/// Aliases in tribes: letters, digits and underscores, spaces as underscores,
/// as the official apps send them.
func tribeAlias(_ alias: String) -> String {
    let fixed = String(alias.replacingOccurrences(of: " ", with: "_").filter {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
    })
    return fixed.isEmpty ? "Unknown" : fixed
}
