import Foundation

/// Anthropic's Messages API, streamed (`POST /v1/messages`, `stream: true`).
public struct AnthropicProvider: ModelProvider {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1")!
    public static let defaultModel = "claude-opus-5-5"

    private let apiKey: Secret
    private let baseURL: URL
    private let session: URLSession

    /// `baseURL` ends before `/messages`; https, or http to this machine.
    public init(apiKey: String, baseURL: URL = defaultBaseURL) {
        self.init(apiKey: apiKey, baseURL: baseURL, session: ModelHTTP.shared)
    }

    init(apiKey: String, baseURL: URL, session: URLSession) {
        self.apiKey = Secret(apiKey)
        self.baseURL = baseURL
        self.session = session
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelHTTP.stream(
            try ModelHTTP.post(
                ModelHTTP.checked(baseURL).appending(path: "messages"),
                headers: ["x-api-key": apiKey.value, "anthropic-version": "2023-06-01"],
                body: Self.body(for: request)),
            session: session, secret: apiKey.value, decoder: AnthropicDecoder(secret: apiKey.value))
    }

    static func body(for request: ModelRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "messages": .array(request.messages.compactMap(encode)),
            "stream": true,
            // Caches the prompt up to its last block, so each step of a turn's
            // tool loop reads the earlier steps from the cache.
            "cache_control": ["type": "ephemeral"],
        ]
        if !request.system.isEmpty { body["system"] = .string(request.system) }
        if !request.tools.isEmpty {
            body["tools"] = .array(
                request.tools.map { tool in
                    [
                        "name": .string(tool.name), "description": .string(tool.description),
                        "input_schema": tool.inputSchema,
                        // Arguments arrive as they are written; the loop checks
                        // they parse before running the tool.
                        "eager_input_streaming": true,
                    ]
                })
        }
        return .object(body)
    }

    /// A message as the API takes it; nil when nothing in it is for Anthropic.
    private static func encode(_ message: ModelMessage) -> JSONValue? {
        let blocks: [JSONValue] = message.content.compactMap { block in
            switch block {
            case .text(let text):
                // The API refuses text blocks that are empty or only whitespace.
                return text.allSatisfy(\.isWhitespace) ? nil : ["type": "text", "text": .string(text)]
            case .toolUse(let call):
                return ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": call.input]
            case .toolResult(let result):
                var block: [String: JSONValue] = [
                    "type": "tool_result", "tool_use_id": .string(result.toolCallID), "content": .string(result.content),
                ]
                if result.isError { block["is_error"] = true }
                return .object(block)
            case .provider(let name, let value):
                return name == AnthropicDecoder.providerName ? value : nil
            }
        }
        guard !blocks.isEmpty else { return nil }
        return ["role": .string(message.role.rawValue), "content": .array(blocks)]
    }
}

/// Reads the Messages API's events: `message_start`, then for each content
/// block `content_block_start`, its deltas and `content_block_stop`, then
/// `message_delta` (stop reason, output tokens) and `message_stop`; `ping`
/// at any time, `error` in place of the rest.
struct AnthropicDecoder: StreamDecoder {
    static let providerName = "anthropic"

    /// One content block being streamed, by its index.
    private enum Block {
        case text
        case toolUse(id: String, name: String, json: String)
        case thinking(text: String, signature: String)
        /// A block kept whole as it started (`redacted_thinking`).
        case opaque(JSONValue)
        case ignored
    }

    let secret: Secret
    private var blocks: [Int: Block] = [:]
    private var usage = Usage()
    private var stopReason: FinishReason?
    private var stopped = false

    init(secret: String) { self.secret = Secret(secret) }

    mutating func decode(_ event: SSEEvent) throws -> [ModelEvent] {
        let json: JSONValue
        do { json = try JSONValue(parsing: event.data) } catch { throw ModelError.malformed("an event that is not JSON") }
        let index = json["index"]?.int ?? 0
        switch json["type"]?.string ?? event.event {
        case "message_start":
            // Input is counted (and billed) from here, even if the reply is stopped.
            readUsage(json["message"]?["usage"])
            return [.usage(usage)]

        case "content_block_start":
            let block = json["content_block"] ?? .null
            switch block["type"]?.string {
            case "text":
                blocks[index] = .text
                let text = block["text"]?.string ?? ""
                return text.isEmpty ? [] : [.textDelta(text)]
            case "tool_use":
                let id = block["id"]?.string ?? "", name = block["name"]?.string ?? ""
                blocks[index] = .toolUse(id: id, name: name, json: "")
            case "thinking":
                blocks[index] = .thinking(text: block["thinking"]?.string ?? "", signature: block["signature"]?.string ?? "")
            case "redacted_thinking":
                blocks[index] = .opaque(block)
            default:
                blocks[index] = .ignored
            }
            return []

        case "content_block_delta":
            let delta = json["delta"] ?? .null
            switch (blocks[index], delta["type"]?.string) {
            case (.text?, "text_delta"):
                let text = delta["text"]?.string ?? ""
                return text.isEmpty ? [] : [.textDelta(text)]
            case (.toolUse(let id, let name, let soFar)?, "input_json_delta"):
                blocks[index] = .toolUse(id: id, name: name, json: soFar + (delta["partial_json"]?.string ?? ""))
            case (.thinking(let text, let signature)?, "thinking_delta"):
                blocks[index] = .thinking(text: text + (delta["thinking"]?.string ?? ""), signature: signature)
            case (.thinking(let text, let signature)?, "signature_delta"):
                blocks[index] = .thinking(text: text, signature: signature + (delta["signature"]?.string ?? ""))
            default:
                break
            }
            return []

        case "content_block_stop":
            defer { blocks[index] = nil }
            switch blocks[index] {
            case .toolUse(let id, let name, let arguments)?:
                return [.toolCallCompleted(ToolCall(id: id, name: name, arguments: arguments))]
            case .thinking(let text, let signature)?:
                let block: JSONValue = ["type": "thinking", "thinking": .string(text), "signature": .string(signature)]
                return [.providerBlock(name: Self.providerName, block)]
            case .opaque(let block)?:
                return [.providerBlock(name: Self.providerName, block)]
            default:
                return []
            }

        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.string { stopReason = Self.finishReason(reason) }
            readUsage(json["usage"])
            return [.usage(usage)]

        case "message_stop":
            stopped = true
            return [.finished(stopReason ?? .endTurn)]

        case "error":
            throw ModelError(streamError: json["error"] ?? .null, secret: secret.value)

        default:
            // `ping`, and event types added after this was written.
            return []
        }
    }

    func finish() throws -> [ModelEvent] {
        guard stopped else { throw ModelError.network("The reply stopped before it was finished.") }
        return []
    }

    /// Input counts arrive in `message_start` (and again in `message_delta`
    /// on newer versions); output counts in `message_delta`, cumulative.
    private mutating func readUsage(_ value: JSONValue?) {
        guard let value else { return }
        let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { value[$0]?.int }
        if !input.isEmpty { usage.inputTokens = input.reduce(0, +) }
        if let output = value["output_tokens"]?.int { usage.outputTokens = output }
    }

    static func finishReason(_ reason: String) -> FinishReason {
        switch reason {
        case "end_turn", "stop_sequence": .endTurn
        case "tool_use": .toolUse
        case "max_tokens", "model_context_window_exceeded": .maxTokens
        case "refusal": .refusal
        default: .other(reason)
        }
    }
}
