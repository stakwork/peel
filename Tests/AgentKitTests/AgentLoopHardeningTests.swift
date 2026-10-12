import Foundation
import Synchronization
import Testing
@testable import AgentKit

/// Retries of a failed model call, and a step's read tools run side by side.
struct AgentLoopRetryTests {
    /// A loop whose waits are recorded and return at once.
    private func loop(_ provider: FakeProvider, tools: [Tool] = [echoTool()], slept: Waits) -> AgentLoop {
        var loop = AgentLoop(provider: provider, tools: ToolRegistry(tools), model: "m", systemPrompt: "system")
        loop.sleep = { slept.record($0) }
        return loop
    }

    @Test func aRateLimitIsRetriedAfterTheWaitTheProviderAsked() async {
        let slept = Waits()
        let provider = FakeProvider([.failing([], .rateLimited(retryAfter: 4)), textReply("Here.")])
        let log = EventLog()
        let turn = await loop(provider, slept: slept).run(history: [], message: "hi") { log.record($0) }

        #expect(turn.outcome == .finished(.endTurn))
        #expect(turn.messages.map(\.text) == ["hi", "Here."])
        #expect(slept.all == [.seconds(4)])
        #expect(provider.received.count == 2)
        #expect(provider.received[0] == provider.received[1])
        // The wait, then the call going again.
        #expect(log.all.prefix(2) == [.retrying(after: .seconds(4), .rateLimited(retryAfter: 4)),
                                      .retrying(after: .zero, .rateLimited(retryAfter: 4))])
    }

    @Test func anOutageIsRetriedAFewTimesThenShown() async {
        let slept = Waits()
        let overloaded = ModelError.unavailable(status: 529, "Overloaded")
        let provider = FakeProvider([], thenRepeat: .failing([], overloaded))
        let turn = await loop(provider, slept: slept).run(history: [], message: "hi")

        #expect(turn.outcome == .failed(overloaded))
        #expect(turn.messages.isEmpty)
        #expect(provider.received.count == 4)
        // Doubling from 2 s, each spread by up to half.
        let seconds = slept.all.map { $0 / .seconds(1) }
        #expect(seconds.count == 3)
        for (wait, base) in zip(seconds, [2.0, 4, 8]) { #expect(wait >= base / 2 && wait <= base) }
    }

    @Test func nothingIsRetriedOnceWordsWereShown() async {
        let slept = Waits()
        let provider = FakeProvider([.failing([.textDelta("Par")], .network("The connection to the provider was lost.")),
                                     textReply("never")])
        let turn = await loop(provider, slept: slept).run(history: [], message: "hi")

        #expect(turn.outcome == .failed(.network("The connection to the provider was lost.")))
        #expect(turn.messages.map(\.text) == ["hi", "Par"])
        #expect(provider.received.count == 1)
        #expect(slept.all.isEmpty)
    }

    @Test func aRefusedKeyIsNotRetried() async {
        let slept = Waits()
        let provider = FakeProvider([.failing([], .invalidKey(nil)), textReply("never")])
        let turn = await loop(provider, slept: slept).run(history: [], message: "hi")
        #expect(turn.outcome == .failed(.invalidKey(nil)))
        #expect(provider.received.count == 1)
        #expect(slept.all.isEmpty)
    }

    @Test func aLaterStepIsRetriedWithoutRunningItsToolsAgain() async {
        let slept = Waits()
        let runs = Counter()
        let provider = FakeProvider([
            toolCallReply(id: "c1", name: "echo"), .failing([], .rateLimited(retryAfter: 1)), textReply("Done."),
        ])
        let turn = await loop(provider, tools: [echoTool(runs: runs)], slept: slept).run(history: [], message: "go")

        #expect(turn.outcome == .finished(.endTurn))
        #expect(runs.value == 1)
        #expect(slept.all == [.seconds(1)])
        #expect(provider.received.count == 3)
        #expect(provider.received[1] == provider.received[2])
    }

    @Test func stopDuringTheWaitEndsTheTurnAtOnce() async {
        let provider = FakeProvider([.failing([], .rateLimited(retryAfter: 30)), textReply("never")])
        // The real wait, which Stop cancels.
        let agent = AgentLoop(provider: provider, tools: ToolRegistry(), model: "m", systemPrompt: "")
        let (waiting, signal) = AsyncStream.makeStream(of: Void.self)
        let started = ContinuousClock.now
        let task = Task {
            await agent.run(history: [], message: "hi") { event in
                if case .retrying = event { signal.yield() }
            }
        }
        for await _ in waiting { break }
        task.cancel()
        let turn = await task.value

        #expect(turn.outcome == .stopped)
        #expect(turn.messages.isEmpty)
        #expect(provider.received.count == 1)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func theWaitsAreCapped() {
        let policy = RetryPolicy()
        let outage = ModelError.unavailable(status: 503, nil)
        #expect(policy.delay(after: outage, retry: 1, elapsed: .zero, jitter: 1) == .seconds(2))
        #expect(policy.delay(after: outage, retry: 2, elapsed: .zero, jitter: 1) == .seconds(4))
        #expect(policy.delay(after: outage, retry: 3, elapsed: .zero, jitter: 0.5) == .seconds(4))
        #expect(policy.delay(after: outage, retry: 4, elapsed: .zero, jitter: 1) == nil)
        // A provider asking for longer than the longest wait gets its error shown.
        #expect(policy.delay(after: .rateLimited(retryAfter: 4), retry: 1, elapsed: .zero, jitter: 0.5) == .seconds(4))
        #expect(policy.delay(after: .rateLimited(retryAfter: 31), retry: 1, elapsed: .zero, jitter: 1) == nil)
        #expect(policy.delay(after: .rateLimited(retryAfter: .infinity), retry: 1, elapsed: .zero, jitter: 1) == nil)
        #expect(policy.delay(after: .rateLimited(retryAfter: .nan), retry: 1, elapsed: .zero, jitter: 1) == nil)
        // So does one that would take the call past its total.
        #expect(policy.delay(after: .rateLimited(retryAfter: 20), retry: 2, elapsed: .seconds(45), jitter: 1) == nil)
        #expect(policy.delay(after: .network("lost"), retry: 1, elapsed: .zero, jitter: 1) == .seconds(2))
        #expect(policy.delay(after: .badRequest(status: 400, "no"), retry: 1, elapsed: .zero, jitter: 1) == nil)
        #expect(policy.delay(after: .cancelled, retry: 1, elapsed: .zero, jitter: 1) == nil)
        #expect(RetryPolicy.never.delay(after: outage, retry: 1, elapsed: .zero, jitter: 1) == nil)
    }
}

struct AgentLoopConcurrencyTests {
    /// A read tool that waits, once started, until `together` tools are
    /// running at once (so it only finishes if they overlap), then `hold`.
    /// `gate`, when given, is the trace whose most at once is waited on.
    private func read(_ name: String, trace: Trace, together: Int = 1, hold: Duration = .zero,
                      fails: Bool = false, gate: Trace? = nil) -> Tool {
        Tool(name: name, description: "", inputSchema: ["type": "object"], effect: .read) { _ in
            trace.enter(name)
            gate?.enter(name)
            defer {
                trace.leave(name)
                gate?.leave(name)
            }
            guard try await (gate ?? trace).until({ $0 >= together }) else { return .text("\(name) ran alone") }
            try await Task.sleep(for: hold)
            if fails { throw Failure() }
            return .text("\(name) done")
        }
    }

    private func send(_ name: String, trace: Trace) -> Tool {
        Tool(name: name, description: "", inputSchema: ["type": "object"], effect: .send) { _ in
            trace.enter(name)
            defer { trace.leave(name) }
            return .text("\(name) sent")
        }
    }

    private struct Failure: LocalizedError { var errorDescription: String? { "it broke" } }

    private func calls(_ names: [String]) -> FakeProvider.Reply {
        .events(names.enumerated().map { .toolCallCompleted(ToolCall(id: "c\($0.offset)", name: $0.element, input: [:])) }
                + [.finished(.toolUse)])
    }

    private func results(_ turn: TurnResult) -> [ToolResult] {
        turn.messages.flatMap(\.content).compactMap { if case .toolResult(let result) = $0 { result } else { nil } }
    }

    private func run(_ names: [String], tools: [Tool], log: EventLog = EventLog()) async -> TurnResult {
        let provider = FakeProvider([calls(names), textReply("ok")])
        var agent = AgentLoop(provider: provider, tools: ToolRegistry(tools), model: "m", systemPrompt: "")
        // Sends are allowed, so they run.
        agent.approver = ScriptedApprover(.outcome(.allowedOnce))
        return await agent.run(history: [], message: "go") { log.record($0) }
    }

    @Test func readsRunSideBySideAndAnswerInCallOrder() async {
        let trace = Trace()
        // Each waits until all three are running: done only if they overlap.
        let tools = [read("a", trace: trace, together: 3, hold: .milliseconds(30)), read("b", trace: trace, together: 3),
                     read("c", trace: trace, together: 3)]
        let log = EventLog()
        let turn = await run(["a", "b", "c"], tools: tools, log: log)

        #expect(turn.outcome == .finished(.endTurn))
        #expect(trace.most == 3)
        #expect(results(turn).map(\.content) == ["a done", "b done", "c done"])
        #expect(turn.toolsRun == ["a", "b", "c"])
        // Rows open in call order.
        let opened = log.opened
        #expect(opened == ["c0", "c1", "c2"])
        let closed = log.closed
        #expect(Set(closed) == ["c0", "c1", "c2"])
        #expect(closed.last == "c0")
    }

    @Test func atMostFourReadsRunAtOnce() async {
        let trace = Trace()
        let names = (1...7).map { "r\($0)" }
        // The first four wait for each other; the rest find four already seen.
        let turn = await run(names, tools: names.map { read($0, trace: trace, together: 4) })
        #expect(trace.most == 4)
        #expect(results(turn).map(\.content) == names.map { "\($0) done" })
    }

    @Test func aFailingReadLeavesTheOthersRunning() async {
        let trace = Trace()
        let tools = [read("a", trace: trace, together: 3, hold: .milliseconds(30)),
                     read("broken", trace: trace, together: 3, fails: true),
                     read("c", trace: trace, together: 3, hold: .milliseconds(30))]
        let turn = await run(["a", "broken", "c"], tools: tools)
        #expect(results(turn).map(\.content) == ["a done", "it broke", "c done"])
        #expect(results(turn).map(\.isError) == [false, true, false])
    }

    @Test func aSendWaitsForTheReadsBeforeItAndTheReadsAfterItWaitForIt() async {
        let trace = Trace()
        let tools = [read("r1", trace: trace, together: 2), read("r2", trace: trace, together: 2), send("s1", trace: trace),
                     read("r3", trace: trace), send("s2", trace: trace)]
        let log = EventLog()
        let turn = await run(["r1", "r2", "s1", "r3", "s2"], tools: tools, log: log)

        #expect(results(turn).map(\.content) == ["r1 done", "r2 done", "s1 sent", "r3 done", "s2 sent"])
        #expect(Set(trace.order.prefix(2)) == ["r1", "r2"])
        #expect(trace.order.suffix(3) == ["s1", "r3", "s2"])
        #expect(trace.mostWithASend == 1)
        let opened = log.opened
        #expect(opened == ["c0", "c1", "c2", "c3", "c4"])
    }

    @Test func anActionWaitsOnItsApprovalAloneBetweenReads() async {
        let trace = Trace()
        let runs = Counter()
        let approver = WatchingApprover(trace: trace)
        // `send` plans an action, approved before it runs.
        let send = Tool(name: "s1", description: "", inputSchema: ["type": "object"], effect: .send) { _ in
            .action(ToolIntent(action: "Send to Kate", target: ToolIntent.Target(id: "kate", name: "Kate"))) {
                trace.enter("s1")
                defer { trace.leave("s1") }
                runs.increment()
                return .text("s1 sent")
            }
        }
        // The reads after it wait for each other on a trace of their own.
        let after = Trace()
        let tools = [read("r1", trace: trace, together: 2), read("r2", trace: trace, together: 2), send,
                     read("r3", trace: trace, together: 2, gate: after), read("r4", trace: trace, together: 2, gate: after)]
        let provider = FakeProvider([calls(["r1", "r2", "s1", "r3", "r4"]), textReply("ok")])
        var agent = AgentLoop(provider: provider, tools: ToolRegistry(tools), model: "m", systemPrompt: "")
        agent.approver = approver
        let log = EventLog()
        let turn = await agent.run(history: [], message: "go") { log.record($0) }

        #expect(results(turn).map(\.content) == ["r1 done", "r2 done", "s1 sent", "r3 done", "r4 done"])
        #expect(runs.value == 1)
        // Asked once, with nothing else running: the reads before had all finished,
        // and the reads after had not started while it waited.
        #expect(approver.asked == ["Send to Kate"])
        #expect(approver.runningWhenAsked == [0])
        #expect(Set(trace.order.prefix(2)) == ["r1", "r2"])
        #expect(trace.order[2] == "s1")
        #expect(Set(trace.order.suffix(2)) == ["r3", "r4"])
        #expect(after.most == 2)
        #expect(trace.mostWithASend == 1)
        #expect(log.opened == ["c0", "c1", "c2", "c3", "c4"])
    }

    @Test func aDeclinedActionLeavesTheReadsAroundIt() async {
        let trace = Trace()
        let send = Tool(name: "s1", description: "", inputSchema: ["type": "object"], effect: .send) { _ in .text("never") }
        let provider = FakeProvider([calls(["r1", "s1", "r2"]), textReply("ok")])
        var agent = AgentLoop(provider: provider, tools: ToolRegistry([read("r1", trace: trace), send, read("r2", trace: trace)]),
                              model: "m", systemPrompt: "")
        agent.approver = WatchingApprover(trace: trace, outcome: .denied)
        let turn = await agent.run(history: [], message: "go")
        #expect(results(turn).map(\.content) == [
            "r1 done", "The user declined: Run s1. Nothing was done; do not try again unless they ask.", "r2 done",
        ])
        #expect(trace.order == ["r1", "r2"])
    }

    @Test func stopWhileACardWaitsLeavesTheReadsAfterItUnrun() async throws {
        let trace = Trace()
        let send = Tool(name: "s1", description: "", inputSchema: ["type": "object"], effect: .send) { _ in .text("never") }
        let approver = ScriptedApprover(.hang)
        let provider = FakeProvider([calls(["r1", "s1", "r2"])])
        var agent = AgentLoop(provider: provider, tools: ToolRegistry([read("r1", trace: trace), send, read("r2", trace: trace)]),
                              model: "m", systemPrompt: "")
        agent.approver = approver
        let task = Task { await agent.run(history: [], message: "go") }
        try await until { !approver.requests.isEmpty }
        task.cancel()
        let turn = await task.value

        #expect(turn.outcome == .stopped)
        #expect(trace.order == ["r1"])
        #expect(results(turn).map(\.content) == ["r1 done", "Not run: stopped by the user.", "Not run: stopped by the user."])
        #expect(turn.toolsNotRun == ["r2"])
    }

    @Test func aReadToolThatPlansAnActionIsNotRunSideBySide() async {
        let rogue = Tool(name: "rogue", description: "", inputSchema: ["type": "object"], effect: .read) { _ in
            .action(ToolIntent(action: "Do something")) { .text("did it") }
        }
        let provider = FakeProvider([calls(["rogue"]), textReply("ok")])
        var agent = AgentLoop(provider: provider, tools: ToolRegistry([rogue]), model: "m", systemPrompt: "")
        let approver = WatchingApprover(trace: Trace())
        agent.approver = approver
        let turn = await agent.run(history: [], message: "go")
        #expect(results(turn).map(\.content) == ["Not run: a read tool may not act."])
        #expect(approver.asked.isEmpty)
    }

    @Test func stopEndsEveryReadAndLeavesTheRestUnrun() async {
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let hang = { (name: String) in
            Tool(name: name, description: "", inputSchema: ["type": "object"], effect: .read) { _ in
                signal.yield()
                try await Task.sleep(for: .seconds(600))
                return .text("never")
            }
        }
        let send = Tool(name: "send", description: "", inputSchema: ["type": "object"], effect: .send) { _ in .text("sent") }
        let provider = FakeProvider([calls(["h1", "h2", "send"])])
        let log = EventLog()
        let agent = AgentLoop(provider: provider, tools: ToolRegistry([hang("h1"), hang("h2"), send]), model: "m",
                              systemPrompt: "")
        let task = Task { await agent.run(history: [], message: "go") { log.record($0) } }
        var count = 0
        for await _ in started {
            count += 1
            if count == 2 { break }
        }
        task.cancel()
        let turn = await task.value

        #expect(turn.outcome == .stopped)
        #expect(results(turn).map(\.content) == [
            "Stopped by the user before it finished.", "Stopped by the user before it finished.", "Not run: stopped by the user.",
        ])
        #expect(turn.toolsRun == ["h1", "h2"])
        #expect(turn.toolsNotRun == ["send"])
        // Every row that opened is closed (failed); the send never opened one.
        #expect(log.all.allSatisfy { if case .toolFinished(_, _, _, _, let failed) = $0 { failed } else { true } })
        let opened = log.opened
        let closed = log.closed
        #expect(opened == ["c0", "c1"])
        #expect(Set(closed) == ["c0", "c1"])
    }
}

/// An approver that notes what it was asked and how many tools were
/// running at that moment, waits a little (a person reading the card), then
/// answers `outcome`.
final class WatchingApprover: ToolApprover {
    private let trace: Trace
    private let outcome: ApprovalOutcome
    private let seen = Mutex<(asked: [String], running: [Int])>(([], []))
    var asked: [String] { seen.withLock { $0.asked } }
    var runningWhenAsked: [Int] { seen.withLock { $0.running } }

    init(trace: Trace, outcome: ApprovalOutcome = .allowedOnce) {
        self.trace = trace
        self.outcome = outcome
    }

    func approve(_ request: ApprovalRequest) async -> ApprovalOutcome {
        let running = trace.running
        let started = trace.order.count
        seen.withLock { $0.asked.append(request.intent.action); $0.running.append(running) }
        try? await Task.sleep(for: .milliseconds(50))
        // Nothing started while the card was up, however briefly.
        #expect(trace.order.count == started)
        return outcome
    }
}

/// Which tools ran when: the order they started, the most at once, and the
/// most running at once while a send ran.
final class Trace: Sendable {
    private struct State {
        var running: Set<String> = []
        var most = 0
        var mostWithASend = 0
        var order: [String] = []
    }

    private let state = Mutex(State())
    var most: Int { state.withLock { $0.most } }
    var mostWithASend: Int { state.withLock { $0.mostWithASend } }
    var order: [String] { state.withLock { $0.order } }
    /// How many are running now.
    var running: Int { state.withLock { $0.running.count } }

    func enter(_ name: String) {
        state.withLock {
            $0.running.insert(name)
            $0.most = max($0.most, $0.running.count)
            if $0.running.contains(where: { $0.hasPrefix("s") }) {
                $0.mostWithASend = max($0.mostWithASend, $0.running.count)
            }
            $0.order.append(name)
        }
    }

    func leave(_ name: String) {
        state.withLock { _ = $0.running.remove(name) }
    }

    /// Waits up to two seconds for the most seen at once to pass `condition`.
    func until(_ condition: @Sendable (Int) -> Bool) async throws -> Bool {
        for _ in 0..<400 {
            if condition(most) { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
