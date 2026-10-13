import Foundation
import Synchronization
import Testing
@testable import AgentKit

private func sendReply(_ id: String = "c1", to: String = "Kate", text: String = "Running 10 min late") -> FakeProvider.Reply {
    toolCallReply(id: id, name: "send", input: ["to": .string(to), "text": .string(text)])
}

/// The tool results the model was sent after the first step.
private func results(_ provider: FakeProvider) -> [ToolResult] {
    provider.received.dropFirst().first?.messages.last?.content.compactMap {
        if case .toolResult(let result) = $0 { result } else { nil }
    } ?? []
}

/// The loop's approval step, with a scripted approver.
struct LoopApprovalTests {
    private func loop(_ provider: FakeProvider, tools: [Tool], approver: (any ToolApprover)?) -> AgentLoop {
        var loop = AgentLoop(provider: provider, tools: ToolRegistry(tools), model: "m", systemPrompt: "s")
        loop.approver = approver
        return loop
    }

    @Test func anAllowedSendRunsWithWhatWasShown() async throws {
        let runs = Counter()
        let provider = FakeProvider([sendReply(), textReply("Sent.")])
        let approver = ScriptedApprover(.outcome(.allowedOnce))
        _ = await loop(provider, tools: [sendTool(runs: runs)], approver: approver).run(history: [], message: "tell Kate")
        #expect(runs.value == 1)
        #expect(approver.requests.map(\.intent.action) == ["Send to Kate"])
        #expect(approver.requests.first?.intent.content == "Running 10 min late")
        #expect(approver.requests.first?.callID == "c1")
        #expect(results(provider).map(\.content) == ["Sent to Kate"])
    }

    @Test func aDeniedSendDoesNothingAndTellsTheModel() async throws {
        let runs = Counter()
        let provider = FakeProvider([sendReply(), textReply("OK, not sent.")])
        let turn = await loop(provider, tools: [sendTool(runs: runs)], approver: ScriptedApprover(.outcome(.denied)))
            .run(history: [], message: "tell Kate")
        #expect(runs.value == 0)
        let result = try #require(results(provider).first)
        #expect(result.content.hasPrefix("The user declined: Send to Kate."))
        #expect(!result.isError)
        #expect(turn.outcome == .finished(.endTurn))
    }

    @Test func withNoApproverASendIsRefused() async throws {
        let runs = Counter()
        let provider = FakeProvider([sendReply(), textReply("I can't.")])
        _ = await loop(provider, tools: [sendTool(runs: runs)], approver: nil).run(history: [], message: "tell Kate")
        #expect(runs.value == 0)
        #expect(results(provider).first?.isError == true)
    }

    @Test func readsNeverAsk() async throws {
        let provider = FakeProvider([toolCallReply(id: "c1", name: "echo", input: ["n": 1]), textReply("Done.")])
        let approver = ScriptedApprover(.outcome(.denied))
        _ = await loop(provider, tools: [echoTool()], approver: approver).run(history: [], message: "echo")
        #expect(approver.requests.isEmpty)
        #expect(results(provider).map(\.content) == [#"{"n":1}"#])
    }

    @Test func writesNeverAskAndRunAlone() async throws {
        let order = Mutex<[String]>([])
        let remember = Tool(name: "remember", description: "", inputSchema: ["type": "object"], effect: .write) { _ in
            try await Task.sleep(for: .milliseconds(50))
            order.withLock { $0.append("write finished") }
            return .text("Remembered")
        }
        let read = Tool(name: "recall", description: "", inputSchema: ["type": "object"], effect: .read) { _ in
            order.withLock { $0.append("read started") }
            return .text("Found")
        }
        let provider = FakeProvider([
            .events([.toolCallCompleted(ToolCall(id: "c1", name: "remember", input: [:])),
                     .toolCallCompleted(ToolCall(id: "c2", name: "recall", input: [:])), .finished(.toolUse)]),
            textReply("Noted."),
        ])
        let approver = ScriptedApprover(.outcome(.denied))
        _ = await loop(provider, tools: [remember, read], approver: approver).run(history: [], message: "remember")
        #expect(approver.requests.isEmpty)
        // The read after the write starts only once the write is done.
        #expect(order.withLock { $0 } == ["write finished", "read started"])
        #expect(results(provider).map(\.content) == ["Remembered", "Found"])
    }

    @Test func anAnswerWithoutActionIsNotAsked() async throws {
        let provider = FakeProvider([sendReply(to: "two"), textReply("Which one?")])
        let approver = ScriptedApprover(.outcome(.allowedOnce))
        _ = await loop(provider, tools: [sendTool()], approver: approver).run(history: [], message: "tell two")
        #expect(approver.requests.isEmpty)
        #expect(results(provider).map(\.content) == ["Two chats match; ask which."])
    }

    @Test func aToolWithOnlyAHandlerIsAskedByNameAndArguments() async throws {
        let runs = Counter()
        let tool = Tool(name: "poke", description: "Pokes.", inputSchema: ["type": "object"], effect: .send) { _ in
            runs.increment()
            return .text("poked")
        }
        let approver = ScriptedApprover(.outcome(.denied))
        let provider = FakeProvider([toolCallReply(id: "c1", name: "poke", input: ["who": "Kate"]), textReply("No.")])
        _ = await loop(provider, tools: [tool], approver: approver).run(history: [], message: "poke")
        #expect(runs.value == 0)
        #expect(approver.requests.first?.intent == ToolIntent(action: "Run poke", content: #"{"who":"Kate"}"#))
    }

}

/// The gate's rules: once, always (per tool and target), deny, a cost
/// always asked, kept across a reopen, revoked.
struct ApprovalGateTests {
    private func request(_ tool: String = "send", to target: String? = "kate", cost: String? = nil) -> ApprovalRequest {
        ApprovalRequest(callID: "c", tool: tool, intent: ToolIntent(
            action: "Send", content: "hi", cost: cost, target: target.map { ToolIntent.Target(id: $0, name: $0.capitalized) }))
    }

    private func gate(_ store: any AgentStore, answer: ApprovalDecision, asked: Counter = Counter()) -> ApprovalGate {
        ApprovalGate(rules: ApprovalRules(store: store)) { _ in
            asked.increment()
            return answer
        }
    }

    @Test func onceAndDenyAreNotRemembered() async throws {
        let store = try SQLiteAgentStore.inMemory(device: "t")
        #expect(await gate(store, answer: .allowOnce).approve(request()) == .allowedOnce)
        #expect(await gate(store, answer: .deny).approve(request()) == .denied)
        #expect(try ApprovalRules(store: store).all().isEmpty)
    }

    @Test func alwaysCoversThatToolAndTargetOnly() async throws {
        let store = try SQLiteAgentStore.inMemory(device: "t")
        #expect(await gate(store, answer: .alwaysAllow).approve(request()) == .alwaysAllowed)
        let asked = Counter()
        let next = gate(store, answer: .deny, asked: asked)
        #expect(await next.approve(request()) == .allowedByRule)
        #expect(asked.value == 0)
        // Another chat, another tool, or one with no target: asked.
        #expect(await next.approve(request(to: "sam")) == .denied)
        #expect(await next.approve(request("other")) == .denied)
        #expect(await next.approve(request(to: nil)) == .denied)
        #expect(asked.value == 3)
        let rules = try ApprovalRules(store: store).all()
        #expect(rules.map(\.tool) == ["send"])
        #expect(rules.first?.target == ToolIntent.Target(id: "kate", name: "Kate"))
    }

    @Test func aCostIsAskedEveryTimeAndNeverRemembered() async throws {
        let store = try SQLiteAgentStore.inMemory(device: "t")
        #expect(await gate(store, answer: .alwaysAllow).approve(request(cost: "Costs 3 sats")) == .allowedOnce)
        #expect(try ApprovalRules(store: store).all().isEmpty)
        // Even a rule for that chat does not cover a send that costs.
        _ = await gate(store, answer: .alwaysAllow).approve(request())
        let asked = Counter()
        #expect(await gate(store, answer: .deny, asked: asked).approve(request(cost: "Costs 3 sats")) == .denied)
        #expect(asked.value == 1)
    }

    @Test func rulesLastAcrossAReopenUntilRevoked() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = await gate(try SQLiteAgentStore(path: path, device: "mac"), answer: .alwaysAllow).approve(request())

        let reopened = try SQLiteAgentStore(path: path, device: "mac")
        #expect(await gate(reopened, answer: .deny).approve(request()) == .allowedByRule)
        let rules = ApprovalRules(store: reopened)
        try rules.revoke(try #require(try rules.all().first))
        #expect(try rules.all().isEmpty)
        #expect(await gate(reopened, answer: .deny).approve(request()) == .denied)
    }

    @Test func onlyContentThatShowsWhole() {
        for shown in ["Running 10 min late", "one\ntwo\tthree", "family 👨‍👩‍👧", "❤️‍🔥", "1️⃣", "👍🏽", "日本語"] {
            #expect(ToolIntent.isShowable(shown), "\(shown)")
        }
        // Each hides something: a selector or tag per byte, a joiner between
        // letters, a filler, a direction change, an escape.
        for hidden in ["ok\u{E0100}", "ok\u{FE01}", "a\u{200D}b", "\u{FE0F}x", "x\u{3164}y", "x\u{034F}y",
                       "ok\u{202E}evil", "tag\u{E0041}", "esc\u{1B}[2J", "a\u{2062}b"] {
            #expect(!ToolIntent.isShowable(hidden), "\(hidden.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    @Test func aToolWithNoTargetIsNeverAlwaysAllowed() async throws {
        let store = try SQLiteAgentStore.inMemory(device: "t")
        // A rule for the whole tool would cover any arguments.
        #expect(await gate(store, answer: .alwaysAllow).approve(request(to: nil)) == .allowedOnce)
        #expect(try ApprovalRules(store: store).all().isEmpty)
        #expect(!ToolIntent.generic("poke", input: ["who": "Kate"]).mayBeAlwaysAllowed)
    }

    @Test func aCancelledAskIsStopped() async throws {
        let store = try SQLiteAgentStore.inMemory(device: "t")
        let gate = ApprovalGate(rules: ApprovalRules(store: store)) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .allowOnce
        }
        #expect(await gate.approve(request()) == .stopped)
    }
}

/// The agent chat's card: it waits on `answer`, Stop takes it down, the
/// outcome is kept on the tool's row, and "always" rules are listed and
/// revoked.
@MainActor
struct SessionApprovalTests {
    private func session(_ provider: FakeProvider, store: any AgentStore, runs: Counter = Counter()) throws -> AgentSession {
        try connectedSession(provider, store: store, tools: [sendTool(runs: runs)])
    }

    @Test func theCardWaitsThenAllowOnceSends() async throws {
        let runs = Counter()
        let agent = try session(FakeProvider([sendReply(), textReply("Sent.")]), store: SQLiteAgentStore.inMemory(device: "t"),
                                runs: runs)
        agent.send("tell Kate")
        try await until { agent.waiting != nil }
        #expect(agent.waiting?.intent.content == "Running 10 min late")
        #expect(agent.reply?.tools.first?.isWaiting == true)
        #expect(runs.value == 0)

        agent.answer(.allowOnce)
        try await until { !agent.isRunning }
        #expect(runs.value == 1)
        #expect(agent.waiting == nil)
        let tool = try #require(agent.turns.last?.tools.first)
        #expect(tool.approval?.outcome == .allowedOnce)
        #expect(!tool.isWaiting)
    }

    @Test func denyTellsTheModel() async throws {
        let runs = Counter()
        let provider = FakeProvider([sendReply(), textReply("Not sent.")])
        let agent = try session(provider, store: SQLiteAgentStore.inMemory(device: "t"), runs: runs)
        agent.send("tell Kate")
        try await until { agent.waiting != nil }
        agent.answer(.deny)
        try await until { !agent.isRunning }
        #expect(runs.value == 0)
        #expect(agent.turns.last?.tools.first?.approval?.outcome == .denied)
        #expect(results(provider).first?.content.hasPrefix("The user declined") == true)
    }

    /// Regression: a failure after an allowed send offered Retry, which
    /// asked the same message again and, under the "always" rule just
    /// given, sent it a second time without a card.
    @Test func aFailureAfterASendKeepsTheReplyWithoutRetry() async throws {
        let runs = Counter()
        // Were the message asked again, the model would send again.
        let provider = FakeProvider([sendReply(), .failing([], .badRequest(status: 400, "broken")), sendReply("c2"),
                                     textReply("Sent again.")])
        let agent = try session(provider, store: SQLiteAgentStore.inMemory(device: "t"), runs: runs)
        agent.send("tell Kate, then sum up")
        try await until { agent.waiting != nil }
        agent.answer(.alwaysAllow)
        try await until { !agent.isRunning }

        #expect(runs.value == 1)
        // Kept with what ran; no Retry that would send it again.
        #expect(agent.problem == nil)
        #expect(agent.turns.last?.ending == .failed)
        #expect(agent.turns.last?.tools.first?.approval?.outcome == .alwaysAllowed)
        agent.retry()
        try await until { !agent.isRunning }
        #expect(runs.value == 1)
        #expect(provider.received.count == 2)
    }

    @Test func stopWhileWaitingSendsNothing() async throws {
        let runs = Counter()
        let provider = FakeProvider([sendReply(), textReply("never")])
        let agent = try session(provider, store: SQLiteAgentStore.inMemory(device: "t"), runs: runs)
        agent.send("tell Kate")
        try await until { agent.waiting != nil }
        agent.stop()
        try await until { !agent.isRunning }
        #expect(runs.value == 0)
        #expect(agent.waiting == nil)
        #expect(provider.received.count == 1)
        #expect(agent.turns.last?.tools.first?.approval?.outcome == .stopped)
        #expect(agent.turns.last?.ending == .stopped)
        // A late answer does nothing.
        agent.answer(.allowOnce)
        #expect(runs.value == 0)
    }

    @Test func alwaysSkipsTheCardAcrossAReopenUntilRevoked() async throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runs = Counter()
        let first = try session(FakeProvider([sendReply(), textReply("Sent.")]), store: SQLiteAgentStore(path: path, device: "mac"),
                                runs: runs)
        first.send("tell Kate")
        try await until { first.waiting != nil }
        first.answer(.alwaysAllow)
        try await until { !first.isRunning }
        #expect(first.approvalRules.map(\.target?.name) == ["Kate"])
        first.close()

        let second = try session(
            FakeProvider([sendReply("c2"), textReply("Sent."), sendReply("c3"), textReply("Asked.")]),
            store: SQLiteAgentStore(path: path, device: "mac"), runs: runs)
        #expect(second.turns.last?.tools.first?.approval?.outcome == .alwaysAllowed)
        #expect(second.turns.last?.tools.first?.approval?.intent.content == "Running 10 min late")
        second.send("again")
        try await until { !second.isRunning }
        #expect(runs.value == 2)
        #expect(second.turns.last?.tools.first?.approval?.outcome == .allowedByRule)

        try second.revoke(try #require(second.approvalRules.first))
        #expect(second.approvalRules.isEmpty)
        second.send("once more")
        try await until { second.waiting != nil }
        second.answer(.deny)
        try await until { !second.isRunning }
        #expect(runs.value == 2)
    }

    @Test func clearWhileTheCardWaitsSendsNothing() async throws {
        let runs = Counter()
        let agent = try session(FakeProvider([sendReply()]), store: SQLiteAgentStore.inMemory(device: "t"), runs: runs)
        agent.send("tell Kate")
        try await until { agent.waiting != nil }
        try agent.clear()
        #expect(agent.waiting == nil)
        #expect(!agent.isRunning)
        agent.answer(.allowOnce)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs.value == 0)
        #expect(agent.turns.isEmpty)
    }

    @Test func closingTakesTheCardDown() async throws {
        let runs = Counter()
        let agent = try session(FakeProvider([sendReply()]), store: SQLiteAgentStore.inMemory(device: "t"), runs: runs)
        agent.send("tell Kate")
        try await until { agent.waiting != nil }
        agent.close()
        #expect(agent.waiting == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs.value == 0)
    }
}
