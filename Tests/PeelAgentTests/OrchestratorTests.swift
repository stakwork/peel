import Foundation
import os
import Testing
import AgentKit
@testable import PeelAgent
import PeelCore
@testable import PeelTestSupport

/// Peel's half of strut's orchestrator: the host delta strut seeds it with,
/// the prompt section, and, through a staged strut that has the automation
/// steps, the `sphinx/*` steps asking a stand-in bridge and the automation
/// steps behind its `approve`.
@MainActor
struct OrchestratorTests {
    @Test func theDeltaGrantsTheReadsTheSendAndTheAutomationsButNeverApprove() throws {
        let config = try AgentKit.JSONValue(parsing: String(decoding: try Orchestrator.hostConfig(), as: UTF8.self))
        let tools = config["orchestrator"]?["tools"]?.array?.compactMap(\.string) ?? []
        #expect(tools == ["sphinx/chats", "sphinx/read", "sphinx/threads", "sphinx/unseen", "sphinx/search", "sphinx/diagnostics",
                          "sphinx/send", "automation/list", "automation/preview", "automation/create", "automation/update",
                          "automation/delete", "automation/run-now"])
        // Only the automation steps ask for a card: the model never words one itself.
        #expect(!tools.contains("sphinx/approve"))
        #expect(config["orchestrator"]?["model"] == .null, "the connected model runs it")
        #expect(config["orchestrator"]?["system"]?.string == Orchestrator.section)
        #expect(config["automation"] == ["workflow": "peel-automation-run", "approve": "sphinx/approve", "grants": true])
        // A call to an org's assistant waits on a card; paired, strut's section for the person's orgs follows Peel's.
        #expect(config["orchestrator"]?["approve"] == ["strut/run-workflow"] && config["job"]?["approve"] == ["strut/run-workflow"])
        let paired = try AgentKit.JSONValue(parsing: String(decoding: try Orchestrator.hostConfig(personal: "Its peers are orgs."), as: UTF8.self))
        #expect(paired["orchestrator"]?["system"]?.string == Orchestrator.section + "\n\nIts peers are orgs.")
        // The builder works with no card and no reach limit; no other strut may launch it.
        #expect(config["builder"] == ["peer": false])
        // An automation's run reads, remembers and posts within its grant; it never sends on a card or schedules.
        #expect(!Orchestrator.automationRunTools.contains { $0.hasPrefix("automation/") || $0 == "sphinx/send" })
        #expect(Orchestrator.automationRunTools.contains("sphinx/post") && !tools.contains("sphinx/post"))
    }

    @Test func peelsSectionNamesStrutsToolsAndTheMac() {
        let section = Orchestrator.section
        for words in ["sphinx/unseen with no chat", "on their Mac, by asking it", "waiting for their Mac", "sphinx/send sends",
                      "memory/remember", "memory/get with user true", "from the time the message starts with",
                      "automation/list before changing it", ChatData.begin, AgentMessageLink.instruction] {
            #expect(section.contains(words), "\(words)")
        }
        for swift in ["read_unseen_messages", "current_time", "read_memory", "list_automations", "send_sphinx_message", "this device"] {
            #expect(!section.contains(swift), "\(swift)")
        }
        let unattended = Orchestrator.unattended
        #expect(unattended.contains("sphinx/unseen") && unattended.contains("memory/remember"))
        #expect(!unattended.contains("sphinx/send") && !unattended.contains("automation/") && unattended.contains("sphinx/post"))
        #expect(!Orchestrator.automationRunTools.contains(DeviceStep.diagnostics.type), "an automation never reads Peel's record")
        #expect(section.contains("give it a grant"))
        // The prompts name the steps by hand: each one granted is named.
        for step in DeviceStep.reads.map(\.type) + [DeviceStep.diagnostics.type, DeviceStep.send.type] + Orchestrator.memoryTools + ["automation/list"] {
            #expect(section.contains(step), "\(step)")
        }
        for step in Orchestrator.automationRunTools { #expect(unattended.contains(step), "\(step)") }
    }

    @Test func eachDeviceStepAsksItsKindAndEndsTheTurnWhenTheMacIsLate() {
        for step in DeviceStep.all {
            let source = step.source
            #expect(source.contains(#"kind: "\#(step.kind)""#) && source.contains(#"type: "\#(step.type)""#))
            #expect(source.contains("withStop({ status: \"pending\""))
            // Only the bridge on this Mac, with the token from strut's secret store.
            #expect(source.contains("http://127.0.0.1:${port}/bridge/device/request") && source.contains("PEEL_BRIDGE_TOKEN"))
        }
        #expect(DeviceStep.approve.source.contains("return { approved: true }"))
        // A post names the fire's automation as strut's scheduler stamped it, never the model's or the input's.
        #expect(DeviceStep.post.source.contains("const automation = ctx.automation?.id;") && !DeviceStep.post.input.contains("automation"))
        #expect(!DeviceStep.post.source.contains("ctx.input?.grant") && !Orchestrator.automationRunYAML.contains("grant:"))
        #expect(DeviceStep.post.lifetime <= Int(DeviceActions.automationWindow), "the Mac refuses an automation's send that lives longer")
        // Bound to its fire: no later than its window after `input.now`, which the Mac's own window holds.
        #expect(DeviceStep.post.source.contains("fired + \(DeviceStep.postWindow + 300)"))
        #expect(DeviceStep.postWindow + 300 <= Int(DeviceActions.automationWindow))
        #expect(DeviceStep.all.allSatisfy { $0.wait <= 300 }, "the bridge waits 300 s at most")
    }

    /// The staged strut, run as the app runs it, with Peel's delta: the
    /// orchestrator seeded with Peel's part, the steps asking a stand-in
    /// bridge, an automation made only once it is allowed.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.appending(path: "build/steps/lib/automation/create.js").path)))
    func theStagedStrutSeedsPeelsPartAndAsksTheMac() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-orchestrator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let strut = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "data"),
                                              secretKey: FileItem(file: root.appending(path: "strut-key"))))
        defer { strut.stop(quietly: true) }
        let server = try await strut.start()

        let orchestrator = try await call("GET", "workflows/orchestrator/flow", on: server)
        #expect(orchestrator["params"]?["tools"]?.array?.contains("sphinx/unseen") == true)
        // strut's own job steps stay beside Peel's: the delta adds, never replaces (PR 6b).
        let tools = orchestrator["params"]?["tools"]?.array?.compactMap(\.string) ?? []
        #expect(Set(["job/start", "job/continue", "job/list", "job/get", "job/read"]).isSubset(of: tools), "\(tools)")
        #expect(orchestrator["params"]?["system"]?.string?.contains("You are Peel's agent") == true)
        #expect(orchestrator["params"]?["model"] == nil, "the connected model runs it")
        // strut's builder, which the orchestrator starts with job/start: no card, closed to peers (strut drops `peer`).
        let builder = try await call("GET", "workflows/builder/flow", on: server)
        #expect(builder["params"]?["approve"]?.array?.isEmpty != false && builder["peer"] == nil, "\(builder)")
        // A job reaches a peer only on a card, as the orchestrator does.
        let job = try await call("GET", "workflows/job/flow", on: server)
        #expect(job["params"]?["approve"]?.array?.contains("strut/run-workflow") == true, "\(job)")

        let answer = OSAllocatedUnfairLock(initialState: #"{"id":"x","status":"done","result":{"text":"3 unseen in Hive"}}"#)
        let bridge = try await HTTPStub { _ in answer.withLock { $0 } }
        defer { bridge.stop() }
        let client = AutomationsClient(server: server)
        try await client.installOrchestrator()
        try await client.useBridge(BundledBridge.Server(base: URL(string: "http://127.0.0.1:\(bridge.port)")!, token: "bridge-token"))
        let run = try await call("GET", "workflows/\(Orchestrator.automationWorkflow)/flow", on: server)
        #expect(run["params"]?["tools"]?.array?.contains("sphinx/unseen") == true && run["steps"]?.array?.count == 3, "\(run)")

        let read = try await runStep("sphinx/unseen", [:], on: server)
        #expect(read["status"] == "success" && read["output"] == "3 unseen in Hive", "\(read)")
        let asked = try #require(bridge.requests.last)
        #expect(asked.contains("authorization: Bearer bridge-token") || asked.contains("Authorization: Bearer bridge-token"))
        let body = try AgentKit.JSONValue(parsing: String(asked[asked.range(of: "\r\n\r\n")!.upperBound...]))
        #expect(body["kind"] == "chats.unseen" && body["wait_secs"] == 30 && body["args"] == AgentKit.JSONValue.object([:]))
        #expect(body["id"]?.string?.hasPrefix((body["run"]?.string ?? "-") + "/") == true, "the id is the run and the step's place")

        // Another question is another id: a stored answer never stands for other args.
        _ = try await runStep("sphinx/unseen", ["chat": "Hive"], on: server)
        let other = try AgentKit.JSONValue(parsing: String(bridge.requests.last!.split(separator: "\r\n\r\n").last ?? ""))
        #expect(other["id"] != body["id"] && other["args"] == ["chat": "Hive"])

        answer.withLock { $0 = #"{"id":"x","status":"pending"}"# }
        #expect(try await runStep("sphinx/unseen", [:], on: server)["output"]?["status"] == "pending")

        // Neither the steps nor Peel's workflow are open to the meta surface: a job never reaches the chats through them.
        #expect(DeviceStep.all.allSatisfy { $0.source.contains("sealed: true,") })
        #expect(run["sealed"] == true || Orchestrator.automationRunYAML.contains("\nsealed: true\n"))

        // A new automation is only a card until the Mac allows it.
        let trigger: AgentKit.JSONValue = ["every": "day", "at": ["08:00"], "tz": "Europe/London"]
        let config: AgentKit.JSONValue = ["name": "Morning", "prompt": "What did I miss overnight?", "trigger": trigger]
        answer.withLock { $0 = #"{"id":"x","status":"denied","error":"The user said no."}"# }
        let denied = try await runStep("automation/create", config, on: server)
        #expect(denied["output"]?["changed"] == false && denied["output"]?["status"] == "denied", "\(denied)")
        #expect(try await client.list(workflow: Orchestrator.automationWorkflow).isEmpty)
        let card = try AgentKit.JSONValue(parsing: String(bridge.requests.last!.split(separator: "\r\n\r\n").last ?? ""))
        #expect(card["kind"] == "approve" && card["args"]?["intent"]?["action"] == "Create the automation \u{201C}Morning\u{201D}")
        #expect(card["args"]?["intent"]?["details"]?.array?.first?.string?.hasPrefix("Runs: Every day at 8:00 AM (London time)") == true)

        answer.withLock { $0 = #"{"id":"x","status":"done","result":{"text":"Allowed."}}"# }
        let made = try await runStep("automation/create", config, on: server)
        #expect(made["output"]?["created"]?["name"] == "Morning", "\(made)")
        let listed = try await client.list(workflow: Orchestrator.automationWorkflow)
        #expect(listed.map(\.name) == ["Morning"] && listed.first?.prompt == "What did I miss overnight?")

        // A grant goes on the same card under the id strut mints for the automation, which it
        // is made with; a post from a run that is no automation's fire is refused before the Mac is asked.
        let posting: AgentKit.JSONValue = ["name": "Hive test", "prompt": "Post: testing automations", "trigger": trigger,
                                           "grant": ["chats": ["Hive"]]]
        _ = try await runStep("automation/create", posting, on: server)
        let grantCard = try AgentKit.JSONValue(parsing: String(bridge.requests.last!.split(separator: "\r\n\r\n").last ?? ""))
        let key = try #require(grantCard["args"]?["grant"]?["automation"]?.string)
        #expect(key.hasPrefix("a-") && grantCard["args"]?["grant"]?["chats"] == ["Hive"] && grantCard["args"]?["grant"]?["name"] == "Hive test")
        let hive = try #require(try await client.list(workflow: Orchestrator.automationWorkflow).first { $0.name == "Hive test" })
        #expect(hive.id == key && hive.input["grant"] == nil, "nothing about the grant rides in the run's input")
        let asks = bridge.requests.count
        let post = try await runStep("sphinx/post", ["chat": "Hive", "text": "hi"], on: server)
        #expect(post["output"]?["status"] == "denied" && bridge.requests.count == asks, "\(post)")

        // Left on peel-automation from before strut was the agent (put there as a move puts them):
        // each moves as it was (id, schedule, prompt, paused), a copy left by a move cut short made only once.
        try await client.publish(AutomationsClient.legacyWorkflow, yaml: Self.oldWorkflow, description: "Peel's before strut was the agent.")
        _ = try await client.update(hive, enabled: false)
        #expect(try await AutomationsClient(server: server, yours: AutomationsClient.legacyWorkflow, callback: nil).moveYours().isEmpty)
        let off = try await client.list().filter(\.isYours)
        #expect(off.count == 2 && off.allSatisfy { $0.workflow == AutomationsClient.legacyWorkflow }, "\(off)")
        let moved = try #require(off.first { $0.name == "Hive test" })
        #expect(moved.id == key && !moved.enabled && moved.prompt == hive.prompt && moved.trigger == hive.trigger)
        let morning = try #require(off.first { $0.name == "Morning" })
        _ = try await call("POST", "workflows/\(Orchestrator.automationWorkflow)/automations",
                           ["id": .string(morning.id), "name": "Morning", "trigger": morning.trigger, "input": morning.input], on: server)
        let ends = try #require(URL(string: "http://127.0.0.1:\(bridge.port)/bridge/run-end?token=bridge-token"))
        #expect(try await AutomationsClient(server: server, yours: Orchestrator.automationWorkflow, callback: ends).moveYours().isEmpty)
        let on = try await client.list().filter(\.isYours)
        #expect(on.map(\.name).sorted() == ["Hive test", "Morning"] && on.allSatisfy { $0.workflow == Orchestrator.automationWorkflow })
        #expect(on.first { $0.name == "Hive test" }?.id == key && on.first { $0.name == "Morning" }?.id == morning.id)
        try await client.pointRunEnds(at: ends)

        // The bridge gone, its port and token are too: a step has nowhere to post.
        try await client.forgetBridge()
        try await client.forgetBridge()
        #expect(try await runStep("sphinx/unseen", [:], on: server)["status"] == "error")
    }

    /// A stand-in for the workflow the person's automations ran on before
    /// strut was the agent, whose step handed each run to Peel.
    static let oldWorkflow = """
        name: \(AutomationsClient.legacyWorkflow)
        input:
          name: { type: string }
          prompt: { type: string }
          since: { type: json, required: false }
        steps:
          - id: dir
            type: job/dir

        """

    func runStep(_ type: String, _ config: AgentKit.JSONValue, on server: MemoryServer) async throws -> AgentKit.JSONValue {
        try await call("POST", "steps/\(type)/run", ["config": config], on: server)
    }

    func call(_ method: String, _ path: String, _ body: AgentKit.JSONValue? = nil, on server: MemoryServer) async throws -> AgentKit.JSONValue {
        try await AutomationsClient(server: server).call(method, path, body, what: path)
    }
}
