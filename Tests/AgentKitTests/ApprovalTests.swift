import Foundation
import Testing
@testable import AgentKit

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
        // A card taken down unanswered (the device's, when the account closes).
        #expect(await ApprovalGate(rules: ApprovalRules(store: store)) { _ in nil }.approve(request()) == .stopped)
    }
}
