import AgentKit
import CryptoKit
import Foundation
import PeelCore

/// One of the person's automations, as strut lists it
/// (`docs/phases/12-automations.md`).
public struct Automation: Sendable, Equatable, Identifiable {
    public struct LastRun: Sendable, Equatable {
        public let runId: String
        /// strut's run status: `success`, `error`, `running`, …
        public let status: String
        public let startedAt: Date?
    }

    public let id: String
    public var name: String
    public var enabled: Bool
    /// strut's trigger object (`every`, `at`, `on`, `tz`, …).
    public var trigger: AgentKit.JSONValue
    public var prompt: String
    /// strut's sentence for the schedule: "Every Friday at 5:00 PM (London time)".
    public var summary: String
    public var nextRun: Date?
    public var lastRun: LastRun?
    public var running: Bool

    /// Its last run did not finish.
    public var lastRunFailed: Bool { lastRun?.status == "error" }

    /// Runs once, at one time: a reminder.
    public var isOnce: Bool { trigger["every"]?.string == "once" }
    /// A one-off that ran, or whose time passed while it was on. strut gives
    /// a paused automation no next run either, but a paused one is not done.
    public var isDone: Bool { isOnce && nextRun == nil && (lastRun != nil || enabled) }
    /// A one-off whose time passed with no run: the Mac was asleep, or strut
    /// or Peel was not running then. strut never runs it late.
    public var isMissed: Bool { isDone && lastRun == nil }
    /// Enabled and due, but strut's clock let the time pass: its scheduler is off.
    public func isOverdue(now: Date = .now) -> Bool {
        enabled && !running && (nextRun.map { $0 < now.addingTimeInterval(-90) } ?? false)
    }

    init?(_ json: AgentKit.JSONValue) {
        guard let id = json["id"]?.string, let name = json["name"]?.string else { return nil }
        self.id = id
        self.name = name
        enabled = json["enabled"] != .bool(false)
        trigger = json["trigger"] ?? .object([:])
        prompt = AutomationsClient.unescaped(json["input"]?["prompt"]?.string ?? "")
        summary = json["summary"]?.string ?? ""
        nextRun = json["nextRunAt"]?.string.flatMap(Self.date)
        lastRun = json["lastRun"].flatMap { last in
            last["runId"]?.string.map {
                LastRun(runId: $0, status: last["status"]?.string ?? "", startedAt: last["startedAt"]?.string.flatMap(Self.date))
            }
        }
        running = json["running"] == .bool(true)
    }

    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}

/// One run of an automation, as strut recorded it.
public struct AutomationRunRecord: Sendable, Equatable, Identifiable {
    public let id: String
    /// strut's status: `success`, `error`, `running`, …
    public let status: String
    public let startedAt: Date?
    /// What Peel answered, for a run that reached Peel.
    public let reply: AutomationReply?
    /// Why it failed, in strut's words.
    public let error: String?

    init?(_ json: AgentKit.JSONValue) {
        guard let id = json["runId"]?.string else { return nil }
        self.id = id
        status = json["status"]?.string ?? "running"
        startedAt = json["startedAt"]?.string.flatMap(Automation.date)
        reply = json["output"]?["body"].flatMap { try? $0.decoded(as: AutomationReply.self) }
        error = json["error"]?["message"]?.string
    }
}

/// strut's own words for a schedule and its next runs, written nowhere.
public struct SchedulePreview: Sendable, Equatable {
    public let summary: String
    public let next: [Date]
}

/// strut's automation endpoints, for the agent's tools and the Automations
/// view alike, over the memory's strut (its address and key, from its ready
/// line: `BundledStrut`). Every Peel automation hangs off one workflow, `peel-automation`,
/// whose one `http` step posts to this Mac's `AutomationServer`.
public struct AutomationsClient: Sendable {
    public let server: MemoryServer

    public static let workflow = "peel-automation"
    static let replyLimit = 2_000_000

    public init(server: MemoryServer) {
        self.server = server
    }

    // MARK: Automations

    /// Every Peel automation, in strut's order.
    public func list() async throws -> [Automation] {
        let reply = try await call("GET", "automations?workflow=\(Self.workflow)", what: "the automations")
        return (reply["automations"]?.array ?? []).compactMap(Automation.init)
    }

    /// strut's sentence for `trigger` and its next five runs; refuses a
    /// trigger strut would refuse, in strut's words.
    public func preview(_ trigger: AgentKit.JSONValue) async throws -> SchedulePreview {
        let reply = try await call("POST", "automations/preview", ["trigger": trigger], what: "the schedule")
        return SchedulePreview(summary: reply["summary"]?.string ?? "",
                               next: (reply["next"]?.array ?? []).compactMap { $0.string.flatMap(Automation.date) })
    }

    public func create(name: String, prompt: String, trigger: AgentKit.JSONValue) async throws -> Automation {
        let body: AgentKit.JSONValue = [
            "name": .string(name), "trigger": trigger, "enabled": true,
            "input": Self.input(name: name, prompt: prompt),
        ]
        return try automation(in: await call("POST", "workflows/\(Self.workflow)/automations", body, what: "the new automation"))
    }

    /// Changes only what is given; the prompt and name travel together in
    /// the run's input, so changing either sends both.
    public func update(
        _ current: Automation, name: String? = nil, prompt: String? = nil, trigger: AgentKit.JSONValue? = nil,
        enabled: Bool? = nil
    ) async throws -> Automation {
        var body: [String: AgentKit.JSONValue] = [:]
        if let name { body["name"] = .string(name) }
        if let trigger { body["trigger"] = trigger }
        if let enabled { body["enabled"] = .bool(enabled) }
        if name != nil || prompt != nil {
            body["input"] = Self.input(name: name ?? current.name, prompt: prompt ?? current.prompt)
        }
        guard !body.isEmpty else { return current }
        return try automation(in: await call("PATCH", path(current.id), .object(body), what: "the automation"))
    }

    public func delete(_ id: String) async throws {
        _ = try await call("DELETE", path(id), what: "the automation")
    }

    /// Runs it now, off its schedule; refused while its last run still goes.
    public func runNow(_ id: String) async throws {
        _ = try await call("POST", path(id) + "/fire", what: "the run")
    }

    /// Its most recent runs, newest first (strut keeps every run of the
    /// workflow in one list, unpaged).
    public func runs(of id: String, limit: Int = 20) async throws -> [AutomationRunRecord] {
        let reply = try await call("GET", "workflows/\(Self.workflow)/runs", what: "the runs")
        return (reply.array ?? []).filter { $0["automation"]?["id"]?.string == id }.prefix(limit)
            .compactMap(AutomationRunRecord.init)
    }

    /// What every run is handed: the prompt, the automation's name, and when
    /// the last successful run finished, resolved by strut at each fire.
    static func input(name: String, prompt: String) -> AgentKit.JSONValue {
        ["name": .string(escaped(name)), "prompt": .string(escaped(prompt)), "since": "{{ last.finishedAt }}"]
    }

    /// strut reads `{{ … }}` anywhere in an automation's input as a template:
    /// it refuses one that reads anything but `now`, `today` or `last`, and
    /// fills in one that does. The person's words keep their braces apart with
    /// a zero-width space, which `unescaped` takes out again.
    static func escaped(_ text: String) -> String {
        var out = "", last: Character?
        for character in text {
            if character == last, character == "{" || character == "}" { out.append(gap) }
            out.append(character)
            last = character
        }
        return out
    }

    static func unescaped(_ text: String) -> String {
        let characters = Array(text)
        return String(characters.indices.compactMap { index -> Character? in
            let character = characters[index]
            guard character == gap, index > 0, index + 1 < characters.count,
                  characters[index - 1] == characters[index + 1], "{}".contains(characters[index - 1]) else { return character }
            return nil
        })
    }

    private static let gap: Character = "\u{200B}"

    private func path(_ id: String) -> String {
        "workflows/\(Self.workflow)/automations/\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? id)"
    }

    private func automation(in reply: AgentKit.JSONValue) throws -> Automation {
        guard let automation = reply["automation"].flatMap(Automation.init) else {
            throw PeelError("strut's reply named no automation.")
        }
        return automation
    }

    // MARK: The workflow

    /// Makes sure strut's `peel-automation` workflow posts to `peel` with
    /// `token`: published when missing, or as a new version when its address
    /// or token changed. Each version is named for its content, so the
    /// check is one read.
    public func install(peel: URL, token: String) async throws {
        let yaml = Self.workflowYAML(peel: peel, token: token)
        let version = Self.version(of: yaml)
        let (status, data) = try await request("GET", "workflows/\(Self.workflow)", nil, what: "the workflow")
        var active: String?
        if status == 404 {
            let created = try await call("POST", "workflows", [
                "name": .string(Self.workflow), "yaml": .string(yaml), "category": "peel",
                "description": "Hands a scheduled prompt to Peel on this Mac (POST /automations/run).",
            ], what: "the workflow")
            guard created["workflow"]?.string == Self.workflow else {
                throw PeelError("strut stored the workflow under another name: \(created["workflow"]?.string ?? "none").")
            }
            // It starts at v1: the content is labelled below too, so the next check matches.
        } else {
            active = try Self.read(status, data)["active"]?.string
        }
        guard active != version else { return }
        _ = try await call("POST", "workflows/\(Self.workflow)", ["version": .string(version), "yaml": .string(yaml)],
                           what: "the workflow")
    }

    /// The workflow: one `http` step to Peel, its address and token in params.
    static func workflowYAML(peel: URL, token: String) -> String {
        """
        name: \(workflow)
        input:
          name: { type: string }
          prompt: { type: string }
          since: { type: json, required: false, description: "When the last successful run finished; null on the first" }
        params:
          peel_url: "\(peel.absoluteString)"
          peel_token: "\(token)"
        steps:
          - id: peel
            type: http
            config:
              url: "{{ params.peel_url }}/automations/run"
              method: POST
              timeout: 600000
              headers:
                Authorization: "Bearer {{ params.peel_token }}"
                Content-Type: application/json
              body:
                name: "{{ input.name }}"
                prompt: "{{ input.prompt }}"
                since: "{{ input.since }}"

        """
    }

    /// `p-` and the content's hash: the same content always has the same label.
    static func version(of yaml: String) -> String {
        "p-" + SHA256.hash(data: Data(yaml.utf8)).prefix(6).hex
    }

    // MARK: HTTP

    private func call(_ method: String, _ path: String, _ body: AgentKit.JSONValue? = nil, what: String) async throws -> AgentKit.JSONValue {
        let (status, data) = try await request(method, path, body, what: what)
        return try Self.read(status, data)
    }

    private func request(_ method: String, _ path: String, _ body: AgentKit.JSONValue?, what: String) async throws -> (Int, Data) {
        guard let url = URL(string: path, relativeTo: server.base.appending(path: "/"))?.absoluteURL else {
            throw PeelError("could not address \(what) on strut")
        }
        do {
            return try await Web.requestThisMac(method, url, json: body.map { Data($0.jsonString.utf8) }, bearer: server.key,
                                                limit: Self.replyLimit, what: what)
        } catch {
            throw PeelError(PeelError.problem(error, couldNot: "reach strut at \(server.base.absoluteString)")
                + " Check that strut is running there.")
        }
    }

    /// The reply, or strut's refusal in its own words (`{ error }`), cleaned
    /// to one capped line: it may echo the prompt.
    static func read(_ status: Int, _ data: Data) throws -> AgentKit.JSONValue {
        let value = try? AgentKit.JSONValue(parsing: String(decoding: data, as: UTF8.self))
        guard (200..<300).contains(status) else {
            let words = value?["error"]?.string ?? value?["error"]?["message"]?.string ?? "HTTP \(status)"
            throw PeelError("strut refused: " + ChatData.clean(words, max: ChatData.maxText))
        }
        guard let value else { throw PeelError("strut's reply was unreadable.") }
        return value
    }
}
