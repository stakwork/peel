import Foundation

/// Something the agent can do, with what the model is told about it.
public struct Tool: Sendable {
    /// What running a tool does: whether a call waits on the loop's
    /// approver (`ToolApprover`, `asks`) and whether it may run beside
    /// others (`runsSideBySide`). Both are exhaustive, so a new effect must
    /// decide.
    public enum Effect: String, Sendable, Hashable {
        /// Only reads; never asks.
        case read
        /// Acts for the person towards others: sends, marks read, pays.
        case send
        /// Changes the person's own data, such as the agent's memory: never
        /// asks, but runs alone and in order, as an action does, so a read
        /// after it sees it.
        case write

        /// Waits on the approver before it runs.
        public var asks: Bool {
            switch self {
            case .read, .write: false
            case .send: true
            }
        }

        /// May run side by side with others like it; anything else runs
        /// alone, in order.
        public var runsSideBySide: Bool {
            switch self {
            case .read: true
            case .send, .write: false
            }
        }
    }

    public enum Output: Sendable, Hashable {
        case text(String)
        case json(JSONValue)
        /// The text the model is sent, and what the tool's row keeps to
        /// show when it is opened. Only for a result worth keeping apart
        /// from what the app already stores (a chat read keeps none).
        case kept(String, row: JSONValue)

        /// As the model is sent it.
        public var text: String {
            switch self {
            case .text(let text), .kept(let text, _): text
            case .json(let value): value.jsonString
            }
        }

        /// What the tool's row keeps, if anything.
        public var row: JSONValue? {
            if case .kept(_, let row) = self { row } else { nil }
        }
    }

    /// `input` is a JSON object, but not checked against `inputSchema`
    /// (arguments stream unvalidated): a handler checks what it reads, and
    /// throws to tell the model what was wrong.
    public typealias Handler = @Sendable (_ input: JSONValue) async throws -> Output

    /// What a call comes to before anything is done: an answer for the
    /// model at once (a read's result, or why there is nothing to do, such
    /// as a name that matches two chats), or an action to approve: what it
    /// will do in a person's words, and the work itself, run only once
    /// allowed, so what runs is what was shown.
    public enum Plan: Sendable {
        case result(Output)
        case action(ToolIntent, run: @Sendable () async throws -> Output)
    }

    public typealias Planner = @Sendable (_ input: JSONValue) async throws -> Plan

    public let definition: ToolDefinition
    public let effect: Effect
    public let plan: Planner

    public var name: String { definition.name }

    /// `inputSchema` is a JSON Schema object. A handler that throws reports
    /// the failure to the model, worded by the error's description. A tool
    /// that acts given only a handler is approved by its name and arguments
    /// (`ToolIntent.generic`); one that can say what it will do uses `plan`.
    public init(name: String, description: String, inputSchema: JSONValue, effect: Effect, handler: @escaping Handler) {
        self.init(name: name, description: description, inputSchema: inputSchema, effect: effect) { input in
            guard effect.asks else { return .result(try await handler(input)) }
            return .action(.generic(name, input: input), run: { try await handler(input) })
        }
    }

    public init(name: String, description: String, inputSchema: JSONValue, effect: Effect, plan: @escaping Planner) {
        definition = ToolDefinition(name: name, description: description, inputSchema: inputSchema)
        self.effect = effect
        self.plan = plan
    }
}

/// The tools one agent has, by name.
public struct ToolRegistry: Sendable {
    public private(set) var tools: [Tool] = []

    public init(_ tools: [Tool] = []) {
        for tool in tools { register(tool) }
    }

    /// Adds a tool, replacing any of the same name.
    public mutating func register(_ tool: Tool) {
        tools.removeAll { $0.name == tool.name }
        tools.append(tool)
    }

    public subscript(name: String) -> Tool? {
        tools.first { $0.name == name }
    }

    public var definitions: [ToolDefinition] { tools.map(\.definition) }
}

extension Tool {
    /// The current date and time where the person is: a trivial built-in for
    /// trying tool calls out.
    public static let currentTime = Tool(
        name: "current_time",
        description: "The current date, time and time zone on the user's device.",
        inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
        effect: .read
    ) { _ in
        .json([
            "local": .string(Date.ISO8601FormatStyle(timeZone: .current).format(Date())),
            "time_zone": .string(TimeZone.current.identifier),
        ])
    }
}
