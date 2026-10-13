import Foundation
import Testing
@testable import AgentKit

struct SSEParserTests {
    @Test func eventsEndAtBlankLinesAndJoinDataLines() {
        let events = SSEParser.events(in: "event: a\ndata: one\ndata:two\n\n: comment\nid: 7\nretry: 10\ndata: three\n\ndata: last")
        #expect(
            events == [
                SSEEvent(event: "a", data: "one\ntwo"), SSEEvent(event: nil, data: "three"), SSEEvent(event: nil, data: "last"),
            ])
    }

    @Test func linesSplitAtEveryEndingAndKeepBlankOnes() throws {
        var splitter = LineSplitter()
        var lines: [String] = []
        for byte in Array("a\r\n\r\nb\rc\n\nd".utf8) {
            if let line = try splitter.feed(byte) { lines.append(line) }
        }
        if let line = splitter.flush() { lines.append(line) }
        #expect(lines == ["a", "", "b", "c", "", "d"])
    }

    @Test func aLineOverTheLimitIsMalformed() {
        var splitter = LineSplitter()
        #expect(throws: ModelError.self) {
            for _ in 0...LineSplitter.maxLineBytes { _ = try splitter.feed(UInt8(ascii: "x")) }
        }
    }
}

/// What every provider's stream must decode to, recorded from the real
/// API or written by hand: a text reply in more than one piece, with its
/// usage, ending its turn; tool calls whose input parses, one with
/// arguments, ending for the tools.
struct StreamCaseTests {
    @Test(arguments: StreamCase.all)
    func decodes(_ stream: StreamCase) throws {
        let (events, error) = try decode(stream: try stream.stream(), with: stream.decoder)
        #expect(error == nil)
        switch stream.kind {
        case .text:
            let deltas = events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }
            let usage = events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }.last
            #expect(deltas.count > 1, "the reply came in one piece: not streamed")
            #expect((usage?.inputTokens ?? 0) > 0 && (usage?.outputTokens ?? 0) > 0)
            #expect(events.last == .finished(.endTurn))
        case .tool:
            let calls = events.compactMap { if case .toolCallCompleted(let call) = $0 { call } else { nil } }
            #expect(calls.contains { $0.input != [:] }, "no call with arguments")
            for call in calls { #expect(!call.id.isEmpty && !call.name.isEmpty && call.malformedInput == nil, "\(call)") }
            #expect(events.last == .finished(.toolUse))
        }
    }
}

struct AnthropicDecoderTests {
    @Test func text() throws {
        let (events, error) = try decode("anthropic-text", with: AnthropicDecoder(secret: "key"))
        #expect(error == nil)
        #expect(
            events == [
                .usage(Usage(inputTokens: 125, outputTokens: 1)), .textDelta("Hello"), .textDelta(", Tom."),
                .usage(Usage(inputTokens: 125, outputTokens: 12)),
                .finished(.endTurn),
            ])
    }

    @Test func thinkingTextAndAToolCallSplitAcrossDeltas() throws {
        let (events, error) = try decode("anthropic-tool", with: AnthropicDecoder(secret: "key"))
        #expect(error == nil)
        let thinking: JSONValue = ["type": "thinking", "thinking": "The user wants the weather.", "signature": "EqQBCgIYAh"]
        #expect(
            events == [
                .usage(Usage(inputTokens: 410, outputTokens: 1)),
                .providerBlock(name: "anthropic", thinking),
                .textDelta("Checking."),
                .toolCallCompleted(ToolCall(id: "toolu_01", name: "lookup", input: ["city": "London", "days": 2])),
                .usage(Usage(inputTokens: 410, outputTokens: 89)),
                .finished(.toolUse),
            ])
    }

    @Test func anErrorEventEndsTheStream() throws {
        let (events, error) = try decode("anthropic-error", with: AnthropicDecoder(secret: "key"))
        #expect(events == [.usage(Usage(inputTokens: 9, outputTokens: 1)), .textDelta("Par")])
        #expect(error == .unavailable(status: 529, "Overloaded"))
    }

    @Test func aStreamCutOffBeforeMessageStopIsAnError() throws {
        var decoder = AnthropicDecoder(secret: "key")
        let events = SSEParser.events(in: try fixture("anthropic-text")).dropLast()
        for event in events { _ = try decoder.decode(event) }
        #expect(throws: ModelError.network("The reply stopped before it was finished.")) { try decoder.finish() }
    }

    @Test func toolInputThatIsNotJSONIsMarkedMalformed() throws {
        var decoder = AnthropicDecoder(secret: "key")
        let stream = """
            data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"x","input":{}}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\": "}}

            data: {"type":"content_block_stop","index":0}

            """
        let events = try SSEParser.events(in: stream).flatMap { try decoder.decode($0) }
        #expect(events.last == .toolCallCompleted(ToolCall(id: "t", name: "x", input: [:], malformedInput: "{\"a\": ")))
    }
}

struct OpenAIDecoderTests {
    @Test func text() throws {
        let (events, error) = try decode("openai-text", with: OpenAIDecoder(secret: "key"))
        #expect(error == nil)
        #expect(
            events == [
                .textDelta("Hello"), .textDelta(", Tom."), .usage(Usage(inputTokens: 20, outputTokens: 5)), .finished(.endTurn),
            ])
    }

    @Test func toolCallsAccumulateByIndexAcrossChunks() throws {
        let (events, error) = try decode("openai-tool", with: OpenAIDecoder(secret: "key"))
        #expect(error == nil)
        #expect(
            events == [
                .toolCallCompleted(ToolCall(id: "call_a", name: "lookup", input: ["city": "London"])),
                .toolCallCompleted(ToolCall(id: "call_b", name: "current_time", input: [:])),
                .usage(Usage(inputTokens: 300, outputTokens: 40)),
                .finished(.toolUse),
            ])
    }

    @Test func anErrorChunkEndsTheStreamWithoutTheKey() throws {
        let (events, error) = try decode("openai-error", with: OpenAIDecoder(secret: "sk-or-v1-abcdef123456"))
        #expect(events == [.textDelta("Par")])
        #expect(error == .unavailable(status: 502, "Upstream provider refused [key]"))
    }

    @Test func aStreamThatClosesAfterItsFinishReasonIsWhole() throws {
        var decoder = OpenAIDecoder(secret: "key")
        let events = SSEParser.events(in: try fixture("openai-text")).dropLast()
        var decoded: [ModelEvent] = []
        for event in events { decoded += try decoder.decode(event) }
        decoded += try decoder.finish()
        #expect(decoded.last == .finished(.endTurn))
    }

    @Test func aRefusalFieldIsShownAndEndsAsARefusal() throws {
        var decoder = OpenAIDecoder(secret: "key")
        let stream = """
            data: {"choices":[{"index":0,"delta":{"role":"assistant","refusal":"I can't help with that."}}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """
        let events = try SSEParser.events(in: stream).flatMap { try decoder.decode($0) }
        #expect(events == [.textDelta("I can't help with that."), .finished(.refusal)])
    }

    @Test func callsWithoutAnIndexAreToldApartByID() throws {
        var decoder = OpenAIDecoder(secret: "key")
        let stream = """
            data: {"choices":[{"delta":{"tool_calls":[{"id":"a","function":{"name":"x","arguments":"{\\"n\\":"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"1}"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"id":"b","function":{"name":"y","arguments":"{}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            """
        let events = try SSEParser.events(in: stream).flatMap { try decoder.decode($0) } + decoder.finish()
        let calls = events.compactMap { if case .toolCallCompleted(let call) = $0 { call } else { nil } }
        #expect(calls == [ToolCall(id: "a", name: "x", input: ["n": 1]), ToolCall(id: "b", name: "y", input: [:])])
    }

    @Test func aStreamCutOffBeforeItsFinishReasonIsAnError() throws {
        var decoder = OpenAIDecoder(secret: "key")
        for event in SSEParser.events(in: try fixture("openai-text")).prefix(2) { _ = try decoder.decode(event) }
        #expect(throws: ModelError.self) { try decoder.finish() }
    }
}
