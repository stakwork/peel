import AgentKit
import Foundation
import PeelAgent
import PeelCore

/// `peel eval memory`: the agent's memory measured end to end. Each
/// scenario (evals/memory.json) is said to the agent with the app's prompt
/// and memory tools (`AgentSetup`, no account, nothing sent) on a fresh
/// memory of its own (the staged strut, its data in a temporary folder,
/// never a profile's), N times; each check must pass in at least two
/// thirds of the runs. A strut that does not start, or a model never asked
/// (a refused key, a bad address, a model id the provider does not know), stops the eval: that is no score. Off unless a model is given: the key from
/// `PEEL_AGENT_API_KEY`, or the model a development profile connected
/// (`--profile`); the key is never printed or written.
enum EvalCommand {
    @MainActor static func run(_ arguments: Arguments, profile name: String?) async throws {
        var arguments = arguments
        guard arguments.next() == "memory" else { throw PeelError("usage: peel eval memory [options]\n\(usage)") }
        let runs = try arguments.option("--runs").map { text in
            guard let runs = Int(text), runs > 0 else { throw PeelError("--runs is a whole number above 0, not \(text)") }
            return runs
        } ?? 3
        let only = arguments.option("--scenario")
        let choice = try AgentCommand.ModelChoice(&arguments)
        guard arguments.isEmpty else { throw PeelError("eval: unexpected \(arguments.rest().joined(separator: " "))") }

        let suite = try MemoryEval(contentsOf: file)
        let scenarios = suite.scenarios.filter { only == nil || $0.name == only }
        if let only, scenarios.isEmpty { throw PeelError("no scenario named \(only) in \(file.path)") }

        let model: (provider: any ModelProvider, id: String, label: String)
        let key = AgentCommand.ModelChoice.environmentKey
        if key != nil, let name {
            throw PeelError("both \(AgentCommand.keyVariable) and --profile \(name) give a model; unset one")
        }
        if let key {
            let (provider, id) = try choice.client(apiKey: key)
            model = (provider, id, "\((choice.provider ?? .anthropic).rawValue), \(id)")
        } else if let name {
            let profile = try Profile(name: name, kind: .development)
            guard let credential = try KeptCredential(item: profile.agentCredential).read() else {
                throw PeelError("development profile \(name) has no connected model")
            }
            if let given = choice.provider, given != credential.provider {
                throw PeelError("--provider \(given.rawValue) is not profile \(name)'s model, \(credential.provider.rawValue)")
            }
            // The profile's key goes to its provider or to this Mac, never to another address.
            if let url = choice.baseURL, !ServerAddress.isLoopback(host: url.host?.lowercased() ?? "") {
                throw PeelError("with --profile, --base-url is this Mac only (localhost, 127.0.0.1 or ::1)")
            }
            let id = choice.model ?? credential.model
            model = (credential.provider.client(apiKey: credential.apiKey, baseURL: choice.baseURL), id,
                     "\(credential.provider.rawValue), \(id), from profile \(name)")
        } else {
            print("""
                memory eval: skipped, no model. \(scenarios.count) scenarios in \(file.path).
                Run with a model: \(AgentCommand.keyVariable)=<key> peel eval memory [--provider <p>] [--model <id>]
                or with a development profile's connected model: peel eval memory --profile <dev profile>
                \(usage)
                """)
            return
        }

        print("memory eval: \(model.label), \(runs) runs per scenario, strut at \(BundledStrut.staged.path)")
        var below = 0, total = 0
        for scenario in scenarios {
            var results: [[MemoryEval.Result]] = []
            for run in 1...runs {
                print("  \(scenario.name): run \(run) of \(runs)…")
                results.append(try await suite.run(scenario, provider: model.provider, model: model.id))
            }
            let (checks, failing) = MemoryEval.report(scenario, results)
            total += checks
            below += failing
        }
        print("\n\(total - below) of \(total) checks passed in at least two thirds of runs")
        if below > 0 { throw PeelError("memory eval: \(below) of \(total) checks passed in under two thirds of runs") }
    }

    static let usage = """
          options: --runs <n> (default 3), --scenario <name>,
          --provider anthropic|openai|openrouter, --model <id>, --base-url <url>, --profile <dev profile>
        """

    /// evals/memory.json in the checkout this was built from.
    static let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "evals/memory.json")
}

/// The scenarios file, checked whole when read, and how a run is scored.
struct MemoryEval: Decodable {
    var neverSay: [String]
    var scenarios: [Scenario]

    struct Scenario: Decodable {
        var name: String
        var round: String?
        var steps: [Step]
    }

    /// One of say, ask (a message) or clear; checks only on a message.
    struct Step: Decodable {
        var say: String?
        var ask: String?
        var clear: Bool?
        var answer: [AnswerCheck]?
        var memory: [MemoryCheck]?

        var message: String? { say ?? ask }
    }

    /// Any of `mustContain`, none of `mustNotContain`.
    struct AnswerCheck: Decodable {
        var mustContain: [String]?
        var mustNotContain: [String]?
    }

    /// A fact on an entity (`on`, `fact`, `state`), none (`on`, `noFact`),
    /// or the entities a name finds (`entity`, `count`, `aliases`).
    struct MemoryCheck: Decodable {
        var on: String?
        var fact: String?
        var noFact: String?
        var state: String?
        var entity: String?
        var count: Int?
        var aliases: [String]?
    }

    /// One check in one run.
    struct Result {
        var label: String
        var passed: Bool
        /// What was answered, or what memory held, when it failed.
        var detail: String = ""
    }
}

extension MemoryEval {
    init(contentsOf file: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw PeelError("cannot read \(file.path): \(PeelError.readable(error))") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            try Self.checkKeys(JSONSerialization.jsonObject(with: data))
            self = try decoder.decode(Self.self, from: data)
        } catch let error as PeelError {
            throw PeelError("\(file.lastPathComponent): \(error.description)")
        } catch {
            throw PeelError("cannot read \(file.lastPathComponent): \(error)")
        }
        try check()
    }

    /// The keys each part of the file may have; any other is a typo the decoder would ignore.
    private static let keys: [String: Set<String>] = [
        "": ["about", "never_say", "scenarios"], "scenarios": ["name", "round", "steps"],
        "steps": ["say", "ask", "clear", "answer", "memory"], "answer": ["must_contain", "must_not_contain"],
        "memory": ["on", "fact", "no_fact", "state", "entity", "count", "aliases"],
    ]

    private static func checkKeys(_ value: Any, in part: String = "") throws {
        if let list = value as? [Any] { for item in list { try checkKeys(item, in: part) } }
        guard let object = value as? [String: Any], let allowed = keys[part] else { return }
        for (key, child) in object {
            guard allowed.contains(key) else { throw PeelError("unknown key \(key) in \(part.isEmpty ? "the file" : part)") }
            try checkKeys(child, in: key)
        }
    }

    /// Names are unique, every step is one thing, every pattern compiles,
    /// every check is one kind with only its own fields.
    func check() throws {
        let patterns = neverSay + scenarios.flatMap(\.steps).flatMap { step in
            (step.answer ?? []).flatMap { ($0.mustContain ?? []) + ($0.mustNotContain ?? []) }
                + (step.memory ?? []).compactMap { $0.fact ?? $0.noFact }
        }
        for pattern in patterns {
            // An empty pattern matches anything: a check that always passes.
            if pattern.trimmingCharacters(in: .whitespaces).isEmpty { throw PeelError("an empty pattern matches anything") }
            _ = try Self.regex(pattern)
        }
        let names = scenarios.map(\.name)
        if Set(names).count != names.count { throw PeelError("two scenarios have the same name") }
        for scenario in scenarios {
            let name = scenario.name
            if scenario.steps.isEmpty { throw PeelError("\(name): no steps") }
            for step in scenario.steps {
                let kinds = [step.say, step.ask].compactMap { $0 }.count + (step.clear == true ? 1 : 0)
                guard kinds == 1 else { throw PeelError("\(name): each step is one of say, ask or clear") }
                if step.clear == true, step.answer != nil || step.memory != nil { throw PeelError("\(name): clear has no checks") }
                for check in step.answer ?? [] {
                    let lists = [check.mustContain, check.mustNotContain].compactMap { $0 }
                    guard !lists.isEmpty, !lists.contains(where: \.isEmpty) else {
                        throw PeelError("\(name): an answer check has patterns in must_contain or must_not_contain")
                    }
                }
                for check in step.memory ?? [] {
                    let kinds = [check.fact, check.noFact, check.entity].compactMap { $0 }.count
                    guard kinds == 1 else { throw PeelError("\(name): a memory check is one of fact, no_fact or entity") }
                    if check.entity == nil {
                        if check.on == nil { throw PeelError("\(name): fact and no_fact need on") }
                        if check.count != nil || check.aliases != nil { throw PeelError("\(name): count and aliases go with entity") }
                    } else if check.on != nil {
                        throw PeelError("\(name): entity takes no on")
                    }
                    if check.state != nil, check.fact == nil { throw PeelError("\(name): state goes with fact") }
                    if !["current", "past", "any", nil].contains(check.state) { throw PeelError("\(name): state is current, past or any") }
                    if [check.on, check.entity].contains(where: { $0?.trimmingCharacters(in: .whitespaces).isEmpty == true }) {
                        throw PeelError("\(name): on and entity name something")
                    }
                    if let count = check.count, count < 0 { throw PeelError("\(name): count is 0 or more") }
                }
            }
        }
    }

    static func regex(_ pattern: String) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) } catch {
            throw PeelError("not a pattern: \(pattern)")
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        (try? regex(pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A name as strut compares names (its `normalize`): compatibility
    /// decomposed, combining marks dropped, lower case, spaces collapsed.
    static func normalize(_ name: String) -> String {
        let kept = name.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
        return String(String.UnicodeScalarView(kept)).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Running

    /// One run of `scenario` on a fresh memory: each check's result, in
    /// order. Throws, ending the eval, when strut does not start or the
    /// model was never asked (key, address or model id refused).
    @MainActor func run(_ scenario: Scenario, provider: any ModelProvider, model: String) async throws -> [Result] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "peel-eval-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let strut = try AgentCommand.strut(data: folder.appending(path: "data"), key: FileItem(file: folder.appending(path: "strut-key")))
        defer { strut.stop(quietly: true) }
        let server: MemoryServer
        do { server = try await strut.start() } catch { throw PeelError("memory eval stopped: strut did not start: \(PeelError.readable(error))") }

        let setup = AgentSetup(memory: server)
        let loop = AgentLoop(provider: provider, tools: setup.tools, model: model, systemPrompt: setup.systemPrompt())
        var history: [ModelMessage] = []
        var results: [Result] = []
        for step in scenario.steps {
            guard let message = step.message else {
                history = []
                continue
            }
            let turn = await loop.run(history: history, message: message)
            switch turn.outcome {
            // The model was never asked (no key, no address, a model it does not know): no score.
            case .failed(.invalidKey), .failed(.invalidAddress), .failed(.badRequest): throw PeelError("memory eval stopped: \(turn.summary ?? "")")
            default: break
            }
            history += turn.messages
            // The answer is the turn's last reply, not what it said on the way (“let me check…”).
            let said = (turn.messages.last { $0.role == .assistant }?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            results += answerResults(step, said: said, unfinished: turn.summary)
            for check in step.memory ?? [] {
                do {
                    results.append(Self.memoryResult(check, found: try await Self.entities(check.entity ?? check.on ?? "", server: server)))
                } catch {
                    results.append(Result(label: Self.label(check), passed: false,
                                          detail: "memory could not be read: \(PeelError.readable(error))"))
                }
            }
        }
        return results
    }

    /// The step's answer checks on what the model `said`, and on an ask
    /// that it kept memory's workings out; all fail when the turn did not
    /// finish (`unfinished`, the turn's summary), which is never matched, or
    /// gave no answer.
    func answerResults(_ step: Step, said: String, unfinished: String?) -> [Result] {
        // No answer is not a pass for a check that only forbids words.
        let unfinished = unfinished ?? (said.isEmpty ? "no answer" : nil)
        let asked = "answer to \"\(step.message ?? "")\""
        let detail = (unfinished.map { "the turn did not finish: \($0) " } ?? "") + "answered: \(said)"
        var results = (step.answer ?? []).map { check in
            var label = asked
            if let any = check.mustContain { label += " has \(any.joined(separator: " or "))" }
            if let none = check.mustNotContain { label += " has none of \(none.joined(separator: ", "))" }
            let any = check.mustContain.map { $0.contains { Self.matches($0, said) } } ?? true
            let none = !(check.mustNotContain ?? []).contains { Self.matches($0, said) }
            return Result(label: label, passed: unfinished == nil && any && none, detail: detail)
        }
        if step.ask != nil {
            let words = neverSay.filter { Self.matches($0, said) }
            results.append(Result(label: "\(asked) keeps memory's workings out", passed: unfinished == nil && words.isEmpty,
                                  detail: words.isEmpty ? detail : "said /\(words.joined(separator: "/, /"))/ in: \(said)"))
        }
        return results
    }

    static func label(_ check: MemoryCheck) -> String {
        if let entity = check.entity {
            return "memory: \(entity == "user" ? "the user" : "\"\(entity)\" finds")"
                + (check.count.map { " \($0) \($0 == 1 ? "entity" : "entities")" } ?? "")
                + (check.aliases.map { ", named \($0.joined(separator: ", "))" } ?? "")
        }
        let on = check.on == "user" ? "the user" : check.on ?? ""
        if let fact = check.fact { return "memory: \(on) has a \(check.state ?? "any") fact /\(fact)/" }
        return "memory: \(on) has no fact /\(check.noFact ?? "")/"
    }

    /// `check` scored on the entities its name `found` (`entities`).
    static func memoryResult(_ check: MemoryCheck, found: [AgentKit.JSONValue]) -> Result {
        let name = check.entity ?? check.on ?? ""
        let held = found.isEmpty ? "memory has no entity \(name == "user" ? "for the user" : "named \(name)")"
            : "memory held: " + found.map(describe).joined(separator: "; ")
        if check.entity != nil {
            let aliases = Set(found.flatMap { ($0["aliases"]?.array ?? []).compactMap(\.string).map(normalize) })
            let passed = !found.isEmpty && check.count.map { found.count == $0 } != false
                && (check.aliases ?? []).allSatisfy { aliases.contains(normalize($0)) }
            return Result(label: label(check), passed: passed, detail: held)
        }
        let now = found.flatMap { texts($0["facts"]) }, before = found.flatMap { texts($0["past"]) }
        if let pattern = check.noFact {
            return Result(label: label(check), passed: !(now + before).contains { matches(pattern, $0) }, detail: held)
        }
        let pool = switch check.state { case "current": now; case "past": before; default: now + before }
        return Result(label: label(check), passed: pool.contains { matches(check.fact ?? "", $0) }, detail: held)
    }

    /// The user (`user`), or the entities recall finds whose name or alias
    /// is `name` (strut's `normalize` on both sides), each read whole.
    static func entities(_ name: String, server: MemoryServer) async throws -> [AgentKit.JSONValue] {
        if name == "user" {
            do { return [try await server.run("get", ["user": true])] } catch is MemoryServer.NotFound { return [] }
        }
        var found: [String: AgentKit.JSONValue] = [:]
        for hit in try await server.run("recall", ["q": .string(name), "limit": 50]).array ?? [] where hit["node_type"]?.string != "Fact" {
            guard let id = hit["ref_id"]?.string else { continue }
            let node = try await server.run("get", ["ref_id": .string(id)])
            let names = ([node["name"]].compactMap { $0 } + (node["aliases"]?.array ?? [])).compactMap(\.string).map(normalize)
            if names.contains(normalize(name)), let kept = node["ref_id"]?.string { found[kept] = node }
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    /// The facts' sentences in a `get` list.
    static func texts(_ list: AgentKit.JSONValue?) -> [String] {
        (list?.array ?? []).compactMap { $0["text"]?.string }
    }

    static func describe(_ node: AgentKit.JSONValue) -> String {
        let name = node["user"] == .bool(true) ? "the user (\(node["name"]?.string ?? ""))" : node["name"]?.string ?? "?"
        let aliases = (node["aliases"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
        return "\(name) [aliases: \(aliases)] now: \(texts(node["facts"])) past: \(texts(node["past"]))"
    }

    // MARK: Scoring

    /// Whether a check that passed `passes` of `runs` times passed often
    /// enough: at least two thirds of the runs.
    static func passing(_ passes: Int, of runs: Int) -> Bool {
        passes * 3 >= runs * 2
    }

    /// Prints the scenario's scorecard: each check's passes, and each
    /// failure's answer or memory. The number of checks, and how many did
    /// not pass often enough. Every run gives the same checks in order.
    static func report(_ scenario: Scenario, _ runs: [[Result]]) -> (checks: Int, below: Int) {
        print("\n\(scenario.name)\(scenario.round.map { ", round \($0)" } ?? "")")
        let checks = runs.first?.count ?? 0
        var below = 0
        for index in 0..<checks {
            let results = runs.map { $0[index] }
            let passes = results.filter(\.passed).count
            let ok = passing(passes, of: runs.count)
            if !ok { below += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(passes)/\(runs.count)  \(results[0].label)")
            for (run, result) in results.enumerated() where !result.passed {
                print("         run \(run + 1): \(oneLine(result.detail))")
            }
        }
        return (checks, below)
    }

    private static func oneLine(_ text: String, max: Int = 600) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
}
