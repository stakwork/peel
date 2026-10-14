import Foundation
import Testing
import AgentKit
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// strut's automation endpoints as Peel reads them (`AutomationsClient`),
/// and the agent's tools over them (`AutomationTools`). The JSON is strut's,
/// as a local strut answered on 2026-10-13.
struct AutomationsClientTests {
    static let listed = #"""
        {"automations":[
          {"id":"a-172f6883","name":"Unread summary","enabled":false,
           "trigger":{"type":"schedule","every":"interval","minutes":1,"anchor":"2026-10-13T12:11:00.000Z","tz":"Europe/London"},
           "input":{"automation":"Unread summary","name":"Unread summary","prompt":"Summarise my unread messages","since":"{{ last.finishedAt }}"},
           "workflow":"peel-automation","summary":"Every minute (London time)","nextRunAt":"2026-10-13T12:12:00.000Z",
           "lastRun":{"runId":"1791894989881","status":"success","startedAt":"2026-10-13T12:36:29.881Z"},"running":false},
          {"id":"a-4f3a06ef","name":"Reminder: unread check","enabled":true,
           "trigger":{"type":"schedule","every":"once","at":"2026-10-13T13:38","tz":"Europe/London"},
           "input":{"prompt":"Tell me which chats have unread messages"},
           "summary":"Once, on Oct 13, 2026 at 1:38 PM (London time)","nextRunAt":null,"lastRun":null,"running":false}
        ]}
        """#

    private func automations() throws -> [Automation] {
        let value = try AgentKit.JSONValue(parsing: Self.listed)
        return (value["automations"]?.array ?? []).compactMap(Automation.init)
    }

    @Test func strutsListReadsAsAutomations() throws {
        let list = try automations()
        #expect(list.map(\.id) == ["a-172f6883", "a-4f3a06ef"])
        let summary = list[0]
        #expect(!summary.enabled && !summary.isOnce && !summary.isDone)
        #expect(summary.prompt == "Summarise my unread messages")
        #expect(summary.summary == "Every minute (London time)")
        #expect(summary.nextRun == Date(timeIntervalSince1970: 1_791_893_520))
        #expect(summary.lastRun?.status == "success")
        let reminder = list[1]
        #expect(reminder.isOnce && reminder.isDone)
        #expect(reminder.lastRun == nil)
    }

    /// A time passed with no run means strut's clock is off; paused or
    /// running ones say nothing about it.
    @Test func anOverdueAutomationMeansTheClockIsOff() throws {
        var due = try automations()[0]
        let next = try #require(due.nextRun)
        #expect(!due.isOverdue(now: next))
        due.enabled = true
        #expect(!due.isOverdue(now: next.addingTimeInterval(60)))
        #expect(due.isOverdue(now: next.addingTimeInterval(120)))
        due.running = true
        #expect(!due.isOverdue(now: next.addingTimeInterval(120)))
    }

    @Test func aRunReadsBackWhatPeelAnswered() throws {
        let delivered = try AgentKit.JSONValue(parsing: #"""
            {"runId":"1","status":"success","startedAt":"2026-10-13T12:38:01.749Z","finishedAt":"2026-10-13T12:38:03.671Z",
             "automation":{"id":"a-4f3a06ef"},"output":{"status":200,"body":{"status":"delivered","text":"No chats have unread messages."}}}
            """#)
        let run = try #require(AutomationRunRecord(delivered))
        #expect(run.reply == AutomationReply(status: .delivered, text: "No chats have unread messages."))
        #expect(run.error == nil)

        let failed = try AgentKit.JSONValue(parsing: #"{"runId":"2","status":"error","error":{"message":"HTTP POST returned 500"}}"#)
        #expect(AutomationRunRecord(failed)?.error == "HTTP POST returned 500")
        #expect(AutomationRunRecord(failed)?.reply == nil)
    }

    /// A system automation's run ends in strut, with its agent's last words
    /// and their cost; not Peel's reply.
    @Test func aSystemRunReadsBackItsTextAndCost() throws {
        let run = try #require(AutomationRunRecord(try AgentKit.JSONValue(parsing: #"""
            {"runId":"3","status":"success","automation":{"id":"tidy"},"output":{"text":"Kate into Katie Moss: same sister","cost":0.0042}}
            """#)))
        #expect(run.text == "Kate into Katie Moss: same sister")
        #expect(run.cost == 0.0042)
        #expect(run.reply == nil)
        let free = try #require(AutomationRunRecord(try AgentKit.JSONValue(parsing: #"{"runId":"4","status":"success","output":{"text":"Nothing to merge"}}"#)))
        #expect(free.text == "Nothing to merge" && free.cost == nil)
        // strut's template may write the cost as text.
        let templated = #"{"runId":"5","status":"success","output":{"text":"Nothing to merge","cost":"0.0013"}}"#
        #expect(AutomationRunRecord(try AgentKit.JSONValue(parsing: templated))?.cost == 0.0013)
        // Nothing said reads as no text, so the row says "Finished".
        let silent = #"{"runId":"7","status":"success","output":{"text":""}}"#
        #expect(AutomationRunRecord(try AgentKit.JSONValue(parsing: silent))?.text == nil)
    }

    /// A failed model call reads as the provider's reason, not its raw reply.
    @Test func aFailedRunSaysWhyInAFewWords() throws {
        let failed = try AgentKit.JSONValue(parsing: #"""
            {"runId":"6","status":"error","error":{"message":"agent failed after 0 step(s): invalid x-api-key (HTTP 401: {\"type\":\"error\"})"}}
            """#)
        #expect(AutomationRunRecord(failed)?.error == "invalid x-api-key")
        let unconnected = try AgentKit.JSONValue(parsing: #"{"runId":"7","status":"error","error":{"message":"agent: no model connected (STRUT_DEFAULT_MODEL is not set)"}}"#)
        #expect(AutomationRunRecord(unconnected)?.error == "no model connected")
    }

    // MARK: System automations

    /// strut's listing across workflows, with each automation's workflow
    /// and its category; the workflow's description and the PATCH's reply
    /// in the same body, since the stub answers every request alike.
    static let everyWorkflow = #"""
        {"automations":[
          {"id":"a-1","name":"Friday list","enabled":true,"trigger":{"every":"week"},"workflow":"peel-automation","category":"peel",
           "input":{"prompt":"Make my list"},"summary":"Every Friday"},
          {"id":"tidy","name":"Tidy memory","enabled":false,"trigger":{"every":"day","at":["12:30"]},"workflow":"tidy-memory",
           "category":"system","summary":"Every day at 12:30 PM"},
          {"id":"done-before","name":"Turned off","enabled":false,"trigger":{"every":"day"},"workflow":"turned-off","category":"system"},
          {"id":"on-already","name":"On","enabled":true,"trigger":{"every":"day"},"workflow":"other-system","category":"system"}
        ],
         "automation":{"id":"tidy","name":"Tidy memory","enabled":true,"workflow":"tidy-memory","category":"system"},
         "active":"s-1","versions":{"s-1":{"description":"Once a day, merges people and things saved twice."}}}
        """#

    private func strut() async throws -> (HTTPStub, AutomationsClient) {
        let stub = try await HTTPStub { _ in Self.everyWorkflow }
        let base = try #require(URL(string: "http://127.0.0.1:\(stub.port)"))
        let server = try #require(MemoryServer(base: base, key: "k"))
        return (stub, AutomationsClient(server: server))
    }

    /// The request lines strut saw: "PATCH /workflows/…".
    private func lines(_ stub: HTTPStub) -> [String] {
        stub.requests.map { String(($0.components(separatedBy: "\r\n").first ?? "").dropLast(" HTTP/1.1".count)) }
    }

    @Test func everyWorkflowsAutomationsAreListedWithTheirWorkflow() async throws {
        let (stub, client) = try await strut()
        defer { stub.stop() }
        let list = try await client.list()
        #expect(list.map(\.workflow) == ["peel-automation", "tidy-memory", "turned-off", "other-system"])
        #expect(list.map(\.isSystem) == [false, true, true, true])
        #expect(list[1].about == "Once a day, merges people and things saved twice.")
        #expect(list[0].about == nil)
        // One read of each system workflow, none of Peel's.
        #expect(Set(lines(stub)) == ["GET /automations", "GET /workflows/tidy-memory", "GET /workflows/turned-off",
                                     "GET /workflows/other-system"])
        // An automation strut lists without one (an older strut) is Peel's.
        let older = try automations()[1]
        #expect(older.workflow == AutomationsClient.workflow && !older.isSystem)
    }

    @Test func eachAutomationIsAddressedOnItsOwnWorkflow() async throws {
        let (stub, client) = try await strut()
        defer { stub.stop() }
        let tidy = try await client.list()[1]
        let before = stub.requests.count
        try await client.runNow(tidy)
        _ = try await client.update(tidy, enabled: true)
        _ = try await client.runs(of: tidy)
        try await client.delete(tidy)
        #expect(Set(lines(stub).dropFirst(before)) == [
            "POST /workflows/tidy-memory/automations/tidy/fire", "PATCH /workflows/tidy-memory/automations/tidy",
            "GET /workflows/tidy-memory/runs", "DELETE /workflows/tidy-memory/automations/tidy",
        ])
    }

    /// The agent sees only the person's automations, and every tool that
    /// changes or runs one refuses a system automation before strut hears
    /// of it.
    @Test func theAgentCannotTouchASystemAutomation() async throws {
        let (stub, client) = try await strut()
        defer { stub.stop() }
        let tools = AutomationTools(client: client)
        let list = try #require(tools.tools.first { $0.name == "list_automations" })
        guard case .result = try await list.plan([:]) else {
            Issue.record("expected a result")
            return
        }
        #expect(lines(stub).first == "GET /automations?workflow=peel-automation")
        for name in ["update_automation", "delete_automation", "run_automation_now"] {
            let tool = try #require(tools.tools.first { $0.name == name })
            await #expect(throws: PeelError.self, "\(name)") { _ = try await tool.plan(["id": "tidy", "enabled": false]) }
        }
        #expect(lines(stub).allSatisfy { $0.hasPrefix("GET ") })
        // The person's own still gets as far as its card.
        let runNow = try #require(tools.tools.first { $0.name == "run_automation_now" })
        guard case .action = try await runNow.plan(["id": "a-1"]) else {
            Issue.record("expected a card")
            return
        }
    }

    /// Each system automation is turned on once, by workflow: one strut
    /// lists off and Peel never turned on is turned on, one already on
    /// counts as done, and one done before stays as the person left it.
    @Test func systemAutomationsAreTurnedOnOnce() async throws {
        let (stub, client) = try await strut()
        defer { stub.stop() }
        let list = try await client.list()
        let before = stub.requests.count
        let (turned, now) = await client.turnOnSystem(in: list, done: ["turned-off"])
        #expect(now == ["tidy-memory", "other-system"])
        #expect(turned.map(\.enabled) == [true, true, false, true])
        let sent = Array(stub.requests.dropFirst(before))
        #expect(sent.count == 1)
        #expect(sent.first?.hasPrefix("PATCH /workflows/tidy-memory/automations/tidy ") == true)
        #expect(sent.first?.hasSuffix(#"{"enabled":true}"#) == true)
        // Once all are done, nothing more is sent.
        #expect(await client.turnOnSystem(in: turned, done: now.union(["turned-off"])).done.isEmpty)
        #expect(stub.requests.count == before + 1)
        // Deleted and made again by strut under a new id ("tidy" here), it
        // is the same workflow's: left off.
        #expect(await client.turnOnSystem(in: list, done: ["tidy-memory", "turned-off"]).done == ["other-system"])
        #expect(stub.requests.count == before + 1)
    }

    /// The connected model and its key go to strut's secret store, the other
    /// providers' keys come out; disconnected, the model and every key do.
    /// Read as the store ends up, from one that held every key before.
    @Test(arguments: [
        (AgentProvider.anthropic, "claude-sonnet-5-5", "anthropic/claude-sonnet-5-5", "ANTHROPIC_API_KEY"),
        (.openAI, "gpt-5", "openai/gpt-5", "OPENAI_API_KEY"),
        (.openRouter, "anthropic/claude-sonnet-5.5", "openrouter/anthropic/claude-sonnet-5.5", "OPENROUTER_API_KEY"),
    ])
    func theConnectedModelIsHandedToStrut(provider: AgentProvider, model: String, named: String, secret: String) async throws {
        let (stub, client) = try await strut()
        defer { stub.stop() }
        let held = ["STRUT_DEFAULT_MODEL": "old/model", "ANTHROPIC_API_KEY": "old", "OPENAI_API_KEY": "old",
                    "OPENROUTER_API_KEY": "old", "PEEL_AUTOMATION_TOKEN": "token"]
        try await client.setModel(AgentCredential(provider: provider, model: model, apiKey: "sk-test-1234"))
        #expect(secrets(stub, from: held) == ["STRUT_DEFAULT_MODEL": named, secret: "sk-test-1234", "PEEL_AUTOMATION_TOKEN": "token"])
        try await client.setModel(nil)
        #expect(secrets(stub, from: held) == ["PEEL_AUTOMATION_TOKEN": "token"])
    }

    /// strut's secret store after the PUTs and DELETEs it saw, from `held`.
    private func secrets(_ stub: HTTPStub, from held: [String: String]) -> [String: String] {
        var store = held
        for request in stub.requests {
            let parts = (request.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
            guard parts.count > 1, parts[1].hasPrefix("/secrets/") else { continue }
            let name = String(parts[1].dropFirst("/secrets/".count))
            switch parts[0] {
            case "PUT":
                let body = request.components(separatedBy: "\r\n\r\n").last ?? ""
                store[name] = (try? AgentKit.JSONValue(parsing: body))?["value"]?.string
            case "DELETE": store[name] = nil
            default: break
            }
        }
        return store
    }

    /// strut's refusals reach the agent in strut's words, on one line.
    @Test func strutsRefusalsAreItsOwnWords() throws {
        #expect(throws: PeelError.self) { try AutomationsClient.read(400, Data(#"{"error":"trigger.at: expected HH:MM"}"#.utf8)) }
        do {
            _ = try AutomationsClient.read(400, Data(#"{"error":"trigger.at:\nexpected HH:MM"}"#.utf8))
        } catch {
            #expect("\(error)".contains("strut refused: trigger.at: expected HH:MM"))
        }
        #expect(throws: PeelError.self) { try AutomationsClient.read(200, Data("not json".utf8)) }
        #expect(try AutomationsClient.read(201, Data(#"{"ok":true}"#.utf8))["ok"] == .bool(true))
    }

    /// Nothing about where Peel is or its token is in the workflow strut
    /// keeps in its workspace: Peel's step reads both from strut's secret
    /// store in code. So the workflow is the same on every launch.
    @Test func theWorkflowRunsPeelsStepAndSaysNothingOfPeel() {
        let yaml = AutomationsClient.workflowYAML
        #expect(yaml.contains("type: peel/run-automation"))
        #expect(yaml.contains("since: { type: json, required: false"))
        for word in ["PEEL_AUTOMATION", "uthorization", "Bearer", "token", "http", "port", "params", "127.0.0.1"] {
            #expect(!yaml.contains(word), "\(word)")
        }
    }

    @Test func eachRunIsHandedItsPromptAndTheLastRun() {
        let input = AutomationsClient.input(name: "Friday", prompt: "Make my to-do list")
        #expect(input["prompt"]?.string == "Make my to-do list")
        #expect(input["since"]?.string == "{{ last.finishedAt }}")
    }

    /// strut would refuse or fill in `{{ … }}` in the person's words: kept
    /// apart on the way in, joined again on the way out.
    @Test func bracesInAPromptSurviveStrut() {
        for text in ["fix the {{ name }} bug", "{{{x}}}", "a { b } c", "plain", "}}{{", ""] {
            let escaped = AutomationsClient.escaped(text)
            #expect(!escaped.contains("{{") && !escaped.contains("}}"), "\(text)")
            #expect(AutomationsClient.unescaped(escaped) == text, "\(text)")
        }
        #expect(AutomationsClient.input(name: "n", prompt: "say {{ now }}")["prompt"]?.string?.contains("{{") == false)
    }

    /// strut gives a paused automation no next run: a paused reminder that
    /// has not run is still to come, not done.
    @Test func aPausedReminderIsNotDone() throws {
        var reminder = try automations()[1]
        reminder.enabled = false
        #expect(!reminder.isDone)
        reminder.lastRun = Automation.LastRun(runId: "1", status: "success", startedAt: nil)
        #expect(reminder.isDone)
        #expect(!reminder.isMissed)
    }

    /// A one-off whose time passed with no run (the Mac asleep) is missed,
    /// not done as if it ran; one that ran is not.
    @Test func aReminderWhoseTimePassedUnrunIsMissed() throws {
        let reminder = try automations()[1]
        #expect(reminder.isDone && reminder.isMissed)
        #expect(tools.describe(reminder).contains("missed"))
        var paused = reminder
        paused.enabled = false
        #expect(!paused.isMissed)
    }

    // MARK: The tools

    private var tools: AutomationTools {
        let server = MemoryServer(base: URL(string: "http://127.0.0.1:1")!, key: "k")!
        return AutomationTools(client: AutomationsClient(server: server), timeZone: TimeZone(identifier: "Europe/London")!)
    }

    @Test func aTriggerIsAScheduleInThePersonsTimeZone() throws {
        let trigger = try tools.trigger(["every": "once", "at": "2026-10-14T08:00"])
        #expect(trigger["type"]?.string == "schedule")
        #expect(trigger["tz"]?.string == "Europe/London")
        #expect(try tools.trigger(["every": "day", "at": ["09:00"], "tz": "America/New_York"])["tz"]?.string == "America/New_York")
        #expect(throws: PeelError.self) { try tools.trigger(["at": "09:00"]) }
        #expect(throws: PeelError.self) { try tools.trigger(nil) }
    }

    /// Reading never asks; anything that makes, changes or runs one does,
    /// every time (no target, so no "Always allow").
    @Test func onlyReadingRunsWithoutACard() {
        let effects = Dictionary(uniqueKeysWithValues: tools.tools.map { ($0.name, $0.effect) })
        #expect(effects == [
            "list_automations": .read, "preview_schedule": .read, "create_automation": .send,
            "update_automation": .send, "delete_automation": .send, "run_automation_now": .send,
        ])
    }

    @Test func anAutomationAsTheAgentReadsIt() throws {
        let line = tools.describe(try automations()[0])
        #expect(line.contains("Unread summary (id=a-172f6883)"))
        #expect(line.contains("paused"))
        #expect(line.contains("Prompt: Summarise my unread messages"))
    }
}
