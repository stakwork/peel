import AgentKit
import Foundation
import PeelCore

/// The agent's automation tools (`docs/phases/12-automations.md`): what it
/// runs on its own, on a schedule or once, over strut's automations
/// (`AutomationsClient`). Reading and previewing never ask; creating,
/// changing, deleting and running one wait on a card that shows strut's
/// own words for the schedule, every time.
public struct AutomationTools: Sendable {
    let client: AutomationsClient
    /// The time zone a trigger without one is in: the person's.
    let timeZone: TimeZone

    public init(client: AutomationsClient, timeZone: TimeZone = .current) {
        self.client = client
        self.timeZone = timeZone
    }

    public var tools: [Tool] { [list, preview, create, update, delete, runNow] }

    public static let systemPrompt = """
        You can set up automations: a task Peel carries out on its own, on a schedule or once, with its result \
        delivered to this chat. A reminder ("remind me tomorrow at 8 to…", "text me the score on Saturday") is an \
        automation that runs once. Write an automation's prompt as a standalone instruction for a future run that \
        has the read and memory tools but no one watching and no send tool. When a request names two times (read \
        on Friday, tell me on Sunday), ask which one it should run at. Find an automation with list_automations \
        before changing it. Each change is shown to the person to approve.
        """

    // MARK: - Schemas

    static let triggerSchema: AgentKit.JSONValue = [
        "type": "object",
        "description": """
            When it runs, in strut's schedule grammar. every: "once" (at: "YYYY-MM-DDTHH:MM", local time), "day" \
            (at: ["HH:MM", …]), "week" (on: ["mon"…"sun"], at: […]), "month" (day: 1–28 or "last" or \
            {"nth": 1–4 or "last", "weekday": "fri"}, at: […]), or "interval" (minutes ≥ 1, optional on: […] and \
            between: ["HH:MM", "HH:MM"], same day, inclusive). tz is an IANA time zone, the person's when left out.
            """,
        "properties": [
            "every": ["type": "string", "enum": ["once", "day", "week", "month", "interval"]],
            "at": ["description": "A local \"YYYY-MM-DDTHH:MM\" for once; a list of \"HH:MM\" otherwise."],
            "on": ["type": "array", "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]]],
            "day": ["description": "For month: 1–28, \"last\", or {\"nth\", \"weekday\"}."],
            "minutes": ["type": "integer", "minimum": 1],
            "between": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 2],
            "tz": ["type": "string"],
        ],
        "required": ["every"],
    ]

    static let idSchema: AgentKit.JSONValue = ["type": "string", "description": "The automation's id, from list_automations."]
    static let idInput: AgentKit.JSONValue = [
        "type": "object", "properties": ["id": idSchema], "required": ["id"], "additionalProperties": false,
    ]

    // MARK: - Tools

    var list: Tool {
        Tool(
            name: "list_automations",
            description: "The person's automations: id, name, schedule, next run, last run, whether paused, and its prompt.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            effect: .read
        ) { _ in
            let automations = try await client.list()
            guard !automations.isEmpty else { return .text("No automations yet.") }
            var data = ChatData("\(automations.count) automations:")
            for automation in automations { data.add(describe(automation)) }
            return .text(data.text)
        }
    }

    var preview: Tool {
        Tool(
            name: "preview_schedule",
            description: "strut's own words for a trigger and its next runs, saving nothing: check a schedule before proposing it.",
            inputSchema: ["type": "object", "properties": ["trigger": Self.triggerSchema], "required": ["trigger"],
                          "additionalProperties": false],
            effect: .read
        ) { input in
            let preview = try await client.preview(trigger(input["trigger"]))
            return .text(describe(preview))
        }
    }

    var create: Tool {
        Tool(
            name: "create_automation",
            description: "Sets up an automation: a prompt run on its own on a schedule, or once for a reminder. Asks the person first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "A short name the person will recognise: \"Friday to-do list\"."],
                    "prompt": ["type": "string", "description": "The standalone instruction each run carries out."],
                    "trigger": Self.triggerSchema,
                ],
                "required": ["name", "prompt", "trigger"],
                "additionalProperties": false,
            ],
            effect: .send
        ) { input in
            let name = try SphinxTools.required("name", in: input), prompt = try SphinxTools.required("prompt", in: input)
            let trigger = try trigger(input["trigger"])
            let preview = try await client.preview(trigger)
            let intent = ToolIntent(action: "Create the automation \u{201C}\(name)\u{201D}", content: prompt,
                                    details: ["Runs: " + describe(preview)])
            return .action(intent) {
                let made = try await client.create(name: name, prompt: prompt, trigger: trigger)
                return .text("Created: " + describe(made))
            }
        }
    }

    var update: Tool {
        Tool(
            name: "update_automation",
            description: "Changes an automation's name, prompt or schedule, or pauses (enabled false) or resumes it. Asks the person first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": Self.idSchema,
                    "name": ["type": "string"],
                    "prompt": ["type": "string"],
                    "trigger": Self.triggerSchema,
                    "enabled": ["type": "boolean", "description": "false pauses it; true resumes it."],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            effect: .send
        ) { input in
            let current = try await find(input)
            let name = SphinxTools.optional("name", in: input), prompt = SphinxTools.optional("prompt", in: input)
            let enabled: Bool? = if case .bool(let value)? = input["enabled"] { value } else { nil }
            let trigger = try input["trigger"].map(trigger)
            var details: [String] = []
            if let name, name != current.name { details.append("Name: \u{201C}\(name)\u{201D}") }
            if let trigger { details.append("Runs: " + describe(try await client.preview(trigger))) }
            if let prompt { details.append("Prompt: " + prompt) }
            let action: String
            switch enabled {
            case false? where current.enabled: action = "Pause \u{201C}\(current.name)\u{201D}"
            case true? where !current.enabled: action = "Resume \u{201C}\(current.name)\u{201D}"
            default:
                guard !details.isEmpty else { return .result(.text("Nothing to change.")) }
                action = "Change \u{201C}\(current.name)\u{201D}"
            }
            return .action(ToolIntent(action: action, details: details)) {
                let changed = try await client.update(current, name: name, prompt: prompt, trigger: trigger, enabled: enabled)
                return .text("Changed: " + describe(changed))
            }
        }
    }

    var delete: Tool {
        Tool(
            name: "delete_automation",
            description: "Deletes an automation for good. Asks the person first.",
            inputSchema: Self.idInput,
            effect: .send
        ) { input in
            let current = try await find(input)
            let intent = ToolIntent(action: "Delete \u{201C}\(current.name)\u{201D}", details: ["Runs: " + current.summary])
            return .action(intent) {
                try await client.delete(current.id)
                return .text("Deleted \u{201C}\(current.name)\u{201D}.")
            }
        }
    }

    var runNow: Tool {
        Tool(
            name: "run_automation_now",
            description: "Runs an automation now, off its schedule; its result arrives in this chat. Asks the person first.",
            inputSchema: Self.idInput,
            effect: .send
        ) { input in
            let current = try await find(input)
            return .action(ToolIntent(action: "Run \u{201C}\(current.name)\u{201D} now", content: current.prompt)) {
                try await client.runNow(current.id)
                return .text("Started \u{201C}\(current.name)\u{201D}; its result arrives in this chat when it finishes.")
            }
        }
    }

    // MARK: - Helpers

    /// The trigger as strut takes it: a schedule, in the person's time zone
    /// unless it names one.
    func trigger(_ value: AgentKit.JSONValue?) throws -> AgentKit.JSONValue {
        guard case .object(var fields)? = value, fields["every"]?.string != nil else {
            throw PeelError("trigger must be an object with \"every\".")
        }
        fields["type"] = "schedule"
        if fields["tz"]?.string == nil { fields["tz"] = .string(timeZone.identifier) }
        return .object(fields)
    }

    private func find(_ input: AgentKit.JSONValue) async throws -> Automation {
        let id = try SphinxTools.required("id", in: input)
        guard let found = try await client.list().first(where: { $0.id == id }) else {
            throw PeelError("No automation has the id \(id); list_automations shows them.")
        }
        return found
    }

    func describe(_ automation: Automation) -> String {
        var parts = ["\(automation.name) (id=\(automation.id))", automation.summary]
        if !automation.enabled { parts.append("paused") }
        if automation.isMissed { parts.append("missed: its time passed without a run") } else if automation.isDone { parts.append("done") }
        if let next = automation.nextRun, automation.enabled { parts.append("next \(format(next))") }
        if let last = automation.lastRun {
            parts.append("last run \(last.status)" + (last.startedAt.map { " \(format($0))" } ?? ""))
        }
        return "- " + parts.joined(separator: " · ") + "\n  Prompt: " + automation.prompt
    }

    func describe(_ preview: SchedulePreview) -> String {
        let next = preview.next.prefix(3).map(format)
        return preview.summary + (next.isEmpty ? " (no runs to come)" : "; next " + next.joined(separator: ", "))
    }

    func format(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
