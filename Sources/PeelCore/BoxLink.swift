import Foundation

// Peel linked to a strut box (a self-hosted Stadeum box; strut's
// plans/people-and-hosts.md §2.1, specs/API.md §13.6): a member signed in
// there asks for a link challenge naming them (the Jamie app's Connect →
// Link Peel), Peel signs it with the account's own key and posts it, and
// the box links that key to the member and answers a person token for
// seven days. The key is what lasts: Peel renews the token by signing
// again, and removing the link in Connect ends it at once. No device flow,
// no device record; beside Hive's pairing (`HiveLink`), never in its place.

/// The values of a `peel://<host><path>?…` link that names exactly `names`,
/// each once, and nothing else: no user or fragment, and `path` as given
/// ("" or "/" for none). Nil for any other link. Any page can open one, so
/// every `peel://` link Peel takes is read through here.
public enum PeelLink {
    public static func values(_ link: URL, host: String, path: String = "", names: Set<String>) -> [String: String]? {
        let pathMatches = path.isEmpty ? link.path.isEmpty || link.path == "/" : link.path == path
        guard link.scheme?.lowercased() == "peel", link.host?.lowercased() == host, pathMatches,
              link.user == nil, link.fragment == nil,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == names.count, Set(items.map(\.name)) == names else { return nil }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value else { return nil }
            values[item.name] = value
        }
        return values
    }
}

/// A box's link challenge (strut's `strut-link.<claims>.<hmac>`, claims
/// `{ host, actor?, name?, nonce, exp }`). Read, never verified: the HMAC is
/// the box's to check. What it names is shown to the person before Peel
/// signs it; it is the only thing Peel signs for a box.
public struct BoxChallenge: Sendable, Equatable {
    public static let prefix = "strut-link."
    /// The longest challenge read; strut's are a few hundred characters.
    public static let maxLength = 4_096

    /// The whole challenge, as signed: its UTF-8 bytes.
    public let text: String
    /// The box's host name, lower case, no port: where it may be signed for.
    public let host: String
    /// The person it links; nil for a renewal's, which names nobody.
    public let actor: String?
    /// Their name as the box shows it, for the question.
    public let name: String?
    public let nonce: String
    /// When it ends, unix MILLISECONDS.
    public let expiresAtMs: Int64

    /// Nil for anything that is not a box's link challenge.
    public init?(_ text: String) {
        guard let c = StrutClaims.read(text, prefix: Self.prefix, maxLength: Self.maxLength),
              let host = c["host"]?.string, !host.isEmpty, let nonce = c["nonce"]?.string, !nonce.isEmpty,
              let exp = WalletProtocol.integer(c["exp"]), exp >= 1 else { return nil }
        // As strut reads one: an actor or a name, when there, is a string.
        if let actor = c["actor"], actor.string == nil { return nil }
        if let name = c["name"], name.string == nil { return nil }
        self.text = text
        self.host = host.lowercased()
        self.actor = c["actor"]?.string?.nilIfEmpty
        self.name = c["name"]?.string?.nilIfEmpty
        self.nonce = nonce
        self.expiresAtMs = exp
    }

    /// Who it links, as the person reads it: the name, else the actor.
    public var person: String? { BoxLink.person(name: name, actor: actor) }

    public func expired(at now: Date) -> Bool { expiresAtMs <= Int64(now.timeIntervalSince1970 * 1000) }
}

/// A box's link as Peel takes it, `peel://strut/link?url=<box>&challenge=<…>`
/// (from the box's QR code, or its Open in Peel): the box's address, which
/// may carry a mount path (`/lab`), and the challenge to sign for it.
public struct BoxLinkOffer: Sendable, Equatable, Identifiable {
    /// The box's base URL as strut names one (`Seller.base`): where Peel posts.
    public let box: URL
    public let challenge: BoxChallenge

    public var id: String { challenge.nonce }

    /// `peel://strut/link?url=…&challenge=…` and nothing else.
    public init?(peelLink link: URL) {
        guard let values = PeelLink.values(link, host: "strut", path: "/link", names: ["url", "challenge"]),
              let url = values["url"], let challenge = values["challenge"] else { return nil }
        self.init(box: url, challenge: challenge)
    }

    /// A box's address (https, or http to this machine) and its challenge.
    public init?(box: String, challenge: String) {
        guard let base = Seller.base(box), let challenge = BoxChallenge(challenge) else { return nil }
        self.box = base
        self.challenge = challenge
    }

    /// The box's host as the person reads it, and as its challenge names it.
    public var host: String { Seller.host(of: box) ?? "" }

    /// Why Peel will not sign it at `now`, in words; nil when it may ask.
    /// It must link someone, be for this box's own host, not have run out,
    /// and be at an address Peel sends a token to (`BoxLink.reachable`).
    public func problem(at now: Date = Date(), allowsLoopback: Bool) -> String? {
        let host = host
        guard challenge.actor != nil else {
            return "This link doesn't name anyone to link Peel to. Choose Link Peel in Connect on \(host) again."
        }
        guard challenge.host == host else {
            return "This link is for \(TextLine.clean(challenge.host, max: 80)), not \(host), so Peel won't sign it."
        }
        guard !challenge.expired(at: now) else {
            return "This link ran out. Choose Link Peel in Connect on \(host) again."
        }
        guard BoxLink.reachable(box, allowsLoopback: allowsLoopback) else {
            return "Peel links only to a box at an https address, not \(host)."
        }
        return nil
    }
}

/// A box Peel is linked to, as kept (`Profile.boxes`, the Keychain for an
/// app profile; never in a database, never logged): its address, the
/// member it is linked to, and their token, renewed by signing again. Never
/// described with its token.
public struct BoxLink: Codable, Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The box's base URL (`Seller.base`): strut's UI and routes under it.
    public var url: URL
    /// The member, as the box names them.
    public var actor: String
    /// Their name as the box shows it.
    public var name: String?
    /// The person token (`strut-person.…`): a bearer credential.
    public var token: String
    /// When the token ends.
    public var exp: Date
    public var linkedAt: Date
    /// When the token was last made: at linking, or renewed.
    public var renewedAt: Date

    public init(url: URL, actor: String, name: String?, token: String, exp: Date, linkedAt: Date, renewedAt: Date) {
        self.url = url
        self.actor = actor
        self.name = name
        self.token = token
        self.exp = exp
        self.linkedAt = linkedAt
        self.renewedAt = renewedAt
    }

    /// How often the token is renewed: it lasts a week.
    public static let renewEvery: TimeInterval = 24 * 3600

    public var id: URL { url }
    /// The box's host as the person reads it.
    public var host: String { Seller.host(of: url) ?? url.absoluteString }
    /// Who Peel is linked as there: their name, else their actor.
    public var person: String { Self.person(name: name, actor: actor) ?? "" }

    /// A member as the person reads them: their name, else their actor, cleaned.
    static func person(name: String?, actor: String?) -> String? {
        [name, actor].lazy.compactMap { $0.map { TextLine.clean($0, max: TextLine.maxName) }?.nilIfEmpty }.first
    }

    public var description: String { "box link to \(host)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["url": url, "actor": actor]) }

    /// Due for renewal: a day since the last, or the token within a day of ending.
    public func due(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(renewedAt) >= Self.renewEvery || exp.timeIntervalSince(now) < Self.renewEvery
    }

    /// Whether Peel sends a token to the box at `url`: https off this
    /// machine; this machine (http or https) only with `allowsLoopback`, a
    /// development profile's local strut.
    public static func reachable(_ url: URL, allowsLoopback: Bool) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else { return false }
        if Seller.isLoopback(host) { return allowsLoopback && ["http", "https"].contains(url.scheme?.lowercased()) }
        return url.scheme?.lowercased() == "https"
    }

    /// The links kept in `item`, none when nothing is.
    public static func read(from item: any SecretItem) throws -> [BoxLink] {
        guard let data = try item.read() else { return [] }
        return try JSONDecoder.hive.decode(Kept.self, from: data).boxes
    }

    /// Keeps `links` in `item`; none deletes it.
    public static func write(_ links: [BoxLink], to item: any SecretItem) throws {
        if links.isEmpty { return try item.delete() }
        try item.write(try JSONEncoder.hive.encode(Kept(boxes: links)))
    }

    /// What `Profile.boxes` holds.
    private struct Kept: Codable {
        var boxes: [BoxLink]
    }
}

/// strut's three routes for Peel on a box (strut's specs/API.md §13.6),
/// none with a credential but the signature, and a token's check on use.
public struct BoxClient: Sendable {
    /// The most an answer may be.
    static let limit = 64 * 1024

    public let box: URL

    public init(box: URL) {
        self.box = box
    }

    var host: String { Seller.host(of: box) ?? "the box" }

    /// What a link or a renewal answers: the member and their token.
    public struct Answer: Sendable, Equatable {
        public let actor: String
        public let name: String?
        public let token: String
        public let exp: Date
    }

    /// Links this account's key to the member `challenge` names
    /// (`POST /people/link`), with the account's `signed` signature over it,
    /// its `name` (its alias) and its Sphinx address. Answers the link to keep.
    public func link(
        _ challenge: BoxChallenge, signed: VisitorSignature, name: String?, now: Date = Date()
    ) async throws -> BoxLink {
        var body: [String: String] = ["challenge": challenge.text, "key": signed.key, "sig": signed.sig]
        // One line of at most 80 characters, as strut keeps a name.
        if let name = name.map({ TextLine.clean($0, max: 80).trimmingCharacters(in: .whitespaces) })?.nilIfEmpty {
            body["name"] = name
        }
        if let address = signed.address { body["address"] = address }
        let (status, data) = try await request("POST", "people/link", body)
        guard status == 200 else { throw failure(status, data, linking: true) }
        let answer = try Self.answer(data, now: now, host: host)
        return BoxLink(url: box, actor: answer.actor, name: answer.name, token: answer.token, exp: answer.exp,
                       linkedAt: now, renewedAt: now)
    }

    /// What a renewal comes to.
    public enum Renewal: Sendable, Equatable {
        case renewed(BoxLink)
        /// The member removed the link (`403 not_linked`): the box is let go.
        case unlinked
    }

    /// A new token for `link`: a fresh challenge from the box
    /// (`GET /people/challenge`), for its own host, signed with `sign` (the
    /// account's key) and posted (`POST /people/token`). Its end is the box's
    /// to check: it lives a minute, and this device's clock may be off by more.
    public func renew(
        _ link: BoxLink, now: Date = Date(), sign: @Sendable (BoxChallenge) async throws -> VisitorSignature
    ) async throws -> Renewal {
        let (status, data) = try await request("GET", "people/challenge", nil)
        guard status == 200 else { throw failure(status, data, linking: false) }
        guard case .object(let fields)? = JSON.decode(JSONValue.self, from: String(decoding: data, as: UTF8.self)),
              let text = fields["challenge"]?.string, let challenge = BoxChallenge(text) else {
            throw PeelError("\(host)'s answer for renewing Peel's link could not be read.")
        }
        guard challenge.host == host else {
            throw PeelError("\(host) gave a challenge for \(TextLine.clean(challenge.host, max: 80)), so Peel didn't sign it.")
        }
        let signed = try await sign(challenge)
        let (renewedStatus, renewed) = try await request("POST", "people/token",
                                                         ["challenge": challenge.text, "key": signed.key, "sig": signed.sig])
        if renewedStatus == 403 { return .unlinked }
        guard renewedStatus == 200 else { throw failure(renewedStatus, renewed, linking: false) }
        let answer = try Self.answer(renewed, now: now, host: host)
        var link = link
        link.actor = answer.actor
        link.name = answer.name
        link.token = answer.token
        link.exp = answer.exp
        link.renewedAt = now
        return .renewed(link)
    }

    /// Whether the box takes `link`'s token: a read any member may make
    /// (`GET /apps`). False for a 401, which is the token no longer held
    /// (expired, or the link removed); throws for anything else.
    public func accepts(_ link: BoxLink) async throws -> Bool {
        let (status, data) = try await Web.requestStrut("GET", box.appending(path: "apps"), bearer: link.token,
                                                        limit: 4 * 1024 * 1024, what: host, timeout: 20)
        if status == 401 { return false }
        guard status == 200 else { throw failure(status, data, linking: false) }
        return true
    }

    private func request(_ method: String, _ path: String, _ body: [String: String]?) async throws -> (Int, Data) {
        try await Web.requestStrut(method, box.appending(path: path), json: try body.map { try JSONEncoder.hive.encode($0) },
                                   limit: Self.limit, what: host, timeout: 30)
    }

    /// `{ actor, name?, token, exp }`, checked: a person token, an actor to
    /// show, and an end still ahead.
    static func answer(_ data: Data, now: Date, host: String) throws -> Answer {
        guard case .object(let a)? = JSON.decode(JSONValue.self, from: String(decoding: data, as: UTF8.self)),
              let actor = a["actor"]?.string, (1...200).contains(actor.count),
              let token = a["token"]?.string, token.hasPrefix("strut-person."), token.utf8.count <= 4_096,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              let ms = WalletProtocol.integer(a["exp"]) else {
            throw PeelError("\(host)'s answer could not be read.")
        }
        let exp = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        guard exp > now else { throw PeelError("\(host) answered a token that had already run out.") }
        return Answer(actor: actor, name: a["name"]?.string?.nilIfEmpty, token: token, exp: exp)
    }

    /// strut's refusal, in words the person can act on (strut's words
    /// beside them only where they say more).
    func failure(_ status: Int, _ data: Data, linking: Bool) -> PeelError {
        let said = (try? JSONDecoder.hive.decode([String: String].self, from: data))?["error"]
            .map { TextLine.clean($0, max: 200) }
        switch status {
        case 401 where linking:
            return PeelError("\(host) didn't take the link: it ran out or was already used. Choose Link Peel in Connect there again.")
        case 401:
            return PeelError("\(host) didn't take Peel's signature.")
        case 409:
            return PeelError("Your Sphinx account is already linked to someone else on \(host). They remove it in Connect there first.")
        case 413:
            return PeelError("\(host) refused the link as too large.")
        case 429:
            return PeelError("\(host) is busy. Try again in a minute.")
        default:
            return PeelError("\(host) could not \(linking ? "link Peel" : "renew Peel's link"): \(said ?? "HTTP \(status)").")
        }
    }
}
