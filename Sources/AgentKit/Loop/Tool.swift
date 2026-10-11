import Foundation

/// Something the agent can do, with what the model is told about it.
public struct Tool: Sendable {
    /// What running a tool does, so a gate can be put in front of `send`
    /// tools later without changing them.
    public enum Effect: String, Sendable, Hashable {
        /// Only reads.
        case read
        /// Acts for the person: sends, marks read, changes something.
        case send
    }

    public enum Output: Sendable, Hashable {
        case text(String)
        case json(JSONValue)

        /// As the model is sent it.
        public var text: String {
            switch self {
            case .text(let text): text
            case .json(let value): value.jsonString
            }
        }
    }

    /// `input` is a JSON object, but not checked against `inputSchema`
    /// (arguments stream unvalidated): a handler checks what it reads, and
    /// throws to tell the model what was wrong.
    public typealias Handler = @Sendable (_ input: JSONValue) async throws -> Output

    public let definition: ToolDefinition
    public let effect: Effect
    public let handler: Handler

    public var name: String { definition.name }

    /// `inputSchema` is a JSON Schema object. A handler that throws reports
    /// the failure to the model, worded by the error's description.
    public init(name: String, description: String, inputSchema: JSONValue, effect: Effect, handler: @escaping Handler) {
        definition = ToolDefinition(name: name, description: description, inputSchema: inputSchema)
        self.effect = effect
        self.handler = handler
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
