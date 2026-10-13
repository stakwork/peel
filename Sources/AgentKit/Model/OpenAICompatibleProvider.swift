import Foundation

/// OpenAI's Chat Completions API, streamed (`POST /chat/completions`,
/// `stream: true`), and the services that copy it: OpenRouter, and local
/// servers.
public struct OpenAICompatibleProvider: ModelProvider {
    public static let openAI = URL(string: "https://api.openai.com/v1")!
    public static let openRouter = URL(string: "https://openrouter.ai/api/v1")!

    private let apiKey: Secret
    private let baseURL: URL
    private let headers: [String: String]
    private let maxTokensField: String
    private let session: URLSession

    /// `baseURL` ends before `/chat/completions`; https, or http to this
    /// machine. `headers` are sent as well (OpenRouter's optional
    /// `HTTP-Referer` and `X-Title`). `maxTokensField` is OpenAI's
    /// `max_completion_tokens`; other services may want `max_tokens`.
    public init(
        apiKey: String, baseURL: URL = openAI, headers: [String: String] = [:],
        maxTokensField: String = "max_completion_tokens"
    ) {
        self.init(
            apiKey: apiKey, baseURL: baseURL, headers: headers, maxTokensField: maxTokensField,
            session: ModelHTTP.shared)
    }

    init(apiKey: String, baseURL: URL, headers: [String: String], maxTokensField: String, session: URLSession) {
        self.apiKey = Secret(apiKey)
        self.baseURL = baseURL
        self.headers = headers
        self.maxTokensField = maxTokensField
        self.session = session
    }

    /// OpenRouter, with the headers that name the app on its rankings.
    public static func openRouter(apiKey: String, baseURL: URL = openRouter) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: apiKey, baseURL: baseURL, headers: ["HTTP-Referer": "https://peel.chat", "X-Title": "Peel"],
            maxTokensField: "max_tokens")
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelHTTP.stream(
            try ModelHTTP.post(
                ModelHTTP.checked(baseURL).appending(path: "chat/completions"),
                headers: headers.merging(["authorization": "Bearer \(apiKey.value)"]) { _, new in new },
                body: body(for: request)),
            session: session, secret: apiKey.value, decoder: OpenAIDecoder(secret: apiKey.value))
    }

    func body(for request: ModelRequest) -> JSONValue {
        var messages: [JSONValue] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": .string(request.system)]) }
        for message in request.messages { messages += Self.encode(message) }
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            maxTokensField: .number(Double(request.maxTokens)),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(
                request.tools.map { tool in
                    [
                        "type": "function",
                        "function": [
                            "name": .string(tool.name), "description": .string(tool.description),
                            "parameters": tool.inputSchema,
                        ],
                    ]
                })
        }
        return .object(body)
    }

    /// A message as Chat Completions takes it: tool results become `tool`
    /// messages of their own, ahead of any text beside them.
    private static func encode(_ message: ModelMessage) -> [JSONValue] {
        let text = message.text
        switch message.role {
        case .assistant:
            let calls = message.toolCalls
            guard !text.isEmpty || !calls.isEmpty else { return [] }
            var encoded: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
            if !calls.isEmpty {
                encoded["tool_calls"] = .array(
                    calls.map { call in
                        [
                            "id": .string(call.id), "type": "function",
                            "function": ["name": .string(call.name), "arguments": .string(call.input.jsonString)],
                        ]
                    })
            }
            return [.object(encoded)]
        case .user:
            var encoded: [JSONValue] = message.content.compactMap { block in
                guard case .toolResult(let result) = block else { return nil }
                return ["role": "tool", "tool_call_id": .string(result.toolCallID), "content": .string(result.content)]
            }
            if !text.isEmpty { encoded.append(["role": "user", "content": .string(text)]) }
            return encoded
        }
    }
}

/// Reads Chat Completions chunks: `choices[0].delta` with `content` and
/// `tool_calls` (by `index`: the id and name first, then pieces of
/// `arguments`), a `finish_reason`, then a chunk with `usage` and no
/// choices, then `data: [DONE]`. OpenRouter may send `error` in a chunk.
struct OpenAIDecoder: StreamDecoder {
    private struct PendingCall {
        var id: String
        var name: String
        var arguments: String
    }

    let secret: Secret
    /// The calls being streamed, by the order they started.
    private var calls: [Int: PendingCall] = [:]
    /// The server's `index` to the call it last named.
    private var keyForIndex: [Int: Int] = [:]
    private var finishReason: FinishReason?
    private var refused = false
    private var done = false

    init(secret: String) { self.secret = Secret(secret) }

    mutating func decode(_ event: SSEEvent) throws -> [ModelEvent] {
        guard !done else { return [] }
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            done = true
            return try complete()
        }
        let json: JSONValue
        do { json = try JSONValue(parsing: event.data) } catch { throw ModelError.malformed("a chunk that is not JSON") }
        if let error = json["error"], error != .null { throw ModelError(streamError: error, secret: secret.value) }

        var events: [ModelEvent] = []
        if let choice = json["choices"]?.array?.first {
            let delta = choice["delta"] ?? .null
            if let text = delta["content"]?.string, !text.isEmpty { events.append(.textDelta(text)) }
            // OpenAI words a refusal in its own field and still finishes with "stop".
            if let text = delta["refusal"]?.string, !text.isEmpty {
                refused = true
                events.append(.textDelta(text))
            }
            for call in delta["tool_calls"]?.array ?? [] {
                // Calls are told apart by id first: some servers leave `index`
                // out, or send every call as index 0. A piece without an id
                // continues the call last seen at its index, or the latest one.
                let id = call["id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                let serverIndex = call["index"]?.int
                let key =
                    if let id { calls.first { $0.value.id == id }?.key ?? calls.count }
                    else { serverIndex.flatMap { keyForIndex[$0] } ?? max(calls.count - 1, 0) }
                if let serverIndex { keyForIndex[serverIndex] = key }
                let function = call["function"] ?? .null
                let piece = function["arguments"]?.string ?? ""
                if calls[key] != nil {
                    calls[key]?.arguments += piece
                } else {
                    calls[key] = PendingCall(id: id ?? "call_\(key)", name: function["name"]?.string ?? "", arguments: piece)
                }
            }
            if let reason = choice["finish_reason"]?.string, !reason.isEmpty {
                finishReason = refused ? .refusal : Self.finishReason(reason)
                events += completedCalls()
            }
        }
        if let usage = json["usage"], usage != .null {
            events.append(
                .usage(Usage(inputTokens: usage["prompt_tokens"]?.int ?? 0, outputTokens: usage["completion_tokens"]?.int ?? 0)))
        }
        return events
    }

    /// The stream may end with `[DONE]` or simply close; either is fine once a
    /// finish reason has come.
    mutating func finish() throws -> [ModelEvent] {
        done ? [] : try complete()
    }

    private mutating func complete() throws -> [ModelEvent] {
        guard let finishReason else { throw ModelError.network("The reply stopped before it was finished.") }
        return completedCalls() + [.finished(finishReason)]
    }

    private mutating func completedCalls() -> [ModelEvent] {
        defer { calls = [:]; keyForIndex = [:] }
        return calls.sorted { $0.key < $1.key }.map { .toolCallCompleted(ToolCall(id: $0.value.id, name: $0.value.name, arguments: $0.value.arguments)) }
    }

    static func finishReason(_ reason: String) -> FinishReason {
        switch reason {
        case "stop": .endTurn
        case "tool_calls", "function_call": .toolUse
        case "length": .maxTokens
        case "content_filter": .refusal
        default: .other(reason)
        }
    }
}
