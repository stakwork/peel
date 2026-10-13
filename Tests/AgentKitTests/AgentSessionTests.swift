import Foundation
import Testing
@testable import AgentKit

/// The agent chat's session over a scripted provider: streaming, Stop,
/// failures and Retry, the key's lifecycle, and the conversation kept in
/// the store across a reopen and forgotten by Clear.
@MainActor
struct AgentSessionTests {
    private func session(
        _ provider: FakeProvider, store: (any AgentStore)? = nil, credentials: MemoryCredentials = MemoryCredentials(),
        tools: [Tool] = [echoTool()]
    ) throws -> AgentSession {
        try connectedSession(provider, store: store ?? SQLiteAgentStore.inMemory(device: "test"), tools: tools,
                             credentials: credentials)
    }

    private func connected(_ provider: FakeProvider, store: (any AgentStore)? = nil) throws -> AgentSession {
        try connectedSession(provider, store: store ?? SQLiteAgentStore.inMemory(device: "test"))
    }

    @Test func aFinishedReplyHasNoEndingAndCountsAsUnreadOffScreen() async throws {
        let agent = try connected(FakeProvider([textReply("Hi **there**.")]))
        agent.send("hi")
        try await until { !agent.isRunning }

        #expect(agent.turns.last?.text == "Hi **there**.")
        #expect(agent.turns.last?.ending == nil)
        #expect(agent.unread == 1)
        agent.isShown = true
        #expect(agent.unread == 0)
    }

    /// A reply streams in; Stop keeps what arrived, marked stopped.
    @Test func aReplyStreamsInAndStopKeepsWhatArrived() async throws {
        let provider = FakeProvider([.hanging([.textDelta("Half a "), .textDelta("thought")]), textReply("Next.")])
        let agent = try connected(provider)
        agent.isShown = true
        agent.send("  go on  ")
        #expect(agent.isRunning)
        #expect(agent.turns.map(\.text) == ["go on"])
        try await until { agent.reply?.text == "Half a thought" }
        #expect(provider.received.first?.model == "claude-sonnet-5-5")
        #expect(provider.received.first?.system == "system")
        agent.stop()
        try await until { !agent.isRunning }

        #expect(agent.reply == nil)
        #expect(agent.turns.map(\.author) == [.user, .agent])
        #expect(agent.turns.last?.text == "Half a thought")
        #expect(agent.turns.last?.ending == .stopped)
        #expect(agent.problem == nil)
        #expect(agent.unread == 0)

        // What arrived is part of what the model sees next.
        agent.send("and?")
        try await until { !agent.isRunning }
        #expect(provider.received.last?.messages.map(\.text) == ["go on", "Half a thought", "and?"])
    }

    @Test func aRefusedKeyIsAProblemWithNothingKeptAndRetryAsksAgain() async throws {
        let provider = FakeProvider([.failing([.textDelta("par")], .invalidKey("bad key")), textReply("Fine now.")])
        let agent = try connected(provider)
        agent.send("hi")
        try await until { !agent.isRunning }

        let problem = try #require(agent.problem)
        #expect(problem.failure == .model(.invalidKey("bad key")))
        #expect(problem.failure.isKeyRefused)
        #expect(problem.turnID == agent.turns.first?.id)
        // The message stays; the partial reply does not.
        #expect(agent.turns.map(\.text) == ["hi"])

        agent.retry()
        try await until { !agent.isRunning }
        #expect(agent.problem == nil)
        #expect(agent.turns.map(\.text) == ["hi", "Fine now."])
        // Asked once, not twice.
        #expect(provider.received.last?.messages.map(\.text) == ["hi"])
    }

    @Test func failuresKeepTheProvidersWords() async throws {
        let agent = try connected(FakeProvider([
            .failing([], .rateLimited(retryAfter: 20)), .failing([], .network("Not connected to the internet.")),
        ]))
        // Shown at once, without the retries the loop would make first.
        agent.retryPolicy = .never
        agent.send("one")
        try await until { !agent.isRunning }
        #expect(agent.problem?.failure == .model(.rateLimited(retryAfter: 20)))
        #expect(agent.problem?.failure.isKeyRefused == false)

        agent.retry()
        try await until { !agent.isRunning }
        #expect(agent.problem?.failure == .model(.network("Not connected to the internet.")))
    }

    @Test func aRetryIsShownWhileItWaitsThenGoes() async throws {
        let provider = FakeProvider([.failing([], .rateLimited(retryAfter: 0.3)), textReply("Here.")])
        let agent = try connected(provider)
        agent.send("hi")
        try await until { agent.retrying != nil }
        #expect(agent.retrying?.reason == .rateLimited(retryAfter: 0.3))
        #expect([.milliseconds(300), .zero].contains(agent.retrying?.after))
        #expect(agent.problem == nil)
        try await until { !agent.isRunning }

        #expect(agent.retrying == nil)
        #expect(agent.problem == nil)
        #expect(agent.turns.map(\.text) == ["hi", "Here."])
        #expect(provider.received.count == 2)
    }

    @Test func stopDuringARetryEndsTheReplyAtOnce() async throws {
        let provider = FakeProvider([.failing([], .unavailable(status: 529, nil)), textReply("never")])
        let agent = try connected(provider)
        agent.send("hi")
        try await until { agent.retrying != nil }
        agent.stop()
        try await until { !agent.isRunning }

        #expect(agent.retrying == nil)
        #expect(agent.problem == nil)
        #expect(agent.turns.last?.ending == .stopped)
        #expect(provider.received.count == 1)
    }

    @Test func withNoModelTheMessageWaitsAndConnectingAsksIt() async throws {
        let provider = FakeProvider([textReply("OK"), textReply("Answer.")])
        let credentials = MemoryCredentials()
        let agent = try session(provider, credentials: credentials)
        #expect(agent.connection == nil)

        agent.send("hello?")
        #expect(agent.problem?.failure == .noModel)
        #expect(!agent.isRunning)
        #expect(provider.received.isEmpty)

        try await agent.connect(testKey)
        #expect(agent.connection == AgentSession.Connection(provider: .anthropic, model: "claude-sonnet-5-5", keyHint: "4f2a"))
        #expect(try credentials.read() == testKey)
        try await until { !agent.isRunning }
        #expect(agent.turns.map(\.text) == ["hello?", "Answer."])
        // The check was one small call of its own.
        #expect(provider.received.first?.messages.map(\.text) == ["Reply with OK."])
        #expect(provider.received.first?.tools.isEmpty == true)
    }

    @Test func aKeyThatFailsItsCheckIsNotKept() async throws {
        let credentials = MemoryCredentials()
        let agent = try session(FakeProvider([.failing([], .invalidKey(nil))]), credentials: credentials)
        await #expect(throws: ModelError.invalidKey(nil)) { try await agent.connect(testKey) }
        #expect(agent.connection == nil)
        #expect(try credentials.read() == nil)
    }

    @Test func theModelChangesAndTheKeyIsRemoved() async throws {
        let provider = FakeProvider([textReply("Hi.")])
        let credentials = MemoryCredentials()
        try credentials.write(testKey)
        let agent = try session(provider, credentials: credentials)

        try agent.setModel("claude-opus-5-5")
        #expect(agent.connection?.model == "claude-opus-5-5")
        #expect(try credentials.read()?.model == "claude-opus-5-5")
        #expect(try credentials.read()?.apiKey == testKey.apiKey)

        try agent.removeKey()
        #expect(agent.connection == nil)
        #expect(try credentials.read() == nil)
        agent.send("still there?")
        #expect(agent.problem?.failure == .noModel)
        #expect(provider.received.isEmpty)
    }

    @Test func theConversationSurvivesAReopen() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try connected(
            FakeProvider([toolCallReply(id: "c1", name: "echo", input: ["n": 1]), textReply("Done."),
                          .hanging([.textDelta("Cut")])]),
            store: SQLiteAgentStore(path: path, device: "mac"))
        first.send("use the tool")
        try await until { !first.isRunning }
        first.send("and stop")
        try await until { first.reply?.text == "Cut" }
        first.stop()
        try await until { !first.isRunning }
        try first.rename("Pip")
        let shown = first.turns

        let provider = FakeProvider([textReply("Again.")])
        let second = try connected(provider, store: SQLiteAgentStore(path: path, device: "mac"))
        #expect(second.turns.map(\.id) == shown.map(\.id))
        #expect(second.turns.map(\.text) == ["use the tool", "Done.", "and stop", "Cut"])
        #expect(second.turns.map(\.author) == [.user, .agent, .user, .agent])
        #expect(second.turns[1].tools.map(\.name) == ["echo"])
        #expect(second.turns[1].tools.first?.summary == #"{"n":1}"#)
        #expect(second.turns[1].tools.first?.input == ["n": 1])
        #expect(second.turns[3].ending == .stopped)
        #expect(second.name == "Pip")

        // The model sees the earlier turns as whole messages and replies.
        second.send("more")
        try await until { !second.isRunning }
        #expect(provider.received.last?.messages.map(\.text) == ["use the tool", "Done.", "and stop", "Cut", "more"])
    }

    @Test func eachToolCallIsARecordOfTheReplyThatMadeIt() async throws {
        let store = try SQLiteAgentStore.inMemory(device: "mac")
        let agent = try connected(
            FakeProvider([toolCallReply(id: "c1", name: "echo", input: ["q": "x"]), textReply("Done.")]), store: store)
        agent.send("use the tool")
        try await until { !agent.isRunning }

        let reply = try #require(agent.turns.last)
        let calls = try store.records(type: "ToolCall")
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.name == "echo")
        #expect(call.body == #"{"q":"x"}"#)
        #expect(call.createdBy == "agent")
        #expect(call.source == reply.id)
        #expect(call.props["call_id"] == .string("c1"))
        #expect(call.props["input"] == ["q": "x"])
        #expect(try store.walk(reply.id, edgeTypes: ["tool_call"], direction: .outgoing).map(\.record.refId) == [call.refId])
        // The reply answers the message it came from.
        #expect(try store.read(reply.id)?.source == agent.turns.first?.id)

        try agent.clear()
        #expect(try store.records(type: "ToolCall").isEmpty)
    }

    @Test func toolCallsComeBackInTheOrderTheyRanAndRepeatedIdsKeepTheirOwnRows() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let names = ["echo", "zeta", "alpha", "mid"]
        let tools = names.map { name in
            Tool(name: name, description: "", inputSchema: ["type": "object"], effect: .read) { _ in .text(name) }
        }
        // Two steps that both number their calls from call_0, as an
        // OpenAI-compatible provider without ids does.
        let provider = FakeProvider([
            .events([.toolCallCompleted(ToolCall(id: "call_0", name: "echo", input: [:])),
                     .toolCallCompleted(ToolCall(id: "call_1", name: "zeta", input: [:])), .finished(.toolUse)]),
            .events([.toolCallCompleted(ToolCall(id: "call_0", name: "alpha", input: [:])),
                     .toolCallCompleted(ToolCall(id: "call_1", name: "mid", input: [:])), .finished(.toolUse)]),
            textReply("Done."),
        ])
        let agent = try connectedSession(provider, store: SQLiteAgentStore(path: path, device: "mac"), tools: tools)
        agent.send("run them")
        try await until { !agent.isRunning }
        #expect(agent.turns.last?.tools.map(\.name) == names)
        #expect(agent.turns.last?.tools.compactMap(\.summary) == names)
        #expect(agent.turns.last?.tools.allSatisfy { !$0.failed && $0.duration != nil } == true)

        let reopened = try connectedSession(FakeProvider([]), store: SQLiteAgentStore(path: path, device: "mac"), tools: tools)
        #expect(reopened.turns.last?.tools.map(\.name) == names)
    }

    /// A row keeps what a tool returned only when the tool says so (the
    /// memory tools), through a reopen; a chat read keeps its first line.
    @Test func aRowKeepsOnlyWhatItsToolKeeps() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let kept = Tool(name: "kept", description: "Keeps its row.", inputSchema: ["type": "object"], effect: .read) { _ in
            .kept("Found 1\n{\"a\":1}", row: ["a": 1])
        }
        let tools = [echoTool(), kept]
        let provider = FakeProvider([
            .events([.toolCallCompleted(ToolCall(id: "c1", name: "echo", input: ["n": 1])),
                     .toolCallCompleted(ToolCall(id: "c2", name: "kept", input: [:])), .finished(.toolUse)]),
            textReply("Done."),
        ])
        let agent = try connectedSession(provider, store: SQLiteAgentStore(path: path, device: "mac"), tools: tools)
        agent.send("look")
        try await until { !agent.isRunning }
        #expect(agent.turns.last?.tools.map(\.row) == [nil, ["a": 1]])
        #expect(agent.turns.last?.tools.last?.summary == "Found 1")
        #expect(provider.received.last?.messages.contains {
            $0.content.contains(.toolResult(ToolResult(toolCallID: "c2", content: "Found 1\n{\"a\":1}")))
        } == true)

        let reopened = try connectedSession(FakeProvider([]), store: SQLiteAgentStore(path: path, device: "mac"), tools: tools)
        #expect(reopened.turns.last?.tools.map(\.row) == [nil, ["a": 1]])
    }

    @Test func aKeyThatCannotBeReadIsNotTakenForNoKey() throws {
        let provider = FakeProvider([])
        let credentials = MemoryCredentials()
        try credentials.write(testKey)
        let agent = try session(provider, credentials: credentials)
        credentials.failing = true
        agent.send("hi")
        #expect(agent.problem?.failure == .unreadableKey("locked"))
        #expect(agent.connection != nil)
        #expect(provider.received.isEmpty)
    }

    @Test func closingLetsGoOfTheReplyAndSavesNothing() async throws {
        let store = try SQLiteAgentStore.inMemory(device: "mac")
        let agent = try connected(FakeProvider([.hanging([.textDelta("Half")])]), store: store)
        agent.send("hi")
        try await until { agent.reply?.text == "Half" }
        agent.close()
        #expect(agent.reply == nil)
        #expect(!agent.isRunning)
        try await Task.sleep(for: .milliseconds(50))
        #expect(agent.turns.map(\.text) == ["hi"])
        #expect(try store.records(type: "Turn").count == 1)
    }

    @Test func wordsAfterAToolStartAParagraph() async throws {
        let provider = FakeProvider([
            toolCallReply(id: "c1", name: "echo", text: "Let me look."), textReply("You have 3 unread."),
            textReply("Fine."),
        ])
        let agent = try connected(provider)
        agent.send("what did I miss?")
        try await until { !agent.isRunning }
        #expect(agent.turns.last?.text == "Let me look.\n\nYou have 3 unread.")

        // The model sees next what a relaunch would rebuild: the words, not the tool's result.
        agent.send("thanks")
        try await until { !agent.isRunning }
        #expect(provider.received.last?.messages.map(\.text) == [
            "what did I miss?", "Let me look.\n\nYou have 3 unread.", "thanks",
        ])
    }

    @Test func anEmptyReplyIsAProblemWithRetry() async throws {
        let agent = try connected(FakeProvider([.events([.finished(.endTurn)]), textReply("Here.")]))
        agent.send("hi")
        try await until { !agent.isRunning }
        #expect(agent.problem?.failure == .model(.malformed("an empty reply")))
        agent.retry()
        try await until { !agent.isRunning }
        #expect(agent.turns.map(\.text) == ["hi", "Here."])
    }

    @Test func aConnectFinishingAfterCloseKeepsNothing() async throws {
        let credentials = MemoryCredentials()
        let provider = FakeProvider([.hanging([])])
        let agent = try session(provider, credentials: credentials)
        agent.send("waiting")
        let connecting = Task { try await agent.connect(testKey) }
        try await until { provider.received.count == 1 }
        agent.close()
        connecting.cancel()
        await #expect(throws: (any Error).self) { try await connecting.value }
        #expect(try credentials.read() == nil)
        #expect(agent.connection == nil)
        agent.send("after")
        #expect(agent.turns.map(\.text) == ["waiting"])
    }

    @Test func clearForgetsTheConversation() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteAgentStore(path: path, device: "mac")
        let agent = try connected(FakeProvider([textReply("One."), textReply("Two.")]), store: store)
        agent.send("first")
        try await until { !agent.isRunning }
        try agent.clear()
        #expect(agent.turns.isEmpty)
        #expect(try store.records(type: "Turn").isEmpty)
        #expect(try store.records(type: "Conversation").isEmpty)

        // A new conversation starts, and the model sees nothing before it.
        agent.send("second")
        try await until { !agent.isRunning }
        let reopened = try connected(FakeProvider([]), store: SQLiteAgentStore(path: path, device: "mac"))
        #expect(reopened.turns.map(\.text) == ["second", "Two."])
    }

    @Test func historyLeavesOutDeclinedAndEmptyReplies() {
        let at = Date(timeIntervalSince1970: 0)
        let turns = [
            AgentTurn(id: "1", author: .user, text: "a", date: at),
            AgentTurn(id: "2", author: .agent, text: "A", date: at),
            AgentTurn(id: "3", author: .user, text: "b", date: at),
            AgentTurn(id: "4", author: .agent, text: "partial", date: at, ending: .declined),
            AgentTurn(id: "5", author: .user, text: "c", date: at),
            AgentTurn(id: "6", author: .agent, text: "", date: at, ending: .stopped),
            AgentTurn(id: "7", author: .user, text: "d", date: at),
        ]
        #expect(AgentSession.exchanges(of: turns).flatMap(\.messages).map(\.text) == ["a", "A"])
    }

    @Test func aCredentialNeverPrintsItsKey() {
        #expect(!String(describing: testKey).contains("4f2a"))
        #expect(!String(reflecting: testKey).contains("sk-ant"))
        var dumped = ""
        dump(testKey, to: &dumped)
        #expect(!dumped.contains("sk-ant"))
    }
}
