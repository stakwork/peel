import AgentKit
import Foundation
import Observation
import PeelCore

/// The box as a peer of the Mac's strut (docs/always-on.md, "The Mac's
/// strut with a home box: two normal struts"): what `strut move send
/// --peer-actor <actor>` returns once Peel Home has arrived, under the
/// `sent` line's `peer` (strut's AGENTS.md, "A peer record after the
/// move"). Kept per profile in the Keychain (`Profile.homePeer`).
public struct HomePeer: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The box's peer port (https, behind the box's allowlist).
    public let baseUrl: URL
    /// A person token for `actor` there, which `peer: person` workflows take.
    let token: String
    /// Who the token is for: the person, as the box's strut knows them.
    public let actor: String
    /// When the token runs out: about a year after the move.
    public let expires: Date
    /// PEM: the CA the box's TLS is signed with, the only one strut trusts
    /// for this peer; nil for a certificate any Mac already trusts.
    let ca: String?
    /// The name the box's certificate is issued for (`peel-home`), checked
    /// in place of its address, which may change; only with `ca`.
    let servername: String?

    /// Nil for anything but https with a host and nothing else in the
    /// address, a token or actor with spaces or control characters, a CA
    /// that is not PEM certificates, or a server name that is not a host
    /// name or comes without a CA (strut's `checkPeer`).
    public init?(baseUrl: URL, token: String, actor: String, expires: Date, ca: String?, servername: String? = nil) {
        let plain = { (text: String) in
            !text.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        }
        guard baseUrl.scheme?.lowercased() == "https", baseUrl.host?.isEmpty == false,
              baseUrl.user == nil, baseUrl.password == nil, baseUrl.query == nil, baseUrl.fragment == nil,
              (1...4096).contains(token.count), plain(token), (1...120).contains(actor.count), plain(actor) else { return nil }
        if let ca {
            guard ca.utf8.count <= 64 * 1024, ca.contains("-----BEGIN CERTIFICATE-----"), ca.contains("-----END CERTIFICATE-----") else { return nil }
        }
        if let servername {
            guard ca != nil, servername.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$"#, options: .regularExpression) != nil
            else { return nil }
        }
        self.baseUrl = baseUrl
        self.token = token
        self.actor = actor
        self.expires = expires
        self.ca = ca
        self.servername = servername
    }

    /// A `sent` line's `peer`: `{ baseUrl, token, actor, exp, ca?, servername? }`, `exp`
    /// in milliseconds. Nil for none, the box's `{ error }` (it was given no
    /// peer address) or one Peel can't take.
    init?(_ json: Any?) {
        guard let json = json as? [String: Any], let url = (json["baseUrl"] as? String).flatMap(URL.init(string:)),
              let token = json["token"] as? String, let actor = json["actor"] as? String,
              let exp = json["exp"] as? NSNumber, CFGetTypeID(exp) != CFBooleanGetTypeID() else { return nil }
        let ca = json["ca"] as? String, servername = json["servername"] as? String
        guard json["ca"] == nil || ca != nil, json["servername"] == nil || servername != nil else { return nil }
        self.init(baseUrl: url, token: token, actor: actor, expires: Date(timeIntervalSince1970: exp.doubleValue / 1000), ca: ca, servername: servername)
    }

    /// The `{ error }` a box gives in place of a peer record.
    static func refusal(_ json: Any?) -> String? {
        (json as? [String: Any])?["error"] as? String
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let peer = HomePeer(baseUrl: try values.decode(URL.self, forKey: .baseUrl), token: try values.decode(String.self, forKey: .token),
                                  actor: try values.decode(String.self, forKey: .actor), expires: try values.decode(Date.self, forKey: .expires),
                                  ca: try values.decodeIfPresent(String.self, forKey: .ca),
                                  servername: try values.decodeIfPresent(String.self, forKey: .servername))
        else { throw PeelError("Peel Home's peer record isn't one Peel can use.") }
        self = peer
    }

    /// The record kept in `item`; nil for none, or one Peel can't read.
    public static func read(_ item: any SecretItem) -> HomePeer? {
        (try? item.read()).flatMap { $0 }.flatMap { try? JSONDecoder().decode(HomePeer.self, from: $0) }
    }

    func keep(in item: any SecretItem) throws {
        try item.write(JSONEncoder().encode(self))
    }

    /// The address; never the token.
    public var description: String { "Peel Home at \(baseUrl.absoluteString)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["baseUrl": baseUrl, "expires": expires], displayStyle: .struct) }
}

/// The Mac's strut while Peel Home is on the box: a normal strut on a
/// folder of its own (`Strut.client` beside Peel Home's), scheduler off,
/// with no bridge and no agent, for dictation and the Vocabulary window.
/// Never the folder set aside at the move, which holds the agent's secrets
/// and is what "Use this Mac's copy" puts back.
public enum HomeClient {
    /// strut's `home-sync { peer }` (strut's AGENTS.md, "Home sync"), one
    /// `home/sync` step: pushes what dictation changed here, then pulls the
    /// box's memory if it changed and loads it in place of this one, keeping
    /// what dictation changed meanwhile. Neither the changes nor the memory
    /// land in a run's journal; its output is a summary. One that fails
    /// records nothing and the next catches up; strut runs one at a time.
    static let syncWorkflow = "home-sync"
    /// The id of the box's peer record on the Mac's strut.
    static let peerID = "home"

    /// `Strut.client` beside Peel Home's strut folder `strut`.
    public nonisolated static func folder(for strut: URL) -> URL {
        strut.appendingPathExtension("client")
    }

    /// Dictation's own files in strut's data, which the client starts with:
    /// the model picks, and pairs waiting to be learned. The speech models
    /// stay in strut's cache, shared by any strut on this Mac.
    static let dictationFiles = ["audio/dictation.json", "audio/dictation-pending.json"]

    /// Makes the client's folder from Peel Home's `strut` folder, still in
    /// place at the move: dictation's files copied across, nothing else.
    public nonisolated static func prepare(_ client: URL, from strut: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: client, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in dictationFiles {
            let from = strut.appending(path: "workspace").appending(path: name)
            let to = client.appending(path: "workspace").appending(path: name)
            guard files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) else { continue }
            try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try files.copyItem(at: from, to: to)
        }
    }

    /// When the last sync finished, kept beside the client's data (strut
    /// keeps its own state, `since` and `hash`, in `workspace/home-sync.json`).
    public nonisolated static func lastSync(in client: URL) -> Date? {
        (try? Data(contentsOf: client.appending(path: "last-sync.json")))
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }?["synced"]
    }

    public nonisolated static func keepLastSync(_ date: Date, in client: URL) {
        let file = client.appending(path: "last-sync.json")
        guard (try? JSONEncoder().encode(["synced": date]).write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Removes the client's folder: Peel Home is back on this Mac, or this
    /// Mac's copy is.
    public nonisolated static func remove(_ client: URL) throws {
        try BundledStrut.erase(data: client)
    }
}

/// How the Mac's strut and the box's are kept in step: the one seam, so
/// the tests can fake it, and strut S2's `home-sync` can change behind it.
public protocol HomeSyncing: Sendable {
    /// Puts the box on file as the peer `home` of the Mac's strut at `server`.
    func addPeer(_ peer: HomePeer, on server: MemoryServer) async throws
    /// Pushes what dictation changed here, then pulls the box's memory if it
    /// changed; returns when it finished, true when it pulled.
    func sync(on server: MemoryServer) async throws -> Bool
}

/// strut's own: `PUT /peers/home`, and its `home-sync` workflow run to the
/// end on the Mac's strut, against that peer.
public struct StrutHomeSync: HomeSyncing {
    /// How long one sync may take: a whole memory, pulled over the home network.
    let timeout: Duration

    public init(timeout: Duration = .seconds(180)) {
        self.timeout = timeout
    }

    /// `{ baseUrl, token, ca?, servername? }`, as strut's `checkPeer` takes
    /// it: the CA the only one strut trusts for this peer.
    nonisolated static func record(_ peer: HomePeer) -> AgentKit.JSONValue {
        var body: [String: AgentKit.JSONValue] = ["baseUrl": .string(peer.baseUrl.absoluteString), "token": .string(peer.token),
                                                  "label": .string("Peel Home")]
        if let ca = peer.ca { body["ca"] = .string(ca) }
        if let servername = peer.servername { body["servername"] = .string(servername) }
        return .object(body)
    }

    public func addPeer(_ peer: HomePeer, on server: MemoryServer) async throws {
        _ = try await AutomationsClient(server: server).call("PUT", "peers/\(HomeClient.peerID)", Self.record(peer),
                                                             what: "Peel Home's peer")
    }

    public func sync(on server: MemoryServer) async throws -> Bool {
        let client = AutomationsClient(server: server)
        let path = "workflows/\(HomeClient.syncWorkflow)"
        guard let run = try await client.call("POST", "\(path)/run", .object(["input": .object(["peer": .string(HomeClient.peerID)])]),
                                          what: "Peel Home's sync")["runId"]?.string,
              run.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else {
            throw PeelError("strut didn't start Peel Home's sync.")
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            let summary = try await client.call("GET", "\(path)/runs/\(run)", what: "Peel Home's sync")
            // Read as the Automations view reads a run: strut's own reason for one that failed.
            guard let record = AutomationRunRecord(summary, workflow: HomeClient.syncWorkflow) else { continue }
            switch record.status {
            case "success": return summary["output"]?["pulled"] == .bool(true)
            case "error", "failed", "cancelled": throw PeelError("Peel Home's sync: " + record.failure)
            default: continue
            }
        }
        throw PeelError("Peel Home's sync took too long.")
    }
}

/// Keeps the Mac's strut in step with the box (`HomeSyncing`): the box put
/// on file as its peer each time it starts, then one sync at a time, and
/// one more after if asked while it ran. Failures are quiet: dictation
/// keeps the last copy. Without a peer record, or with one run out,
/// nothing is tried.
@MainActor @Observable
public final class HomeSyncer {
    /// Where the sync stands, as Account › Brain says it.
    public enum Status: Equatable, Sendable {
        /// The box gave no peer record: dictation keeps what it knew at the move.
        case noPeer
        /// The record's token ran out then.
        case expired(Date)
        case notYet
        case synced(Date)
    }

    /// When the last sync finished, here or at an earlier launch.
    public private(set) var lastSync: Date?
    /// From the peer record as the last sync (or the start) read it, and `lastSync`.
    public private(set) var status = Status.notYet
    /// Called after a sync that pulled the box's memory.
    @ObservationIgnored public var onPull: (() -> Void)?

    private let syncing: any HomeSyncing
    private let client: URL
    private let peer: any SecretItem
    private let now: () -> Date
    private var server: MemoryServer?
    /// The strut the peer was put on: once per start.
    private var peered: MemoryServer?
    private var running: Task<Void, Never>?
    private var again = false

    public init(syncing: any HomeSyncing = StrutHomeSync(), client: URL, peer: any SecretItem, now: @escaping () -> Date = Date.init) {
        self.syncing = syncing
        self.client = client
        self.peer = peer
        self.now = now
        lastSync = HomeClient.lastSync(in: client)
        _ = readPeer()
    }

    /// The client's strut, once it is ready (synced at once), or nil once it stopped.
    public func use(_ server: MemoryServer?) {
        guard server != self.server else { return }
        self.server = server
        if server != nil { sync() }
    }

    /// Pushes, then pulls: now, or once the sync under way ends.
    public func sync() {
        guard server != nil else { return }
        guard running == nil else { again = true; return }
        running = Task { [weak self] in
            await self?.run()
        }
    }

    /// Waits for the sync under way, then runs one more: for a move back.
    public func finish() async {
        await running?.value
        guard server != nil else { return }
        sync()
        await running?.value
    }

    private func run() async {
        repeat {
            again = false
            guard let server, let record = readPeer() else { break }
            if peered != server {
                guard (try? await syncing.addPeer(record, on: server)) != nil else { break }
                peered = server
            }
            // Away from home, or the box off: the last copy stays.
            guard let pulled = try? await syncing.sync(on: server), server == self.server else { continue }
            let date = now()
            lastSync = date
            status = .synced(date)
            HomeClient.keepLastSync(date, in: client)
            if pulled { onPull?() }
        } while again
        running = nil
    }

    /// The peer record, if there is one still in date; `status` from it.
    private func readPeer() -> HomePeer? {
        let record = HomePeer.read(peer)
        status = switch record {
        case nil: .noPeer
        case let record? where record.expires <= now(): .expired(record.expires)
        default: lastSync.map(Status.synced) ?? .notYet
        }
        return record.flatMap { $0.expires > now() ? $0 : nil }
    }
}
