import Foundation
import Testing
@testable import AgentKit

/// The agent on this Mac now that strut is the agent: the chat Peel's own
/// loop kept, read only and cleared on request; the connected model's key;
/// the agent's name.
@MainActor
struct AgentSessionTests {
    private func session(_ store: any AgentStore, credentials: MemoryCredentials = MemoryCredentials()) -> AgentSession {
        AgentSession(store: store, credentials: credentials)
    }

    /// The records as Peel's loop wrote them, by their stored literals (never
    /// through `AgentSession`): a conversation, a question, a reply with two
    /// tool calls (kept out of order) and its summary.
    private func writeOldChat(in store: any AgentStore) throws -> (turns: [String], calls: [String], summary: String) {
        let conversation = try store.add(type: "Conversation", name: "Peel", createdBy: "user")
        let asked = try store.add(type: "Turn", name: "What did I miss?", body: "What did I miss?", createdBy: "user")
        try store.link(conversation, "turn", asked, createdBy: "user")
        let reply = try store.add(type: "Turn", name: "Kate wrote", body: "Kate wrote. [View](peel://message?chat=c&uuid=u)",
                                  props: ["ending": "stopped"], createdBy: "agent", source: asked)
        try store.link(conversation, "turn", reply, createdBy: "agent")
        let approval: JSONValue = ["intent": ["action": "Send to Kate", "content": "On my way", "details": []], "outcome": "allowed_once"]
        let send = try store.add(type: "ToolCall", name: "send_sphinx_message", body: "Sent to Kate",
                                 props: ["call_id": "c2", "input": ["chat": "Kate"], "failed": false, "ms": 400, "index": 1,
                                         "approval": approval],
                                 createdBy: "agent", source: reply)
        let read = try store.add(type: "ToolCall", name: "remember", body: "Remembered 1 fact",
                                 props: ["call_id": "c1", "input": [:], "failed": true, "ms": 120, "index": 0, "row": ["a": 1]],
                                 createdBy: "agent", source: reply)
        try store.link(reply, "tool_call", send, createdBy: "agent")
        try store.link(reply, "tool_call", read, createdBy: "agent")
        let summary = try store.add(type: "Summary", name: "Summary of the earlier conversation", body: "Kate wrote.",
                                    props: ["through": .string(reply)], createdBy: "agent", source: reply)
        try store.link(summary, "covers", asked, createdBy: "agent")
        try store.link(conversation, "summary", summary, createdBy: "agent")
        return ([asked, reply], [read, send], summary)
    }

    @Test func theEarlierChatReadsAsTheLoopKeptIt() throws {
        let store = try SQLiteAgentStore.inMemory(device: "mac")
        let written = try writeOldChat(in: store)
        let agent = session(store)
        #expect(agent.turns.map(\.id) == written.turns)
        #expect(agent.turns.map(\.author) == [.user, .agent])
        #expect(agent.turns.map(\.text) == ["What did I miss?", "Kate wrote. [View](peel://message?chat=c&uuid=u)"])
        #expect(agent.turns[1].ending == .stopped)
        let tools = agent.turns[1].tools
        // In the order they ran, whatever order they were kept in.
        #expect(tools.map(\.id) == ["c1", "c2"])
        #expect(tools.map(\.name) == ["remember", "send_sphinx_message"])
        #expect(tools.map(\.failed) == [true, false])
        #expect(tools.map(\.duration) == [.milliseconds(120), .milliseconds(400)])
        #expect(tools[0].row == ["a": 1])
        #expect(tools[1].input == ["chat": "Kate"])
        #expect(tools[1].approval == ToolApproval(intent: ToolIntent(action: "Send to Kate", content: "On my way"),
                                                  outcome: .allowedOnce))
        #expect(agent.notice == nil)
    }

    @Test func clearForgetsTheEarlierChatAndItsSummaries() throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteAgentStore(path: path, device: "mac")
        let written = try writeOldChat(in: store)
        let agent = session(store)
        try agent.clear()
        #expect(agent.turns.isEmpty)
        for id in written.turns + written.calls + [written.summary] {
            #expect(try store.read(id) == nil)
        }
        #expect(try store.records(type: "Conversation").isEmpty)
        #expect(session(try SQLiteAgentStore(path: path, device: "mac")).turns.isEmpty)
    }

    @Test func theKeyIsKeptChangedAndRemovedAndEachChangeIsHandedOn() throws {
        let credentials = MemoryCredentials()
        let agent = session(try SQLiteAgentStore.inMemory(device: "mac"), credentials: credentials)
        var changes = 0
        agent.credentialChanged = { changes += 1 }
        #expect(agent.connection == nil)

        try agent.connect(testKey)
        #expect(try credentials.read() == testKey)
        #expect(agent.connection == AgentSession.Connection(provider: .anthropic, model: "claude-sonnet-5-5", keyHint: "4f2a",
                                                                 workspaceID: nil))
        try agent.setModel("claude-opus-5-5")
        #expect(try credentials.read()?.model == "claude-opus-5-5")
        #expect(agent.connection?.model == "claude-opus-5-5")
        // Connect with the key left empty: the model and workspace change, the key stays.
        try agent.keepKey(model: "claude-haiku-5-5", workspaceID: "wrkspc_01abc")
        #expect(try credentials.read() == AgentCredential(provider: .anthropic, model: "claude-haiku-5-5",
                                                          apiKey: testKey.apiKey, workspaceID: "wrkspc_01abc"))
        #expect(agent.connection?.workspaceID == "wrkspc_01abc")
        try agent.removeKey()
        #expect(try credentials.read() == nil)
        #expect(agent.connection == nil)
        #expect(changes == 4)
    }

    @Test func aKeyThatCannotBeReadIsSaid() throws {
        let credentials = MemoryCredentials()
        try credentials.write(testKey)
        credentials.failing = true
        let agent = session(try SQLiteAgentStore.inMemory(device: "mac"), credentials: credentials)
        #expect(agent.connection == nil)
        #expect(agent.notice == "Could not read the connected model's key: locked")
    }

    @Test func theNameLastsAcrossAReopen() throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let agent = session(try SQLiteAgentStore(path: path, device: "mac"))
        #expect(agent.name == AgentSession.defaultName)
        try agent.rename("  ")
        #expect(agent.name == AgentSession.defaultName)
        try agent.rename(" Pip ")
        try agent.rename("Pip")
        #expect(session(try SQLiteAgentStore(path: path, device: "mac")).name == "Pip")
    }

    /// One kept before workspaces were: it still reads, with none.
    @Test func aCredentialKeptBeforeWorkspacesStillReads() throws {
        let kept = Data(#"{"provider":"anthropic","model":"claude-sonnet-5-5","apiKey":"sk-ant-test-4f2a"}"#.utf8)
        #expect(try JSONDecoder().decode(AgentCredential.self, from: kept) == testKey)
    }

    @Test func aCredentialNeverPrintsItsKey() {
        #expect(!String(describing: testKey).contains("4f2a"))
        #expect(!String(reflecting: testKey).contains("sk-ant"))
        var dumped = ""
        dump(testKey, to: &dumped)
        #expect(!dumped.contains("sk-ant"))
    }
}
