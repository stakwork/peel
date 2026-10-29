import Foundation
import Observation
import PeelDiagnostics

/// One message of the agent chat Peel ran on this Mac before strut was the
/// agent ("Old assistant chats (this Mac only)"): the person's, or the agent's reply with
/// the tools it ran on the way.
public struct AgentTurn: Identifiable, Sendable, Equatable {
    public enum Author: String, Sendable { case user, agent }

    /// How an agent's reply ended, when not on its own.
    public enum Ending: String, Sendable {
        case stopped
        /// The reply reached its length limit.
        case cutOff = "cut_off"
        /// The provider declined to answer.
        case declined
        /// The turn ran out of steps.
        case stepLimit = "step_limit"
        /// The provider failed after an action had run.
        case failed
    }

    public internal(set) var id: String
    public var author: Author
    public var text: String
    public var date: Date
    /// The tools an agent's reply ran, in order, shown above its text.
    public var tools: [ToolActivity] = []
    public var ending: Ending?

    public init(id: String, author: Author, text: String, date: Date, tools: [ToolActivity] = [], ending: Ending? = nil) {
        self.id = id
        self.author = author
        self.text = text
        self.date = date
        self.tools = tools
        self.ending = ending
    }
}

/// A tool the agent ran, as a quiet row: what it was, how long it took,
/// and what it was asked and answered, for when the row is opened.
public struct ToolActivity: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSONValue
    /// The first line of what it returned.
    public var summary: String?
    public var duration: Duration?
    public var failed = false
    /// For a tool that acts: what it asked to do and how the person answered.
    public var approval: ToolApproval?
    /// What it returned, kept for its row by the memory tools; nil for the rest.
    public var row: JSONValue?

    public init(id: String, name: String, input: JSONValue, summary: String? = nil, duration: Duration? = nil,
                failed: Bool = false, approval: ToolApproval? = nil, row: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.summary = summary
        self.duration = duration
        self.failed = failed
        self.approval = approval
        self.row = row
    }

}

/// A tool call that needed approval: what it would do, and the answer.
public struct ToolApproval: Sendable, Equatable, Codable {
    public var intent: ToolIntent
    public var outcome: ApprovalOutcome?

    public init(intent: ToolIntent, outcome: ApprovalOutcome? = nil) {
        self.intent = intent
        self.outcome = outcome
    }
}

/// The agent's settings on this Mac and the chat Peel's own loop kept
/// before strut was the agent: the connected model (its key in this
/// device's Keychain, handed to strut), the agent's name, the "Always
/// allow" rules its cards share (`DeviceActions`), and the old turns, read
/// only, in the account's agent store.
///
/// Each old message is a `Turn` record linked from one `Conversation`
/// record (`created_by` user or agent), its tool calls `ToolCall` records
/// linked from it.
@MainActor @Observable
public final class AgentSession {
    /// The connected model as screens show it: no key, only its last four.
    public struct Connection: Sendable, Equatable {
        public let provider: AgentProvider
        public let model: String
        public let keyHint: String
    }

    /// The earlier conversation, oldest first.
    public private(set) var turns: [AgentTurn] = []
    public private(set) var connection: Connection? {
        didSet { credentialChanged?() }
    }
    /// What the agent is called in the sidebar, its header and its messages.
    public private(set) var name = AgentSession.defaultName
    /// A failure to read or change any of it, said once in the chat.
    public var notice: String?

    /// The account's remembered "Always allow" rules, for Account to list.
    public private(set) var approvalRules: [ApprovalRule] = []

    public static let defaultName = "Peel"

    /// Called whenever `connection` is set (a key or model kept, or the
    /// key gone), so the app can hand the change on.
    @ObservationIgnored public var credentialChanged: (() -> Void)?

    private let store: any AgentStore
    /// The "always" rules, which the device's send cards share (`DeviceActions`).
    public let rules: ApprovalRules
    private let credentials: any AgentCredentialStore
    private var conversationID: String?

    public init(store: any AgentStore, credentials: any AgentCredentialStore) {
        self.store = store
        rules = ApprovalRules(store: store)
        self.credentials = credentials
        load()
    }

    private func load() {
        do {
            connection = try credentials.read().map(Connection.init)
        } catch {
            // The kind only: the words (and the error's own) stay out of the ring.
            Diagnostics.note(errorKind: .other)
            notice = "Could not read the connected model's key: \(error.localizedDescription)"
        }
        do {
            approvalRules = try rules.all()
        } catch {
            Diagnostics.note(errorKind: .database)
            notice = [notice, "Could not read what the agent is always allowed to do: \(error.localizedDescription)"]
                .compactMap { $0 }.joined(separator: " ")
        }
        do {
            name = try store.records(type: RecordType.agent, limit: 1).first?.name ?? Self.defaultName
            guard let conversation = try store.records(type: RecordType.conversation, limit: 1).first else { return }
            conversationID = conversation.refId
            turns = try store.walk(conversation.refId, edgeTypes: [LinkType.turn], direction: .outgoing, depth: 1,
                                   limit: Int.max).map { step in
                var turn = AgentTurn(record: step.record)
                if turn.author == .agent { turn.tools = try Self.toolCalls(of: turn.id, in: store).map(ToolActivity.init(record:)) }
                return turn
            }
        } catch {
            Diagnostics.note(errorKind: .database)
            notice = "Could not read the agent chat: \(error.localizedDescription)"
        }
    }

    // MARK: Approvals

    /// Forgets an "Always allow": that tool asks again for that target.
    public func revoke(_ rule: ApprovalRule) throws {
        try rules.revoke(rule)
        approvalRules = try rules.all()
    }

    /// Reads the rules again, after a card remembered one.
    public func reloadRules() {
        approvalRules = (try? rules.all()) ?? approvalRules
    }

    // MARK: The model

    /// Keeps `credential` in the Keychain, for strut to answer with.
    public func connect(_ credential: AgentCredential) throws {
        // The name another device gave stays with the key, so a key changed
        // here goes back to the preferences file under it.
        var credential = credential
        if credential.agentName == nil { credential.agentName = (try? credentials.read())?.agentName }
        try credentials.write(credential)
        connection = Connection(credential)
    }

    /// Reads the connected model again, after the preferences sync kept a
    /// key from another device in the Keychain: the app then hands it to
    /// strut as a manual connect would (`credentialChanged`).
    public func reloadConnection() {
        do {
            connection = try credentials.read().map(Connection.init)
        } catch {
            Diagnostics.note(errorKind: .other)
            notice = "Could not read the connected model's key: \(error.localizedDescription)"
        }
    }

    /// Changes the model the connected key uses.
    public func setModel(_ model: String) throws {
        guard var credential = try credentials.read() else { return }
        credential.model = model
        try credentials.write(credential)
        connection = Connection(credential)
    }

    /// Removes the key from this device. The agent stops until connected again.
    public func removeKey() throws {
        try credentials.delete()
        connection = nil
    }

    // MARK: The conversation

    /// Forgets every message of the earlier conversation, with the
    /// summaries Peel's loop made of it.
    public func clear() throws {
        let summaries = try conversationID.map {
            try store.walk($0, edgeTypes: [LinkType.summary], direction: .outgoing, depth: 1, limit: Int.max).map(\.record.refId)
        } ?? []
        // The conversation first: once it is forgotten nothing reads its
        // turns, so a failure part way leaves no old chat to come back.
        if let conversationID { try store.forget(conversationID, reason: "cleared") }
        let ids = turns.map(\.id)
        conversationID = nil
        turns = []
        for id in summaries { try store.forget(id, reason: "cleared") }
        for id in ids {
            for call in try Self.toolCalls(of: id, in: store) { try store.forget(call.refId, reason: "cleared") }
            try store.forget(id, reason: "cleared")
        }
    }

    /// Renames the agent; an empty name is refused.
    public func rename(_ newName: String) throws {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != name else { return }
        if let agent = try store.records(type: RecordType.agent, limit: 1).first {
            try store.update(agent.refId, name: newName)
        } else {
            try store.add(type: RecordType.agent, name: newName, createdBy: AgentTurn.Author.user.rawValue)
        }
        name = newName
    }

    // MARK: Records

    enum RecordType {
        static let agent = "Agent"
        static let conversation = "Conversation"
        static let turn = "Turn"
        static let toolCall = "ToolCall"
    }

    enum LinkType {
        static let turn = "turn"
        static let toolCall = "tool_call"
        /// A summary Peel's loop made of the turns before it.
        static let summary = "summary"
    }

    /// The tool calls a reply made, in the order they ran.
    private static func toolCalls(of turn: String, in store: any AgentStore) throws -> [Record] {
        try store.walk(turn, edgeTypes: [LinkType.toolCall], direction: .outgoing, depth: 1, limit: Int.max)
            .map(\.record)
            .sorted { ($0.props["index"].flatMap(\.int) ?? 0) < ($1.props["index"].flatMap(\.int) ?? 0) }
    }

    /// Writes `turns` into `store` as Peel's loop kept them, as one
    /// conversation: for the offscreen driver's list journeys, which open
    /// an agent chat with a history of their own.
    public static func keep(_ turns: [AgentTurn], in store: any AgentStore) throws {
        let conversation = try store.add(type: RecordType.conversation, name: defaultName,
                                         createdBy: AgentTurn.Author.user.rawValue)
        var asked: String?
        for turn in turns {
            let author = turn.author.rawValue
            let id = try store.add(type: RecordType.turn, name: String(turn.text.prefix(80)), body: turn.text,
                                   props: turn.props, createdBy: author, source: turn.author == .agent ? asked : nil)
            try store.link(conversation, LinkType.turn, id, createdBy: author)
            for (index, tool) in turn.tools.enumerated() {
                var props = tool.props
                props["index"] = .number(Double(index))
                let call = try store.add(type: RecordType.toolCall, name: tool.name, body: tool.summary,
                                         props: props, createdBy: author, source: id)
                try store.link(id, LinkType.toolCall, call, createdBy: author)
            }
            if turn.author == .user { asked = id }
        }
    }
}

extension AgentSession.Connection {
    init(_ credential: AgentCredential) {
        self.init(provider: credential.provider, model: credential.model, keyHint: credential.keyHint)
    }
}

// MARK: - Turns as records

extension AgentTurn {
    init(record: Record) {
        let props = JSONValue.object(record.props)
        self.init(
            id: record.refId,
            author: record.createdBy == Author.agent.rawValue ? .agent : .user,
            text: record.body ?? "",
            date: Date(timeIntervalSince1970: Double(record.createdMs) / 1000),
            ending: props["ending"]?.string.flatMap(Ending.init(rawValue:)))
    }

    var props: [String: JSONValue] {
        var props: [String: JSONValue] = [:]
        if let ending { props["ending"] = .string(ending.rawValue) }
        return props
    }
}

extension ToolActivity {
    /// A `ToolCall` record: the tool's name, the summary of its result as
    /// the body, what it was asked, how long it took and whether it failed.
    /// What it returned in full is not kept: it is a copy of chats Peel
    /// already stores. Only a row a tool chose to keep is (`row`).
    init(record: Record) {
        let props = JSONValue.object(record.props)
        let ms: Double? = if case .number(let ms)? = props["ms"] { ms } else { nil }
        self.init(id: props["call_id"]?.string ?? record.refId, name: record.name, input: props["input"] ?? .object([:]),
                  summary: record.body, duration: .milliseconds(Int64(ms ?? 0)), failed: props["failed"] == .bool(true),
                  approval: props["approval"].flatMap { try? $0.decoded(as: ToolApproval.self) }, row: props["row"])
    }

    var props: [String: JSONValue] {
        var props: [String: JSONValue] = ["call_id": .string(id), "input": input, "failed": .bool(failed)]
        if let duration { props["ms"] = .number((duration / .milliseconds(1)).rounded()) }
        if let approval, let json = try? JSONValue(encoding: approval) { props["approval"] = json }
        if let row { props["row"] = row }
        return props
    }
}
