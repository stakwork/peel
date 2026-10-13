import AgentKit
import Foundation
import PeelCore

/// The agent's long-term memory: a Ladybug graph that strut owns
/// (`docs/agent-brain.md`), reached through strut's synchronous
/// `POST /steps/memory/<verb>/run`. Peel never opens the graph's file.
/// Only a server on this Mac, and with its key: anything on the Mac can
/// reach a loopback port. Never set by hand: the strut Peel ships says its
/// address and key when it starts (`BundledStrut`).
public struct MemoryServer: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let base: URL
    /// strut's `STRUT_API_KEY`.
    let key: String

    /// Nil for anything but plain http to this Mac with nothing else in the
    /// address (no user, password, query or fragment, which would be shown
    /// and kept), or a key that is empty or has spaces or control characters in it.
    public init?(base: URL, key: String) {
        guard Web.isThisMac(base), base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !key.isEmpty,
              !key.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { return nil }
        self.base = base
        self.key = key
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
            reply = try await Web.postToThisMac(url, json: body, bearer: key, limit: Self.replyLimit, what: "memory/\(verb)")
        } catch {
            let action = "run memory/\(verb) on the memory server at \(base.absoluteString)"
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
}
