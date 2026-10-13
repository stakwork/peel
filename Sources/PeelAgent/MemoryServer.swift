import AgentKit
import Foundation
import PeelCore

/// The agent's long-term memory: a Ladybug graph that strut owns
/// (`docs/agent-brain.md`), reached through strut's synchronous
/// `POST /steps/memory/<verb>/run`. Peel never opens the graph's file.
/// Only a server on this Mac, and with its key: anything on the Mac can
/// reach a loopback port. Kept per profile in `Profile.memoryServer`.
public struct MemoryServer: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let base: URL
    /// strut's `STRUT_API_KEY`; nil for a strut started without one.
    let key: String?

    /// Nil for anything but plain http to this Mac with nothing else in the
    /// address (no user, password, query or fragment, which would be shown
    /// and kept), or a key with spaces or control characters in it.
    public init?(base: URL, key: String? = nil) {
        guard Web.isThisMac(base), base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !(key ?? "").unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { return nil }
        self.base = base
        self.key = key.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The address and whether it has a key; never the key, however it is
    /// printed (`print`, `debugPrint`, `dump`).
    public var description: String { base.absoluteString + (key == nil ? "" : " (with a key)") }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public var hasKey: Bool { key != nil }

    /// As `Profile.memoryServer` keeps it.
    private struct Kept: Codable {
        let url: String
        let key: String?
    }

    /// The server kept in `item`; nil when none is, or what is kept no longer qualifies.
    public static func kept(in item: any SecretItem) throws -> MemoryServer? {
        guard let data = try item.read() else { return nil }
        let kept = try JSONDecoder().decode(Kept.self, from: data)
        return URL(string: kept.url).flatMap { MemoryServer(base: $0, key: kept.key) }
    }

    public func keep(in item: any SecretItem) throws {
        try item.write(JSONEncoder().encode(Kept(url: base.absoluteString, key: key)))
    }

    /// The test call before a server is kept: it answers, takes the key,
    /// and has the memory steps.
    public func check() async throws {
        _ = try await run("ontology", [:])
    }

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
            reply = try await Web.postToThisMac(url, json: body, bearer: key, limit: Self.replyLimit, what: "memory/\(verb)")
        } catch {
            let action = "run memory/\(verb) on the memory server at \(base.absoluteString)"
            throw PeelError(PeelError.problem(error, couldNot: action) + " Check that strut is running there with the memory steps, and that the key is its STRUT_API_KEY.")
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
        if let refusal = output["error"]?.string { throw PeelError(words(refusal)) }
        return output
    }
}
