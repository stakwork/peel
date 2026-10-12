import Foundation
import Synchronization
import Testing
@testable import AgentKit

/// A recorded stream from `Fixtures/`.
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
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

/// A fixture run through the SSE parser and `decoder`: the events, and the
/// error that ended them, if any.
func decode(_ name: String, with decoder: some StreamDecoder) throws -> (events: [ModelEvent], error: ModelError?) {
    var decoder = decoder
    var events: [ModelEvent] = []
    do {
        for event in SSEParser.events(in: try fixture(name)) { events += try decoder.decode(event) }
        events += try decoder.finish()
        return (events, nil)
    } catch let error as ModelError {
        return (events, error)
    }
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
