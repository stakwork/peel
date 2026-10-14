import AgentKit
import Foundation
import PeelCore

/// The agent's long-term memory: a Ladybug graph that strut owns
/// (`docs/agent-brain.md`), reached through strut's synchronous
/// `POST /steps/memory/<verb>/run`. Peel never opens the graph's file.
/// Peel's own strut on this Mac, which says its address and key when it
/// starts (`BundledStrut`), or a home server (`Brain`, `docs/peel-brain.md`);
/// always with its key: anything on the Mac can reach a loopback port.
public struct MemoryServer: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let base: URL
    /// strut's `STRUT_API_KEY`.
    let key: String
    /// The account's home server (`Brain`), not Peel's own strut, wherever
    /// it is (a strut in Docker on this Mac is one too): never handed this
    /// Mac's automation token or model key, never stood in for.
    public let isHomeServer: Bool

    /// Nil for anything but where a strut may be (`Web.isStrut`: http to this
    /// Mac or a Tailscale address, https anywhere; Peel's own only http to
    /// this Mac) with nothing else in the address (no user, password, query
    /// or fragment, which would be shown and kept), or a key that is empty or
    /// has spaces or control characters in it.
    public init?(base: URL, key: String, home: Bool = false) {
        guard home ? Web.isStrut(base) : Web.isThisMac(base), base.query == nil, base.fragment == nil,
              !key.isEmpty,
              !key.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { return nil }
        self.base = base
        self.key = key
        isHomeServer = home
    }

    /// The address; never the key, however it is printed (`print`,
    /// `debugPrint`, `dump`).
    public var description: String { base.absoluteString }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The most a reply may be.
    static let replyLimit = 2_000_000

    /// Runs one memory step with `arguments`: its output, or the step's
    /// refusal in its own words. The arguments go as the run's `input`, and
    /// the step's config is the single template `{{ input }}`: strut resolves
    /// `{{ … }}` anywhere in a config, so memory text sent as config would be
    /// evaluated ("Hi {{ name }}" stored as "Hi "), while a whole-string
    /// template's value is used as it is.
    public func run(_ verb: String, _ arguments: AgentKit.JSONValue) async throws -> AgentKit.JSONValue {
        let url = base.appending(path: "steps/memory/\(verb)/run")
        let body = Data(AgentKit.JSONValue.object(["input": arguments, "config": "{{ input }}"]).jsonString.utf8)
        let reply: Data
        do {
            reply = try await Web.postToStrut(url, json: body, bearer: key, limit: Self.replyLimit, what: "memory/\(verb)")
        } catch {
            let action = "run memory/\(verb) on the memory server at \(base.absoluteString)"
            // A home server is never stood in for (`docs/peel-brain.md`): a
            // refused key, or no answer at all, is said as such; any other
            // refusal is the server's own answer.
            switch (isHomeServer, Web.refusedStatus(of: error)) {
            case (true, 401), (true, 403):
                throw PeelError("The home server did not take Peel's key. Set it again in Account › Brain.")
            case (true, nil), (true, (500...)?):
                throw PeelError("The brain is offline. " + PeelError.problem(error, couldNot: action))
            default: break
            }
            throw PeelError(PeelError.problem(error, couldNot: action) + " Check that strut is running there with the memory steps.")
        }
        return try Self.output(of: reply)
    }

    /// The step's output from strut's reply, `{status, output, error}`; a
    /// step's own `{error}` (nothing found, bad input) is a failure too. Its
    /// words are cleaned to one capped line: they may echo memory text.
    static func output(of reply: Data) throws -> AgentKit.JSONValue {
        guard let value = try? AgentKit.JSONValue(parsing: String(decoding: reply, as: UTF8.self)) else {
            throw PeelError("The memory server's reply was not strut's. Check that strut is running there with the memory steps.")
        }
        let words = { (text: String) in ChatData.clean(text, max: ChatData.maxText) }
        guard value["status"]?.string == "success" else {
            throw PeelError("The memory server refused: " + words(value["error"]?["message"]?.string ?? "no reason given"))
        }
        guard let output = value["output"] else { throw PeelError("The memory server's step returned nothing.") }
        if let refusal = output["error"]?.string {
            throw refusal.hasPrefix("not_found") ? NotFound(description: words(refusal)) : PeelError(words(refusal))
        }
        return output
    }

    /// Strut's `not_found`: no such node, or it was forgotten. Told as a
    /// `PeelError` is, in strut's words.
    public struct NotFound: LocalizedError, CustomStringConvertible, Sendable {
        public let description: String
        /// The model reads errors as `localizedDescription`.
        public var errorDescription: String? { description }
    }

    /// One node as `memory/get` reads it; nil when memory no longer has it.
    public func node(_ id: String) async throws -> MemoryNode? {
        do {
            guard let node = MemoryNode(try await run("get", ["ref_id": .string(id)])) else {
                throw PeelError("Memory gave back something Peel cannot show.")
            }
            return node
        } catch is NotFound {
            return nil
        }
    }

    /// How a strut answers `GET /health` with this key. strut answers a
    /// probe without its key with `{ok: true}` alone and one with it with
    /// its data folder and step count too, so a 200 without them is a key
    /// it did not take. It names no version yet.
    public func health() async -> BrainStatus {
        do {
            let (status, data) = try await Web.requestStrut("GET", base.appending(path: "health"), bearer: key,
                                                            limit: 100_000, what: "health", timeout: 10)
            if status == 401 || status == 403 { return .badKey }
            guard status == 200, let value = try? AgentKit.JSONValue(parsing: String(decoding: data, as: UTF8.self)),
                  value["ok"] == .bool(true) else { return .offline("It did not answer as strut does (HTTP \(status)).") }
            return value["stepCount"] == nil ? .badKey : .connected
        } catch {
            return .offline(PeelError.problem(error, couldNot: "reach \(base.host ?? "it")"))
        }
    }
}

/// What a home server said when Peel last checked it (`MemoryServer.health`).
public enum BrainStatus: Sendable, Equatable {
    case connected
    /// It did not answer, or not as strut; why, in words.
    case offline(String)
    /// It answered, but not to Peel's key.
    case badKey
}
