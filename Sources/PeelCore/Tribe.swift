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
        isOwner: Bool = false, left: Bool = false
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

/// What a new tribe is created with, as the official apps send it. Prices
/// are in msat, as the tribes server keeps them.
public struct NewTribe: Encodable, Sendable {
    public var name: String
    public var summary: String?
    public var pricePerMessageMsat: UInt64
    public var priceToJoinMsat: UInt64
    /// Staked with every message and paid back later.
    public var escrowMsat: UInt64
    /// Members need the owner's approval.
    public var isPrivate: Bool
    /// Not shown in the tribes server's public listing.
    public var unlisted: Bool
    /// Set by the engine to this account's alias.
    var ownerAlias = ""

    public init(
        name: String, summary: String? = nil, pricePerMessageMsat: UInt64 = 0, priceToJoinMsat: UInt64 = 0,
        escrowMsat: UInt64 = 0, isPrivate: Bool = false, unlisted: Bool = false
    ) {
        self.name = name
        self.summary = summary
        self.pricePerMessageMsat = pricePerMessageMsat
        self.priceToJoinMsat = priceToJoinMsat
        self.escrowMsat = escrowMsat
        self.isPrivate = isPrivate
        self.unlisted = unlisted
    }

    enum CodingKeys: String, CodingKey {
        case name, unlisted
        case summary = "description"
        case pricePerMessageMsat = "price_per_message"
        case priceToJoinMsat = "price_to_join"
        case escrowMsat = "escrow_amount"
        case isPrivate = "private"
        case ownerAlias = "owner_alias"
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
              let pubkey = value("pubkey"), pubkey.count == 66, pubkey.allSatisfy(\.isHexDigit),
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

    enum CodingKeys: String, CodingKey {
        case pubkey, name, img, deleted
        case routeHint = "route_hint"
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

    /// Plain http only for a loopback host, as for the MQTT server.
    public static func fetch(pubkey: String, host: String) async throws -> TribeInfo {
        guard TribeLink.isPlainHost(host) else { throw PeelError("unreadable tribes host \(host)") }
        let scheme = ServerAddress.isLoopback(host: host.split(separator: ":").first.map(String.init) ?? host)
            ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)/tribes/\(pubkey)") else {
            throw PeelError("unreadable tribes host \(host)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PeelError("the tribes server does not know this tribe")
        }
        let info = try JSONDecoder().decode(TribeInfo.self, from: data)
        guard info.pubkey == pubkey else { throw PeelError("the tribes server answered for a different tribe") }
        return info
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
    }
}

/// Aliases in tribes: letters, digits and underscores, spaces as underscores,
/// as the official apps send them.
func tribeAlias(_ alias: String) -> String {
    let fixed = String(alias.replacingOccurrences(of: " ", with: "_").filter {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
    })
    return fixed.isEmpty ? "Unknown" : fixed
}
