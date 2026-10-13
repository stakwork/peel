import Foundation
import Testing
import AgentKit
import PeelCore
@testable import PeelAgent

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

    /// The same address and token always make the same version, so the
    /// install check is one read; a new token makes a new one.
    @Test func theWorkflowsVersionIsItsContent() throws {
        let peel = try #require(URL(string: "http://127.0.0.1:4778"))
        let yaml = AutomationsClient.workflowYAML(peel: peel, token: "t0k")
        #expect(AutomationsClient.version(of: yaml) == AutomationsClient.version(of: yaml))
        #expect(AutomationsClient.version(of: yaml).hasPrefix("p-"))
        #expect(AutomationsClient.version(of: yaml) != AutomationsClient.version(of: AutomationsClient.workflowYAML(peel: peel, token: "t1k")))
        #expect(yaml.contains(#"peel_url: "http://127.0.0.1:4778""#))
        #expect(yaml.contains("since: { type: json, required: false"))
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
