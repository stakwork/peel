import AgentKit
import Foundation
import Testing
@testable import PeelAgent

/// "What it learned": the habit rules, the check and the person's answers, on
/// the person's own graph. No strut and no model: a stand-in judge and a
/// stand-in graph that answers the memory steps.
struct LearnedTests {
    static let good = "When I ask for a short answer, the assistant writes several paragraphs."
    static let other = "When I name a file, the assistant opens a different file."
    static let recordPredicate = GraphLearnedStore.record
    static let at = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Detection

    /// A rejected card is one candidate, once, with its words trimmed; the run is its turn.
    @Test func aRejectedCardProducesOneCandidate() {
        let long = String(repeating: "x ", count: 300)
        let signal = LearnedDetector.rejected(request: "run1/abc", action: "Send a message", content: long, at: Self.at)
        let found = LearnedDetector.candidates(from: [signal, signal], now: Self.at)
        #expect(found.count == 1)
        #expect(found[0].kind == .cardRejected)
        #expect(found[0].turn == "run1")
        #expect(found[0].excerpt.count <= LearnedDetector.excerptLimit)
        // Already evidence: not a candidate again.
        #expect(LearnedDetector.candidates(from: [signal], known: [found[0].id], now: Self.at).isEmpty)
    }

    @Test func followUpsAreTheObjectionsRightAfterAReply() {
        let turns = [
            DMTurn(id: "a1", fromPerson: false, text: "Sent it to Kate.", at: Self.at),
            DMTurn(id: "p1", fromPerson: true, text: "No, not that one, the other Kate", at: Self.at),
            DMTurn(id: "a2", fromPerson: false, text: "Sorry.", at: Self.at),
            DMTurn(id: "p2", fromPerson: true, text: "No problem, thanks", at: Self.at),
            DMTurn(id: "p3", fromPerson: true, text: "that's wrong", at: Self.at),
        ]
        let found = LearnedDetector.followUps(in: turns)
        // p3 follows the person's own message, not a reply; p2 is no objection.
        #expect(found.map(\.turn) == ["a1"])
        #expect(found[0].kind == .followUp)
    }

    // MARK: Rules

    @Test func aStatementIsOneShortSentenceWithNoNames() throws {
        try CauseRules.validate(Self.good)
        let words = (1...30).map { "word\($0)" }.joined(separator: " ")
        #expect(throws: LearnedRefusal.self) { try CauseRules.validate("When asked, the assistant " + words + ".") }
        #expect(throws: LearnedRefusal.self) { try CauseRules.validate("When Kate writes, the assistant answers late.") }
        #expect(throws: LearnedRefusal.self) { try CauseRules.validate("When I use hive, the assistant answers late.") }
        #expect(throws: LearnedRefusal.self) { try CauseRules.validate("When I use Peel, the assistant answers late.") }
        #expect(throws: LearnedRefusal.self) { try CauseRules.validate("The assistant answers late.") }
        #expect(throws: LearnedRefusal.self) { try CauseRules.validate("When asked, the assistant waits. Then it stops.") }
    }

    @Test func aRepeatHasTheSameKey() {
        let a = CauseRules.identityKey(type: .promptGap, statement: Self.good)
        // Hive's shape: ck1_ and 16 hex characters (equality with Hive's own key is not verified).
        #expect(a.hasPrefix("ck1_") && a.count == 20)
        #expect(a == CauseRules.identityKey(type: .promptGap, statement: "  when I ask for a SHORT answer,  the assistant writes several paragraphs "))
        #expect(a != CauseRules.identityKey(type: .correction, statement: Self.good))
    }

    // MARK: Grouping

    static func leaf(_ id: String, _ statement: String, _ type: CauseType = .promptGap) -> PersonalCause {
        PersonalCause(id: id, statement: statement, causeType: type, severity: .medium,
                      evidence: [CauseEvidence(turn: "t\(id)", excerpt: "no", confidence: 0.6, kind: "follow_up", why: "")])
    }

    static let theme = ProposedTheme(statement: "When I ask for something small, the assistant does far more than asked.",
                                     causeType: .promptGap, severity: .medium, mechanism: "It ignores the size asked for.", leaves: ["a", "b"])

    @Test func twoLeavesGroupOnlyWhenOneMechanismFits() {
        let a = Self.leaf("a", Self.good), b = Self.leaf("b", Self.other)
        let ok = GroupingRules.admit([Self.theme], leaves: [a, b], themes: [], rejected: [])
        #expect(ok.groupings.count == 1)

        // One leaf alone does not make a theme.
        var one = Self.theme
        one.leaves = ["a"]
        #expect(GroupingRules.admit([one], leaves: [a, b], themes: [], rejected: []).groupings.isEmpty)

        // No mechanism, or the judge says the fixes differ: not glued.
        var bare = Self.theme
        bare.mechanism = nil
        #expect(GroupingRules.admit([bare], leaves: [a, b], themes: [], rejected: []).groupings.isEmpty)
        var differ = Self.theme
        differ.needsDifferentFixes = true
        #expect(GroupingRules.admit([differ], leaves: [a, b], themes: [], rejected: []).groupings.isEmpty)

        // One mechanism may explain leaves of different types.
        let c = Self.leaf("b", Self.other, .formatViolation)
        #expect(GroupingRules.admit([Self.theme], leaves: [a, c], themes: [], rejected: []).groupings.count == 1)

        // A parent that is not a short, nameless sentence is dropped.
        var named = Self.theme
        named.statement = "When Kate asks, the assistant does more."
        #expect(GroupingRules.admit([named], leaves: [a, b], themes: [], rejected: []).groupings.isEmpty)
    }

    @Test func oneLeafMayJoinAnExistingThemeAndEachLeafIsInOneTheme() {
        let parent = PersonalCause(id: "p", statement: "When I ask for something small, the assistant does more.", causeType: .promptGap,
                                   severity: .medium)
        let a = Self.leaf("a", Self.good), b = Self.leaf("b", Self.other)
        let join = ProposedTheme(statement: "", causeType: .promptGap, severity: .medium, leaves: ["a"], existing: "p")
        #expect(GroupingRules.admit([join], leaves: [a, b], themes: [parent], rejected: []).groupings.count == 1)

        // A second theme that wants a leaf the first took loses it, and with one left it is not a theme.
        let second = ProposedTheme(statement: "When I name a file, the assistant picks a nearby one.", causeType: .promptGap,
                                   severity: .low, mechanism: "m", leaves: ["a", "b"])
        let both = GroupingRules.admit([Self.theme, second], leaves: [a, b], themes: [], rejected: [])
        #expect(both.groupings.count == 1)
    }

    @Test func aRejectedGroupingIsNeverProposedAgain() {
        let a = Self.leaf("a", Self.good), b = Self.leaf("b", Self.other), c = Self.leaf("c", "When I ask for a list, the assistant writes prose.")
        let rejected = [RejectedGrouping(leafKeys: [a.identityKey, b.identityKey])]
        #expect(GroupingRules.admit([Self.theme], leaves: [a, b], themes: [], rejected: rejected).groupings.isEmpty)
        // Nor a larger one that holds it.
        var wider = Self.theme
        wider.leaves = ["a", "b", "c"]
        #expect(GroupingRules.admit([wider], leaves: [a, b, c], themes: [], rejected: rejected).groupings.isEmpty)
    }

    @Test func aNearDuplicateThemeIsReportedNotMerged() {
        let a = Self.leaf("a", Self.good), b = Self.leaf("b", Self.other)
        var existing = PersonalCause(id: "p", statement: Self.theme.statement, causeType: .promptGap, severity: .medium)
        existing.status = .active
        let result = GroupingRules.admit([Self.theme], leaves: [a, b], themes: [existing], rejected: [])
        #expect(result.groupings.isEmpty)
        #expect(result.dropped.first?.1 == .duplicate(of: "p"))
    }

    // MARK: The check and the answers

    struct Judge: LearnedJudge {
        var statements: [String: String] = [:]
        func word(_ candidates: [LeafCandidate]) async throws -> [DraftedLeaf] {
            candidates.compactMap { c in
                statements[c.turn].map { DraftedLeaf(candidate: c.id, statement: $0, causeType: .promptGap, severity: .medium) }
            }
        }
        func group(leaves: [PersonalCause], themes: [PersonalCause], rejected: [RejectedGrouping]) async throws -> [ProposedTheme] {
            guard leaves.count >= 2 else { return [] }
            return [ProposedTheme(statement: LearnedTests.theme.statement, causeType: .promptGap, severity: .medium,
                                  mechanism: "It ignores the size asked for.", leaves: leaves.map(\.id))]
        }
        func concept(for theme: PersonalCause, leaves: [PersonalCause]) async throws -> ConceptDraft {
            ConceptDraft(name: "Keep it short", statement: "Match the length the person asks for.")
        }
    }

    static func service(_ graph: FakeGraph, judge: Judge? = nil) -> LearnedService {
        let signals = [
            LearnedDetector.rejected(request: "r1/x", action: "Send", content: "long text", at: at),
            LearnedDetector.rejected(request: "r2/x", action: "Send", content: "another long text", at: at),
        ]
        return LearnedService(store: GraphLearnedStore(graph: graph),
                              judge: judge ?? Judge(statements: ["r1": good, "r2": other]),
                              signals: { signals })
    }

    @Test func aCheckIsADryRunAndWritesNothing() async throws {
        let graph = FakeGraph()
        let report = try await Self.service(graph).check(now: Self.at)
        #expect(report.groupings.count == 1 && report.habits.isEmpty)
        #expect(graph.writes == 0)
    }

    @Test func approvingAGroupingKeepsLeavesWithEvidenceAndAParentWithout() async throws {
        let graph = FakeGraph()
        let service = Self.service(graph)
        let grouping = try #require(try await service.check(now: Self.at).groupings.first)
        let parent = try await service.approve(grouping: grouping)
        let causes = try await service.causes()
        #expect(causes.count == 3)
        #expect(causes.first { $0.id == parent.id }?.evidence.isEmpty == true)
        let leaves = causes.filter { $0.id != parent.id }
        #expect(leaves.allSatisfy { $0.parent == parent.id && $0.evidence.count == 1 })
        // The same corrections are not found again, and the theme now waits for a concept.
        let again = try await service.check(now: Self.at)
        #expect(again.habits.isEmpty && again.groupings.isEmpty && again.concepts.count == 1)
    }

    @Test func aRejectedGroupingStaysRejectedAcrossChecks() async throws {
        let graph = FakeGraph()
        let service = Self.service(graph)
        let grouping = try #require(try await service.check(now: Self.at).groupings.first)
        try await service.reject(grouping: grouping)
        let again = try await service.check(now: Self.at)
        #expect(again.groupings.isEmpty)
        // The leaves are still there to keep one by one.
        #expect(again.habits.count == 2)
    }

    @Test func aRepeatAttachesItsEvidenceToTheHabitThatExists() async throws {
        let graph = FakeGraph()
        let store = GraphLearnedStore(graph: graph)
        let one = Self.leaf("n", Self.good)
        let kept = try await store.keep(one)
        var again = Self.leaf("m", Self.good)
        again.evidence[0].turn = "other-turn"
        _ = try await store.keep(again)
        let all = try await store.causes()
        #expect(all.count == 1 && all[0].id == kept.id && all[0].evidence.count == 2)
    }

    @Test func approvingAConceptThenUndoRestoresThePriorOne() async throws {
        let graph = FakeGraph()
        let service = Self.service(graph)
        let theme = Self.leaf("t", Self.theme.statement)
        let v1 = try await service.approve(concept: ConceptProposal(theme: theme, name: "Keep it short", statement: "Match the length asked for."))
        #expect(v1.prior == nil)

        let v2 = try await service.approve(concept: ConceptProposal(theme: theme, name: "Keep it short", statement: "Answer in one paragraph."))
        #expect(v2.prior?.statement == "Match the length asked for.")
        try await service.undo(concept: v2)
        let restored = try #require(try await service.concepts().first)
        #expect(restored.statement == "Match the length asked for." && restored.live)
        #expect(try await service.concepts().count == 1)

        // Undoing the first write takes the concept away, and its line with it.
        try await service.undo(concept: restored.withNoPrior)
        #expect(try await service.concepts().isEmpty)
        // Nothing of it is left to recall.
        #expect(graph.entities(of: "Concept").isEmpty)
    }

    @Test func aConceptWithANameOrALongSentenceIsRefused() async throws {
        let service = Self.service(FakeGraph())
        let theme = Self.leaf("t", Self.theme.statement)
        await #expect(throws: LearnedRefusal.self) {
            try await service.approve(concept: ConceptProposal(theme: theme, name: "Ask Hive", statement: "Be short."))
        }
        let long = (1...41).map { "w\($0)" }.joined(separator: " ")
        await #expect(throws: LearnedRefusal.self) {
            try await service.approve(concept: ConceptProposal(theme: theme, name: "Short", statement: long))
        }
    }

    @Test func takingAThemeApartKeepsTheLeaves() async throws {
        let graph = FakeGraph()
        let service = Self.service(graph)
        let grouping = try #require(try await service.check(now: Self.at).groupings.first)
        let parent = try await service.approve(grouping: grouping)
        try await service.undo(theme: parent)
        let causes = try await service.causes()
        #expect(causes.count == 2 && causes.allSatisfy { $0.parent == nil && !$0.evidence.isEmpty })
    }

    // MARK: Scope

    /// The personal path is made from a `MemoryServer` and nothing else, and its
    /// sources name no Hive peer, workspace or other strut.
    @Test func thePersonalPathReachesOnlyPeelsOwnStrut() throws {
        let make: (MemoryServer, @escaping @Sendable () async -> [LearnedSignal]) -> LearnedService = { LearnedService(server: $0, signals: $1) }
        _ = make
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PeelAgent")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Learned") && $0.pathExtension == "swift" }
        #expect(files.count >= 5)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["HiveClient", "HivePeer", "HiveLink", "pinnedApps", "run-workflow", "/peers/", "URLSession", "LearnedInstructions", "learned-instructions"] {
                #expect(!source.contains(forbidden), "\(file.lastPathComponent) names \(forbidden)")
            }
        }
    }

    // MARK: Live means a Concept in memory

    static func approvedConcept(_ graph: FakeGraph) async throws -> GraphLearnedStore {
        let store = GraphLearnedStore(graph: graph)
        let theme = try await store.group(Grouping(theme: Self.theme, leaves: [
            try await store.keep(Self.leaf("a", Self.good)), try await store.keep(Self.leaf("b", Self.other)),
        ]))
        _ = try await store.save(PersonalConcept(id: "", name: "Keep answers short",
                                                 statement: "Match the length of answer the person asks for.", cause: theme.id, live: true))
        return store
    }

    /// An approved Concept is what `memory/recall` returns for the words of a related task,
    /// and what the store reads back as in use.
    @Test func aLiveConceptIsRecalledForARelatedTask() async throws {
        let graph = FakeGraph()
        let store = try await Self.approvedConcept(graph)
        let query = LearnedWords.recallQuery(for: "Please write a short answer about the booking for Friday")
        #expect(!query.isEmpty)
        let raw = try await graph.run("recall", ["q": .string(query)])
        #expect((raw.array ?? []).contains { $0["node_type"]?.string == "Concept" && $0["name"]?.string == "Keep answers short" })
        let related = try await store.related(to: "Please write a short answer about the booking for Friday")
        #expect(related.map(\.name) == ["Keep answers short"] && related[0].live)
        // An unrelated task finds none.
        #expect(try await store.related(to: "Translate the menu into French").isEmpty)
        // It answers its theme and is about its topics, as facts of its own.
        #expect(graph.facts("answers").count == 1 && !graph.facts("about").isEmpty)
    }

    /// A proposed Concept is never written: the check proposes it and the graph holds none until the yes.
    @Test func aProposedConceptIsNeverWrittenOrRecalled() async throws {
        let graph = FakeGraph()
        let service = Self.service(graph)
        let grouping = try #require(try await service.check(now: Self.at).groupings.first)
        try await service.approve(grouping: grouping)
        let before = graph.writes
        let proposed = try await service.check(now: Self.at)
        #expect(proposed.concepts.count == 1)
        #expect(graph.writes == before)
        #expect(graph.entities(of: "Concept").isEmpty)
        let store = GraphLearnedStore(graph: graph)
        #expect(try await store.related(to: "write a short answer about the length").isEmpty)
        // Rejecting it writes the refusal only, still no Concept.
        try await service.reject(concept: try #require(proposed.concepts.first))
        #expect(graph.entities(of: "Concept").isEmpty)
        #expect(try await service.check(now: Self.at).concepts.isEmpty)
    }

    /// Recall-style search on the Concept's own keywords finds an approved one; one never approved is not there to find.
    @Test func anApprovedConceptIsFoundByItsKeywordsAndAnUnapprovedOneIsNot() async throws {
        let graph = FakeGraph()
        let store = try await Self.approvedConcept(graph)
        let concept = try #require(try await store.concepts().first)
        #expect(concept.live && !concept.keywords.isEmpty)
        for word in concept.keywords {
            let hits = try await graph.run("recall", ["q": .string(word)])
            #expect((hits.array ?? []).contains { $0["node_type"]?.string == "Concept" }, "\(word)")
        }
        #expect(graph.entities(of: "Concept") == ["Keep answers short"])
        // A proposal that was never approved has no node: nothing to recall by its words.
        let hits = try await graph.run("recall", ["q": "unapproved-proposal-word"])
        #expect((hits.array ?? []).isEmpty)
    }

    /// Strut's memory refusing the types says so in plain words; nothing is half-written as a crash.
    @Test func aMemoryThatDoesNotKnowTheTypesSaysSoInPlainWords() async throws {
        let graph = FakeGraph()
        graph.refuseRemember = true
        let store = GraphLearnedStore(graph: graph)
        do {
            _ = try await store.keep(Self.leaf("a", Self.good))
            Issue.record("expected a refusal")
        } catch let refusal as LearnedRefusal {
            #expect(refusal.description == GraphLearnedStore.unsupported)
            #expect(!refusal.description.lowercased().contains("cause") && !refusal.description.lowercased().contains("graph"))
        }
    }

    // MARK: Evidence is an edge

    @Test func evidenceIsAFactToATurnEntityNotAStringOnTheHabit() async throws {
        let graph = FakeGraph()
        let store = GraphLearnedStore(graph: graph)
        var leaf = Self.leaf("n", Self.good)
        leaf.evidence = [CauseEvidence(turn: "run-7", excerpt: "no, shorter", confidence: 0.6, kind: "follow_up", why: "pushed back",
                                       previousRef: "msg-1", turnAt: Self.at)]
        let kept = try await store.keep(leaf)
        let edge = try #require(graph.facts("EVIDENCED_BY").first)
        #expect(edge.subject == kept.id && edge.objectType == "Turn" && edge.objectName == "run-7" && edge.text == "no, shorter")
        let payload = try JSONValue(parsing: try #require(edge.value))
        #expect(payload["kind"]?.string == "follow_up" && payload["why"]?.string == "pushed back" && payload["previous_ref"]?.string == "msg-1")
        // The habit's own record holds no evidence and no turn.
        let record = try #require(graph.facts(Self.recordPredicate).first { $0.subject == kept.id }).text
        #expect(!record.contains("run-7") && !record.contains("evidence") && !record.contains("excerpt"))
        // And it reads back from the edge.
        let back = try #require(try await store.causes().first)
        #expect(back.evidence.first?.excerpt == "no, shorter" && back.evidence.first?.turn == "run-7" && back.evidence.first?.previousRef == "msg-1")
    }

    @Test func aThemeHasNoEvidenceAndPointsFromItsChildren() async throws {
        let graph = FakeGraph()
        let store = GraphLearnedStore(graph: graph)
        let a = try await store.keep(Self.leaf("a", Self.good)), b = try await store.keep(Self.leaf("b", Self.other))
        let parent = try await store.group(Grouping(theme: Self.theme, leaves: [a, b]))
        #expect(graph.facts("EVIDENCED_BY").allSatisfy { $0.subject != parent.id })
        let links = graph.facts("CAUSE_CHILD_OF")
        #expect(links.count == 2 && links.allSatisfy { $0.objectName == parent.statement && [a.id, b.id].contains($0.subject) })
        // A habit with nothing that showed it is refused: evidence belongs on leaves.
        var bare = Self.leaf("x", "When I ask for a list, the assistant writes prose.")
        bare.evidence = []
        await #expect(throws: LearnedRefusal.self) { try await store.keep(bare) }
    }

    @Test func aDictationFixIsATurnNamedByItsTime() async throws {
        let signal = LearnedDetector.dictated(typed: "stack work", edited: "Stakwork", at: Self.at)
        #expect(signal.turn == "dictation/1800000000")
        let graph = FakeGraph()
        var leaf = Self.leaf("d", "When I dictate a company name, the assistant writes it as two words.")
        leaf.evidence[0].turn = signal.turn
        _ = try await GraphLearnedStore(graph: graph).keep(leaf)
        #expect(graph.facts("EVIDENCED_BY").first?.objectName == "dictation/1800000000")
        #expect(graph.entities(of: "Turn").first == "dictation/1800000000")
    }

    // MARK: The judge's wire

    @Test func theJudgesAnswersAreReadStrictly() throws {
        let words = try AgentKit.JSONValue(parsing: #"{"items":[{"candidate":"c1","statement":"s","cause_type":"prompt_gap","severity":"low"},{"candidate":"c2","statement":"s","cause_type":"nonsense","severity":"low"}]}"#)
        #expect(StrutLearnedJudge.drafts(from: words).map(\.candidate) == ["c1"])
        let themes = try AgentKit.JSONValue(parsing: #"{"themes":[{"statement":"s","cause_type":"correction","severity":"high","leaves":["a","b"],"existing":"","needs_different_fixes":true}]}"#)
        let read = StrutLearnedJudge.themes(from: themes)
        #expect(read.count == 1 && read[0].existing == nil && read[0].leaves == ["a", "b"] && read[0].needsDifferentFixes)
        #expect(LearnedWorkflows.judges.allSatisfy { LearnedWorkflows.yaml($0).contains("agentTools: []") })
    }

    /// The daily check can only read memory and ships off, on a daily trigger.
    @Test func theDailyCheckIsReadOnlyAndShipsOff() throws {
        let yaml = LearnedWorkflows.yaml(LearnedWorkflows.check)
        #expect(yaml.contains(#"agentTools: ["memory/recall", "memory/get"]"#))
        for write in ["memory/remember", "memory/forget", "memory/merge", "sphinx/", "job/start"] { #expect(!yaml.contains(write)) }
        #expect(AutomationsClient.learnedTrigger["every"]?.string == "day" && AutomationsClient.learnedTrigger["at"]?.array?.count == 1)
        #expect(LearnedWorkflows.all.contains(LearnedWorkflows.check) && AutomationsClient.version(of: yaml).hasPrefix("p-"))
    }

    /// Nothing about habits goes in the prompt: the memory prompt only says to recall.
    @Test func thePromptHoldsNoHabitsOnlyTheInstructionToRecall() throws {
        #expect(Orchestrator.memoryPrompt.contains("memory/recall the task's words for habit Concepts"))
        let json = try AgentKit.JSONValue(parsing: String(decoding: Orchestrator.hostConfig(personal: "A note."), as: UTF8.self))
        let system = try #require(json["orchestrator"]?["system"]?.string)
        #expect(system.contains("A note.") && !system.contains("Keep it short"))
    }
}

private extension PersonalConcept {
    /// The concept as its first write left it.
    var withNoPrior: PersonalConcept {
        var copy = self
        copy.prior = nil
        return copy
    }
}

/// A stand-in for Peel's strut's memory steps, as `GraphLearnedStore` uses them.
/// Entities and facts only (no per-edge properties); an identical fact is kept once.
final class FakeGraph: LearnedGraph, @unchecked Sendable {
    private let lock = NSLock()
    private struct Entity { var ref: String; var type: String; var name: String }
    struct Stored {
        var ref: String
        var subject: String
        var predicate: String
        var text: String
        var objectType: String?
        var objectName: String?
        var objectRef: String?
        var value: String?
    }
    private var entityList: [Entity] = []
    private var factList: [Stored] = []
    private var next = 0
    private(set) var writes = 0
    /// As a strut whose ontology lacks the types: every remember refused.
    var refuseRemember = false

    func facts(_ predicate: String) -> [Stored] { lock.withLock { factList.filter { $0.predicate == predicate } } }
    func entities(of type: String) -> [String] { lock.withLock { entityList.filter { $0.type == type }.map(\.name) } }

    func run(_ verb: String, _ arguments: JSONValue) async throws -> JSONValue {
        try lock.withLock {
            switch verb {
            case "remember":
                if refuseRemember { throw MemoryServer.Refusal(code: "unknown_type", description: "unknown_type: Cause") }
                writes += 1
                var out: [JSONValue] = [], written: [JSONValue] = []
                for entity in arguments["entities"]?.array ?? [] {
                    let name = entity["name"]?.string ?? "", type = entity["type"]?.string ?? ""
                    let found = entityList.first { $0.name == name && $0.type == type } ?? make(type, name)
                    out.append(["ref_id": .string(found.ref), "type": .string(type), "name": .string(name)])
                }
                for fact in arguments["facts"]?.array ?? [] {
                    guard let subject = entityList.first(where: { $0.name == fact["subject"]?.string }) else { continue }
                    let object = fact["object"]?.string.flatMap { name in entityList.first { $0.name == name } }
                    var made = Stored(ref: "", subject: subject.ref, predicate: fact["predicate"]?.string ?? "", text: fact["text"]?.string ?? "",
                                      objectType: object?.type, objectName: object?.name, objectRef: object?.ref, value: fact["value"]?.string)
                    if let same = factList.first(where: {
                        $0.subject == made.subject && $0.predicate == made.predicate && $0.text == made.text && $0.objectRef == made.objectRef
                            && $0.value == made.value
                    }) {
                        made.ref = same.ref
                    } else {
                        next += 1
                        made.ref = "f\(next)"
                        factList.append(made)
                    }
                    written.append(["ref_id": .string(made.ref), "predicate": .string(made.predicate), "text": .string(made.text)])
                }
                return ["entities": .array(out), "facts": .array(written)]
            case "get":
                let ref = arguments["ref_id"]?.string ?? ""
                guard let entity = entityList.first(where: { $0.ref == ref }) else {
                    throw MemoryServer.Refusal(code: "not_found", description: "not_found: \(ref)")
                }
                let own = factList.filter { $0.subject == ref }.map { fact -> JSONValue in
                    var value: [String: JSONValue] = ["ref_id": .string(fact.ref), "predicate": .string(fact.predicate), "text": .string(fact.text)]
                    if let name = fact.objectName, let objectRef = fact.objectRef { value["object"] = ["ref_id": .string(objectRef), "name": .string(name)] }
                    if let payload = fact.value { value["value"] = .string(payload) }
                    return .object(value)
                }
                return ["ref_id": .string(ref), "node_type": .string(entity.type), "name": .string(entity.name), "facts": .array(own)]
            case "recall":
                // An exact name, or any word of the query found in an entity's name or its facts' words.
                let q = arguments["q"]?.string ?? ""
                let words = q.lowercased().split(separator: " ").map(String.init)
                let hits = entityList.filter { entity in
                    if entity.name == q { return true }
                    let haystack = ([entity.name] + factList.filter { $0.subject == entity.ref }.map(\.text)).joined(separator: " ").lowercased()
                    return words.contains { haystack.contains($0) }
                }
                return .array(hits.map { ["ref_id": .string($0.ref), "name": .string($0.name), "node_type": .string($0.type)] })
            case "forget":
                let ref = arguments["ref_id"]?.string ?? ""
                entityList.removeAll { $0.ref == ref }
                factList.removeAll { $0.ref == ref || $0.subject == ref }
                return ["forgotten": true]
            default:
                throw MemoryServer.Refusal(code: "bad_request", description: "bad_request: \(verb)")
            }
        }
    }

    private func make(_ type: String, _ name: String) -> Entity {
        next += 1
        let entity = Entity(ref: "e\(next)", type: type, name: name)
        entityList.append(entity)
        return entity
    }
}
