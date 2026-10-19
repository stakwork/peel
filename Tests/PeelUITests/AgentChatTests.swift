import Testing
@testable import PeelCore
@testable import PeelUI

/// The phone's agent row says "Ready" once the agent's account is a chat here.
@MainActor
struct AgentChatTests {
    private func conversation(_ chat: String) -> Conversation {
        Conversation(chat: chat, alias: nil, photoURL: nil, isTribe: false,
                     lastContent: nil, lastTimestamp: nil, lastFromMe: nil)
    }

    @Test func agentIsReadyOnlyOnceItsContactIsAChat() {
        let agent = "03agent"
        #expect(AppModel.agentChat(contact: agent, in: []) == nil)
        #expect(AppModel.agentChat(contact: agent, in: [conversation("03other")]) == nil)
        #expect(AppModel.agentChat(contact: agent, in: [conversation("03other"), conversation(agent)]) == agent)
        #expect(AppModel.agentChat(contact: nil, in: [conversation(agent)]) == nil)
    }
}
