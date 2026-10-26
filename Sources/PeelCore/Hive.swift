import Foundation

// A device paired with Hive (the person knows it as Stadeum) by the device
// flow (strut's specs/DESKTOP.md §2; stakwork/hive#5602): it keeps the
// `hivedev_` credential and one record per org, each with a person-scoped
// token Hive renews daily. The Mac puts the records on its strut as peers
// (PeelAgent's `syncPeers`); the iPhone, which has no strut, opens an
// org's pages on that org's own strut with them (strut's specs/DESKTOP.md,
// "A device with no strut of its own"; `OrgPage`).

/// One org's strut as Hive hands it over: strut's `PUT /peers/:id` body
/// and its id, which the person types as `@<id>`.
public struct HivePeer: Codable, Sendable, Equatable {
    public var id: String
    public var baseUrl: String
    public var token: String
    public var label: String?
    public var description: String?
    public var repos: [String]?

    /// What the person reads: its label, or its id.
    public var name: String { Self.name(label: label, id: id) }

    /// A workspace's label cleaned for showing, or its id when it has none.
    public static func name(label: String?, id: String) -> String {
        let label = label.map { TextLine.clean($0, max: TextLine.maxName) } ?? ""
        return label.isEmpty ? TextLine.clean(id, max: TextLine.maxName) : label
    }
}

/// An org Hive gave no record for this time, and why, in Hive's words.
public struct HiveOrgError: Codable, Sendable, Equatable {
    public var org: String
    public var error: String

    /// The org and why, cleaned for showing.
    public var name: String { TextLine.clean(org, max: TextLine.maxName) }
    public var reason: String { TextLine.clean(error, max: 200) }
}

/// What this device keeps of its Hive pairing (`Profile.hive`, the
/// Keychain for an app profile): the device credential, which only Hive's
/// renewal takes, the person's actor on their orgs, and the peer records
/// last renewed. Never in a database, never logged.
public struct HiveLink: Codable, Sendable, Equatable {
    public var hive: URL
    public var credential: String
    public var deviceID: String
    public var deviceName: String
    /// The `sub` of every token: the person in `<person>/<org>`.
    public var actor: String
    public var peers: [HivePeer]
    public var errors: [HiveOrgError]
    public var expiresAt: Date?
    public var renewedAt: Date
    /// When Hive answered that it no longer knows the device (a 401 on
    /// renewal): kept with the link, so its tokens stay unused across a
    /// restart or an unlock until it is paired again.
    public var revokedAt: Date?

    public static func read(from item: any SecretItem) throws -> HiveLink? {
        guard let data = try item.read() else { return nil }
        return try JSONDecoder.hive.decode(HiveLink.self, from: data)
    }

    public func write(to item: any SecretItem) throws {
        try item.write(try JSONEncoder.hive.encode(self))
    }

    /// Due for renewal: a day since the last, or its tokens within a day of expiring.
    public func due(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(renewedAt) >= HiveClient.renewEvery
            || expiresAt.map { $0.timeIntervalSince(now) < HiveClient.renewEvery } ?? false
    }
}

/// Hive's device-flow API for a strut desktop app (stakwork/hive#5602).
public struct HiveClient: Sendable {
    /// Hive in production.
    public static let production = URL(string: "https://hive.sphinx.chat")!
    /// How often the peers are renewed: their tokens last a week.
    public static let renewEvery: TimeInterval = 24 * 3600
    /// The most a Hive answer may be.
    static let limit = 512 * 1024

    public let hive: URL

    public init(hive: URL = production) {
        self.hive = hive
    }

    /// The Hive `profile` pairs with: Hive itself, or for a development
    /// profile `-hiveURL` (a local or staging Hive, or a test's stand-in).
    public init(for profile: Profile) {
        if profile.kind == .development, let given = UserDefaults.standard.string(forKey: "hiveURL"),
           let url = URL(string: given), Web.isStrut(url) {
            self.init(hive: url)
        } else {
            self.init()
        }
    }

    /// A code for the person to approve in Hive, signed in there.
    public struct Pairing: Codable, Sendable, Equatable {
        public let deviceCode: String
        public let userCode: String
        public let verificationUri: URL
        /// The page with the code filled in: the QR and the button open it.
        public let verificationUriComplete: URL
        public let expiresIn: Int
        public let interval: Int
    }

    /// Where a pairing stands after one poll.
    public enum Poll: Sendable, Equatable {
        case pending
        /// The person denied it in Hive.
        case denied
        /// Expired, unknown or already collected: start over.
        case expired
        case paired(HiveLink)
    }

    /// Asks Hive for a code, naming this device.
    public func start(name: String) async throws -> Pairing {
        let (status, data) = try await request("POST", "api/strut-devices/pair", ["name": name])
        guard status == 200 else { throw Self.failure(status, data, couldNot: "start pairing") }
        let pairing = try JSONDecoder.hive.decode(Pairing.self, from: data)
        // Only Hive's own page is ever shown or opened.
        for page in [pairing.verificationUri, pairing.verificationUriComplete] where !isHive(page) {
            throw PeelError("Stadeum gave a pairing page on another site (\(page.host ?? "none")); nothing was opened.")
        }
        guard (1...600).contains(pairing.interval), !pairing.userCode.isEmpty, pairing.userCode.count <= 32 else {
            throw PeelError("Stadeum's pairing code could not be read.")
        }
        return pairing
    }

    /// One poll of `pairing`: still waiting, an answer, or the device.
    public func poll(_ pairing: Pairing, name: String, now: Date = Date()) async throws -> Poll {
        let (status, data) = try await request("POST", "api/strut-devices/pair/token", ["deviceCode": pairing.deviceCode])
        if status == 400 {
            switch (try? JSONDecoder.hive.decode([String: String].self, from: data))?["error"] {
            case "authorization_pending": return .pending
            case "access_denied": return .denied
            case "expired_token": return .expired
            default: throw Self.failure(status, data, couldNot: "pair")
            }
        }
        guard status == 200 else { throw Self.failure(status, data, couldNot: "pair") }
        let paired = try JSONDecoder.hive.decode(Paired.self, from: data)
        guard paired.credential.hasPrefix("hivedev_") else { throw PeelError("Stadeum's device credential could not be read.") }
        let (peers, refused) = reachable(paired.peers)
        return .paired(HiveLink(hive: hive, credential: paired.credential, deviceID: paired.device.id,
                                deviceName: paired.device.name ?? name, actor: try Self.actor(paired.actor),
                                peers: peers, errors: (paired.errors ?? []) + refused, expiresAt: paired.expiresAt, renewedAt: now))
    }

    /// Polls `pairing` every `interval` until the person answers in Hive or
    /// the code runs out: never `.pending`. Cancelling the task stops it.
    public func answer(to pairing: Pairing, name: String) async throws -> Poll {
        while true {
            try await Task.sleep(for: .seconds(pairing.interval))
            let poll = try await poll(pairing, name: name)
            if poll != .pending { return poll }
        }
    }

    /// `link` with Hive's peers as they are now; nil once Hive no longer
    /// knows the device (revoked): pair again.
    public func renew(_ link: HiveLink, now: Date = Date()) async throws -> HiveLink? {
        let (status, data) = try await request("GET", "api/strut-devices/peers", nil, bearer: link.credential)
        if status == 401 { return nil }
        guard status == 200 else { throw Self.failure(status, data, couldNot: "renew the Stadeum workspaces") }
        let renewed = try JSONDecoder.hive.decode(Renewed.self, from: data)
        var link = link
        link.actor = try Self.actor(renewed.actor)
        let (peers, refused) = reachable(renewed.peers)
        link.peers = peers
        link.errors = (renewed.errors ?? []) + refused
        link.expiresAt = renewed.expiresAt
        link.renewedAt = now
        return link
    }

    // MARK: - Hive's answers

    private struct Paired: Decodable {
        struct Device: Decodable {
            let id: String
            let name: String?
        }

        let credential: String
        let device: Device
        let actor: String
        let peers: [HivePeer]
        let expiresAt: Date?
        let errors: [HiveOrgError]?
    }

    private struct Renewed: Decodable {
        let actor: String
        let peers: [HivePeer]
        let expiresAt: Date?
        let errors: [HiveOrgError]?
    }

    /// The person's actor: the first part of a strut session id, so plain.
    static func actor(_ actor: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard (1...120).contains(actor.count), actor.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            throw PeelError("Stadeum named this account in a way Peel cannot use (\(TextLine.clean(actor, max: 40))).")
        }
        return actor
    }

    /// The peers whose token may go to their address: https off this
    /// machine (plain http on this machine only from a test Hive on it),
    /// each id once and in strut's form; the rest as errors, never used.
    func reachable(_ peers: [HivePeer]) -> (peers: [HivePeer], refused: [HiveOrgError]) {
        let testHive = Web.isThisMac(hive)
        var kept: [HivePeer] = [], refused: [HiveOrgError] = []
        for peer in peers {
            guard AgentArtifact.Handle.isPeerID(peer.id), !kept.contains(where: { $0.id == peer.id }) else {
                refused.append(HiveOrgError(org: peer.id, error: "its id is not one Peel can use"))
                continue
            }
            let url = URL(string: peer.baseUrl)
            let local = url?.host.map(ServerAddress.isLoopback) ?? false
            let fine = url.map { $0.user == nil && $0.password == nil && ($0.scheme == "https" && !local || testHive && Web.isThisMac($0)) }
            if fine == true { kept.append(peer) } else {
                refused.append(HiveOrgError(org: peer.id, error: "its address is not one Peel sends a token to"))
            }
        }
        return (kept, refused)
    }

    /// A page on this Hive: its host, over https (or this machine, for a test Hive).
    func isHive(_ url: URL) -> Bool {
        url.host?.lowercased() == hive.host?.lowercased() && url.scheme == hive.scheme && Web.isStrut(url)
    }

    private func request(
        _ method: String, _ path: String, _ body: [String: String]?, bearer: String? = nil
    ) async throws -> (Int, Data) {
        let json = try body.map { try JSONEncoder.hive.encode($0) }
        return try await Web.requestStrut(method, hive.appending(path: path), json: json,
                                          bearer: bearer, limit: Self.limit, what: "Stadeum", timeout: 30)
    }

    private static func failure(_ status: Int, _ data: Data, couldNot what: String) -> PeelError {
        let said = (try? JSONDecoder.hive.decode([String: String].self, from: data))?["error"]
        return PeelError("Stadeum could not \(what): \(said.map { TextLine.clean($0, max: 200) } ?? "HTTP \(status)").")
    }
}

extension JSONDecoder {
    /// Hive's JSON: ISO 8601 dates, with or without fractions.
    static var hive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Date(iso8601: text) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "not ISO 8601: \(text)")
            }
            return date
        }
        return decoder
    }
}

extension JSONEncoder {
    /// What is kept and sent to Hive: ISO 8601 dates, keys in order, a `/` as itself.
    static var hive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
