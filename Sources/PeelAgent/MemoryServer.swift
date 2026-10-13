import AgentKit
import Foundation
import PeelCore

/// The agent's long-term memory: a Ladybug graph that strut owns
/// (`docs/agent-brain.md`), reached through strut's synchronous
/// `POST /steps/memory/<verb>/run`. Peel never opens the graph's file.
/// Only a server on this Mac, so it needs no key.
public struct MemoryServer: Sendable, Hashable {
    public let base: URL

    /// Nil for anything but plain http to this Mac.
    public init?(base: URL) {
        guard Web.isThisMac(base) else { return nil }
        self.base = base
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
            reply = try await Web.postToThisMac(url, json: body, limit: Self.replyLimit, what: "memory/\(verb)")
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
        if let refusal = output["error"]?.string { throw PeelError(words(refusal)) }
        return output
    }
}
