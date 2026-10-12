import Foundation
import Testing
@testable import AgentKit

/// When older turns are summarised, where the cut falls, and the summary
/// kept in the store, reused after a reopen and forgotten by Clear.
struct CompactionTests {
    /// A message of `tokens` estimated tokens.
    private func words(_ tokens: Int, _ letter: Character = "a") -> String { String(repeating: letter, count: tokens * 3) }

    private func exchange(_ tokens: Int, _ letter: Character = "a") -> [ModelMessage] {
        [.user(words(tokens, letter)), ModelMessage(role: .assistant, content: [.text(words(tokens, letter))])]
    }

    @Test func dueOnlyPastTheTriggerSummaryIncluded() {
        var compaction = Compaction()
        compaction.trigger = 100
        #expect(!compaction.isDue(summary: nil, history: exchange(50)))
        #expect(compaction.isDue(summary: nil, history: exchange(51)))
        #expect(compaction.isDue(summary: words(1), history: exchange(50)))
    }

    @Test func theCutKeepsTheRecentTurnsThatFit() {
        var compaction = Compaction()
        compaction.keep = 40
        let turns = [exchange(10, "a"), exchange(10, "b"), exchange(10, "c")]
        // The last two turns are 40 tokens: they stay, the first is summarised.
        #expect(compaction.split(turns) == 1)
        compaction.keep = 39
        #expect(compaction.split(turns) == 2)
        // The latest turn always stays, even over the budget; with nothing older, nothing to cut.
        compaction.keep = 1
        #expect(compaction.split(turns) == 2)
        #expect(compaction.split([exchange(10)]) == 0)
        #expect(compaction.split([]) == 0)
    }

    @Test func aToolCallIsNeverSplitFromItsResult() {
        var compaction = Compaction()
        compaction.keep = 30
        let call = ToolCall(id: "c", name: "echo", input: [:])
        let toolTurn: [ModelMessage] = [
            .user("q"),
            ModelMessage(role: .assistant, content: [.toolUse(call)]),
            ModelMessage(role: .user, content: [.toolResult(ToolResult(toolCallID: "c", content: words(20)))]),
            ModelMessage(role: .assistant, content: [.text(words(5))]),
        ]
        // The cut is between whole turns: the call, its result and the words
        // after it go together. The tool turn does not fit with the last one,
        // so the cut is before it, not inside it.
        let turns = [exchange(10), toolTurn, exchange(5, "z")]
        #expect(compaction.split(turns) == 2)
    }

    @Test func theRequestCarriesTheSummarySoFarAndTheNewestTurnsThatFit() throws {
        var compaction = Compaction()
        compaction.maxInput = 25
        let request = try #require(compaction.request(summary: "Kate is late.", older: exchange(10, "a") + exchange(10, "b")))
        #expect(request.hasPrefix("The summary so far:\nKate is late.\n\n"))
        #expect(request.contains("Person: " + words(10, "b")))
        #expect(request.contains("Peel: " + words(10, "b")))
        // Over the input cap, the oldest go first.
        #expect(!request.contains(words(10, "a")))
        // A message longer than the cap for one is read in part, not dropped.
        compaction.maxMessageCharacters = 6
        let cut = try #require(compaction.request(summary: nil, older: exchange(10)))
        #expect(cut.contains("Person: aaaaaa [cut]"))
        #expect(compaction.request(summary: nil, older: []) == nil)
    }
}

@MainActor
struct AgentCompactionTests {
    /// Three exchanges of 10 + 10 tokens: two are past the trigger, and the last one is kept.
    private func session(_ provider: FakeProvider, path: String, tools: [Tool] = []) throws -> AgentSession {
        let agent = try connectedSession(provider, store: SQLiteAgentStore(path: path, device: "mac"), tools: tools)
        agent.compaction.trigger = 30
        agent.compaction.keep = 25
        agent.retryPolicy = .never
        return agent
    }

    private let first = String(repeating: "a", count: 30)
    private let second = String(repeating: "b", count: 30)
    private let third = String(repeating: "c", count: 30)

    private func ask(_ agent: AgentSession, _ text: String) async throws {
        agent.send(text)
        for _ in 0..<200 {
            if !agent.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
    }

    @Test func olderTurnsAreSummarisedBeforeATurnAndTheSummaryIsKept() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let provider = FakeProvider([
            textReply(first), textReply(second), textReply("Kate said she is late."), textReply("Three."),
            textReply("Four."),
        ])
        let agent = try session(provider, path: path)
        try await ask(agent, first)
        try await ask(agent, second)
        #expect(agent.summary == nil)
        try await ask(agent, third)

        let requests = provider.received
        #expect(requests.count == 4)
        // One call to summarise, before the turn, with the older exchange only.
        #expect(requests[2].system == Compaction.instructions)
        #expect(requests[2].tools.isEmpty)
        #expect(requests[2].messages.first?.text.contains("Person: " + first) == true)
        #expect(requests[2].messages.first?.text.contains(second) == false)
        // Then the turn: the summary, the kept exchange, the question.
        #expect(requests[3].messages.map(\.text) == [
            AgentLoop.opening("Kate said she is late.")[0].text, "Noted.", second, second, third,
        ])
        let summary = try #require(agent.summary)
        #expect(summary.text == "Kate said she is late.")
        #expect(summary.through == agent.turns[1].id)
        // Every turn still shows.
        #expect(agent.turns.map(\.text) == [first, first, second, second, third, "Three."])

        // Kept in the store, linked to what it covers; a reopen sends it again.
        let store = try SQLiteAgentStore(path: path, device: "mac")
        let record = try #require(try store.records(type: "Summary").first)
        #expect(record.body == "Kate said she is late.")
        #expect(Set(try store.walk(record.refId, edgeTypes: ["covers"], direction: .outgoing).map(\.record.refId))
                == Set(agent.turns.prefix(2).map { $0.id }))
        let reopened = try session(provider, path: path)
        #expect(reopened.summary.map { [$0.id, $0.text, $0.through] } == [summary.id, summary.text, summary.through])
        reopened.compaction.trigger = 1_000
        try await ask(reopened, "more")
        #expect(provider.received.last?.messages.map(\.text) == [
            AgentLoop.opening("Kate said she is late.")[0].text, "Noted.", second, second, third, "Three.", "more",
        ])
    }

    @Test func aLaterSummaryBuildsOnTheLastAndReachesFurther() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let provider = FakeProvider([
            textReply(first), textReply(second), textReply("Sum one."), textReply("Three."), textReply("Sum two."),
            textReply("Four."),
        ])
        let agent = try session(provider, path: path)
        try await ask(agent, first)
        try await ask(agent, second)
        try await ask(agent, third)
        let one = try #require(agent.summary)
        try await ask(agent, "four")

        let requests = provider.received
        #expect(requests.count == 6)
        // Made from the summary so far and the exchange after it, not from the start again.
        let request = try #require(requests[4].messages.first?.text)
        #expect(request.hasPrefix("The summary so far:\nSum one."))
        #expect(request.contains("Person: " + second) && !request.contains(first))
        let two = try #require(agent.summary)
        #expect(two.text == "Sum two.")
        #expect(two.through == agent.turns[3].id)
        #expect(requests[5].messages.map(\.text) == [
            AgentLoop.opening("Sum two.")[0].text, "Noted.", third, "Three.", "four",
        ])
        // It covers the turns since the last one, and the last one.
        let store = try SQLiteAgentStore(path: path, device: "mac")
        #expect(Set(try store.walk(two.id, edgeTypes: ["covers"], direction: .outgoing).map(\.record.refId))
                == Set(agent.turns[2...3].map { $0.id } + [one.id]))
        // A reopen takes the one that reaches furthest.
        #expect(try session(provider, path: path).summary?.id == two.id)
    }

    @Test func aDeclinedSendStaysDeclinedThroughASummary() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // A reply long enough to be cut in the summary's request.
        let long = String(repeating: "recap ", count: 1_000)
        let provider = FakeProvider([
            toolCallReply(id: "c1", name: "send", input: ["to": "Kate", "text": "late"]), textReply(long),
            textReply(second), textReply("Kate was not told; the person declined."), textReply("Three."),
        ])
        let agent = try session(provider, path: path, tools: [sendTool()])
        agent.send(first)
        try await until { agent.waiting != nil }
        agent.answer(.deny)
        try await until { !agent.isRunning }
        try await ask(agent, second)
        // The model is told what the action came to, before the reply's words.
        let record = AgentSession.actionRecordHeading + "\n- Send to Kate: declined by the person, not done"
        #expect(provider.received[2].messages[1].text.hasPrefix(record))
        try await ask(agent, third)

        // So is the summariser, ahead of the long reply's cut.
        #expect(provider.received[3].system == Compaction.instructions)
        let request = try #require(provider.received[3].messages.first?.text)
        #expect(request.contains("Peel: " + record))
        #expect(request.contains("[cut]"))
        #expect(agent.summary != nil)
        // The tool row keeps its answer, here and after a reopen.
        #expect(agent.turns[1].tools.first?.approval?.outcome == .denied)
        let reopened = try session(provider, path: path)
        #expect(reopened.turns[1].tools.first?.approval?.outcome == .denied)
    }

    @Test func theActionRecordSaysWhatEachActionCameTo() {
        let intent = ToolIntent(action: "Send to Kate")
        func tool(_ outcome: ApprovalOutcome?, failed: Bool = false) -> ToolActivity {
            ToolActivity(id: "c", name: "send", input: [:], summary: "x", duration: .zero, failed: failed,
                         approval: ToolApproval(intent: intent, outcome: outcome))
        }
        #expect(AgentSession.actionRecord(of: [tool(.allowedOnce)])?.hasSuffix("- Send to Kate: allowed and done") == true)
        #expect(AgentSession.actionRecord(of: [tool(.allowedOnce, failed: true)])?
            .hasSuffix("- Send to Kate: allowed, but it failed: not done") == true)
        #expect(AgentSession.actionRecord(of: [tool(.stopped)])?.hasSuffix("stopped by the person, not done") == true)
        // A read, or an action never answered, records nothing.
        #expect(AgentSession.actionRecord(of: [ToolActivity(id: "r", name: "read", input: [:])]) == nil)
        #expect(AgentSession.actionRecord(of: [tool(nil)]) == nil)
        // A stopped send with no words still reaches the model.
        let at = Date(timeIntervalSince1970: 0)
        let turns = [
            AgentTurn(id: "1", author: .user, text: "tell Kate", date: at),
            AgentTurn(id: "2", author: .agent, text: "", date: at, tools: [tool(.stopped)], ending: .stopped),
        ]
        #expect(AgentSession.exchanges(of: turns).first?.messages[1].text.contains("stopped by the person") == true)
    }

    @Test func aFailedSummarySendsWhatItWouldHaveAndKeepsNothing() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let provider = FakeProvider([
            textReply(first), textReply(second), .failing([], .badRequest(status: 400, "too long")), textReply("Three."),
            textReply("Four."),
        ])
        let agent = try session(provider, path: path)
        try await ask(agent, first)
        try await ask(agent, second)
        try await ask(agent, third)

        #expect(agent.summary == nil)
        #expect(agent.problem == nil)
        #expect(agent.turns.last?.text == "Three.")
        // The turn went ahead with the history as before.
        #expect(provider.received.last?.messages.map(\.text) == [first, first, second, second, third])
        #expect(try SQLiteAgentStore(path: path, device: "mac").records(type: "Summary").isEmpty)

        // The next turn is not held up by another try so soon.
        try await ask(agent, "four")
        #expect(provider.received.count == 5)
        #expect(provider.received.last?.system == "system")
    }

    @Test func clearForgetsTheSummary() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let provider = FakeProvider([
            textReply(first), textReply(second), textReply("Summary."), textReply("Three."), textReply("Fresh."),
        ])
        let agent = try session(provider, path: path)
        try await ask(agent, first)
        try await ask(agent, second)
        try await ask(agent, third)
        #expect(agent.summary != nil)

        try agent.clear()
        #expect(agent.summary == nil)
        let store = try SQLiteAgentStore(path: path, device: "mac")
        #expect(try store.records(type: "Summary").isEmpty)
        try await ask(agent, "hello")
        #expect(provider.received.last?.messages.map(\.text) == ["hello"])
        #expect(try session(provider, path: path).summary == nil)
    }
}
