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
    /// The tribe's web app and second brain, from the registry: http or
    /// https only (`WebPage.address`), opened in the web pane.
    public var appURL: String?
    public var secondBrainURL: String?

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

    /// What a message of `type` costs to send: a call only the 3-sat floor,
    /// because the tribes server charges no price for one
    /// (`type_that_need_ppm` in `tribes/src/forward.rs`).
    public func messageAmountMsat(type: Int) -> UInt64 {
        type == MessageType.call ? Self.messageAmount(pricePerMessage: 0, escrow: 0) : messageAmountMsat
    }

    /// What a payment or boost to the tribe pays on top of its own amount:
    /// price plus escrow, with no 3-sat floor (the Mac app's boost).
    public var paymentPriceMsat: UInt64 {
        Self.messageAmount(pricePerMessage: pricePerMessageMsat, escrow: escrowMsat, floor: 0)
    }

    /// Prices come from the tribes server, so the sum saturates rather than overflows.
    static func messageAmount(pricePerMessage: Int64, escrow: Int64, floor: Int64 = 3000) -> UInt64 {
        let (sum, overflow) = max(pricePerMessage, 0).addingReportingOverflow(max(escrow, 0))
        return UInt64(max(overflow ? Int64.max : sum, floor))
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
        var pending: [Entry]
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
        guard !settings.name.isEmpty else { throw Engine.Failure.tribeNeedsName }
        if let photo = settings.photoURL, photo != currentImage, photo.httpsOnly == nil {
            throw Engine.Failure.tribeImageNotHTTPS
        }
        guard [pricePerMessageMsat, priceToJoinMsat, escrowMsat, escrowMillis].allSatisfy({ $0 <= UInt64(Int64.max) })
        else { throw Engine.Failure.amountTooLarge }
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

    /// `name[:port]` and nothing else, so a link cannot smuggle a path or
    /// credentials. ASCII only (an international name in its `xn--` form):
    /// `URL` maps other letters and digits onto ASCII ones, so a full-width
    /// `１２７.０.０.１` would pass here as a name and be fetched as 127.0.0.1.
    static func isPlainHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || ".-:".utf8.contains(byte)
        }
    }

    /// Where to reach a plain `host[:port]`: http for this machine, https for
    /// everything else. Nil for anything that is not a plain host.
    static func baseURL(_ host: String) -> URL? {
        guard isPlainHost(host) else { return nil }
        return URL(string: "\(isLoopback(host) ? "http" : "https")://\(host)")
    }

    /// Whether a plain `host[:port]` is this machine.
    static func isLoopback(_ host: String) -> Bool {
        ServerAddress.isLoopback(host: host.split(separator: ":").first.map(String.init) ?? host)
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
    /// The tribe's web app and second brain, as the owner typed them. Only
    /// read: an edit sends back the record as the server had it
    /// (`TribeSettings.fields(over:)`).
    public let appURL: String?
    public let secondBrainURL: String?

    enum CodingKeys: String, CodingKey {
        case pubkey, name, img, deleted, unlisted, pin
        case appURL = "app_url"
        case secondBrainURL = "second_brain_url"
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
        guard info.pubkey == pubkey else { throw Engine.Failure.tribeServerMismatch }
        return info
    }

    /// `GET /tribes/<pubkey>`, as the server sent it. Plain http only for a
    /// loopback host, as for the MQTT server; otherwise a public host, as the
    /// host comes from a link someone else may have sent.
    static func record(pubkey: String, host: String) async throws -> Data {
        guard let url = TribeLink.baseURL(host)?.appendingPathComponent("tribes/\(pubkey)") else {
            throw Engine.Failure.unreadableTribeHost(host)
        }
        do {
            return try await Web.get(url, limit: 1_000_000, what: "the tribe")
        } catch Web.Failure.refused(_, let status) {
            throw NotServed(status: status)
        }
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
    /// Private only when `trustingPrivacy`: the record came from the
    /// account's own tribes host (`Engine.isOwnTribeHost`). Any other host
    /// could mark a public tribe private and have Peel send the time zone to
    /// its members, so a tribe read there counts as public (audit C, finding
    /// 4; Tom, 2026-10-09).
    mutating func update(from info: TribeInfo, trustingPrivacy: Bool) {
        name = info.name
        photoURL = info.img?.httpsOnly
        summary = info.summary
        pricePerMessageMsat = max(info.pricePerMessage ?? 0, 0)
        escrowMsat = max(info.escrowAmount ?? 0, 0)
        isPrivate = trustingPrivacy && info.isPrivate == true
        pin = info.pin?.nilIfEmpty
        appURL = WebPage.address(info.appURL)?.absoluteString
        secondBrainURL = WebPage.address(info.secondBrainURL)?.absoluteString
    }
}

/// A mention is `@alias` in a tribe message's text; no other field marks it.
/// The official apps insert `@alias ` from their autocomplete, and they and
/// the tribes server disagree on how strictly to read it: the server pushes
/// only for an exact word between spaces, the Mac app's badge is any
/// case-insensitive `@alias` in the text. Peel reads it as people write it:
/// any case, after a space or the start, and ended by anything an alias
/// cannot contain (so "@Tom_Smith," and "@tom_smith:" count, "@Tom_Smith_2"
/// and "mail@Tom_Smith" do not).
public func mentions(_ text: String, aliases: some Collection<String>) -> Bool {
    guard text.contains("@") else { return false }
    let words = aliases.filter { !$0.isEmpty }.map { "@" + $0.lowercased() }
    let lower = text.lowercased()
    for word in words {
        var from = lower.startIndex
        while let found = lower.range(of: word, range: from..<lower.endIndex) {
            let before = found.lowerBound == lower.startIndex || !isAliasCharacter(lower[lower.index(before: found.lowerBound)])
            let after = found.upperBound == lower.endIndex || !isAliasCharacter(lower[found.upperBound])
            if before && after { return true }
            from = found.upperBound
        }
    }
    return false
}

/// What a mention of this account looks like in one tribe, for its chip: the
/// aliases the mention scan reads (`ownTribeAliases` of its name and what the
/// tribe echoed back), and "all". @all is styled as a mention of you but, as
/// in the official apps, not counted as one (`mentionsMe` leaves it out).
public func ownMentionAliases(name: String, echoed: Set<String>) -> Set<String> {
    ownTribeAliases(sent: tribeAlias(name), echoed: echoed).union(["all"])
}

private func isAliasCharacter(_ c: Character) -> Bool {
    c.isASCII && (c.isLetter || c.isNumber || c == "_")
}

/// The aliases that name this account in one tribe. Members know it by what
/// the tribe forwarded, and the tribe echoes that back on this account's own
/// messages: the alias it was sent with, or `name_2` when the tribes server
/// made it unique because another member already had the name (who then owns
/// the plain one; the server only ever appends `_2`), or an earlier name
/// (kept on purpose: older messages name it), or one sent from another
/// device. And the alias it sends now (`sent`, `tribeAlias` of its name),
/// unless the tribe has already made that one unique.
func ownTribeAliases(sent: String, echoed: Set<String>) -> Set<String> {
    echoed.contains(sent + "_2") ? echoed : echoed.union([sent])
}

/// Whether the owner's approval of `alias` is this account's: one of its
/// aliases, or the one it sends made unique, which an approval can carry
/// before anything has echoed it.
func approvalNamesUs(_ alias: String, sent: String, echoed: Set<String>) -> Bool {
    alias == sent + "_2" || ownTribeAliases(sent: sent, echoed: echoed).contains(alias)
}

/// What stored tribe messages were last checked for mentions with
/// (`Setting.mentionScan`): the account's tribe alias (`sent`) and the
/// aliases each tribe echoed back.
struct MentionScan: Codable, Equatable, Sendable {
    var sent: String
    var echoed: [String: Set<String>]

    var stored: String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The tribes whose messages need checking again since `last`: all of
    /// them (nil) when there was none or the account's alias changed, else
    /// those whose echoed aliases changed.
    func chats(changedSince last: MentionScan?) -> Set<String>? {
        guard let last, last.sent == sent else { return nil }
        return Set(echoed.keys).union(last.echoed.keys).filter { echoed[$0] != last.echoed[$0] }
    }
}

extension String {
    /// A compressed public key in hex, as Sphinx names accounts and tribes.
    /// ASCII only: `isHexDigit` also takes fullwidth digits and letters.
    public var isPubkey: Bool { count == 66 && allSatisfy { $0.isASCII && $0.isHexDigit } }
}

/// Aliases in tribes: letters, digits and underscores, spaces as underscores,
/// as the official apps send them.
func tribeAlias(_ alias: String) -> String {
    let fixed = String(alias.replacingOccurrences(of: " ", with: "_").filter(isAliasCharacter))
    return fixed.isEmpty ? "Unknown" : fixed
}

extension MentionScan {
    init?(stored: String) {
        guard let scan = JSON.decode(Self.self, from: stored) else { return nil }
        self = scan
    }
}
