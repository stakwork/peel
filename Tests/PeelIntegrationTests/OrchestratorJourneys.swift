import AgentKit
import Foundation
import GRDB
import os
@testable import PeelAgent
@testable import PeelTestSupport
import Testing
@testable import PeelCore

extension Journeys {
    /// Milestone 1, "strut answers" (docs/agent-on-strut.md, PR 5), through
    /// the real core, broker, the staged runner and the staged strut with
    /// Peel's delta. Only the model is a stand-in, an Anthropic endpoint that
    /// asks for what a model would.
    @Suite struct Orchestrator {
        static var staged: Bool {
            FileManager.default.isExecutableFile(atPath: BundledBridge.staged.path)
                && FileManager.default.fileExists(atPath: BundledStrut.staged.appending(path: "build/steps/lib/automation/create.js").path)
        }

        /// Alice asks her agent "What did I miss?" in its DM. The bridge runs
        /// strut's orchestrator, whose model calls `sphinx/unseen`; the bridge
        /// asks her Mac, which reads her chats (Bob's two messages, his thread
        /// in her tribe) and answers once; the model's reply, written from
        /// that, comes back to her in the DM. Timed beside today's Swift loop
        /// on the same chats, with a model that takes no time in either, so
        /// what is measured is the plumbing (open question 3: within 3 s).
        @Test(.enabled(if: staged))
        @MainActor
        func whatDidIMissReadsThroughTheMac() async throws {
            let fixture = try await Agent.CatchUp.make()
            let alice = fixture.alice

            // Today's loop: one read and its answer.
            let scripted = ScriptedModel([.calls([("c1", "read_unseen_messages", [:])]), .text("Bob wrote twice.")])
            let session = try Agent.session(for: alice, model: scripted)
            let swiftStart = ContinuousClock.now
            session.send("What did I miss?")
            try await eventually("the Swift loop's reply") { !session.isRunning }
            let swift = ContinuousClock.now - swiftStart
            session.close()

            let asked = OSAllocatedUnfairLock(initialState: [String]())
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                asked.withLock { $0.append(body) }
                guard body.contains(#""type":"tool_result""#) else { return Self.toolUse("sphinx_unseen", [:]) }
                let read = body.contains(fixture.first) && body.contains(fixture.replyText) && body.contains(ChatData.begin)
                return Self.toolUse("final_answer", ["text": read ? "Caught up: Bob wrote twice, and in your tribe's thread." : "I read nothing.",
                                                     "artifacts": []])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-orchestrator-journey-\(UUID().uuidString)")
            setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(model.port)", 1)
            let strut = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "strut"),
                                                  secretKey: FileItem(file: root.appending(path: "strut-key"))))
            let bridge = try #require(BundledBridge(executable: BundledBridge.staged, data: root.appending(path: "bridge")))
            defer {
                bridge.stop(quietly: true)
                strut.stop(quietly: true)
                model.stop()
                unsetenv("ANTHROPIC_BASE_URL")
                try? FileManager.default.removeItem(at: root)
            }
            let server = try await strut.start()
            let client = AutomationsClient(server: server)
            try await client.setModel(AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "stand-in"))
            try await client.installOrchestrator()
            let agent = try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: true)
            try await client.useBridge(try #require(bridge.server))
            await alice.engine.answerDeviceRequests(with: DeviceReads(storage: alice.storage).handler)
            try await alice.engine.setDeviceAgent(agent.pubkey)

            let strutStart = ContinuousClock.now
            try await alice.engine.sendText("What did I miss?", to: agent.pubkey)
            let reply = try await eventually("the agent's reply", timeout: .seconds(60)) {
                try alice.messages(in: agent.pubkey).first { !$0.fromMe && $0.control == nil && $0.content?.hasPrefix("Caught up") == true }
            }
            let onStrut = ContinuousClock.now - strutStart
            print("catch-up timing: Swift loop \(swift), strut \(onStrut)")

            #expect(reply.content == "Caught up: Bob wrote twice, and in your tribe's thread.")
            // Read on the Mac, once: one request, done.
            let requests = try await alice.storage.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT kind, state FROM deviceRequest WHERE agent = ?", arguments: [agent.pubkey])
                    .map { [$0["kind"] as String, $0["state"] as String] }
            }
            #expect(requests == [["chats.unseen", "done"]])
            let turnPrompts = asked.withLock { $0 }.count
            // The model got Alice's chats as today's loop does: Bob's words between the markers.
            let toolResult = try #require(asked.withLock { $0 }.first { $0.contains(#""type":"tool_result""#) })
            #expect(toolResult.contains(fixture.bobKey) && toolResult.contains(fixture.club.pubkey))
            // Peel's section is the system prompt the turn ran with.
            #expect(asked.withLock { $0 }.first?.contains("You are Peel's agent") == true)
            #expect(onStrut - swift < .seconds(3), "catch-ups must not get worse: Swift \(swift), strut \(onStrut)")

            // An automation's run, as strut fires one: the run's message from its input, the chats read on the Mac.
            let fired = try await Self.strutCall("POST", "workflows/\(PeelAgent.Orchestrator.automationWorkflow)/run", [
                "input": ["name": "Morning", "prompt": "What did I miss overnight?", "since": .null, "now": "2026-10-18T07:00:00Z"],
            ], on: server)
            let runId = try #require(fired["runId"]?.string)
            let run = try await eventually("the automation's run to end", timeout: .seconds(60)) {
                // Not found until strut has recorded it.
                let record = try? await Self.strutCall("GET", "workflows/\(PeelAgent.Orchestrator.automationWorkflow)/runs/\(runId)", on: server)
                return ["success", "error"].contains(record?["status"]?.string ?? "") ? record : nil
            }
            #expect(run["status"] == "success" && run["output"]?["text"]?.string?.hasPrefix("Caught up") == true, "\(run)")
            let runAsked = asked.withLock { $0 }.dropFirst(turnPrompts)
            #expect(runAsked.first?.contains(#"running on its own at 2026-10-18T07:00:00Z (UTC)"#) == true)
            #expect(runAsked.first?.contains("no time yet: this is its first run") == true)
            #expect(runAsked.first?.contains("Your result reaches the user") == true)

            for person in [alice, fixture.bob] { await person.close() }
        }

        static func strutCall(_ method: String, _ path: String, _ body: AgentKit.JSONValue? = nil, on server: MemoryServer) async throws -> AgentKit.JSONValue {
            try await AutomationsClient(server: server).call(method, path, body, what: path)
        }

        /// One streamed Anthropic reply calling `name` with `input`, as the
        /// AI SDK reads one.
        static func toolUse(_ name: String, _ input: [String: Any]) -> String {
            func event(_ object: [String: Any]) -> String {
                let data = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return "event: \(object["type"] as? String ?? "")\ndata: \(data)\n\n"
            }
            let json = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let id = "toolu_\(UUID().uuidString.prefix(8))"
            return [
                event(["type": "message_start", "message": [
                    "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-sonnet-4-5", "content": [],
                    "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": ["input_tokens": 10, "output_tokens": 1],
                ] as [String: Any]]),
                event(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": id, "name": name, "input": [:]] as [String: Any]]),
                event(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": json]]),
                event(["type": "content_block_stop", "index": 0]),
                event(["type": "message_delta", "delta": ["stop_reason": "tool_use", "stop_sequence": NSNull()] as [String: Any], "usage": ["output_tokens": 5]]),
                event(["type": "message_stop"]),
            ].joined()
        }
    }
}
