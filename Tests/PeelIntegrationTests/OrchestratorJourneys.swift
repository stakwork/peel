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
            #expect(run["status"] == "success" && run["output"]?["text"]?.string?.hasPrefix("**Morning**\n\nCaught up") == true, "\(run)")
            let runAsked = asked.withLock { $0 }.dropFirst(turnPrompts)
            #expect(runAsked.first?.contains(#"running on its own at 2026-10-18T07:00:00Z (UTC)"#) == true)
            #expect(runAsked.first?.contains("no time yet: this is its first run") == true)
            #expect(runAsked.first?.contains("Your result reaches the user") == true)

            for person in [alice, fixture.bob] { await person.close() }
        }

        /// The agent chat as the agent's DM (docs/agent-on-strut.md, PR 6),
        /// on what the Mac reads from it: each reply names the message it
        /// answers (`AgentDM.unanswered`) and lists the tools its run used
        /// (`agentTools`); Stop's `cancel` with no run named stops the turn
        /// in flight, whose reply is "Stopped."; `/new` is the bridge's own,
        /// answered with its confirmation and no model call.
        @Test(.enabled(if: staged))
        @MainActor
        func theDMAnswersStopsAndStartsAgainAsTheAgentChatReadsIt() async throws {
            let (alice, other) = try await Journeys.Payments.pair()
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                if body.contains("Take your time") {
                    // Long enough that only a cancel ends the turn sooner.
                    Thread.sleep(forTimeInterval: 25)
                    return Self.toolUse("final_answer", ["text": "Took my time.", "artifacts": []])
                }
                guard body.contains(#""type":"tool_result""#) else { return Self.toolUse("sphinx_unseen", [:]) }
                return Self.toolUse("final_answer", ["text": "Caught up.", "artifacts": []])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-agent-dm-journey-\(UUID().uuidString)")
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
            let agent = try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: true).pubkey
            try await client.useBridge(try #require(bridge.server))
            await alice.engine.answerDeviceRequests(with: DeviceReads(storage: alice.storage).handler)
            try await alice.engine.setDeviceAgent(agent)

            /// Sends `text` to the agent; its stored message once the server has it.
            func ask(_ text: String) async throws -> Message {
                let tag = try #require(try await alice.engine.sendText(text, to: agent))
                return try await eventually("\(text) to go") {
                    try alice.storage.message(tag: tag).flatMap { $0.delivery == .delivered && $0.uuid != nil ? $0 : nil }
                }
            }
            func reply(to asked: Message) async throws -> Message {
                try await eventually("the reply to \(asked.content ?? "")", timeout: .seconds(60)) {
                    try alice.messages(in: agent).first { !$0.fromMe && $0.control == nil && $0.replyUUID == asked.uuid }
                }
            }

            let caughtUp = try await ask("What did I miss?")
            #expect(AgentDM.unanswered(in: try alice.messages(in: agent))?.uuid == caughtUp.uuid)
            let answer = try await reply(to: caughtUp)
            #expect(answer.content == "Caught up.")
            // The tool its run called, as the bridge read it from the run's events.
            #expect(answer.agentTools.map { $0.name.replacingOccurrences(of: "/", with: "_") } == ["sphinx_unseen"], "\(answer.agentTools)")
            #expect(AgentDM.unanswered(in: try alice.messages(in: agent)) == nil)

            let slow = try await ask("Take your time")
            try await eventually("the model to be asked") { model.requests.contains { $0.contains("Take your time") } }
            let stopStart = ContinuousClock.now
            _ = try await alice.engine.sendControl(ControlEnvelope(op: .cancel), text: "Stop", to: agent)
            let stopped = try await reply(to: slow)
            #expect(stopped.content == "Stopped.", "strut ended the turn with \(stopped.content ?? "nothing")")
            // strut ends the run once the model call in flight returns (it is
            // not aborted), so the Mac's Stop does not wait for this.
            print("stop took \(ContinuousClock.now - stopStart)")

            let fresh = try await ask("/new")
            #expect(try await reply(to: fresh).content == "Started a new conversation.")
            #expect(AgentDM.unanswered(in: try alice.messages(in: agent)) == nil)

            for person in [alice, other] { await person.close() }
        }

        /// Milestone 2, "it acts for you" (docs/agent-on-strut.md, PR 7). Alice
        /// asks her agent to post to her tribe in a couple of minutes: one card
        /// on her Mac, the automation and its grant. At that minute strut fires
        /// it with nobody at the Mac; the run posts through the grant, the Mac
        /// sends "[Agent] …" as Alice with no card, Bob reads it in the tribe,
        /// and the run's report reaches the agent's DM. A weekly report run now
        /// lands in the DM too. Then the preview off and on again: both
        /// automations move to `peel-automation` and back, none lost.
        @Test(.enabled(if: staged))
        @MainActor
        func anAutomationPostsAtItsMinuteAndReportsToTheDM() async throws {
            let fixture = try await Agent.CatchUp.make()
            let alice = fixture.alice
            let post = "testing whether an automation can post for me \(UUID().uuidString.prefix(6))"
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            // Two minutes on, to the minute: strut runs a one-off only at its time.
            let at = utc.date(bySetting: .second, value: 0, of: Date().addingTimeInterval(120))!
            let atText = at.formatted(Date.ISO8601FormatStyle(timeZone: utc.timeZone).year().month().day().time(includingFractionalSeconds: false))
            let minute = String(atText.prefix(16))

            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                let answered = body.contains(#""type":"tool_result""#)
                if body.contains("scheduled automation"), body.contains("Hive test") {
                    return answered ? Self.toolUse("final_answer", ["text": "Posted to your club."])
                        : Self.toolUse("sphinx_post", ["chat": fixture.clubName, "text": post])
                }
                if body.contains("scheduled automation") {
                    // Another automation, with no grant, tries to post too.
                    return answered ? Self.toolUse("final_answer", ["text": "This week: Bob planned the release."])
                        : Self.toolUse("sphinx_post", ["chat": fixture.clubName, "text": "weekly " + post])
                }
                return answered ? Self.toolUse("final_answer", ["text": "Set up.", "artifacts": []])
                    : Self.toolUse("automation_create", ["name": "Hive test", "prompt": "Post to \(fixture.clubName): \(post)",
                                                          "trigger": ["every": "once", "at": minute, "tz": "UTC"], "grant": ["chats": [fixture.clubName]]])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-automation-journey-\(UUID().uuidString)")
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
            let setup = AutomationsClient(server: server)
            try await setup.setModel(AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "stand-in"))
            try await setup.installOrchestrator()
            let agent = try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: true)
            let running = try #require(bridge.server)
            try await setup.useBridge(running)
            let cards = OSAllocatedUnfairLock(initialState: [ToolIntent]())
            let rules = ApprovalRules(store: try SQLiteAgentStore(path: alice.profile.directory.appendingPathComponent("agent.sqlite").path, device: "mac"))
            let actions = DeviceActions(engine: alice.engine, rules: rules) { _, approval in
                cards.withLock { $0.append(approval.intent) }
                return .allowOnce
            }
            await alice.engine.answerDeviceRequests(with: actions.handler)
            try await alice.engine.setDeviceAgent(agent.pubkey)

            try await alice.engine.sendText("In two minutes, post to my club that we're testing automations", to: agent.pubkey)
            try await eventually("the agent's reply", timeout: .seconds(60)) {
                try alice.messages(in: agent.pubkey).contains { !$0.fromMe && $0.control == nil && $0.content == "Set up." }
            }
            // One card: the automation and its grant, worded on the Mac.
            let asked = cards.withLock { $0 }
            #expect(asked.count == 1)
            let card = try #require(asked.first)
            #expect(card.action == "Create the automation \u{201C}Hive test\u{201D}")
            #expect(card.details.first?.contains("post as you to \(fixture.clubName) without asking") == true, "\(card)")
            let client = AutomationsClient(server: server, yours: PeelAgent.Orchestrator.automationWorkflow, callback: running.runEnds)
            let made = try #require(try await client.list().first { $0.name == "Hive test" })
            #expect(made.workflow == PeelAgent.Orchestrator.automationWorkflow)
            #expect(try SendGrants(beside: rules).grant(for: made.id)?.chats.map(\.id) == [fixture.club.pubkey])

            // At its minute, with nobody at the Mac: it runs, and Bob reads the post in the club, from Alice.
            let fire = try await eventually("the automation to fire and end", timeout: .seconds(240), every: .seconds(1)) {
                try await client.runs(of: made).first { $0.status != "running" }
            }
            #expect(fire.status == "success", "\(fire)")
            let read = try? await eventually("Bob to read the automation's post", timeout: .seconds(90)) {
                try fixture.bob.messages(in: fixture.club.pubkey).contains { !$0.fromMe && $0.content == "[Agent] " + post }
            }
            if read == nil {
                print("alice club: \(try alice.messages(in: fixture.club.pubkey).map { "\($0.fromMe) \($0.delivery) \($0.content ?? "-")" })")
                print("bob club: \(try fixture.bob.messages(in: fixture.club.pubkey).map { "\($0.fromMe) \($0.content ?? "-")" })")
            }
            #expect(read != nil, "Bob never read the post")
            let sentAt = try #require(try alice.messages(in: fixture.club.pubkey).first { $0.fromMe && $0.content == "[Agent] " + post })
            #expect(abs(sentAt.date.timeIntervalSince(at)) < 60, "posted at \(sentAt.date), set for \(at)")
            #expect(cards.withLock { $0 }.count == 1, "no card for the post")
            try await eventually("the run's report in the DM", timeout: .seconds(60)) {
                try alice.messages(in: agent.pubkey).contains { !$0.fromMe && $0.content == "**Hive test**\n\nPosted to your club." }
            }

            // A weekly report, run now: it lands in the DM.
            let weekly = try await client.create(name: "Weekly report", prompt: "Tell me what happened in my club this week",
                                                 trigger: ["every": "week", "on": ["mon"], "at": ["09:00"], "tz": "UTC"])
            try await client.runNow(weekly)
            try await eventually("the weekly report in the DM", timeout: .seconds(60)) {
                try alice.messages(in: agent.pubkey).contains { !$0.fromMe && $0.content == "**Weekly report**\n\nThis week: Bob planned the release." }
            }
            // Its post named its own automation, which has no grant: the Mac refused it, and nothing went.
            let refused = try await alice.storage.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT args, status FROM deviceRequest WHERE agent = ? AND kind = 'send'", arguments: [agent.pubkey])
                    .compactMap { row -> String? in (row["args"] as String).contains(weekly.id) ? row["status"] as String? : nil }
            }
            #expect(refused == ["denied"], "\(refused)")
            #expect(try !alice.messages(in: fixture.club.pubkey).contains { $0.content?.contains("weekly " + post) == true })

            // Preview off, then on: each moves to peel-automation and back, its schedule and grant kept.
            // Off, it runs as before: strut hands it to this Mac's AutomationServer.
            let handed = OSAllocatedUnfairLock(initialState: [AutomationRequest]())
            let mac = try await AutomationServer.start(port: try BundledBridge.freePort(), token: try AutomationServer.newKey()) { request in
                handed.withLock { $0.append(request) }
                return AutomationReply(status: .delivered, text: "Handled on the Mac.")
            }
            defer { Task { await mac.stop() } }
            try await setup.install(port: mac.port, token: mac.token)
            _ = try await AutomationsClient(server: server, yours: AutomationsClient.workflow, callback: nil).moveYours()
            let off = try await client.list().filter(\.isYours)
            let weeklyOff = try #require(off.first { $0.name == "Weekly report" })
            #expect(off.count == 2 && weeklyOff.workflow == AutomationsClient.workflow, "\(off)")
            try await client.runNow(weeklyOff)
            try await eventually("the weekly report handed to the Mac", timeout: .seconds(60)) {
                handed.withLock { $0 }.contains { $0.name == "Weekly report" && $0.prompt == "Tell me what happened in my club this week" }
            }
            _ = try await AutomationsClient(server: server, yours: PeelAgent.Orchestrator.automationWorkflow, callback: running.runEnds).moveYours()
            let on = try await client.list().filter(\.isYours)
            #expect(on.count == 2 && on.allSatisfy { $0.workflow == PeelAgent.Orchestrator.automationWorkflow || $0.isDone }, "\(on)")
            #expect(on.first { $0.name == "Weekly report" }?.trigger == weekly.trigger)
            #expect(on.first { $0.name == "Hive test" }?.id == made.id, "the grant is kept under the id, which a move keeps")

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
