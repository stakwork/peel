import Foundation
import Synchronization
import Testing
@testable import AgentKit
import PeelCore
@testable import PeelAgent

/// A scheduled run strut hands to Peel (`docs/phases/12-automations.md`):
/// the loopback server's door, and how a run's end becomes strut's output.
struct AutomationTests {
    // MARK: The server

    @Test func onlyAnAuthorisedPostToTheOnePathStartsARun() {
        let refusal = { (method: String, uri: String, auth: String?, size: Int) in
            AutomationServer.refusal(method: method, uri: uri, authorization: auth, token: "t0k", bodySize: size)?.status
        }
        #expect(refusal("POST", "/automations/run", "Bearer t0k", 10) == nil)
        #expect(refusal("POST", "/automations/run?x=1", "Bearer t0k", 10) == 404)
        #expect(refusal("POST", "/", "Bearer t0k", 10) == 404)
        #expect(refusal("GET", "/automations/run", "Bearer t0k", 10) == 405)
        #expect(refusal("POST", "/automations/run", nil, 10) == 401)
        #expect(refusal("POST", "/automations/run", "Bearer t0", 10) == 401)
        #expect(refusal("POST", "/automations/run", "bearer t0k", 10) == 401)
        #expect(refusal("POST", "/automations/run", "Bearer t0k", 64_001) == 413)
    }

    @Test func aFailedRunIsAnErrorToStrut() {
        #expect(AutomationServer.status(of: AutomationReply(status: .delivered, text: "x")) == 200)
        #expect(AutomationServer.status(of: AutomationReply(status: .nothing)) == 200)
        #expect(AutomationServer.status(of: .failed("no")) == 500)
    }

    /// Over a real socket on this Mac, as strut's `http` step calls it.
    @Test func aRunOverTheSocket() async throws {
        let seen = Mutex<[AutomationRequest]>([])
        let server = try await AutomationServer.start(port: 0, token: "t0k") { request in
            seen.withLock { $0.append(request) }
            return AutomationReply(status: .delivered, text: "Done: \(request.prompt)")
        }
        defer { Task { await server.stop() } }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/automations/run"))
        let body = #"{"name":"Daily","prompt":"Summarise","since":null}"#

        let (data, status) = try await post(url, body: body, token: "t0k")
        #expect(status == 200)
        #expect(try JSONDecoder().decode(AutomationReply.self, from: data) == AutomationReply(status: .delivered, text: "Done: Summarise"))
        #expect(seen.withLock { $0 } == [AutomationRequest(name: "Daily", prompt: "Summarise")])

        #expect(try await post(url, body: body, token: "wrong").1 == 401)
        #expect(try await post(url, body: #"{"name":"no prompt"}"#, token: "t0k").1 == 400)
        #expect(seen.withLock { $0.count } == 1)
    }

    @Test func noTokenNoServer() async {
        await #expect(throws: PeelError.self) { try await AutomationServer.start(port: 0, token: "") { _ in .failed("") } }
    }

    // MARK: The run

    @Test func aRunDeliversItsReply() async {
        let provider = Scripted(.textDelta("Kate needs the recipe."), .finished(.endTurn))
        let request = AutomationRequest(name: "Friday", prompt: "Make my to-do list",
                                        since: "2026-10-09T16:00:00Z")
        let reply = await AutomationRun.run(request, with: loop(provider))
        #expect(reply == AutomationReply(status: .delivered, text: "Kate needs the recipe."))

        let asked = try? #require(provider.requests.first?.messages.first?.text)
        #expect(asked?.contains("Task: Make my to-do list") == true)
        #expect(asked?.contains("The last run finished at 2026-10-09T16:00:00Z") == true)
        #expect(asked?.contains(AutomationRun.nothingToReport) == true)
    }

    @Test func nothingToReportIsSilent() async {
        let reply = await AutomationRun.run(
            AutomationRequest(name: "Cardiff", prompt: "Score once it's final"),
            with: loop(Scripted(.textDelta(" NOTHING_TO_REPORT\n"), .finished(.endTurn))))
        #expect(reply == AutomationReply(status: .nothing))
    }

    @Test func aModelFailureFailsTheRun() async {
        let reply = await AutomationRun.run(
            AutomationRequest(name: "Daily", prompt: "Summarise"),
            with: loop(Scripted(failing: .invalidKey("bad key"))))
        #expect(reply.status == .failed)
        #expect(reply.text == nil)
    }

    /// A run that outlasts its deadline is stopped and fails, so nothing is
    /// delivered for a run strut has already given up on.
    @Test func aRunPastItsDeadlineFails() async {
        var loop = AgentLoop(provider: Hanging(), tools: ToolRegistry([.currentTime]), model: "m", systemPrompt: "s")
        loop.retry = .never
        let reply = await AutomationRun.run(AutomationRequest(name: "Slow", prompt: "Wait"), with: loop,
                                            deadline: .milliseconds(50))
        #expect(reply.status == .failed)
        #expect(reply.error?.contains("longer than") == true)
    }

    private func loop(_ provider: Scripted) -> AgentLoop {
        var loop = AgentLoop(provider: provider, tools: ToolRegistry([.currentTime]), model: "m", systemPrompt: "s")
        loop.retry = .never
        return loop
    }

    private func post(_ url: URL, body: String, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// One scripted reply, and what it was asked.
private final class Scripted: ModelProvider {
    private let events: [ModelEvent]
    private let failure: ModelError?
    private let asked = Mutex<[ModelRequest]>([])

    init(_ events: ModelEvent...) {
        self.events = events
        failure = nil
    }

    init(failing failure: ModelError) {
        events = []
        self.failure = failure
    }

    var requests: [ModelRequest] { asked.withLock { $0 } }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        asked.withLock { $0.append(request) }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: failure)
        }
    }
}

/// A model that never answers until it is stopped.
private struct Hanging: ModelProvider {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(600))
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
