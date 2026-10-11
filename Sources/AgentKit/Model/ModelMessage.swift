import Foundation

/// One message of a conversation with a model, in AgentKit's own shape; each
/// provider translates it to its wire format.
public struct ModelMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case user, assistant
    }

    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ModelMessage {
        ModelMessage(role: .user, content: [.text(text)])
    }

    public var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    public var toolCalls: [ToolCall] {
        content.compactMap { if case .toolUse(let call) = $0 { call } else { nil } }
    }

    /// A user message the person typed, not one carrying tool results: where
    /// a turn starts.
    var startsTurn: Bool {
        role == .user && !content.contains { if case .toolResult = $0 { true } else { false } }
    }

    /// The message without provider blocks (a model's signed reasoning),
    /// which are only sent back within the turn that produced them.
    var withoutProviderBlocks: ModelMessage {
        ModelMessage(role: role, content: content.filter { if case .provider = $0 { false } else { true } })
    }
}

public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case toolUse(ToolCall)
    case toolResult(ToolResult)
    /// A block only its provider reads, sent back to it as it came
    /// (Anthropic's thinking blocks, which must precede the tool use they led
    /// to). Other providers leave it out.
    case provider(name: String, JSONValue)
}

/// A tool the model asked to run.
public struct ToolCall: Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue
    /// The arguments as sent, when they were not one JSON object (cut off,
    /// or malformed). `input` is then empty and the call is not run.
    public var malformedInput: String?

    public init(id: String, name: String, input: JSONValue, malformedInput: String? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.malformedInput = malformedInput
    }

    /// A call whose arguments arrived as JSON text, in pieces.
    init(id: String, name: String, arguments: String) {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.init(id: id, name: name, input: .object([:]))
        } else if let input = try? JSONValue(parsing: trimmed), case .object = input {
            self.init(id: id, name: name, input: input)
        } else {
            self.init(id: id, name: name, input: .object([:]), malformedInput: arguments)
        }
    }
}

/// What a tool returned, sent back to the model.
public struct ToolResult: Sendable, Hashable {
    public var toolCallID: String
    public var content: String
    public var isError: Bool

    public init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

/// What the model is told about a tool.
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
