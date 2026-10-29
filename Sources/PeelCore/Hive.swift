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

    /// The org a call in a chat brings Jamie from (docs/hive-calls.md):
    /// `picked`, the peer id chosen there ("" for No Jamie), while it is
    /// among `peers`; with nothing picked, the org whose swarm a tribe's
    /// `app_url` or `second_brain_url` is on, as the official apps choose;
    /// else none.
    public static func jamie(picked: String?, pages: [String?], in peers: [HivePeer]) -> HivePeer? {
        if let picked { return peers.first { $0.id == picked } }
        let swarms = pages.compactMap { $0.flatMap { Self.swarm(of: $0) } }
        return swarms.lazy.compactMap { name in peers.first { Self.swarm(of: $0.baseUrl) == name } }.first
    }

    /// A swarm's name: the first label of an address's host
    /// (`swarm38.sphinx.chat` → `swarm38`); nil for a host of one label.
    static func swarm(of address: String) -> String? {
        guard let host = URL(string: address)?.host?.lowercased() else { return nil }
        let labels = host.split(separator: ".")
        return labels.count > 1 ? String(labels[0]) : nil
    }
}

/// Jamie in Sphinx tribes (docs/hive-tribes.md): the one Sphinx account
/// Hive runs in every tribe linked to an org (stakwork/sphinx `wasm/daemon`).
public struct JamieAccount: Codable, Sendable, Equatable {
    /// Its key: a private tribe's request to join from it is approved unasked.
    public var pubkey: String
    public var alias: String

    public init(pubkey: String, alias: String) {
        self.pubkey = pubkey
        self.alias = alias
    }

    /// Its key in lower case and its alias cleaned; nil for a key that is not one.
    var checked: JamieAccount? {
        guard pubkey.isPubkey else { return nil }
        let alias = TextLine.clean(alias, max: TextLine.maxName)
        return JamieAccount(pubkey: pubkey.lowercased(), alias: alias.isEmpty ? "Jamie" : alias)
    }
}

/// A tribe the person linked to one of their orgs: `@jamie` there is a turn
/// of that org's assistant, run as them, answered in the tribe.
public struct JamieLink: Codable, Sendable, Equatable {
    /// The tribe's key.
    public var pubkey: String
    /// Its tribes server, `host[:port]`.
    public var host: String
    public var name: String?
    /// The workspace whose org answers: a `HivePeer.id`.
    public var workspace: String
    /// The org's GitHub login.
    public var org: String?

    public init(pubkey: String, host: String, name: String? = nil, workspace: String, org: String? = nil) {
        self.pubkey = pubkey
        self.host = host
        self.name = name
        self.workspace = workspace
        self.org = org
    }

    /// Its keys as Peel holds them; nil for one it could not use.
    var checked: JamieLink? {
        guard pubkey.isPubkey, AgentArtifact.Handle.isPeerID(workspace) else { return nil }
        var link = self
        link.pubkey = pubkey.lowercased()
        return link
    }
}

/// Every tribe the person linked, and Jamie's account.
public struct JamieLinks: Codable, Sendable, Equatable {
    public var jamie: JamieAccount
    public var tribes: [JamieLink]

    public init(jamie: JamieAccount, tribes: [JamieLink]) {
        self.jamie = jamie
        self.tribes = tribes
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
        guard (1...600).contains(pairing.interval), (1...3600).contains(pairing.expiresIn),
              !pairing.userCode.isEmpty, pairing.userCode.count <= 32 else {
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
        guard status == 200 else {
            // Busy or failing, as `Web.retryLater` judges it: `answer(to:)` asks again.
            let failure = Self.failure(status, data, couldNot: "pair")
            throw status == 429 || status >= 500 ? Unanswered(failure: failure) : failure
        }
        let paired = try JSONDecoder.hive.decode(Paired.self, from: data)
        guard paired.credential.hasPrefix("hivedev_") else { throw PeelError("Stadeum's device credential could not be read.") }
        let (peers, refused) = reachable(paired.peers)
        return .paired(HiveLink(hive: hive, credential: paired.credential, deviceID: paired.device.id,
                                deviceName: paired.device.name ?? name, actor: try Self.actor(paired.actor),
                                peers: peers, errors: (paired.errors ?? []) + refused, expiresAt: paired.expiresAt, renewedAt: now))
    }

    /// Polls `pairing` every `interval` until the person answers in Hive or
    /// the code runs out: never `.pending`. A poll that gets no answer (the
    /// network, or Hive failing for a moment) is tried again until
    /// `deadline`, when the code runs out: on the iPhone the person approves
    /// in Safari, and the first poll back in Peel often goes out on a
    /// connection the system dropped while Peel was away. `wait` is how it
    /// waits between polls. Cancelling the task stops it.
    public func answer(
        to pairing: Pairing, name: String, until deadline: Date,
        wait: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async throws -> Poll {
        while true {
            await wait(.seconds(pairing.interval))
            try Task.checkCancellation()
            do {
                let poll = try await poll(pairing, name: name)
                if poll != .pending { return poll }
            } catch where error is Unanswered || (error as? URLError).map({ Self.unreached.contains($0.code) }) == true {
                guard Date() < deadline else { throw (error as? Unanswered)?.failure ?? error }
            }
        }
    }

    /// A poll that reached no one, which may reach Hive next time: never a
    /// certificate Peel will not trust, which fails at once.
    static let unreached: Set<URLError.Code> = [
        .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// A poll Hive could not answer this time (429, 5xx): `answer(to:)` polls
    /// again. Said in Hive's words, as `failure`.
    struct Unanswered: Error, CustomStringConvertible {
        let failure: PeelError
        var description: String { failure.description }
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

    /// A call with Jamie in it, for `workspace` (a peer's id: the org's
    /// central workspace), as the person `link` pairs: Hive dispatches Jamie
    /// into a new room and answers its link (docs/hive-calls.md). The link
    /// as Hive wrote it; the caller checks it against the call server.
    public func startCall(_ link: HiveLink, workspace: String) async throws -> String {
        let (status, data) = try await request("POST", "api/strut-devices/calls", ["workspace": workspace], bearer: link.credential)
        let answer = try? JSONDecoder.hive.decode([String: String].self, from: data)
        switch status {
        case 200:
            guard let url = answer?["url"] else { throw PeelError("Stadeum's call link could not be read.") }
            return url
        // A revoked device, and a Hive from before the route alike: its
        // middleware turns away the device credential on any path it does not know.
        case 401:
            throw PeelError("Stadeum didn't accept this device for a call. If it was disconnected in Stadeum, connect it again.")
        default:
            throw Self.failure(status, data, couldNot: "start a call with Jamie")
        }
    }

    // MARK: - Jamie in tribes

    /// The tribes `link`'s person linked to their orgs, and Jamie's account
    /// (docs/hive-tribes.md): read from Hive, so their Mac and iPhone agree.
    public func jamieLinks(_ link: HiveLink) async throws -> JamieLinks {
        let (status, data) = try await request("GET", "api/strut-devices/tribes", nil, bearer: link.credential)
        guard status == 200 else { throw Self.tribeFailure(status, data, couldNot: "read which tribes have Jamie") }
        guard let answer = try? JSONDecoder.hive.decode(JamieAnswer.self, from: data), let jamie = answer.jamie.checked,
              let tribes = answer.tribes else {
            throw PeelError("Stadeum's answer about Jamie could not be read.")
        }
        // A link Peel could not use (not a tribe's key, a workspace id strut would not take) is left out.
        return JamieLinks(jamie: jamie, tribes: tribes.compactMap(\.checked))
    }

    /// Links `tribe` (a tribe the person owns, on its tribes server `host`)
    /// to `workspace` (a peer's id): from now on `@jamie` there is a turn
    /// of that org's assistant, run as the person, and Jamie is told to
    /// join. Answers Jamie's account and the link as Hive keeps it.
    public func linkTribe(
        _ link: HiveLink, workspace: String, tribe: String, host: String, name: String?
    ) async throws -> (jamie: JamieAccount, tribe: JamieLink) {
        struct Body: Encodable {
            struct Tribe: Encodable {
                let pubkey: String
                let host: String
                let name: String?
            }

            let workspace: String
            let tribe: Tribe
        }
        let body = Body(workspace: workspace, tribe: Body.Tribe(pubkey: tribe, host: host, name: name))
        let (status, data) = try await request("POST", "api/strut-devices/tribes", json: try JSONEncoder.hive.encode(body),
                                               bearer: link.credential)
        guard status == 200 else { throw Self.tribeFailure(status, data, couldNot: "add Jamie") }
        guard let answer = try? JSONDecoder.hive.decode(JamieAnswer.self, from: data),
              let jamie = answer.jamie.checked, let linked = answer.tribe?.checked, linked.pubkey == tribe.lowercased() else {
            throw PeelError("Stadeum's answer about Jamie could not be read.")
        }
        return (jamie, linked)
    }

    /// Unlinks `tribe` (its pubkey): Hive refuses its mentions from now on
    /// and tells Jamie to leave. One Hive no longer has (unlinked from the
    /// person's other device) is unlinked already.
    public func unlinkTribe(_ link: HiveLink, tribe: String) async throws {
        guard tribe.isPubkey else { throw PeelError("That isn't a tribe's key.") }
        let (status, data) = try await request("DELETE", "api/strut-devices/tribes/\(tribe.lowercased())", nil,
                                               bearer: link.credential)
        guard status == 200 || status == 404 else { throw Self.tribeFailure(status, data, couldNot: "remove Jamie") }
    }

    /// What Hive answers instead, in words: the refusals a person can act
    /// on said as such (docs/hive-tribes.md), the rest in Hive's words.
    private static func tribeFailure(_ status: Int, _ data: Data, couldNot what: String) -> PeelError {
        switch status {
        // A revoked device, and a Hive from before the routes alike (its
        // middleware turns the device credential away on a path it does not know).
        case 401: PeelError("Stadeum didn't accept this device for Jamie. If it was disconnected in Stadeum, connect it again.")
        case 409: PeelError("Someone else already linked this tribe to an org.")
        case 503: PeelError("Jamie isn't switched on in Stadeum yet.")
        default: failure(status, data, couldNot: what)
        }
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

    /// `GET /api/strut-devices/tribes` (`tribes`) and its `POST` (`tribe`).
    private struct JamieAnswer: Decodable {
        let jamie: JamieAccount
        let tribes: [JamieLink]?
        let tribe: JamieLink?
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
        try await request(method, path, json: try body.map { try JSONEncoder.hive.encode($0) }, bearer: bearer)
    }

    private func request(_ method: String, _ path: String, json: Data?, bearer: String?) async throws -> (Int, Data) {
        try await Web.requestStrut(method, hive.appending(path: path), json: json,
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
