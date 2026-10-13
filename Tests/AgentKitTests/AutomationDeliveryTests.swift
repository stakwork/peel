import Foundation
import Testing
@testable import AgentKit

/// A scheduled automation's result arriving in the agent chat on its own
/// (`AgentSession.deliver`): kept, named, unread, and never taken for the
/// reply to a message.
@MainActor
struct AutomationDeliveryTests {
    @Test func aDeliveryIsKeptNamedAndUnreadAcrossAReopen() throws {
        let store = try SQLiteAgentStore.inMemory(device: "test")
        let agent = try connectedSession(FakeProvider([]), store: store)
        agent.deliver("  Kate needs the recipe by Sunday.  ", from: "Friday to-do")
        agent.deliver("   ", from: "Friday to-do")

        #expect(agent.turns.map(\.text) == ["Kate needs the recipe by Sunday."])
        #expect(agent.turns.first?.author == .agent)
        #expect(agent.turns.first?.automation == "Friday to-do")
        #expect(agent.unread == 1)

        let reopened = try connectedSession(FakeProvider([]), store: store)
        #expect(reopened.turns.map(\.automation) == ["Friday to-do"])
    }

    /// Delivered between a message and its reply, it is its own exchange:
    /// the reply still answers the message.
    @Test func aDeliveryIsItsOwnExchange() {
        let at = Date(timeIntervalSince1970: 0)
        let turns = [
            AgentTurn(id: "1", author: .user, text: "a", date: at),
            AgentTurn(id: "2", author: .agent, text: "X", date: at, automation: "Daily"),
            AgentTurn(id: "3", author: .agent, text: "A", date: at),
        ]
        let exchanges = AgentSession.exchanges(of: turns)
        #expect(exchanges.map(\.through) == ["2", "3"])
        #expect(exchanges.flatMap(\.messages).map(\.text) == [
            "(The scheduled automation \"Daily\" ran on its own and told the person:)", "X", "a", "A",
        ])
    }

    @Test func aDeliveryWhileAReplyStreamsLeavesItAlone() async throws {
        let agent = try connectedSession(
            FakeProvider([.hanging([.textDelta("Thinking")])]), store: SQLiteAgentStore.inMemory(device: "test"))
        agent.isShown = true
        agent.send("hi")
        try await until { agent.reply?.text == "Thinking" }
        agent.deliver("Scores are in.", from: "Cardiff")

        #expect(agent.isRunning)
        #expect(agent.reply?.text == "Thinking")
        #expect(agent.turns.map(\.text) == ["hi", "Scores are in."])
        agent.stop()
        try await until { !agent.isRunning }
        #expect(agent.turns.map(\.text) == ["hi", "Scores are in.", "Thinking"])
    }

    /// A run with no approver (an automation's) is not offered the tools
    /// that ask; with one, it is.
    @Test func aRunWithNoApproverIsNotOfferedToolsThatAsk() async {
        let send = Tool(name: "send_it", description: "", inputSchema: ["type": "object"], effect: .send) { _ in .text("sent") }
        let tools = ToolRegistry([echoTool(), send])
        let provider = FakeProvider([textReply("ok"), textReply("ok")])
        _ = await AgentLoop(provider: provider, tools: tools, model: "m", systemPrompt: "s").run(history: [], message: "go")
        var attended = AgentLoop(provider: provider, tools: tools, model: "m", systemPrompt: "s")
        attended.approver = AllowAll()
        _ = await attended.run(history: [], message: "go")

        #expect(provider.received.map { $0.tools.map(\.name) } == [["echo"], ["echo", "send_it"]])
    }
}

private struct AllowAll: ToolApprover {
    func approve(_ request: ApprovalRequest) async -> ApprovalOutcome { .allowedOnce }
}
