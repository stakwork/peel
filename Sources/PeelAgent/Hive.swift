import AgentKit
import Foundation
import PeelCore

// A Hive workspace as a peer of Peel's strut (docs/connectors-and-authoring.md,
// "Peers"; strut's specs/DESKTOP.md §2; stakwork/hive#5602): this Mac pairs
// with Hive by the device flow, keeps the `hivedev_` credential, and puts one
// peer record per org on its strut, each with a person-scoped token that Hive
// renews daily. The org's own assistant is then one `strut/run-workflow` away,
// behind a card on the Mac (`PeerRequest`).

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
        let label = label.map { ChatData.clean($0, max: ChatData.maxName) } ?? ""
        return label.isEmpty ? ChatData.clean(id, max: ChatData.maxName) : label
    }
}

/// An org Hive gave no record for this time, and why, in Hive's words.
public struct HiveOrgError: Codable, Sendable, Equatable {
    public var org: String
    public var error: String

    /// The org and why, cleaned for showing.
    public var name: String { ChatData.clean(org, max: ChatData.maxName) }
    public var reason: String { ChatData.clean(error, max: 200) }
}

/// What this Mac keeps of its Hive pairing (`Profile.hive`, the Keychain
/// for an app profile): the device credential, which only Hive's renewal
/// takes, the person's actor on their orgs, and the peer records last put
/// on strut. Never in a database, never logged.
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

    /// Asks Hive for a code, naming this Mac.
    public func start(name: String) async throws -> Pairing {
        let (status, data) = try await request("POST", "api/strut-devices/pair", ["name": .string(name)])
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
        let (status, data) = try await request("POST", "api/strut-devices/pair/token", ["deviceCode": .string(pairing.deviceCode)])
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
            throw PeelError("Stadeum named this account in a way Peel cannot use (\(ChatData.clean(actor, max: 40))).")
        }
        return actor
    }

    /// The peers whose token may go to their address: https off this Mac
    /// (plain http on this Mac only from a test Hive on this Mac), each id
    /// once and in strut's form; the rest as errors, never put on strut.
    func reachable(_ peers: [HivePeer]) -> (peers: [HivePeer], refused: [HiveOrgError]) {
        let testHive = Web.isThisMac(hive)
        var kept: [HivePeer] = [], refused: [HiveOrgError] = []
        for peer in peers {
            guard (try? AutomationsClient.peerID(peer.id)) != nil, !kept.contains(where: { $0.id == peer.id }) else {
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

    /// A page on this Hive: its host, over https (or this Mac, for a test Hive).
    func isHive(_ url: URL) -> Bool {
        url.host?.lowercased() == hive.host?.lowercased() && url.scheme == hive.scheme && Web.isStrut(url)
    }

    private func request(
        _ method: String, _ path: String, _ body: AgentKit.JSONValue?, bearer: String? = nil
    ) async throws -> (Int, Data) {
        try await Web.requestStrut(method, hive.appending(path: path), json: body.map { Data($0.jsonString.utf8) },
                                   bearer: bearer, limit: Self.limit, what: "Stadeum", timeout: 30)
    }

    private static func failure(_ status: Int, _ data: Data, couldNot what: String) -> PeelError {
        let said = (try? JSONDecoder.hive.decode([String: String].self, from: data))?["error"]
        return PeelError("Stadeum could not \(what): \(said.map { ChatData.clean($0, max: 200) } ?? "HTTP \(status)").")
    }
}

extension JSONDecoder {
    /// Hive's JSON: ISO 8601 dates, with or without fractions.
    static var hive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Automation.date(text) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "not ISO 8601: \(text)")
            }
            return date
        }
        return decoder
    }
}

extension JSONEncoder {
    static var hive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - On strut

/// A call to an org's assistant waiting on the person: a `strut/run-workflow`
/// proposal, read from strut's own record.
public struct PeerRequest: Sendable, Equatable {
    public let peer: String
    /// The org as the person knows it: its peer record's label.
    public let name: String
    public let workflow: String
    /// The message the org's assistant is sent.
    public let prompt: String?
    /// Whether the call's input holds anything but the message and its
    /// thread, which the card could not show.
    public var more = false
}

extension AutomationsClient {
    /// Makes strut's peers exactly `kept`: each put (`PUT /peers/:id`
    /// replaces the record), any other taken off (an org left; one already
    /// gone is fine). Peel puts no peers but Hive's.
    public func syncPeers(_ kept: [HivePeer]) async throws {
        let there = try await call("GET", "peers", what: "the workspaces")["peers"]?.array?.compactMap { $0["id"]?.string } ?? []
        for peer in kept {
            var body: [String: AgentKit.JSONValue] = ["baseUrl": .string(peer.baseUrl), "token": .string(peer.token)]
            if let label = peer.label { body["label"] = .string(label) }
            if let description = peer.description { body["description"] = .string(description) }
            if let repos = peer.repos { body["repos"] = .array(repos.map(AgentKit.JSONValue.string)) }
            _ = try await call("PUT", "peers/\(try Self.peerID(peer.id))", .object(body), what: "the workspace \(peer.name)")
        }
        for id in there where !kept.contains(where: { $0.id == id }) {
            let (status, data) = try await request("DELETE", "peers/\(try Self.peerID(id))", nil, what: "the workspace \(id)")
            if status != 404 { _ = try Self.read(status, data) }
        }
    }

    /// The peer call proposal `id` waits for, from strut's record; nil for
    /// a proposal of another step. Throws when it cannot be read, is no
    /// longer pending, or names a peer strut has not got: the card is then
    /// refused, never shown in other words.
    public func peerRequest(proposal id: String) async throws -> PeerRequest? {
        guard id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw PeelError("That is not a proposal id strut gives.")
        }
        let proposal = try await call("GET", "proposals/\(id)", what: "the proposal")
        guard proposal["status"] == "pending" else { throw PeelError("strut's proposal is no longer waiting.") }
        guard proposal["step"]?.string == DeviceActions.peerTool else { return nil }
        guard let peer = proposal["input"]?["peer"]?.string else { throw PeelError("strut's proposal names no workspace.") }
        let peers = try await call("GET", "peers", what: "the workspaces")["peers"]?.array ?? []
        guard let record = peers.first(where: { $0["id"]?.string == peer }) else {
            throw PeelError("strut has no workspace \u{201C}\(ChatData.clean(peer, max: 40))\u{201D}.")
        }
        let input = proposal["input"]?["input"]
        return PeerRequest(peer: peer, name: HivePeer.name(label: record["label"]?.string, id: peer),
                           workflow: proposal["input"]?["workflow"]?.string ?? "orchestrator",
                           prompt: input?["prompt"]?.string,
                           more: !Set(input?.object?.keys ?? [:].keys).subtracting(["prompt", "session"]).isEmpty
                               || !Set(proposal["input"]?.object?.keys ?? [:].keys).subtracting(Self.peerCallKeys).isEmpty)
    }

    /// What a call to an org may hold beside its message for the card to
    /// show it all: not `params`, `version` or a `job` there.
    static let peerCallKeys: Set<String> = ["peer", "workflow", "input", "wait", "room"]

    /// A peer id as one path segment: strut's own form.
    static func peerID(_ id: String) throws -> String {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            throw PeelError("\u{201C}\(ChatData.clean(id, max: 40))\u{201D} is not a workspace id Peel can use.")
        }
        return id
    }
}
