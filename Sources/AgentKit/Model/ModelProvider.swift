import Foundation

/// A model behind an API: messages and tools in, a stream of events out.
/// Cancelling the task that reads the stream cancels the request.
public protocol ModelProvider: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
}

public struct ModelRequest: Sendable, Hashable {
    public var model: String
    public var system: String
    public var messages: [ModelMessage]
    public var tools: [ToolDefinition]
    public var maxTokens: Int

    public init(model: String, system: String, messages: [ModelMessage], tools: [ToolDefinition] = [], maxTokens: Int) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

/// One step of a streamed reply. A stream that ends without throwing has
/// sent `.finished` last.
public enum ModelEvent: Sendable, Hashable {
    case textDelta(String)
    case toolCallCompleted(ToolCall)
    /// A provider block to keep in the assistant message, in order.
    case providerBlock(name: String, JSONValue)
    case usage(Usage)
    case finished(FinishReason)
}

/// Tokens one reply used. `inputTokens` counts the whole prompt, cached or not.
public struct Usage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func += (lhs: inout Usage, rhs: Usage) {
        lhs.inputTokens += rhs.inputTokens
        lhs.outputTokens += rhs.outputTokens
    }
}

public enum FinishReason: Sendable, Hashable {
    /// The model finished its reply.
    case endTurn
    /// The model wants its tool calls run.
    case toolUse
    /// The reply reached the request's `maxTokens`.
    case maxTokens
    /// The provider declined to answer (a safety refusal or content filter).
    case refusal
    case other(String)
}
