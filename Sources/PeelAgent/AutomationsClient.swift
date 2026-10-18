import AgentKit
import CryptoKit
import Foundation
import PeelCore

/// One automation, as strut lists it (`docs/phases/12-automations.md`):
/// the person's own, on `peel-automation` (or `peel-automation-run` once
/// the agent's bridge has run), or a system automation strut ships on a workflow
/// of its own (`docs/system-automations.md`).
public struct Automation: Sendable, Equatable, Identifiable {
    public struct LastRun: Sendable, Equatable {
        public let runId: String
        /// strut's run status: `success`, `error`, `running`, …
        public let status: String
        public let startedAt: Date?
    }

    public let id: String
    /// The workflow it fires: `peel-automation`, or a system one's own.
    public let workflow: String
    /// Its workflow's category: `system` for the ones strut ships.
    public let category: String?
    /// Its workflow's description, read for system automations only.
    public var about: String?
    public var name: String
    public var enabled: Bool
    /// strut's trigger object (`every`, `at`, `on`, `tz`, …).
    public var trigger: AgentKit.JSONValue
    public var prompt: String
    /// What each run is handed, as strut keeps it (templates and all).
    public var input: AgentKit.JSONValue
    /// strut's sentence for the schedule: "Every Friday at 5:00 PM (London time)".
    public var summary: String
    public var nextRun: Date?
    public var lastRun: LastRun?
    public var running: Bool

    /// Shipped with strut and run by strut alone: the person may turn it
    /// on or off and run it, and the agent may not touch it.
    public var isSystem: Bool { category == "system" }
    /// The person's own, made through the agent: on `peel-automation`, or
    /// on `peel-automation-run` once the agent's bridge has run.
    public var isYours: Bool { AutomationsClient.yourWorkflows.contains(workflow) }

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
        workflow = json["workflow"]?.string ?? AutomationsClient.workflow
        category = json["category"]?.string
        enabled = json["enabled"] != .bool(false)
        trigger = json["trigger"] ?? .object([:])
        input = json["input"] ?? .object([:])
        prompt = AutomationsClient.unescaped(input["prompt"]?.string ?? "")
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
    /// What a system automation's agent said at the end, run in strut.
    public let text: String?
    /// What that run's model calls cost, in US dollars, as strut counted it.
    public let cost: Double?
    /// Why it failed, in strut's words, without the provider's raw reply.
    public let error: String?
    /// Why it did not finish, as the Automations view says it: a sentence
    /// of Peel's or strut's own ("Didn't run: …") as it is, any other
    /// reason after "Didn't finish: ". Anything shaped like a key is masked
    /// first, whoever wrote it.
    public let failure: String

    /// `workflow`: the one its runs were read from, unless the record names its own.
    init?(_ json: AgentKit.JSONValue, workflow: String = AutomationsClient.workflow) {
        guard let id = json["runId"]?.string else { return nil }
        self.id = id
        status = json["status"]?.string ?? "running"
        startedAt = json["startedAt"]?.string.flatMap(Automation.date)
        reply = json["output"]?["body"].flatMap { try? $0.decoded(as: AutomationReply.self) }
        // An empty one says nothing: "Finished".
        text = json["output"]?["text"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // A number, or one a template wrote as text.
        cost = switch json["output"]?["cost"] {
        case .number(let dollars)?: dollars
        case .string(let text)?: Double(text)
        default: nil
        }
        let peels = (json["workflow"]?.string ?? workflow) == AutomationsClient.workflow
        error = json["error"]?["message"]?.string.map { Self.shortened($0, peels: peels) }
        let why = ModelError.maskingKeys(reply?.error ?? error ?? "no reason given")
        failure = AutomationFailure.isSentence(why) ? why : "Didn't finish: " + why
    }



    /// strut's words for a failed run, as a person reads them. Peel's own
    /// reply without the step's "Peel answered 500: "; on Peel's workflow
    /// (`peels`), strut's "fetch failed" from that step, Peel not
    /// listening, as Peel not reached; the agent step's provider refusing
    /// the key (HTTP 401) as that, never its raw reply (OpenAI's quotes part of the key);
    /// "agent: no model connected (STRUT_DEFAULT_MODEL is not set)" as no
    /// model connected; and any other model call's failure, "agent failed
    /// after 0 step(s): overloaded (HTTP 529: {…})", as "overloaded".
    static func shortened(_ message: String, peels: Bool) -> String {
        if let peel = message.firstMatch(of: #/Peel answered \d{3}: /#) {
            let words = message[peel.range.upperBound...]
            return words.isEmpty ? message : String(words)
        }
        if peels, message.hasSuffix("fetch failed") { return AutomationFailure.peelUnreachable }
        // The agent step's model call only, whose status strut puts last: other
        // steps (git/push) print an HTTP 401 of their own.
        if message.contains(#/^agent failed after \d+ step\(s\): .*\(HTTP 401\b/#.dotMatchesNewlines()) {
            return AutomationFailure.keyRejected(by: provider(in: message))
        }
        if message.contains("(STRUT_DEFAULT_MODEL is not set)") { return AutomationFailure.noModel }
        var text = message
        for tail in [" (HTTP ", " (STRUT_"] {
            if let cut = text.range(of: tail) { text = String(text[..<cut.lowerBound]) }
        }
        if let prefix = text.firstMatch(of: #/^agent(?: failed after \d+ step\(s\))?: /#) { text.removeSubrange(prefix.range) }
        return text.isEmpty ? message : text
    }

    /// The provider a refusal names: Anthropic's header, OpenAI's or
    /// OpenRouter's address; nil when it names none.
    static func provider(in message: String) -> AgentProvider? {
        let words = message.lowercased()
        if words.contains("x-api-key") { return .anthropic }
        if words.contains("openrouter") { return .openRouter }
        if words.contains("openai.com") { return .openAI }
        return nil
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
/// whose one `http` step posts to this Mac's `AutomationServer`; a system
/// automation hangs off its own workflow, which strut runs alone.
public struct AutomationsClient: Sendable {
    public let server: MemoryServer
    /// Where the person's new automations go and the agent's tools look:
    /// `workflow`, or `Orchestrator.automationWorkflow` while the agent's bridge runs.
    public let yours: String
    /// Where a new automation's run ends go: the agent's bridge, which sends
    /// each one's report to the agent's DM. None on `workflow`, whose step
    /// hands the run to this Mac.
    public let callback: URL?

    public static let workflow = "peel-automation"
    /// The workflows the person's own automations run on.
    public static let yourWorkflows: Set<String> = [workflow, Orchestrator.automationWorkflow]
    /// The secrets in strut's store that `step` reads: Peel's bearer token
    /// and its port on this Mac. Two, not one JSON value, so strut's
    /// cassettes scrub each (they scrub a secret's whole value).
    static let tokenSecret = "PEEL_AUTOMATION_TOKEN"
    static let portSecret = "PEEL_AUTOMATION_PORT"
    /// The custom step the workflow runs: Peel's adapter, published with it.
    static let step = "peel/run-automation"
    static let replyLimit = 2_000_000

    public init(server: MemoryServer, yours: String = Self.workflow, callback: URL? = nil) {
        self.server = server
        self.yours = yours
        self.callback = callback
    }

    // MARK: Automations

    /// Every workflow's automations in strut's order, or only `workflow`'s.
    public func list(workflow: String? = nil) async throws -> [Automation] {
        var descriptions: [String: String] = [:]
        return try await list(workflow: workflow, descriptions: &descriptions)
    }

    /// The same, a system one with its workflow's description: from
    /// `descriptions` (by workflow), else read once and kept there; "" when
    /// strut cannot say it, so it is not asked again.
    public func list(workflow: String? = nil, descriptions: inout [String: String]) async throws -> [Automation] {
        let path = workflow.map { "automations?workflow=\(Self.escaped(path: $0))" } ?? "automations"
        var list = try await call("GET", path, what: "the automations")["automations"]?.array?.compactMap(Automation.init) ?? []
        for name in Set(list.filter(\.isSystem).map(\.workflow)) where descriptions[name] == nil {
            descriptions[name] = (try? await description(of: name)) ?? ""
        }
        for index in list.indices where list[index].isSystem {
            list[index].about = descriptions[list[index].workflow].flatMap { $0.isEmpty ? nil : $0 }
        }
        return list
    }

    /// A workflow's description: strut keeps one per version, so the
    /// active version's.
    func description(of workflow: String) async throws -> String? {
        let meta = try await call("GET", "workflows/\(Self.escaped(path: workflow))", what: "the workflow")
        return meta["active"]?.string.flatMap { meta["versions"]?[$0]?["description"]?.string }
    }

    /// strut's sentence for `trigger` and its next five runs; refuses a
    /// trigger strut would refuse, in strut's words.
    public func preview(_ trigger: AgentKit.JSONValue) async throws -> SchedulePreview {
        let reply = try await call("POST", "automations/preview", ["trigger": trigger], what: "the schedule")
        return SchedulePreview(summary: reply["summary"]?.string ?? "",
                               next: (reply["next"]?.array ?? []).compactMap { $0.string.flatMap(Automation.date) })
    }

    public func create(name: String, prompt: String, trigger: AgentKit.JSONValue) async throws -> Automation {
        try automation(in: await make(name: name, trigger: trigger, enabled: true, input: Self.input(name: name, prompt: prompt),
                                      what: "the new automation"))
    }

    /// Makes one on `yours`, under `id` when given, its run ends to
    /// `callback` when there is one.
    func make(
        id: String? = nil, name: String, trigger: AgentKit.JSONValue, enabled: Bool, input: AgentKit.JSONValue, what: String
    ) async throws -> AgentKit.JSONValue {
        var body: [String: AgentKit.JSONValue] = ["name": .string(name), "trigger": trigger, "enabled": .bool(enabled), "input": input]
        if let id { body["id"] = .string(id) }
        if let callback { body["callback"] = Self.callback(callback) }
        return try await call("POST", "workflows/\(Self.escaped(path: yours))/automations", .object(body), what: what)
    }

    /// strut's `callback` for an automation: where its run ends go.
    static func callback(_ url: URL) -> AgentKit.JSONValue { ["url": .string(url.absoluteString)] }

    /// Changes only what is given; the prompt and name travel together in
    /// the run's input, so changing either sends both, with the rest of the
    /// input as it was (a send grant's key, `now`).
    public func update(
        _ current: Automation, name: String? = nil, prompt: String? = nil, trigger: AgentKit.JSONValue? = nil,
        enabled: Bool? = nil
    ) async throws -> Automation {
        var body: [String: AgentKit.JSONValue] = [:]
        if let name { body["name"] = .string(name) }
        if let trigger { body["trigger"] = trigger }
        if let enabled { body["enabled"] = .bool(enabled) }
        if name != nil || prompt != nil {
            var input = current.input.object ?? [:]
            input.merge(Self.input(name: name ?? current.name, prompt: prompt ?? current.prompt).object ?? [:]) { _, new in new }
            body["input"] = .object(input)
        }
        guard !body.isEmpty else { return current }
        return try automation(in: await call("PATCH", path(current), .object(body), what: "the automation"))
    }

    public func delete(_ automation: Automation) async throws {
        _ = try await call("DELETE", path(automation), what: "the automation")
    }

    /// Runs it now, off its schedule; refused while its last run still goes.
    public func runNow(_ automation: Automation) async throws {
        _ = try await call("POST", path(automation) + "/fire", what: "the run")
    }

    /// Its most recent runs, newest first (strut keeps every run of the
    /// workflow in one list, unpaged).
    public func runs(of automation: Automation, limit: Int = 20) async throws -> [AutomationRunRecord] {
        let reply = try await call("GET", "workflows/\(Self.escaped(path: automation.workflow))/runs", what: "the runs")
        return (reply.array ?? []).filter { $0["automation"]?["id"]?.string == automation.id }.prefix(limit)
            .compactMap { AutomationRunRecord($0, workflow: automation.workflow) }
    }

    /// Turns on, once, each system automation Peel has not turned on before
    /// (`done`, by workflow: strut makes a deleted one again under a new
    /// id): strut ships them off, since it cannot know a model is
    /// connected. One already on counts as done, so either way one the
    /// person turns off later stays off. Returns `list` as it is now and the
    /// workflows done now; one strut refused is tried again next time.
    public func turnOnSystem(in list: [Automation], done: Set<String>) async -> (list: [Automation], done: Set<String>) {
        var list = list, now: Set<String> = []
        for index in list.indices where list[index].isSystem && !done.contains(list[index].workflow) {
            if !list[index].enabled {
                guard (try? await update(list[index], enabled: true)) != nil else { continue }
                list[index].enabled = true
            }
            now.insert(list[index].workflow)
        }
        return (list, now)
    }

    /// What every run is handed: the prompt, the automation's name, when
    /// the last successful run finished and when this one fired, resolved by
    /// strut at each fire (`peel-automation` reads no `now`; strut drops it).
    static func input(name: String, prompt: String) -> AgentKit.JSONValue {
        ["name": .string(escaped(name)), "prompt": .string(escaped(prompt)), "since": "{{ last.finishedAt }}", "now": "{{ now }}"]
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

    func path(_ automation: Automation) -> String {
        "workflows/\(Self.escaped(path: automation.workflow))/automations/\(Self.escaped(path: automation.id))"
    }

    static func escaped(path part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? part
    }

    private func automation(in reply: AgentKit.JSONValue) throws -> Automation {
        guard let automation = reply["automation"].flatMap(Automation.init) else {
            throw PeelError("strut's reply named no automation.")
        }
        return automation
    }

    // MARK: The workflow

    /// Hands strut `token` and `port` for its encrypted secret store
    /// (`tokenSecret`, `portSecret`), publishes `step` (strut keeps one
    /// version per content, so the same source is a no-op), then makes sure
    /// its `peel-automation` workflow is the current one (`publish`). The connected model
    /// is not part of it (`setModel`): it is handed over whether or not Peel listens.
    public func install(port: Int, token: String) async throws {
        _ = try await call("PUT", "secrets/\(Self.tokenSecret)", ["value": .string(token)], what: "the automation token")
        _ = try await call("PUT", "secrets/\(Self.portSecret)", ["value": .string(String(port))], what: "the automation port")
        _ = try await call("POST", "steps", ["name": .string(Self.step), "code": .string(Self.stepSource),
                                             "description": "Hands a scheduled prompt to Peel on this Mac."],
                           what: "the automation step")
        try await publish(Self.workflow, yaml: Self.workflowYAML,
                          description: "Hands a scheduled prompt to Peel on this Mac (POST /automations/run).")
    }

    /// Makes sure Peel's workflow `name` is `yaml`: published when missing,
    /// or as a new version when Peel's changed. Each version is named for
    /// its content, so the check is one read.
    func publish(_ name: String, yaml: String, description: String) async throws {
        let version = Self.version(of: yaml)
        let (status, data) = try await request("GET", "workflows/\(Self.escaped(path: name))", nil, what: "the workflow")
        var active: String?
        if status == 404 {
            let created = try await call("POST", "workflows", [
                "name": .string(name), "yaml": .string(yaml), "category": "peel", "description": .string(description),
            ], what: "the workflow")
            guard created["workflow"]?.string == name else {
                throw PeelError("strut stored the workflow under another name: \(created["workflow"]?.string ?? "none").")
            }
            // It starts at v1: the content is labelled below too, so the next check matches.
        } else {
            active = try Self.read(status, data)["active"]?.string
        }
        guard active != version else { return }
        _ = try await call("POST", "workflows/\(Self.escaped(path: name))", ["version": .string(version), "yaml": .string(yaml)],
                           what: "the workflow")
    }

    /// The secret a system automation's `agent` step takes its model from
    /// when its workflow names none: `<provider>/<model>`, as strut names one.
    static let modelSecret = "STRUT_DEFAULT_MODEL"

    /// Where strut reads `provider`'s key from.
    static func keySecret(_ provider: AgentProvider) -> String {
        switch provider {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        }
    }

    /// Every provider's (`keySecret`).
    static let keySecrets = AgentProvider.allCases.map(keySecret)

    /// Puts the connected model and its key in strut's secret store, for
    /// the system automations, and takes out any other provider's key;
    /// with no model connected, takes out the model and every key. Called
    /// whenever strut starts or the connected model changes, apart from
    /// `install` (`AppModel.modelChanged`).
    public func setModel(_ credential: AgentCredential?) async throws {
        if let credential {
            _ = try await call("PUT", "secrets/\(Self.modelSecret)",
                               ["value": .string("\(credential.provider.rawValue)/\(credential.model)")], what: "the model")
            _ = try await call("PUT", "secrets/\(Self.keySecret(credential.provider))", ["value": .string(credential.apiKey)],
                               what: "the model's key")
        }
        let gone = (credential == nil ? [Self.modelSecret] : [])
            + AgentProvider.allCases.filter { $0 != credential?.provider }.map(Self.keySecret)
        try await deleteSecrets(gone, what: "the model's key")
    }

    /// Takes `names` out of strut's secret store; one never stored, or taken
    /// out before, is already as wanted.
    func deleteSecrets(_ names: [String], what: String) async throws {
        for name in names {
            let (status, data) = try await request("DELETE", "secrets/\(name)", nil, what: what)
            if status != 404 { _ = try Self.read(status, data) }
        }
    }

    /// The step: reads the token and Peel's port from strut's secret store in
    /// code, as strut's adapters do, and posts the run through
    /// `ctx.services.http` to 127.0.0.1 at that port. Its config is the run
    /// only: a workflow can name neither the token nor where it goes.
    static let stepSource = #"""
        import { z, defineStep } from "strut";

        export default defineStep({
          type: "\#(step)",
          description: "Hands an automation's prompt to Peel on this Mac, at the port and with the token Peel keeps in the secret store. Output: { status, body } — body is Peel's reply.",
          input: z.object({
            name: z.string(),
            prompt: z.string(),
            since: z.any().optional(),
          }),
          output: z.any(),
          async run(cfg, ctx) {
            const token = await ctx.services.secrets.get("\#(tokenSecret)");
            const port = Number(await ctx.services.secrets.get("\#(portSecret)"));
            if (!token || !Number.isInteger(port) || port < 1 || port > 65535) {
              throw new Error('secrets "\#(tokenSecret)" and "\#(portSecret)" are not set: Peel stores them when its agent chat opens');
            }
            const res = await ctx.services.http(`http://127.0.0.1:${port}/automations/run`, {
              method: "POST",
              headers: { authorization: `Bearer ${token}` },
              body: { name: cfg.name, prompt: cfg.prompt, since: cfg.since ?? null },
              timeout: 600000,
            });
            if (!res.ok) {
              const why = typeof res.body === "string" ? res.body : res.body?.error ?? JSON.stringify(res.body);
              throw new Error(`Peel answered ${res.status}: ${why}`);
            }
            return { status: res.status, body: res.body };
          },
        });

        """#

    /// The workflow: one `step` to Peel, and nothing about where Peel is or
    /// its token, so it is the same on every launch.
    static let workflowYAML = """
        name: \(workflow)
        input:
          name: { type: string }
          prompt: { type: string }
          since: { type: json, required: false, description: "When the last successful run finished; null on the first" }
        steps:
          - id: peel
            type: \(step)
            config:
              name: "{{ input.name }}"
              prompt: "{{ input.prompt }}"
              since: "{{ input.since }}"

        """

    /// `p-` and the content's hash: the same content always has the same label.
    static func version(of yaml: String) -> String {
        "p-" + SHA256.hash(data: Data(yaml.utf8)).prefix(6).hex
    }

    // MARK: HTTP

    func call(_ method: String, _ path: String, _ body: AgentKit.JSONValue? = nil, what: String) async throws -> AgentKit.JSONValue {
        let (status, data) = try await request(method, path, body, what: what)
        return try Self.read(status, data)
    }

    func request(_ method: String, _ path: String, _ body: AgentKit.JSONValue?, what: String) async throws -> (Int, Data) {
        guard let url = URL(string: path, relativeTo: server.base.appending(path: "/"))?.absoluteURL else {
            throw PeelError("could not address \(what) on strut")
        }
        do {
            return try await Web.requestStrut(method, url, json: body.map { Data($0.jsonString.utf8) }, bearer: server.key,
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
