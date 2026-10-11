import Foundation
import Testing
@testable import AgentKit

struct AgentLoopTests {
    private func loop(_ provider: FakeProvider, tools: [Tool] = [echoTool()]) -> AgentLoop {
        AgentLoop(provider: provider, tools: ToolRegistry(tools), model: "m", systemPrompt: "system")
    }

    @Test func toolCallsRunAndTheirResultsGoBackUntilTheModelIsDone() async throws {
        let runs = Counter()
        let provider = FakeProvider([
            toolCallReply(id: "c1", name: "echo", input: ["n": 1], text: "Let me look."),
            toolCallReply(id: "c2", name: "echo", input: ["n": 2]),
            textReply("Done."),
        ])
        let log = EventLog()
        let turn = await loop(provider, tools: [echoTool(runs: runs)]).run(history: [], message: "go") { log.record($0) }

        #expect(turn.outcome == .finished(.endTurn))
        #expect(runs.value == 2)
        #expect(turn.toolsRun == ["echo", "echo"])
        #expect(turn.usage == Usage(inputTokens: 250, outputTokens: 25))
        #expect(
            turn.messages == [
                .user("go"),
                ModelMessage(role: .assistant, content: [.text("Let me look."), .toolUse(ToolCall(id: "c1", name: "echo", input: ["n": 1]))]),
                ModelMessage(role: .user, content: [.toolResult(ToolResult(toolCallID: "c1", content: #"{"n":1}"#))]),
                ModelMessage(role: .assistant, content: [.toolUse(ToolCall(id: "c2", name: "echo", input: ["n": 2]))]),
                ModelMessage(role: .user, content: [.toolResult(ToolResult(toolCallID: "c2", content: #"{"n":2}"#))]),
                ModelMessage(role: .assistant, content: [.text("Done.")]),
            ])
        #expect(turn.summary == nil)

        // Each call sees everything so far.
        let requests = provider.received
        #expect(requests.map(\.messages.count) == [1, 3, 5])
        #expect(requests[0].system == "system")
        #expect(requests[0].tools.map(\.name) == ["echo"])

        let events = log.all
        #expect(events.first == .textDelta("Let me look."))
        #expect(events.contains(.toolStarted(id: "c1", name: "echo", input: ["n": 1])))
        let finished = events.compactMap { event -> (String, Bool)? in
            if case .toolFinished(_, _, let summary, _, let failed) = event { (summary, failed) } else { nil }
        }
        #expect(finished.map(\.0) == [#"{"n":1}"#, #"{"n":2}"#])
        #expect(finished.allSatisfy { !$0.1 })
    }

    @Test func theStepCapStopsTheTurnWithEveryCallAnswered() async {
        let runs = Counter()
        let provider = FakeProvider([], thenRepeat: toolCallReply(id: "again", name: "echo"))
        var agent = loop(provider, tools: [echoTool(runs: runs)])
        agent.maxSteps = 3
        let turn = await agent.run(history: [], message: "loop forever")

        #expect(turn.outcome == .stepLimit)
        #expect(provider.received.count == 3)
        #expect(runs.value == 2)
        #expect(turn.toolsNotRun == ["echo"])
        #expect(turn.messages.dropLast().last == ModelMessage(role: .user, content: [.toolResult(ToolResult(toolCallID: "again", content: "Not run: the turn reached its limit of 3 steps.", isError: true))]))
        // Closed on the model's side, so the next turn does not open on tool results.
        #expect(turn.messages.last == ModelMessage(role: .assistant, content: [.text("(The turn ended before an answer.)")]))
        #expect(turn.summary == "Stopped after the most steps a turn may take. Ran echo, echo. Did not run echo.")
    }

    @Test func cancellingMidStreamKeepsTheTextThatArrived() async {
        let provider = FakeProvider([
            .hanging([
                .textDelta("Half a "), .textDelta("thought"), .toolCallCompleted(ToolCall(id: "c", name: "echo", input: [:])),
            ])
        ])
        let agent = loop(provider)
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            await agent.run(history: [], message: "hi") { event in
                if event == .textDelta("thought") { signal.yield() }
            }
        }
        for await _ in started { break }
        task.cancel()
        let turn = await task.value

        #expect(turn.outcome == .stopped)
        // The unanswered call is dropped; the text stays.
        #expect(turn.messages == [.user("hi"), ModelMessage(role: .assistant, content: [.text("Half a thought")])])
        #expect(turn.summary == "Stopped. No tools ran.")
    }

    @Test func cancellingDuringAToolAnswersEveryCall() async {
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let slow = Tool(name: "slow", description: "", inputSchema: ["type": "object"], effect: .read) { _ in
            signal.yield()
            try await Task.sleep(for: .seconds(600))
            return .text("never")
        }
        let provider = FakeProvider([
            .events([
                .toolCallCompleted(ToolCall(id: "a", name: "slow", input: [:])),
                .toolCallCompleted(ToolCall(id: "b", name: "echo", input: [:])),
                .finished(.toolUse),
            ])
        ])
        let agent = loop(provider, tools: [slow, echoTool()])
        let task = Task { await agent.run(history: [], message: "hi") }
        for await _ in started { break }
        task.cancel()
        let turn = await task.value

        #expect(turn.outcome == .stopped)
        #expect(provider.received.count == 1)
        #expect(turn.toolsRun == ["slow"])
        #expect(turn.toolsNotRun == ["echo"])
        #expect(turn.messages.last?.role == .assistant)
        #expect(
            turn.messages.dropLast().last
                == ModelMessage(
                    role: .user,
                    content: [
                        .toolResult(ToolResult(toolCallID: "a", content: "Stopped by the user before it finished.", isError: true)),
                        .toolResult(ToolResult(toolCallID: "b", content: "Not run: stopped by the user.", isError: true)),
                    ]))
    }

    @Test func aProviderErrorEndsTheTurnAndIsReported() async {
        let provider = FakeProvider([.failing([.textDelta("Par")], .invalidKey("bad key"))])
        let turn = await loop(provider).run(history: [], message: "hi")
        #expect(turn.outcome == .failed(.invalidKey("bad key")))
        #expect(turn.messages == [.user("hi"), ModelMessage(role: .assistant, content: [.text("Par")])])
        #expect(turn.summary == "The provider refused the API key. (bad key) No tools ran.")
    }

    @Test func aTurnWithNoReplyAddsNothing() async {
        let provider = FakeProvider([.failing([], .network("Not connected to the internet."))])
        let turn = await loop(provider).run(history: [], message: "hi")
        #expect(turn.outcome == .failed(.network("Not connected to the internet.")))
        #expect(turn.messages == [])
        #expect(turn.summary == "Not connected to the internet. No tools ran.")
    }

    @Test func reasoningGoesBackWithinItsTurnOnly() async {
        let thinking: JSONValue = ["type": "thinking", "thinking": "", "signature": "sig"]
        let provider = FakeProvider([
            .events([
                .providerBlock(name: "anthropic", thinking), .toolCallCompleted(ToolCall(id: "c1", name: "echo", input: [:])),
                .finished(.toolUse),
            ]),
            textReply("Done."),
            textReply("Again."),
        ])
        let agent = loop(provider)
        let first = await agent.run(history: [], message: "go")
        // Step 2 sends step 1's reasoning back before its tool call.
        #expect(provider.received[1].messages[1].content.first == .provider(name: "anthropic", thinking))
        _ = await agent.run(history: first.messages, message: "more")
        // The next turn sends earlier turns without it.
        #expect(provider.received[2].messages[1].content == [.toolUse(ToolCall(id: "c1", name: "echo", input: [:]))])
    }

    @Test func badCallsAreAnsweredWithErrorsNotRun() async {
        let runs = Counter()
        let provider = FakeProvider([
            .events([
                .toolCallCompleted(ToolCall(id: "a", name: "missing", input: [:])),
                .toolCallCompleted(ToolCall(id: "b", name: "echo", input: [:], malformedInput: "{\"n\":")),
                .finished(.toolUse),
            ]),
            textReply("Sorry."),
        ])
        let turn = await loop(provider, tools: [echoTool(runs: runs)]).run(history: [], message: "hi")
        #expect(runs.value == 0)
        guard case .user = turn.messages[2].role, case .toolResult(let first) = turn.messages[2].content[0],
            case .toolResult(let second) = turn.messages[2].content[1]
        else {
            Issue.record("no tool results")
            return
        }
        #expect(first.isError && first.content == "There is no tool named missing.")
        #expect(second.isError && second.content.contains("not a valid JSON object"))
    }

    @Test func callsInACutOffReplyAreNotRun() async {
        let runs = Counter()
        let provider = FakeProvider([
            .events([.toolCallCompleted(ToolCall(id: "a", name: "echo", input: [:])), .finished(.maxTokens)])
        ])
        let turn = await loop(provider, tools: [echoTool(runs: runs)]).run(history: [], message: "hi")
        #expect(turn.outcome == .finished(.maxTokens))
        #expect(runs.value == 0)
        #expect(turn.toolsNotRun == ["echo"])
        #expect(provider.received.count == 1)
    }

    @Test func aRefusedReplyStaysOutOfTheHistory() async {
        let runs = Counter()
        let provider = FakeProvider([
            .events([.textDelta("Part"), .toolCallCompleted(ToolCall(id: "a", name: "echo", input: [:])), .finished(.refusal)])
        ])
        let turn = await loop(provider, tools: [echoTool(runs: runs)]).run(history: [], message: "hi")
        #expect(turn.outcome == .finished(.refusal))
        #expect(turn.messages == [])
        #expect(runs.value == 0)
        #expect(turn.toolsNotRun == ["echo"])
        #expect(turn.summary == "The provider declined to answer. No tools ran. Did not run echo.")
    }

    @Test func earlierTurnsAreWindowedAndLoseTheirProviderBlocks() async {
        let old = [ModelMessage.user(String(repeating: "x", count: 400)), ModelMessage(role: .assistant, content: [.text("old")])]
        let recent = [
            ModelMessage.user("recent"),
            ModelMessage(role: .assistant, content: [.provider(name: "anthropic", ["type": "thinking"]), .text("ok")]),
        ]
        let provider = FakeProvider([textReply("hi")])
        var agent = loop(provider)
        agent.historyBudget = 50
        _ = await agent.run(history: old + recent, message: "now")
        #expect(
            provider.received.first?.messages
                == [.user("recent"), ModelMessage(role: .assistant, content: [.text("ok")]), .user("now")])
    }

    @Test func longToolResultsAreCut() async {
        let big = Tool(name: "big", description: "", inputSchema: ["type": "object"], effect: .read) { _ in
            .text(String(repeating: "y", count: 100))
        }
        let provider = FakeProvider([toolCallReply(id: "a", name: "big"), textReply("ok")])
        var agent = loop(provider, tools: [big])
        agent.maxToolResultCharacters = 10
        let turn = await agent.run(history: [], message: "hi")
        guard case .toolResult(let result) = turn.messages[2].content.first else {
            Issue.record("no result")
            return
        }
        #expect(result.content == String(repeating: "y", count: 10) + "\n[cut: the result was longer]")
    }
}

struct ContextWindowTests {
    private func turn(_ text: String, reply: String) -> [ModelMessage] {
        [.user(text), ModelMessage(role: .assistant, content: [.text(reply)])]
    }

    @Test func estimateIsAThirdTokenPerUTF8Byte() {
        #expect(ContextWindow.estimatedTokens("") == 0)
        #expect(ContextWindow.estimatedTokens("abc") == 1)
        #expect(ContextWindow.estimatedTokens("abcd") == 2)
        // Three bytes a character: a token each, about what a tokenizer gives.
        #expect(ContextWindow.estimatedTokens("日本語") == 3)
        #expect(ContextWindow.estimatedTokens(ModelMessage(role: .user, content: [.text("abc"), .text("def")])) == 2)
    }

    @Test func theMostRecentWholeTurnsThatFit() {
        // Each turn is 42 + 42 bytes: 28 estimated tokens.
        let a = turn(String(repeating: "a", count: 42), reply: String(repeating: "A", count: 42))
        let b = turn(String(repeating: "b", count: 42), reply: String(repeating: "B", count: 42))
        let c = turn(String(repeating: "c", count: 42), reply: String(repeating: "C", count: 42))
        #expect(ContextWindow.recent(a + b + c, budget: 84) == a + b + c)
        #expect(ContextWindow.recent(a + b + c, budget: 83) == b + c)
        #expect(ContextWindow.recent(a + b + c, budget: 28) == c)
        #expect(ContextWindow.recent(a + b + c, budget: 27) == [])
        #expect(ContextWindow.recent([], budget: 100) == [])
    }

    @Test func anOversizedLatestTurnDoesNotEmptyTheWindow() {
        let small = turn("hi", reply: "hello")
        let huge = turn(String(repeating: "x", count: 600), reply: "ok")
        #expect(ContextWindow.recent(small + huge, budget: 100) == small)
    }

    @Test func aWindowNeverOpensOnToolResults() {
        let call = ToolCall(id: "c", name: "echo", input: [:])
        let toolTurn: [ModelMessage] = [
            .user("q"),
            ModelMessage(role: .assistant, content: [.toolUse(call)]),
            ModelMessage(role: .user, content: [.toolResult(ToolResult(toolCallID: "c", content: String(repeating: "r", count: 400)))]),
            ModelMessage(role: .assistant, content: [.text("a")]),
        ]
        // The tool turn is over budget as a whole, so none of it is sent,
        // although its last two messages would fit alone.
        #expect(ContextWindow.recent(toolTurn + turn("next", reply: "ok"), budget: 50) == turn("next", reply: "ok"))
    }
}
