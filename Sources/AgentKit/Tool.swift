import Foundation

/// Something the Mac does when the agent asks (`DeviceReads`,
/// `DeviceActions`): a read of the person's chats or a send as them, with
/// how it is described.
public struct Tool: Sendable {
    /// What running a tool does: a read never asks; a send waits on the
    /// person's approval (`asks`). Exhaustive, so a new effect must decide.
    public enum Effect: String, Sendable, Hashable {
        /// Only reads; never asks.
        case read
        /// Acts for the person towards others: sends, marks read, pays.
        case send

        /// Waits on the approver before it runs.
        public var asks: Bool {
            switch self {
            case .read: false
            case .send: true
            }
        }
    }

    public enum Output: Sendable, Hashable {
        case text(String)
        case json(JSONValue)

        /// As the agent is sent it.
        public var text: String {
            switch self {
            case .text(let text): text
            case .json(let value): value.jsonString
            }
        }
    }

    /// `input` is a JSON object, but not checked against `inputSchema`: a
    /// handler checks what it reads, and throws to tell the agent what was
    /// wrong.
    public typealias Handler = @Sendable (_ input: JSONValue) async throws -> Output

    /// What a call comes to before anything is done: an answer for the
    /// agent at once (a read's result, or why there is nothing to do, such
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
    /// the failure to the agent, worded by the error's description. A tool
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

/// A tool's name, what it does and its input's JSON Schema.
public struct ToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    /// A JSON Schema for the tool's input, an object.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
