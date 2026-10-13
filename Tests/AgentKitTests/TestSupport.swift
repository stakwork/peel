import Foundation
import Synchronization
import Testing
@testable import AgentKit

/// A stream from `Fixtures/`, written by hand from each provider's
/// streaming docs: the decoders' logic on documented shapes, pinned event
/// by event. Real streams, once Tom has recorded them, are in
/// `Fixtures/recorded/` (see `StreamCase`).
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// One provider's streamed reply of one kind: the one recorded from the
/// real API (`scripts/record-agent-fixtures.sh`) when
/// `Fixtures/recorded/<provider>-<kind>.sse` exists, else the hand-written
/// one (OpenRouter's falls back to OpenAI's, the same wire shape). Never
/// the network.
struct StreamCase: CustomTestStringConvertible, Sendable {
    enum Kind: String, CaseIterable, Sendable { case text, tool }

    let provider: AgentProvider
    let kind: Kind

    static let all = AgentProvider.allCases.flatMap { provider in Kind.allCases.map { StreamCase(provider: provider, kind: $0) } }

    /// Anthropic's own API, or OpenAI's Chat Completions (OpenAI, OpenRouter).
    private var isAnthropic: Bool { provider == .anthropic }

    var recorded: URL? {
        Bundle.module.url(forResource: "\(provider.rawValue)-\(kind.rawValue)", withExtension: "sse", subdirectory: "Fixtures/recorded")
    }

    var testDescription: String { "\(provider.rawValue)-\(kind.rawValue) (\(recorded == nil ? "written" : "recorded"))" }

    func stream() throws -> String {
        if let recorded { return try String(contentsOf: recorded, encoding: .utf8) }
        return try fixture("\(isAnthropic ? "anthropic" : "openai")-\(kind.rawValue)")
    }

    var decoder: any StreamDecoder { isAnthropic ? AnthropicDecoder(secret: "key") : OpenAIDecoder(secret: "key") }
}

extension SSEParser {
    /// Every event in a whole stream's text.
    static func events(in text: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let event = parser.feed(line) { events.append(event) }
        }
        if let event = parser.flush() { events.append(event) }
        return events
    }
}

/// A stream's text run through the SSE parser and `decoder`: the events,
/// and the error that ended them, if any.
func decode(stream text: String, with decoder: some StreamDecoder) throws -> (events: [ModelEvent], error: ModelError?) {
    var decoder = decoder
    var events: [ModelEvent] = []
    do {
        for event in SSEParser.events(in: text) { events += try decoder.decode(event) }
        events += try decoder.finish()
        return (events, nil)
    } catch let error as ModelError {
        return (events, error)
    }
}

/// A hand-written fixture, decoded.
func decode(_ name: String, with decoder: some StreamDecoder) throws -> (events: [ModelEvent], error: ModelError?) {
    try decode(stream: try fixture(name), with: decoder)
}

/// A provider that plays scripted replies, one per call, and records what it
/// was asked.
final class FakeProvider: ModelProvider {
    enum Reply: Sendable {
        /// These events, then the end of the stream.
        case events([ModelEvent])
        /// These events, then this error.
        case failing([ModelEvent], ModelError)
        /// These events, then nothing until the reader is cancelled.
        case hanging([ModelEvent])
    }

    private let replies: Mutex<[Reply]>
    private let requests = Mutex<[ModelRequest]>([])
    /// Played when the script runs out.
    private let fallback: Reply?

    init(_ replies: [Reply], thenRepeat fallback: Reply? = nil) {
        self.replies = Mutex(replies)
        self.fallback = fallback
    }

    var received: [ModelRequest] { requests.withLock { $0 } }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        requests.withLock { $0.append(request) }
        let reply = replies.withLock { $0.isEmpty ? fallback : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .events(let events)?:
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                case .failing(let events, let error)?:
                    for event in events { continuation.yield(event) }
                    continuation.finish(throwing: error)
                case .hanging(let events)?:
                    for event in events { continuation.yield(event) }
                    try? await Task.sleep(for: .seconds(600))
                    continuation.finish(throwing: CancellationError())
                case nil:
                    continuation.finish(throwing: ModelError.malformed("no reply scripted"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Events a loop emitted, collected across tasks.
final class EventLog: Sendable {
    private let events = Mutex<[LoopEvent]>([])
    var all: [LoopEvent] { events.withLock { $0 } }
    func record(_ event: LoopEvent) { events.withLock { $0.append(event) } }

    /// The tool rows opened and closed, by call id, in order.
    var opened: [String] { all.compactMap { if case .toolStarted(let id, _, _) = $0 { id } else { nil } } }
    var closed: [String] { all.compactMap { if case .toolFinished(let id, _, _, _, _, _) = $0 { id } else { nil } } }
}

/// Waits a loop was asked to make.
final class Waits: Sendable {
    private let waits = Mutex<[Duration]>([])
    var all: [Duration] { waits.withLock { $0 } }
    func record(_ wait: Duration) { waits.withLock { $0.append(wait) } }
}


/// A reply that asks for one tool call.
func toolCallReply(id: String, name: String, input: JSONValue = [:], text: String = "") -> FakeProvider.Reply {
    .events(
        (text.isEmpty ? [] : [.textDelta(text)]) + [
            .toolCallCompleted(ToolCall(id: id, name: name, input: input)),
            .usage(Usage(inputTokens: 100, outputTokens: 10)),
            .finished(.toolUse),
        ])
}

func textReply(_ text: String) -> FakeProvider.Reply {
    .events([.textDelta(text), .usage(Usage(inputTokens: 50, outputTokens: 5)), .finished(.endTurn)])
}

final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// A tool that echoes its input, counting its runs.
func echoTool(runs: Counter = Counter()) -> Tool {
    Tool(name: "echo", description: "Echoes its input.", inputSchema: ["type": "object"], effect: .read) { input in
        runs.increment()
        return .json(input)
    }
}

/// Waits for `condition`, up to two seconds.
@MainActor
func until(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
}

/// An approver that answers from a script and records what it was asked;
/// `.hang` waits until its task is cancelled.
final class ScriptedApprover: ToolApprover {
    enum Answer: Sendable { case outcome(ApprovalOutcome), hang }

    private let answer: Answer
    private let asked = Mutex<[ApprovalRequest]>([])
    var requests: [ApprovalRequest] { asked.withLock { $0 } }

    init(_ answer: Answer) {
        self.answer = answer
    }

    func approve(_ request: ApprovalRequest) async -> ApprovalOutcome {
        asked.withLock { $0.append(request) }
        switch answer {
        case .outcome(let outcome):
            return outcome
        case .hang:
            try? await Task.sleep(for: .seconds(600))
            return .stopped
        }
    }
}

/// A send-effect tool that says what it will do, counting its runs.
func sendTool(runs: Counter = Counter(), cost: String? = nil) -> Tool {
    Tool(name: "send", description: "Sends.", inputSchema: ["type": "object"], effect: .send) { input in
        let to = input["to"]?.string ?? "nobody"
        guard to != "two" else { return .result(.text("Two chats match; ask which.")) }
        let intent = ToolIntent(action: "Send to \(to)", content: input["text"]?.string, cost: cost,
                                target: ToolIntent.Target(id: "id-\(to)", name: to))
        return .action(intent) {
            runs.increment()
            return .text("Sent to \(to)")
        }
    }
}

/// A credential kept in memory; `failing` makes reads throw, as a locked Keychain would.
final class MemoryCredentials: AgentCredentialStore {
    private let kept = Mutex<AgentCredential?>(nil)
    private let fails = Mutex(false)
    var failing: Bool {
        get { fails.withLock { $0 } }
        set { fails.withLock { $0 = newValue } }
    }

    struct Locked: LocalizedError { var errorDescription: String? { "locked" } }

    func read() throws -> AgentCredential? {
        if failing { throw Locked() }
        return kept.withLock { $0 }
    }
    func write(_ credential: AgentCredential) throws { kept.withLock { $0 = credential } }
    func delete() throws { kept.withLock { $0 = nil } }
}

/// The credential every session test connects with.
let testKey = AgentCredential(provider: .anthropic, model: "claude-sonnet-5-5", apiKey: "sk-ant-test-4f2a")

/// A session playing `provider`'s script, connected with `testKey`
/// unless given `credentials` of its own.
@MainActor
func connectedSession(
    _ provider: FakeProvider, store: any AgentStore, tools: [Tool] = [echoTool()], credentials: MemoryCredentials? = nil
) throws -> AgentSession {
    let credentials = try credentials ?? {
        let connected = MemoryCredentials()
        try connected.write(testKey)
        return connected
    }()
    return AgentSession(store: store, credentials: credentials, tools: ToolRegistry(tools), systemPrompt: "system",
                        makeClient: { _ in provider })
}

/// A fresh path for an agent store in the temporary directory; the caller removes it.
func temporaryStorePath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).sqlite").path
}

/// Every event of a stream, and the error that ended it, as `ModelError`.
func collect(_ stream: AsyncThrowingStream<ModelEvent, Error>) async -> ([ModelEvent], ModelError?) {
    var events: [ModelEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, ModelError(error))
    }
}
