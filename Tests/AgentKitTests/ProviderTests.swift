import Foundation
import Synchronization
import Testing
@testable import AgentKit

/// Serves canned HTTP responses in process, by request path, and keeps the
/// requests it saw. No network.
final class StubProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String
    }

    static let responses = Mutex<[String: Response]>([:])
    static let requests = Mutex<[String: URLRequest]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var seen = request
        // URLSession moves the body into a stream before a protocol sees it.
        if seen.httpBody == nil, let stream = seen.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            seen.httpBody = data
        }
        Self.requests.withLock { $0[path] = seen }
        guard let response = Self.responses.withLock({ $0[path] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func serve(_ path: String, _ response: Response) {
        responses.withLock { $0[path] = response }
    }

    static func request(_ path: String) -> URLRequest? {
        requests.withLock { $0[path] }
    }
}

private let request = ModelRequest(
    model: "test-model", system: "Be brief.",
    messages: [
        .user("What time is it?"),
        ModelMessage(
            role: .assistant,
            content: [
                .provider(name: "anthropic", ["type": "thinking", "thinking": "t", "signature": "s"]),
                .provider(name: "other", ["x": 1]),
                .text(""),
                .text(" \n"),
                .text("Checking."),
                .toolUse(ToolCall(id: "c1", name: "current_time", input: [:])),
            ]),
        ModelMessage(role: .user, content: [.toolResult(ToolResult(toolCallID: "c1", content: "14:05", isError: true))]),
    ],
    tools: [Tool.currentTime.definition], maxTokens: 1000)

struct ProviderTests {
    private let session = ModelHTTP.session(protocolClasses: [StubProtocol.self])

    @Test func anthropicStreamsAndSendsTheKeyOnlyInItsHeader() async throws {
        StubProtocol.serve("/a1/messages", .init(status: 200, headers: ["content-type": "text/event-stream"], body: try StreamCase(provider: .anthropic, kind: .text).stream()))
        let provider = AnthropicProvider(apiKey: "sk-ant-secret", baseURL: URL(string: "https://anthropic.test/a1")!, session: session)
        let (events, error) = await collect(provider.stream(request))
        #expect(error == nil)
        #expect(events.last == .finished(.endTurn))

        let sent = try #require(StubProtocol.request("/a1/messages"))
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-ant-secret")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        #expect(!body.contains("sk-ant-secret"))
    }

    @Test func anthropicBody() throws {
        let body = AnthropicProvider.body(for: request)
        #expect(body["model"] == "test-model")
        #expect(body["max_tokens"] == 1000)
        #expect(body["stream"] == true)
        #expect(body["system"] == "Be brief.")
        #expect(body["cache_control"] == ["type": "ephemeral"])
        #expect(body["tools"]?.array?.first?["eager_input_streaming"] == true)
        #expect(body["tools"]?.array?.first?["input_schema"] == Tool.currentTime.definition.inputSchema)
        let messages = try #require(body["messages"]?.array)
        #expect(messages.count == 3)
        // Its own provider block kept, in order; another's and empty text left out.
        #expect(
            messages[1]["content"]
                == [
                    ["type": "thinking", "thinking": "t", "signature": "s"],
                    ["type": "text", "text": "Checking."],
                    ["type": "tool_use", "id": "c1", "name": "current_time", "input": [:]],
                ])
        #expect(messages[2]["content"] == [["type": "tool_result", "tool_use_id": "c1", "content": "14:05", "is_error": true]])
    }

    @Test func openAIStreamsWithBearerAuthAndExtraHeaders() async throws {
        StubProtocol.serve("/o1/chat/completions", .init(status: 200, body: try StreamCase(provider: .openRouter, kind: .tool).stream()))
        let provider = OpenAICompatibleProvider(
            apiKey: "sk-or-secret", baseURL: URL(string: "https://router.test/o1")!, headers: ["X-Title": "Peel"],
            maxTokensField: "max_tokens", session: session)
        let (events, error) = await collect(provider.stream(request))
        #expect(error == nil)
        #expect(events.last == .finished(.toolUse))

        let sent = try #require(StubProtocol.request("/o1/chat/completions"))
        #expect(sent.value(forHTTPHeaderField: "authorization") == "Bearer sk-or-secret")
        #expect(sent.value(forHTTPHeaderField: "X-Title") == "Peel")
        let body = try JSONValue(parsing: String(decoding: try #require(sent.httpBody), as: UTF8.self))
        #expect(body["max_tokens"] == 1000)
        #expect(body["stream_options"] == ["include_usage": true])
        #expect(!body.jsonString.contains("sk-or-secret"))
        #expect(
            body["messages"]
                == [
                    ["role": "system", "content": "Be brief."],
                    ["role": "user", "content": "What time is it?"],
                    [
                        "role": "assistant", "content": " \nChecking.",
                        "tool_calls": [["id": "c1", "type": "function", "function": ["name": "current_time", "arguments": "{}"]]],
                    ],
                    ["role": "tool", "tool_call_id": "c1", "content": "14:05"],
                ])
        #expect(body["tools"]?.array?.first?["function"]?["parameters"] == Tool.currentTime.definition.inputSchema)
    }

    @Test func anErrorStatusBecomesAModelError() async throws {
        StubProtocol.serve(
            "/e1/messages",
            .init(status: 429, headers: ["retry-after": "30"], body: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#))
        let provider = AnthropicProvider(apiKey: "k", baseURL: URL(string: "https://anthropic.test/e1")!, session: session)
        let (events, error) = await collect(provider.stream(request))
        #expect(events.isEmpty)
        #expect(error == .rateLimited(retryAfter: 30))
    }

    /// Each provider's answer to a bad key, as its docs give it (OpenAI's
    /// masks the key; this OpenRouter one echoes it whole), reaches the
    /// session as `.invalidKey`, without the key in its words.
    @Test(arguments: AgentProvider.allCases)
    func aBadKeyIsInvalidKeyWithoutTheKey(provider: AgentProvider) async {
        let key = "sk-peel-not-a-real-key-cd12"
        let base = URL(string: "https://provider.test/key-\(provider.rawValue)")!
        let body = switch provider {
        case .anthropic: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        case .openAI:
            #"{"error":{"message":"Incorrect API key provided: sk-peel****cd12.","type":"invalid_request_error","code":"invalid_api_key"}}"#
        case .openRouter: #"{"error":{"message":"Invalid key \#(key)","code":401}}"#
        }
        let client: any ModelProvider = provider == .anthropic
            ? AnthropicProvider(apiKey: key, baseURL: base, session: session)
            : OpenAICompatibleProvider(apiKey: key, baseURL: base, headers: [:], maxTokensField: "max_tokens", session: session)
        StubProtocol.serve(base.path + (provider == .anthropic ? "/messages" : "/chat/completions"), .init(status: 401, body: body))
        let (events, error) = await collect(client.stream(request))
        #expect(events.isEmpty)
        guard case .invalidKey(let message, _) = error else {
            Issue.record("\(provider.name) answered a bad key with \(String(describing: error))")
            return
        }
        for part in [key, "cd12", "sk-peel"] { #expect(message?.contains(part) != true, "\(message ?? "")") }
    }

    @Test func noNetworkIsAPlainError() async {
        // Nothing is served at this path: the stub fails as an unreachable host would.
        let provider = AnthropicProvider(apiKey: "k", baseURL: URL(string: "https://anthropic.test/offline")!, session: session)
        let (events, error) = await collect(provider.stream(request))
        #expect(events.isEmpty)
        #expect(error == .network("Could not reach the provider."))
    }

    @Test func theKeyNeverPrints() {
        let provider = AnthropicProvider(apiKey: "sk-ant-secret", baseURL: AnthropicProvider.defaultBaseURL, session: session)
        let loop = AgentLoop(provider: provider, tools: ToolRegistry(), model: "m", systemPrompt: "")
        for text in [String(describing: loop), String(reflecting: loop), { var s = ""; dump(loop, to: &s); return s }()] {
            #expect(!text.contains("sk-ant-secret"))
        }
    }

    @Test(arguments: ["http://api.example.com/v1", "ftp://example.com", "https://user:pw@example.com/v1", "file:///tmp"])
    func theKeyGoesOnlyOverHTTPS(address: String) async {
        let provider = AnthropicProvider(apiKey: "k", baseURL: URL(string: address)!, session: session)
        let (_, error) = await collect(provider.stream(request))
        guard error == .invalidAddress else {
            Issue.record("sent to \(address)")
            return
        }
    }

    @Test func httpToThisMachineIsAllowed() throws {
        #expect(throws: Never.self) { try ModelHTTP.checked(URL(string: "http://127.0.0.1:8080/v1")!) }
        #expect(throws: Never.self) { try ModelHTTP.checked(URL(string: "http://localhost/v1")!) }
        #expect(throws: Never.self) { try ModelHTTP.checked(URL(string: "http://[::1]:8080/v1")!) }
    }
}
