import AgentKit
import Foundation
import GRDB
import os
@testable import PeelAgent
@testable import PeelTestSupport
import Testing
@testable import PeelCore
@testable import PeelUI

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
        /// that, comes back to her in the DM. Timed, with a model that takes
        /// no time, so what is printed is the plumbing (open question 3).
        @Test(.enabled(if: staged))
        @MainActor
        func whatDidIMissReadsThroughTheMac() async throws {
            let fixture = try await Agent.CatchUp.make()
            let alice = fixture.alice

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
            await alice.engine.answerDeviceRequests(with: DeviceReads(storage: alice.storage, myAlias: { nil }).handler)
            try await alice.engine.setDeviceAgent(agent.pubkey)

            let strutStart = ContinuousClock.now
            try await alice.engine.sendText("What did I miss?", to: agent.pubkey)
            let reply = try await eventually("the agent's reply", timeout: .seconds(60)) {
                try alice.messages(in: agent.pubkey).first { !$0.fromMe && $0.control == nil && $0.content?.hasPrefix("Caught up") == true }
            }
            let onStrut = ContinuousClock.now - strutStart
            print("catch-up timing: strut \(onStrut)")

            #expect(reply.content == "Caught up: Bob wrote twice, and in your tribe's thread.")
            // Read on the Mac, once: one request, done.
            let requests = try await alice.storage.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT kind, state FROM deviceRequest WHERE agent = ?", arguments: [agent.pubkey])
                    .map { [$0["kind"] as String, $0["state"] as String] }
            }
            #expect(requests == [["chats.unseen", "done"]])
            let turnPrompts = asked.withLock { $0 }.count
            // The model got Alice's chats: Bob's words between the markers.
            let toolResult = try #require(asked.withLock { $0 }.first { $0.contains(#""type":"tool_result""#) })
            #expect(toolResult.contains(fixture.bobKey) && toolResult.contains(fixture.club.pubkey))
            // Peel's section is the system prompt the turn ran with.
            #expect(asked.withLock { $0 }.first?.contains("You are Peel's agent") == true)

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
        /// answered with its confirmation and no model call; a turn cut off
        /// by quitting ends when Peel opens again, and the next one answers.
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
            await alice.engine.answerDeviceRequests(with: DeviceReads(storage: alice.storage, myAlias: { nil }).handler)
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

            // Peel quits mid-turn (strut and the bridge stopped, as on quit) and
            // opens again: strut answers the cut-off run as stale, and the bridge
            // ends that turn (sphinx#386), so the DM is not held.
            let cut = try await ask("Take your time, again")
            try await eventually("the model to be asked again") { model.requests.contains { $0.contains("Take your time, again") } }
            bridge.stop(quietly: true)
            strut.stop(quietly: true)
            let again = try await strut.start()
            try await AutomationsClient(server: again).installOrchestrator()
            #expect(try await bridge.setUp(on: alice.engine, beside: again, alias: "Agent", pair: false).pubkey == agent)
            try await AutomationsClient(server: again).useBridge(try #require(bridge.server))
            let interrupted = try await reply(to: cut)
            #expect(interrupted.content?.contains("interrupted") == true, "the cut-off turn ended with \(interrupted.content ?? "nothing")")
            let after = try await ask("What did I miss?")
            #expect(try await reply(to: after).content == "Caught up.")
            #expect(AgentDM.unanswered(in: try alice.messages(in: agent)) == nil)

            for person in [alice, other] { await person.close() }
        }

        /// Authoring (docs/connectors-and-authoring.md, P1). Alice asks her
        /// agent for a workflow; the orchestrator starts strut's `builder` job,
        /// whose model test-runs a step through `meta/run-step` (here a shell)
        /// and calls `meta/publish-workflow`. Peel gives the builder no
        /// `approve:` and no `builder.reach`: both run at once, no card.
        @Test(.enabled(if: staged))
        @MainActor
        func aWorkflowTheAgentBuildsIsTestedAndPublishedWithNoCard() async throws {
            let (alice, other) = try await Journeys.Payments.pair()
            let workflow = "daily-hello"
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                let answered = body.contains(#""type":"tool_result""#)
                if body.contains("You are a workflow BUILDER") {
                    switch body.components(separatedBy: #""type":"tool_result""#).count - 1 {
                    case 0:
                        return Self.toolUse("meta_run_step", ["type": "exec", "config": ["cmd": "printf", "args": ["%s-%s", "shell", "ran"]]])
                    case 1:
                        return Self.toolUse("meta_publish_workflow", [
                            "name": workflow, "description": "Says hello",
                            "yaml": "name: \(workflow)\nsteps:\n  - id: hi\n    type: pack\n    config: { text: hello }\n",
                        ])
                    default:
                        return Self.toolUse("final_answer", ["text": "Published \(workflow).", "artifacts": []])
                    }
                }
                guard answered else {
                    return Self.toolUse("job_start", ["prompt": "A workflow that says hello", "title": "Daily hello", "workflow": "builder"])
                }
                return Self.toolUse("final_answer", ["text": "Started building it.", "artifacts": []])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-builder-journey-\(UUID().uuidString)")
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
            await alice.engine.answerDeviceRequests(with: DeviceReads(storage: alice.storage, myAlias: { nil }).handler)
            try await alice.engine.setDeviceAgent(agent)

            try await alice.engine.sendText("Make me a workflow that says hello every morning", to: agent)
            try await eventually("the agent's reply", timeout: .seconds(60)) {
                try alice.messages(in: agent).contains { !$0.fromMe && $0.control == nil && $0.content == "Started building it." }
            }
            let ended = try await eventually("the builder's turn to end", timeout: .seconds(60)) {
                model.requests.first { $0.contains("You are a workflow BUILDER") && $0.components(separatedBy: #""type":"tool_result""#).count == 3 }
            }
            // The shell ran, and nothing waits on a card.
            #expect(ended.contains("shell-ran"), "\(ended.suffix(2000))")
            let pending = try await Self.strutCall("GET", "proposals?status=pending", on: server)["proposals"]?.array ?? []
            #expect(pending.isEmpty, "\(pending)")
            // Published with no card.
            let flow = try await Self.strutCall("GET", "workflows/\(workflow)/flow", on: server)
            #expect(flow["steps"]?.array?.first?["id"] == "hi", "\(flow)")

            for person in [alice, other] { await person.close() }
        }

        /// Connections (docs/connectors-and-authoring.md, P3): an MCP server
        /// registered with Peel's strut, its key there by name, granted to the
        /// assistant. From the DM, a read-only tool runs at once; a tool that
        /// writes is a proposal, whose card the bridge brings to the Mac
        /// (runner R1); allowed, strut calls the server once, with the key.
        @Test(.enabled(if: staged))
        @MainActor
        func aConnectedServersWriteWaitsForTheCardAndRunsOnce() async throws {
            let (alice, other) = try await Journeys.Payments.pair()
            let mcp = try await MCPStub()
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                func answered(_ asked: String) -> Bool {
                    guard let at = body.range(of: asked, options: .backwards) else { return false }
                    return body[at.upperBound...].contains(#""type":"tool_result""#)
                }
                if body.contains("File an issue: Try Connections") {
                    guard answered("File an issue: Try Connections") else {
                        return Self.toolUse("linear_create_issue", ["title": "Try Connections"])
                    }
                    return Self.toolUse("final_answer", ["text": "Asked you first.", "artifacts": []])
                }
                guard answered("What are my open issues?") else { return Self.toolUse("linear_list_issues", [:]) }
                return Self.toolUse("final_answer", ["text": body.contains("PEEL-1") ? "One: PEEL-1." : "None.", "artifacts": []])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-connections-journey-\(UUID().uuidString)")
            setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(model.port)", 1)
            let strut = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "strut"),
                                                  secretKey: FileItem(file: root.appending(path: "strut-key"))))
            let bridge = try #require(BundledBridge(executable: BundledBridge.staged, data: root.appending(path: "bridge")))
            defer {
                bridge.stop(quietly: true)
                strut.stop(quietly: true)
                model.stop()
                mcp.stop()
                unsetenv("ANTHROPIC_BASE_URL")
                try? FileManager.default.removeItem(at: root)
            }
            strut.allowsLocalMCP = true
            try strut.keep(MCPGrants(assistant: ["linear"]))
            let server = try await strut.start()
            let client = AutomationsClient(server: server)
            try await client.setModel(AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "stand-in"))
            try await client.installOrchestrator()
            try await client.addMCPServer(name: "linear", url: mcp.url, key: "lin_api_secret")
            let agent = try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: true).pubkey
            try await client.useBridge(try #require(bridge.server))
            let cards = OSAllocatedUnfairLock(initialState: [ToolIntent]())
            let rules = ApprovalRules(store: try SQLiteAgentStore(path: alice.profile.directory.appendingPathComponent("agent.sqlite").path, device: "mac"))
            let actions = DeviceActions(engine: alice.engine, rules: rules) { _, approval in
                cards.withLock { $0.append(approval.intent) }
                return .allowOnce
            }
            await alice.engine.answerDeviceRequests(with: actions.handler)
            try await alice.engine.setDeviceAgent(agent)
            func reply(_ text: String) async throws {
                try await eventually(text, timeout: .seconds(60)) {
                    try alice.messages(in: agent).contains { !$0.fromMe && $0.control == nil && $0.content == text }
                }
            }

            try await alice.engine.sendText("What are my open issues?", to: agent)
            try await reply("One: PEEL-1.")
            #expect(mcp.calls.map(\.tool) == ["list_issues"] && cards.withLock { $0 }.isEmpty)

            try await alice.engine.sendText("File an issue: Try Connections", to: agent)
            try await reply("Asked you first.")
            try await eventually("the card, then the call", timeout: .seconds(60)) { mcp.calls.count == 2 }
            #expect(cards.withLock { $0 }.count == 1, "\(cards.withLock { $0 })")
            let made = try #require(mcp.calls.last)
            #expect(made.tool == "create_issue" && made.arguments.contains("Try Connections") && made.bearer == "lin_api_secret")
            // Decided once: nothing more reaches the server.
            try await Task.sleep(for: .seconds(5))
            #expect(mcp.calls.count == 2)
            for person in [alice, other] { await person.close() }
        }

        /// A Hive workspace as a peer (docs/connectors-and-authoring.md,
        /// "Peers", P8), on two staged struts: Peel's, speaking for the person
        /// (strut's own section, rendered by its Node), and one standing in
        /// for the org's central strut, whose person token it mints. The
        /// orchestrator's call to the org is a proposal; the Mac's card is worded
        /// from strut's record ("Send this to Acme?", the message), and Always
        /// keeps a rule for that org only; strut's `decide` (the bridge's, in
        /// runner R1) then reaches the org's assistant as the person, on this
        /// conversation's thread there (`<person>/<conversation id>`, strut#290),
        /// and the next call to Acme needs no card. The builder launched with
        /// `peer` gets no route around the card (strut#294).
        @Test(.enabled(if: staged))
        @MainActor
        func aHiveWorkspaceIsAskedOnlyOnACard() async throws {
            let person = "tom-cm1"
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                guard body.contains("Its peers are the person's ORGS") else {
                    // Acme's own assistant, on its strut (which speaks for no person).
                    return Self.toolUse("final_answer", ["text": "Acme ships v2 on Friday.", "artifacts": []])
                }
                guard body.contains(#""type":"tool_result""#) else {
                    return Self.toolUse("strut_run_workflow", ["peer": "acme", "workflow": "orchestrator",
                                                               "input": ["prompt": "What is Acme shipping?", "session": "\(person)/peel/agent-1/dm"]])
                }
                return Self.toolUse("final_answer", ["text": "Asked Acme; waiting for your yes.", "artifacts": []])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-hive-journey-\(UUID().uuidString)")
            setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(model.port)", 1)
            let mine = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "mine"),
                                                 secretKey: FileItem(file: root.appending(path: "mine-key"))))
            let acme = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "acme"),
                                                 secretKey: FileItem(file: root.appending(path: "acme-key"))))
            defer {
                mine.stop(quietly: true)
                acme.stop(quietly: true)
                model.stop()
                unsetenv("ANTHROPIC_BASE_URL")
                try? FileManager.default.removeItem(at: root)
            }
            mine.person = person
            let (local, central) = (try await mine.start(), try await acme.start())
            let credential = AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "stand-in")
            let client = AutomationsClient(server: local)
            for server in [local, central] { try await AutomationsClient(server: server).setModel(credential) }
            let token = try #require(try await Self.strutCall("POST", "peers/tokens", ["actor": .string(person)], on: central)["token"]?.string)
            try await client.syncPeers([HivePeer(id: "acme", baseUrl: central.base.absoluteString, token: token, label: "Acme")])
            #expect(try await Self.strutCall("GET", "peers", on: local)["peers"]?.array?.compactMap { $0["id"]?.string } == ["acme"])
            // strut's section for a person's orgs, behind Peel's.
            let system = try await Self.strutCall("GET", "workflows/orchestrator/flow", on: local)["params"]?["system"]?.string ?? ""
            #expect(system.contains("You are Peel's agent") && system.contains("Its peers are the person's ORGS") && system.contains("\(person)/<conversation>"))

            // No route around the card (strut#294): the builder launched with `peer`, as `job/start` and
            // `meta/run-workflow` do, is refused on Peel's strut and nothing reaches Acme.
            let build = try await Self.strutCall("POST", "workflows/builder/run", ["input": ["prompt": "Build hello on Acme", "peer": "acme"]], on: local)
            let buildId = try #require(build["runId"]?.string)
            let built = try await eventually("the builder's run to end", timeout: .seconds(60)) {
                let record = try? await Self.strutCall("GET", "workflows/builder/runs/\(buildId)", on: local)
                return ["success", "error"].contains(record?["status"]?.string ?? "") ? record : nil
            }
            #expect(built["status"] == "error" && built["error"]?["message"]?.string?.contains("needs the person's approval") == true, "\(built)")
            for workflow in ["builder", "orchestrator"] {
                #expect(try await Self.strutCall("GET", "workflows/\(workflow)/runs", on: central).array?.isEmpty == true)
            }

            func ask() async throws -> String {
                let run = try await Self.strutCall("POST", "workflows/orchestrator/run", ["input": ["prompt": "@acme what are you shipping?"]], on: local)
                let runId = try #require(run["runId"]?.string)
                return try await eventually("the call to Acme to wait as a proposal", timeout: .seconds(60)) {
                    let pending = try await Self.strutCall("GET", "proposals?status=pending&runId=\(runId)", on: local)["proposals"]?.array ?? []
                    return pending.first?["id"]?.string
                }
            }
            let first = try await ask()
            guard case .record(let firstRecord) = try await client.readProposal(first) else {
                Issue.record("the proposal was not read")
                return
            }
            #expect(try await client.peerRequest(from: firstRecord) == PeerRequest(peer: "acme", name: "Acme", workflow: "orchestrator",
                                                                                    prompt: "What is Acme shipping?"))

            let (alice, other) = try await Journeys.Payments.pair()
            let rules = ApprovalRules(store: try SQLiteAgentStore.inMemory(device: "mac"))
            let cards = OSAllocatedUnfairLock(initialState: [ToolIntent]())
            do {
                let reader = ProposalReader(read: { id in try await client.readProposal(id) },
                                            peer: { record in try await client.peerRequest(from: record) }, keep: { _, _ in })
                let actions = DeviceActions(engine: alice.engine, rules: rules, proposals: reader) { _, approval in
                    cards.withLock { $0.append(approval.intent) }
                    return .alwaysAllow
                }
                // As the bridge relays a proposal (runner R1): its own words, which the Mac does not use.
                func card(_ proposal: String) async -> DeviceAnswer? {
                    await actions.answer(DeviceRequest(agent: "02a", id: "proposal:\(proposal)", kind: "approve",
                                                       args: .object(["intent": .object(["action": .string("Run strut/run-workflow")])]),
                                                       deadline: Date().addingTimeInterval(3600)))
                }
                #expect(await card(first)?.status == .done)
                let shown = try #require(cards.withLock { $0 }.first)
                #expect(shown.action == "Send this to Acme?" && shown.content == "What is Acme shipping?")
                #expect(shown.details == ["To Acme's assistant (@acme) in Stadeum, as you"] && shown.target?.id == "acme/orchestrator")
                #expect(try rules.all().map { "\($0.tool) \($0.target?.id ?? "-")" } == ["strut/run-workflow acme/orchestrator"])

                // Allowed: strut runs the call (as the bridge's decide will), and Acme's assistant answers as the person.
                let decided = try await Self.strutCall("POST", "proposals/\(first)/decide", ["action": "accept"], on: local)
                let applied = try await eventually("the call to reach Acme", timeout: .seconds(60)) {
                    let record = try await Self.strutCall("GET", "proposals/\(first)", on: local)
                    return ["applied", "failed"].contains(record["status"]?.string ?? "") ? record : nil
                }
                #expect(applied["status"] == "applied", "\(decided) \(applied)")
                #expect(applied["result"]?["output"]?["output"]?["text"] == "Acme ships v2 on Friday.", "\(applied)")

                // Always for Acme: the next call to it is allowed with no card.
                let second = try await ask()
                #expect(await card(second)?.status == .done && cards.withLock { $0 }.count == 1)
            }
            // Disconnected (or Acme left): its record is gone from strut.
            try await client.syncPeers([])
            #expect(try await Self.strutCall("GET", "peers", on: local)["peers"]?.array?.isEmpty == true)
            for person in [alice, other] { await person.close() }
        }

        /// An automation whose task needs the web (connectors and authoring,
        /// "automations wake the agent"): its run starts a job, which has the
        /// web, and says nothing itself; the job's result reaches Alice's DM
        /// on its own, as the bridge sends the end of a job no DM started.
        @Test(.enabled(if: staged))
        @MainActor
        func anAutomationStartsAJobWhoseResultReachesTheDM() async throws {
            let (alice, other) = try await Journeys.Payments.pair()
            let found = "Top 3 padel videos this week: \(UUID().uuidString.prefix(6))"
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                let answered = body.contains(#""type":"tool_result""#)
                if body.contains("scheduled automation") {
                    return answered ? Self.toolUse("final_answer", ["text": PeelAgent.Orchestrator.nothingToReport])
                        : Self.toolUse("job_start", ["prompt": "Find the top 3 YouTube videos about padel", "title": "Padel videos"])
                }
                // The job.
                return Self.toolUse("final_answer", ["text": found, "artifacts": []])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-automation-job-journey-\(UUID().uuidString)")
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
            let agent = try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: true).pubkey
            let running = try #require(bridge.server)
            try await setup.useBridge(running)
            await alice.engine.answerDeviceRequests(with: DeviceReads(storage: alice.storage, myAlias: { nil }).handler)
            try await alice.engine.setDeviceAgent(agent)

            let client = AutomationsClient(server: server, yours: PeelAgent.Orchestrator.automationWorkflow, callback: running.runEnds)
            let padel = try #require(Automation(try await client.make(
                name: "Padel videos", trigger: ["every": "week", "on": ["sun"], "at": ["09:00"], "tz": "UTC"], enabled: true,
                input: AutomationsClient.input(name: "Padel videos", prompt: "Send me the top 3 YouTube videos about padel"),
                what: "the automation")["automation"] ?? .null))
            try await client.runNow(padel)
            try await eventually("the job's result in the DM", timeout: .seconds(90)) {
                try alice.messages(in: agent).contains { !$0.fromMe && $0.content == found }
            }
            let fire = try #require(try await client.runs(of: padel).first)
            #expect(fire.status == "success" && fire.nothing, "\(fire)")
            // The run itself said nothing: the job's result is the agent's one message.
            let said = try alice.messages(in: agent).filter { !$0.fromMe && $0.control == nil }.compactMap(\.content)
            #expect(said == [found], "\(said)")

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
            let weekly = try #require(Automation(try await client.make(
                name: "Weekly report", trigger: ["every": "week", "on": ["mon"], "at": ["09:00"], "tz": "UTC"], enabled: true,
                input: AutomationsClient.input(name: "Weekly report", prompt: "Tell me what happened in my club this week"),
                what: "the weekly report")["automation"] ?? .null))
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

            for person in [alice, fixture.bob] { await person.close() }
        }

        /// Proposal cards (docs/agent-on-strut.md, "Built: proposal cards"),
        /// on two staged struts at the pin. Peel's own: a connected server's
        /// write is a proposal whose card the bridge brings to the Mac
        /// (runner R1); the Mac reads the record and draws strut's card
        /// from it (one field per input key, Accept and Reject) rather than
        /// the bridge's words, keeps it, and after Allow the kept record
        /// follows the bridge's decide to `applied`. A workspace's: the
        /// person's own pending proposal on the org's strut, listed and
        /// decided with a person token minted there, strut's card for
        /// `app/grant` (every field a warning, Grant and Don't grant) on it;
        /// another person's never listed to that token; a decide on another
        /// person's refused with 403.
        @Test(.enabled(if: staged))
        @MainActor
        func aProposalsCardComesFromTheRecordHereAndOnAWorkspace() async throws {
            let (alice, other) = try await Journeys.Payments.pair()
            let mcp = try await MCPStub()
            let person = "tom-cm1"
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
                let answered = body.contains(#""type":"tool_result""#)
                if body.contains("Grant the todo app") {
                    // Acme's own assistant, as the person: an app/grant proposal.
                    return answered ? Self.toolUse("final_answer", ["text": "Proposed the grant.", "artifacts": []])
                        : Self.toolUse("app_grant", ["name": "todo", "rationale": "The app needs to ask the assistant."])
                }
                if body.contains("Someone else's install") {
                    return answered ? Self.toolUse("final_answer", ["text": "Proposed.", "artifacts": []])
                        : Self.toolUse("package_install", ["package": "acme/secret"])
                }
                guard answered else { return Self.toolUse("linear_create_issue", ["title": "Try proposal cards", "team": "PEEL"]) }
                return Self.toolUse("final_answer", ["text": "Asked you first.", "artifacts": []])
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-proposal-cards-journey-\(UUID().uuidString)")
            setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(model.port)", 1)
            let mine = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "mine"),
                                                 secretKey: FileItem(file: root.appending(path: "mine-key"))))
            let acme = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "acme"),
                                                 secretKey: FileItem(file: root.appending(path: "acme-key"))))
            let bridge = try #require(BundledBridge(executable: BundledBridge.staged, data: root.appending(path: "bridge")))
            defer {
                bridge.stop(quietly: true)
                mine.stop(quietly: true)
                acme.stop(quietly: true)
                model.stop()
                mcp.stop()
                unsetenv("ANTHROPIC_BASE_URL")
                try? FileManager.default.removeItem(at: root)
            }
            mine.allowsLocalMCP = true
            try mine.keep(MCPGrants(assistant: ["linear"]))
            let (local, central) = (try await mine.start(), try await acme.start())
            let credential = AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "stand-in")
            let client = AutomationsClient(server: local)
            for server in [local, central] { try await AutomationsClient(server: server).setModel(credential) }
            try await client.installOrchestrator()
            try await client.addMCPServer(name: "linear", url: mcp.url, key: "lin_api_secret")
            let agent = try await bridge.setUp(on: alice.engine, beside: local, alias: "Agent", pair: true).pubkey
            try await client.useBridge(try #require(bridge.server))

            // Peel's own strut: the Mac's card from the record, kept, then applied.
            let watch = ProposalWatch()
            await watch.open(alice.storage)
            defer { watch.close() }
            watch.readLocal = { id in try await client.readProposal(id) }
            let cards = OSAllocatedUnfairLock(initialState: [ToolIntent]())
            let rules = ApprovalRules(store: try SQLiteAgentStore(path: alice.profile.directory.appendingPathComponent("agent.sqlite").path, device: "mac"))
            let reader = ProposalReader(
                read: { id in try await client.readProposal(id) }, peer: { record in try await client.peerRequest(from: record) },
                keep: { request, record in
                    await watch.keep(record, source: .local, request: request.id, notAfter: Int64(request.deadline.timeIntervalSince1970))
                }
            )
            let actions = DeviceActions(engine: alice.engine, rules: rules, proposals: reader) { request, approval in
                cards.withLock { $0.append(approval.intent) }
                // As the card's Accept: the watch told, so it reads the record until the bridge's decide lands.
                await watch.answered(request: request.id)
                return .allowOnce
            }
            await alice.engine.answerDeviceRequests(with: actions.handler)
            try await alice.engine.setDeviceAgent(agent)
            try await alice.engine.sendText("File an issue: Try proposal cards", to: agent)
            try await eventually("the reply", timeout: .seconds(60)) {
                try alice.messages(in: agent).contains { !$0.fromMe && $0.control == nil && $0.content == "Asked you first." }
            }
            try await eventually("the card, then the call", timeout: .seconds(60)) { mcp.calls.count == 1 }
            let shown = try #require(cards.withLock { $0 }.first)
            let kept = try #require(watch.kept.values.first { $0.source == .local })
            #expect(shown.action == kept.record.shownCard.title && shown.content == nil && shown.target == nil, "\(shown)")
            #expect(kept.record.step == "mcp/linear/create_issue" && kept.request?.hasPrefix("proposal:") == true, "\(kept.record)")
            let card = try #require(kept.record.card)
            #expect(Set(card.fields.map(\.label)) == ["title", "team"] && card.fields.first { $0.label == "title" }?.value == "Try proposal cards")
            #expect(card.accept == "Accept" && card.reject == "Reject" && card.full && kept.record.by.actor == nil)
            // The bridge's decide lands on the record, and the watch reads it: applied.
            try await eventually("the kept record to be applied", timeout: .seconds(60), every: .seconds(1)) {
                await watch.tick()
                return watch.kept.values.first { $0.source == .local }?.record.status == .applied
            }
            #expect(watch.kept.values.first { $0.source == .local }?.isOver == true)
            #expect(mcp.calls.count == 1 && mcp.calls.first?.bearer == "lin_api_secret")

            // A workspace's strut, as the org's central: a person token for the person, and another's.
            let token = try #require(try await Self.strutCall("POST", "peers/tokens", ["actor": .string(person)], on: central)["token"]?.string)
            let kates = try #require(try await Self.strutCall("POST", "peers/tokens", ["actor": .string("kate-x1")], on: central)["token"]?.string)
            let peer = HivePeer(id: "acme", baseUrl: central.base.absoluteString, token: token, label: "Acme")
            // The org's assistant run with a person's token, as a hand-off runs it: its proposals are that person's,
            // in a thread of theirs (`<actor>/…`), which is where strut lists them to that token since strut#419.
            func propose(_ prompt: String, with token: String, actor: String) async throws -> String {
                let body = Data(#"{"input":{"prompt":"\#(prompt)","session":"\#(actor)/c1"}}"#.utf8)
                let (status, data) = try await Web.requestStrut("POST", central.base.appending(path: "workflows/orchestrator/run"), json: body,
                                                                bearer: token, limit: 1_000_000, what: "the run")
                // strut takes a run (202) and runs it on its own.
                #expect(status == 200 || status == 202, "\(status) \(String(decoding: data, as: UTF8.self).prefix(300))")
                return try await eventually("\(actor)'s proposal", timeout: .seconds(60)) {
                    let pending = try await Self.strutCall("GET", "proposals?status=pending", on: central)["proposals"]?.array ?? []
                    return pending.first { $0["by"]?["actor"]?.string == actor }?["id"]?.string
                }
            }
            let grant = try await propose("Grant the todo app", with: token, actor: person)
            let secret = try await propose("Someone else's install", with: kates, actor: "kate-x1")
            let (listed, others) = try await peer.pendingProposals(actor: person)
            #expect(listed.map(\.id) == [grant] && listed.first?.by.actor == person, "\(listed.map(\.id))")
            #expect(others == 0, "a strut at the pin shows a person token only their own")
            let grantCard = try #require(listed.first?.card)
            #expect(grantCard.accept == "Grant" && grantCard.reject == "Don't grant" && grantCard.fields.allSatisfy(\.danger) && !grantCard.fields.isEmpty)
            #expect(listed.first?.rationale == "The app needs to ask the assistant.")
            // Watched as the Mac and the iPhone watch it: listed, decided as the person, final.
            watch.orgs = { ([peer], person) }
            await watch.tick()
            let key = ProposalKey(source: .org("acme"), id: grant)
            #expect(watch.orgCards.map(\.kept.record.id) == [grant] && watch.orgCards.first?.org == "Acme")
            await watch.decide(key, accept: true)
            let decided = try #require(watch.kept[key])
            #expect(decided.record.status.isFinal && decided.isOver, "\(decided.record.status)")
            #expect(try await Self.strutCall("GET", "proposals/\(grant)", on: central)["decision"]?["by"]?.string == person)
            // Another person's: read by its id (strut#407: whoever was shown it), never listed (above) or decided.
            guard case .record(let read) = try await peer.proposal(secret) else { Issue.record("another's proposal by id"); return }
            #expect(read.id == secret)
            #expect(try await peer.decide(secret, accept: true) == .notYours("forbidden: proposal \"\(secret)\" is not yours to decide"))
            let katesPeer = HivePeer(id: "acme", baseUrl: central.base.absoluteString, token: kates, label: "Acme")
            #expect(try await katesPeer.pendingProposals(actor: "kate-x1").mine.map(\.id) == [secret])
            for person in [alice, other] { await person.close() }
        }

        /// Memory on the workspace graph (`BundledStrut.graphMemory`), the
        /// October scenario (memory-test-2026-10-14) through the orchestrator's
        /// own turns on the staged strut: the user saying who they are, a fact
        /// Kate said, "used to", a dated move, a way they like things done, a
        /// recall in a turn of its own (no chat before it, as after clearing
        /// the chat) on the orchestrator and an automation's run, two
        /// duplicates merged, and a fact forgotten. The model is a stand-in
        /// that calls the graph tools as the prompt says to: this proves the
        /// grants, the readers and what strut writes and reads back, not
        /// what a live model chooses to call.
        @Test(.enabled(if: staged && FileManager.default.fileExists(
            atPath: BundledStrut.staged.appending(path: "build/steps/lib/graph/import-memory.js").path)))
        @MainActor
        func memoryOnTheGraphRemembersRecallsMergesAndForgets() async throws {
            let script = Script()
            let model = try await HTTPStub(contentType: "text/event-stream") { _, request in
                script.next(String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...]))
            }
            let root = FileManager.default.temporaryDirectory.appending(path: "peel-graph-memory-journey-\(UUID().uuidString)")
            setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(model.port)", 1)
            let strut = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "strut"),
                                                  secretKey: FileItem(file: root.appending(path: "strut-key"))))
            strut.graphMemory = true
            defer {
                strut.stop(quietly: true)
                model.stop()
                unsetenv("ANTHROPIC_BASE_URL")
                try? FileManager.default.removeItem(at: root)
            }
            let server = try await strut.start()
            let client = AutomationsClient(server: server)
            try await client.setModel(AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "stand-in"))
            try await client.installOrchestrator(graphMemory: true)
            // A first start with no old database: recorded as done, nothing imported.
            #expect(FileManager.default.fileExists(atPath: strut.memoryImportRecord.path))

            /// One turn: `prompt` run on `workflow` with `calls` as the
            /// model's, each given the result before it; the results.
            func turn(_ prompt: String, on workflow: String = BundledBridge.workflow,
                      _ calls: [@Sendable (AgentKit.JSONValue) -> String]) async throws -> [AgentKit.JSONValue] {
                script.start(calls)
                let input: AgentKit.JSONValue = workflow == BundledBridge.workflow
                    ? ["prompt": .string(prompt)]
                    : ["name": "Recall", "prompt": .string(prompt), "since": .null, "now": "2026-11-03T09:00:00Z"]
                let fired = try await Self.strutCall("POST", "workflows/\(workflow)/run", ["input": input], on: server)
                let runId = try #require(fired["runId"]?.string, "\(fired)")
                let run = try await eventually("\(workflow)'s run to end", timeout: .seconds(60)) {
                    let record = try? await Self.strutCall("GET", "workflows/\(workflow)/runs/\(runId)", on: server)
                    return ["success", "error"].contains(record?["status"]?.string ?? "") ? record : nil
                }
                #expect(run["status"] == "success", "\(prompt): \(run)")
                let results = script.results
                #expect(results.count == calls.count, "\(prompt): \(results.count) of \(calls.count) tools answered")
                for (index, result) in results.enumerated() {
                    let text = result.string ?? result.jsonString
                    #expect(!text.contains(" failed") && !text.contains("invalid input") && !text.contains("REFUSED"),
                            "\(prompt), call \(index): \(text.prefix(600))")
                }
                return results
            }
            // Who they are: no user yet, so made once; a place type made when none fits.
            let me = try await turn("Remember: I'm Tom and I live in Bristol.", [
                { _ in Self.toolUse("graph_graph_get", ["owner": true]) },
                { _ in Self.toolUse("graph_create_node", ["node_type": "Person", "node_data": ["name": "Tom", "is_owner": true]]) },
                { last in
                    Script.refs.withLock { $0["tom"] = last["ref_id"]?.string }
                    return Self.toolUse("graph_create_schema", ["type": "Place", "attributes": ["name": "string"], "role": "entity"])
                },
                { _ in Self.toolUse("graph_resolve", ["node_type": "Place", "name": "Bristol"]) },
                { _ in Self.toolUse("graph_assert", ["facts": [[
                    "source_ref_id": Script.refs.withLock { $0["tom"] ?? "" }, "edge_type": "LIVES_IN", "target_type": "Place",
                    "target_data": ["name": "Bristol"], "text": "Tom lives in Bristol.", "source": "chat-1",
                    "create_schema_if_missing": true, "cardinality": "one",
                ]]]) },
            ])
            #expect(me[0].jsonString.contains("is_owner"), "\(me[0])")
            let tom = try #require(me[1]["ref_id"]?.string, "\(me[1])")
            #expect(me[4]["facts"]?.array?.first?["action"] == "created", "\(me[4])")

            // Someone else's words: Kate said it, so the fact is hers.
            let kate = try await turn("Kate texted me: \"I work at Monzo now.\"", [
                { _ in Self.toolUse("graph_resolve", ["node_type": "Person", "name": "Kate"]) },
                { _ in Self.toolUse("graph_create_node", ["node_type": "Person", "node_data": ["name": "Kate"]]) },
                { last in
                    Script.refs.withLock { $0["kate"] = last["ref_id"]?.string }
                    return Self.toolUse("graph_create_schema", ["type": "Organization", "attributes": ["name": "string"], "role": "entity"])
                },
                { _ in
                    let kate = Script.refs.withLock { $0["kate"] ?? "" }
                    return Self.toolUse("graph_assert", ["facts": [[
                        "source_ref_id": kate, "edge_type": "WORKS_AT", "target_type": "Organization", "target_data": ["name": "Monzo"],
                        "text": "Kate works at Monzo.", "said_by": kate, "source": "message-kate-1", "create_schema_if_missing": true,
                    ]]])
                },
            ])
            #expect(kate[0]["match"] == .null || kate[0]["match"] == nil, "no Kate yet: \(kate[0])")
            let monzo = try #require(kate[3]["facts"]?.array?.first?["edge_ref_id"]?.string, "\(kate[3])")
            let kateRef = try #require(Script.refs.withLock { $0["kate"] })

            // "Used to", with no date, and a dated move: Bristol ends when Manchester begins.
            let moved = try await turn("I used to live in London, and I moved to Manchester in March.", [
                { _ in Self.toolUse("graph_resolve", ["node_type": "Place", "name": "London"]) },
                { _ in Self.toolUse("graph_assert", ["facts": [
                    ["source_ref_id": tom, "edge_type": "LIVES_IN", "target_type": "Place", "target_data": ["name": "London"],
                     "text": "Tom used to live in London.", "ended": true],
                    ["source_ref_id": tom, "edge_type": "LIVES_IN", "target_type": "Place", "target_data": ["name": "Manchester"],
                     "text": "Tom lives in Manchester.", "valid_at": "2026-03"],
                ]]) },
            ])
            #expect(moved[1]["facts"]?.array?.count == 2, "\(moved[1])")

            // How they like things done: a page under Personal.
            let page = try await turn("When you write to me, keep it short: no bullet lists.", [
                { _ in Self.toolUse("graph_graph_get", ["node_type": "Concept", "name": "Personal", "children": "PARENT_OF"]) },
                { last in Self.toolUse("graph_create_triplet", [
                    "source_ref_id": last["ref_id"]?.string ?? "", "edge_type": "PARENT_OF", "target_type": "Concept",
                    "target_data": ["name": "Writing to Tom", "description": "Short replies, no bullet lists.",
                                    "docs": "Tom likes short replies with no bullet lists."],
                ]) },
            ])
            #expect(page[0]["name"] == "Personal", "the Personal root is seeded: \(page[0])")

            // Recall in a turn of its own, on both workflows that run as the assistant: private memory is theirs to read.
            for workflow in [BundledBridge.workflow, PeelAgent.Orchestrator.automationWorkflow] {
                let recall = try await turn("Where do I live, and where did I live before? Who works at Monzo?", on: workflow, [
                    { _ in Self.toolUse("graph_graph_search", ["q": "where does Tom live", "facts": true, "include_ended": true]) },
                    { _ in Self.toolUse("graph_graph_get", ["owner": true]) },
                    { _ in Self.toolUse("graph_graph_neighbors", ["ref_id": tom, "include_ended": true]) },
                    { _ in Self.toolUse("graph_graph_search", ["q": "Monzo", "facts": true]) },
                ])
                let facts = recall[0]["facts"]?.array ?? []
                let fact = { (text: String) in facts.first { $0["text"]?.string == text } }
                #expect(fact("Tom lives in Manchester.")?["valid_at"]?.string?.hasPrefix("2026-03") == true, "\(workflow): \(recall[0])")
                #expect(fact("Tom lives in Bristol.")?["invalid_at"]?.string?.hasPrefix("2026-03") == true, "\(workflow): \(recall[0])")
                #expect(fact("Tom used to live in London.")?["expired_at"] != nil, "\(workflow): \(recall[0])")
                #expect(facts.allSatisfy { $0["namespace"] == "private" }, "\(workflow): \(recall[0])")
                #expect(recall[1]["ref_id"]?.string == tom)
                #expect(recall[3].jsonString.contains("Kate works at Monzo."), "\(workflow): \(recall[3])")
            }

            // Two of Kate: merged, and the other name now finds her.
            let katie = try await turn("Katie Moss is coming round tonight.", [
                { _ in Self.toolUse("graph_resolve", ["node_type": "Person", "name": "Katie Moss"]) },
                { _ in Self.toolUse("graph_create_node", ["node_type": "Person", "node_data": ["name": "Katie Moss"]]) },
            ])
            let duplicate = try #require(katie[1]["ref_id"]?.string, "\(katie[1])")
            let merged = try await turn("Katie Moss is Kate: merge them.", [
                { _ in Self.toolUse("graph_graph_get", ["ref_id": kateRef]) },
                { _ in Self.toolUse("graph_graph_get", ["ref_id": duplicate]) },
                { _ in Self.toolUse("graph_merge", ["keep": kateRef, "duplicate": duplicate]) },
                { _ in Self.toolUse("graph_resolve", ["node_type": "Person", "name": "Katie Moss"]) },
            ])
            #expect(merged[2]["merge"]?.string != nil, "\(merged[2])")
            #expect(merged[3]["match"]?["ref_id"]?.string == kateRef, "\(merged[3])")

            // Forgotten: the fact is gone from search.
            let forgot = try await turn("Forget that Kate works at Monzo.", [
                { _ in Self.toolUse("graph_graph_search", ["q": "Kate Monzo", "facts": true]) },
                { _ in Self.toolUse("graph_delete_edge", ["edge_ref_id": monzo]) },
                { _ in Self.toolUse("graph_graph_search", ["q": "Kate Monzo", "facts": true, "include_ended": true]) },
            ])
            #expect(forgot[0].jsonString.contains("Kate works at Monzo."), "\(forgot[0])")
            #expect(!forgot[2].jsonString.contains("Kate works at Monzo."), "\(forgot[2])")
        }

        /// The stand-in model's calls for the turn under way: each request's
        /// tool results so far say which call is next; then a final answer.
        final class Script: @unchecked Sendable {
            static let refs = OSAllocatedUnfairLock(initialState: [String: String]())
            private let lock = NSLock()
            private var calls: [@Sendable (AgentKit.JSONValue) -> String] = []
            private var answered: [AgentKit.JSONValue] = []

            var results: [AgentKit.JSONValue] { lock.withLock { answered } }

            func start(_ calls: [@Sendable (AgentKit.JSONValue) -> String]) {
                lock.withLock {
                    self.calls = calls
                    self.answered = []
                }
            }

            func next(_ body: String) -> String {
                let request = (try? AgentKit.JSONValue(parsing: body)) ?? .null
                let results = (request["messages"]?.array ?? []).flatMap { $0["content"]?.array ?? [] }
                    .filter { $0["type"] == "tool_result" }.map(Self.output)
                let (call, last): ((@Sendable (AgentKit.JSONValue) -> String)?, AgentKit.JSONValue) = lock.withLock {
                    if results.count > answered.count, let newest = results.last { answered.append(newest) }
                    return (results.count < calls.count ? calls[results.count] : nil, results.last ?? .null)
                }
                return call?(last) ?? Orchestrator.toolUse("final_answer", ["text": "Done.", "artifacts": []])
            }

            /// A tool result's content as the step's output: its JSON when it is JSON.
            static func output(_ block: AgentKit.JSONValue) -> AgentKit.JSONValue {
                let text = block["content"]?.string
                    ?? (block["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined()
                return (try? AgentKit.JSONValue(parsing: text)) ?? .string(text)
            }
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
