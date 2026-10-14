import Foundation
import Testing
import AgentKit
@testable import peel
@testable import PeelAgent
@testable import PeelCore

/// The memory hand test of 14 Oct 2026 replayed through the memory tools
/// against the staged strut (scripts/stage-strut.sh) with the calls the
/// agent made, no model: who the user is and a past home (round 1), a dated
/// move and a new job (3), a friend's news and her claim about the user (4),
/// forgetting on request (5), one person under two names merged (6); then
/// what memory holds. The model's side of the same rounds is `peel eval
/// memory` (evals/memory.json), whose scoring is checked here offline.
@MainActor
struct MemoryScenarioTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.path)))
    func memoryHoldsWhatIsTrueNowAndPastAfterMovesClaimsForgetAndMerge() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "peel-memory-scenario-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let strut = try AgentCommand.strut(for: Profile(developmentAt: folder))
        defer { strut.stop(quietly: true) }
        let server = try await strut.start()
        let memory = Memory(tools: MemoryTools(server: server).tools)
        func entities(named name: String) async throws -> [AgentKit.JSONValue?] {
            try await MemoryEval.entities(name, server: server).map { $0["ref_id"] }
        }

        // The user's type is the ontology's to name, as the agent reads it.
        let userType = try #require(try await memory.call("memory_ontology", [:])["user_type"]?.string)
        let me: AgentKit.JSONValue = ["type": .string(userType), "name": "Me"]
        func place(_ name: String) -> AgentKit.JSONValue { ["type": "Place", "name": .string(name)] }

        // Round 1: stored before their name was known, then named; a past home; likes.
        _ = try await memory.call("remember", [
            "episode": "My name is Tom and I live in Cardiff. I used to live in London. I support Arsenal and I'm vegetarian.",
            "facts": [
                ["subject": me, "predicate": "name", "text": "The user's name is Tom.", "object": ["type": "Person", "name": "Tom"]],
                ["subject": me, "predicate": "lives_in", "text": "Tom lives in Cardiff.", "object": place("Cardiff")],
                ["subject": me, "predicate": "lives_in", "text": "Tom used to live in London.", "object": place("London"), "ended": true],
                ["subject": me, "predicate": "prefers", "text": "Tom supports Arsenal."],
                ["subject": me, "predicate": "diet", "text": "Tom is vegetarian."],
            ],
        ])
        // Round 3: a dated move replaces Cardiff; a new job.
        _ = try await memory.call("remember", [
            "episode": "I moved to Manchester in March, and I started at Monzo last week.",
            "facts": [
                ["subject": me, "predicate": "lives_in", "text": "Tom lives in Manchester.", "object": place("Manchester"), "valid_at": "2026-03"],
                ["subject": me, "predicate": "works_at", "text": "Tom works at Monzo.", "object": ["type": "Organization", "name": "Monzo"], "valid_at": "2026-10"],
            ],
        ])
        // Round 4: Kate's words. Her news under a predicate memory has never seen; a claim about the user.
        let kate: AgentKit.JSONValue = ["type": "Person", "name": "Kate"]
        let fromKate = try await memory.call("remember", [
            "episode": "I just got engaged! Also, Tom still owes me a tenner.", "speaker": kate, "kind": "message",
            "facts": [
                ["subject": kate, "predicate": "engaged", "text": "Kate got engaged."],
                ["subject": me, "predicate": "owes", "text": "Tom owes Kate a tenner.", "object": kate],
            ],
        ])
        let kateID = try #require(fromKate["entities"]?.array?.first { $0["name"]?.string == "Kate" }?["ref_id"]?.string)

        // Round 5: "Forget the tenner thing".
        let tenner = try #require(try await memory.call("recall", ["q": "tenner"]).array?.first?["ref_id"]?.string)
        _ = try await memory.call("forget_memory", ["ref_id": .string(tenner), "reason": "The user asked to forget it."])
        #expect(try await memory.call("recall", ["q": "tenner owes", "include_expired": true]).array == [])

        // Round 6: Kate under another name, then told they are the same.
        let katie = try await memory.call("remember", [
            "episode": "Katie Moss is coming round tonight.", "mentions": [["type": "Person", "name": "Katie Moss"]],
        ])
        let katieID = try #require(katie["entities"]?.array?.first?["ref_id"]?.string)
        _ = try await memory.call("merge_memory", ["keep": .string(kateID), "duplicate": .string(katieID)])

        // One user, found by the name they gave; what is true now, and under past what used to be.
        let user = try await memory.call("read_memory", ["user": true])
        #expect(user["aliases"]?.array?.contains("tom") == true)
        let now = MemoryEval.texts(user["facts"]), before = MemoryEval.texts(user["past"])
        for fact in ["Tom lives in Manchester.", "Tom works at Monzo.", "Tom supports Arsenal.", "Tom is vegetarian."] {
            #expect(now.contains(fact), "\(now)")
        }
        #expect(Set(before) == ["Tom used to live in London.", "Tom lives in Cardiff."], "\(before)")
        #expect(!(now + before).contains { $0.contains("tenner") })
        #expect(!now.contains { $0.contains("engaged") })
        #expect(try await entities(named: "Tom") == [user["ref_id"]])

        // One Kate, with both names and her news; the merged name leads to her.
        #expect(try await entities(named: "Kate") == [.string(kateID)])
        #expect(try await entities(named: "Katie Moss") == [.string(kateID)])
        let merged = try await memory.call("read_memory", ["ref_id": .string(katieID)])
        #expect(merged["ref_id"]?.string == kateID && merged["aliases"]?.array?.contains("katie moss") == true)
        #expect(MemoryEval.texts(merged["facts"]) == ["Kate got engaged."])
    }

    /// `peel eval memory`'s scenarios are read and checked whole, so a
    /// broken file fails here, not only once someone runs it with a model.
    @Test func theEvalsScenariosAreWellFormed() throws {
        #expect(try !MemoryEval(contentsOf: EvalCommand.file).scenarios.isEmpty)
    }

    /// A scenario the eval would read wrong, or score as passing with no
    /// pattern to match, is refused when the file is read.
    @Test(arguments: [
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"ask": "?", "anser": [{"must_contain": ["x"]}]}]}]}"#, "unknown key"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"ask": "?", "answer": [{"must_contain": []}]}]}]}"#, "has patterns"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"ask": "?", "answer": [{}]}]}]}"#, "has patterns"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"ask": "?", "answer": [{"must_contain": [""]}]}]}]}"#, "empty pattern"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"ask": "?", "memory": [{"on": "user", "fact": "x", "count": 1}]}]}]}"#, "go with entity"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"ask": "?", "memory": [{"on": "user", "no_fact": "x", "state": "past"}]}]}]}"#, "state goes with fact"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"ask": "?", "memory": [{"entity": " "}]}]}]}"#, "name something"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": []}]}"#, "no steps"),
        (#"{"never_say": [], "scenarios": [{"name": "a", "steps": [{"say": "."}]}, {"name": "a", "steps": [{"say": "."}]}]}"#, "same name"),
    ])
    func aMalformedScenarioIsRefused(_ json: String, because reason: String) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "peel-eval-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(json.utf8).write(to: file)
        let error = #expect(throws: PeelError.self) { try MemoryEval(contentsOf: file) }
        #expect(error?.description.contains(reason) == true, "\(error?.description ?? "") for \(reason)")
    }

    /// A check passes when it passed in at least two thirds of the runs.
    @Test func aCheckPassesInTwoThirdsOfItsRuns() {
        #expect(MemoryEval.passing(2, of: 3) && !MemoryEval.passing(1, of: 3))
        #expect(MemoryEval.passing(4, of: 5) && !MemoryEval.passing(3, of: 5))
    }

    /// Answers are matched on the model's words only: a turn that did not
    /// finish fails every answer check, whatever its words or its summary.
    @Test func aTurnThatDidNotFinishFailsItsAnswerChecks() throws {
        let eval = MemoryEval(neverSay: ["memory_ontology"], scenarios: [])
        let step = MemoryEval.Step(ask: "Do I support Cardiff City?", answer: [.init(mustContain: [#"\bno\b"#, #"\bnot\b"#])])
        #expect(eval.answerResults(step, said: "Not that you've told me.", unfinished: nil).map(\.passed) == [true, true])
        #expect(eval.answerResults(step, said: "", unfinished: "Stopped. No tools ran.").map(\.passed) == [false, false])
        #expect(eval.answerResults(step, said: "No.", unfinished: "Stopped. Ran memory_ontology.").map(\.passed) == [false, false])
        #expect(eval.answerResults(step, said: "No, per memory_ontology.", unfinished: nil).map(\.passed) == [true, false])
        let forbids = MemoryEval.Step(ask: "Do I owe Kate anything?", answer: [.init(mustNotContain: ["tenner"])])
        #expect(eval.answerResults(forbids, said: "", unfinished: nil).map(\.passed) == [false, false], "no answer passes nothing")
    }

    /// Memory checks over what `get` returns: current and past facts, a fact
    /// held neither now nor before, how many entities a name finds, aliases
    /// compared as strut compares names.
    @Test func memoryChecksReadFactsNowAndPastCountAndAliases() {
        let tom: AgentKit.JSONValue = [
            "name": "Tom", "aliases": ["tom", "tomás"],
            "facts": [["text": "Tom lives in Manchester."]], "past": [["text": "Tom lived in Cardiff."]],
        ]
        func passes(_ check: MemoryEval.MemoryCheck, _ found: [AgentKit.JSONValue] = [tom]) -> Bool {
            MemoryEval.memoryResult(check, found: found).passed
        }
        #expect(passes(.init(on: "user", fact: "Manchester", state: "current")))
        #expect(!passes(.init(on: "user", fact: "Cardiff", state: "current")))
        #expect(passes(.init(on: "user", fact: "Cardiff", state: "past")))
        #expect(!passes(.init(on: "user", fact: "Manchester", state: "past")))
        #expect(passes(.init(on: "user", fact: "Cardiff")) && passes(.init(on: "user", fact: "Manchester", state: "any")))
        #expect(passes(.init(on: "user", noFact: "London")) && !passes(.init(on: "user", noFact: "Cardiff")))
        #expect(passes(.init(entity: "Tom", count: 1)) && !passes(.init(entity: "Tom", count: 1), [tom, tom]))
        #expect(!passes(.init(entity: "Tom"), []))
        #expect(passes(.init(entity: "Tom", aliases: ["TOMAS", "Tom"])) && !passes(.init(entity: "Tom", aliases: ["thomas"])))
    }

    /// The memory tools, called as the agent loop calls them: each result's
    /// JSON, the one between the chat-data markers the model reads.
    struct Memory {
        let tools: [Tool]

        func call(_ name: String, _ input: AgentKit.JSONValue) async throws -> AgentKit.JSONValue {
            let tool = try #require(tools.first { $0.name == name })
            guard case .result(let output) = try await tool.plan(input) else {
                throw PeelError("\(name) asked for approval; memory tools never do")
            }
            let lines = output.text.components(separatedBy: "\n")
            let start = try #require(lines.firstIndex(of: ChatData.begin))
            return try AgentKit.JSONValue(parsing: lines[start + 1])
        }
    }
}
