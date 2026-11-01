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

        // No mechanism, or failures that need different fixes: not glued.
        var bare = Self.theme
        bare.mechanism = nil
        #expect(GroupingRules.admit([bare], leaves: [a, b], themes: [], rejected: []).groupings.isEmpty)
        let c = Self.leaf("b", Self.other, .formatViolation)
        #expect(GroupingRules.admit([Self.theme], leaves: [a, c], themes: [], rejected: []).groupings.isEmpty)

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
            ConceptDraft(name: "Keep it short", guidance: "Match the length the person asks for.")
        }
    }

    static func service(_ graph: FakeGraph, judge: Judge? = nil, lines: LineBox = LineBox()) -> LearnedService {
        let signals = [
            LearnedDetector.rejected(request: "r1/x", action: "Send", content: "long text", at: at),
            LearnedDetector.rejected(request: "r2/x", action: "Send", content: "another long text", at: at),
        ]
        return LearnedService(store: GraphLearnedStore(graph: graph),
                              judge: judge ?? Judge(statements: ["r1": good, "r2": other]),
                              signals: { signals }, changed: { lines.set($0) })
    }

    final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var line: String?
        func set(_ value: String?) { lock.withLock { line = value } }
        var value: String? { lock.withLock { line } }
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
        let lines = LineBox()
        let service = Self.service(graph, lines: lines)
        let theme = Self.leaf("t", Self.theme.statement)
        let v1 = try await service.approve(concept: ConceptProposal(theme: theme, name: "Keep it short", guidance: "Match the length asked for."))
        #expect(v1.prior == nil)
        #expect(lines.value?.contains("Keep it short") == true)

        let v2 = try await service.approve(concept: ConceptProposal(theme: theme, name: "Keep it short", guidance: "Answer in one paragraph."))
        #expect(v2.prior?.guidance == "Match the length asked for.")
        try await service.undo(concept: v2)
        let restored = try #require(try await service.concepts().first)
        #expect(restored.guidance == "Match the length asked for." && restored.live)
        #expect(try await service.concepts().count == 1)

        // Undoing the first write takes the concept away, and its line with it.
        try await service.undo(concept: restored.withNoPrior)
        #expect(try await service.concepts().isEmpty)
        #expect(lines.value == nil)
    }

    @Test func aConceptWithANameOrALongSentenceIsRefused() async throws {
        let service = Self.service(FakeGraph())
        let theme = Self.leaf("t", Self.theme.statement)
        await #expect(throws: LearnedRefusal.self) {
            try await service.approve(concept: ConceptProposal(theme: theme, name: "Ask Hive", guidance: "Be short."))
        }
        let long = (1...41).map { "w\($0)" }.joined(separator: " ")
        await #expect(throws: LearnedRefusal.self) {
            try await service.approve(concept: ConceptProposal(theme: theme, name: "Short", guidance: long))
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
            for forbidden in ["HiveClient", "HivePeer", "HiveLink", "pinnedApps", "run-workflow", "/peers/", "URLSession"] {
                #expect(!source.contains(forbidden), "\(file.lastPathComponent) names \(forbidden)")
            }
        }
    }

    @Test func theLiveConceptsReachThePersonalInstructions() throws {
        let live = PersonalConcept(id: "c", name: "Keep it short", guidance: "Match the length asked for.", cause: "t", live: true)
        let off = PersonalConcept(id: "d", name: "Hidden one", guidance: "Nope.", cause: "t", live: false)
        let line = try #require(LearnedInstructions.line(for: [live, off]))
        #expect(line.contains("Keep it short") && !line.contains("Hidden one"))
        let json = try AgentKit.JSONValue(parsing: String(decoding: Orchestrator.hostConfig(learned: line), as: UTF8.self))
        #expect(json["orchestrator"]?["system"]?.string?.contains("Keep it short") == true)
        #expect(LearnedInstructions.line(for: [off]) == nil)
    }

    // MARK: The judge's wire

    @Test func theJudgesAnswersAreReadStrictly() throws {
        let words = try AgentKit.JSONValue(parsing: #"{"items":[{"candidate":"c1","statement":"s","cause_type":"prompt_gap","severity":"low"},{"candidate":"c2","statement":"s","cause_type":"nonsense","severity":"low"}]}"#)
        #expect(StrutLearnedJudge.drafts(from: words).map(\.candidate) == ["c1"])
        let themes = try AgentKit.JSONValue(parsing: #"{"themes":[{"statement":"s","cause_type":"correction","severity":"high","leaves":["a","b"],"existing":""}]}"#)
        let read = StrutLearnedJudge.themes(from: themes)
        #expect(read.count == 1 && read[0].existing == nil && read[0].leaves == ["a", "b"])
        #expect(LearnedWorkflows.all.allSatisfy { LearnedWorkflows.yaml($0).contains("agentTools: []") })
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
final class FakeGraph: LearnedGraph, @unchecked Sendable {
    private let lock = NSLock()
    private struct Entity { var ref: String; var type: String; var name: String }
    private struct Fact { var ref: String; var subject: String; var predicate: String; var text: String }
    private var entities: [Entity] = []
    private var facts: [Fact] = []
    private var next = 0
    private(set) var writes = 0

    func run(_ verb: String, _ arguments: AgentKit.JSONValue) async throws -> AgentKit.JSONValue {
        try lock.withLock {
            switch verb {
            case "remember":
                writes += 1
                var out: [AgentKit.JSONValue] = [], written: [AgentKit.JSONValue] = []
                for entity in arguments["entities"]?.array ?? [] {
                    let name = entity["name"]?.string ?? "", type = entity["type"]?.string ?? ""
                    let found = entities.first { $0.name == name && $0.type == type } ?? make(type, name)
                    out.append(["ref_id": .string(found.ref), "type": .string(type), "name": .string(name)])
                }
                for fact in arguments["facts"]?.array ?? [] {
                    let subject = entities.first { $0.name == fact["subject"]?.string }
                    next += 1
                    let made = Fact(ref: "f\(next)", subject: subject?.ref ?? "", predicate: fact["predicate"]?.string ?? "",
                                    text: fact["text"]?.string ?? "")
                    facts.append(made)
                    written.append(["ref_id": .string(made.ref), "predicate": .string(made.predicate), "text": .string(made.text)])
                }
                return ["entities": .array(out), "facts": .array(written)]
            case "get":
                let ref = arguments["ref_id"]?.string ?? ""
                guard let entity = entities.first(where: { $0.ref == ref }) else {
                    throw MemoryServer.Refusal(code: "not_found", description: "not_found: \(ref)")
                }
                let own = facts.filter { $0.subject == ref }.map { fact -> AgentKit.JSONValue in
                    ["ref_id": .string(fact.ref), "predicate": .string(fact.predicate), "text": .string(fact.text)]
                }
                return ["ref_id": .string(ref), "node_type": .string(entity.type), "name": .string(entity.name), "facts": .array(own)]
            case "recall":
                let q = arguments["q"]?.string ?? ""
                return .array(entities.filter { $0.name == q }.map { ["ref_id": .string($0.ref), "name": .string($0.name), "node_type": .string($0.type)] })
            case "forget":
                let ref = arguments["ref_id"]?.string ?? ""
                entities.removeAll { $0.ref == ref }
                facts.removeAll { $0.ref == ref || $0.subject == ref }
                return ["forgotten": true]
            default:
                throw MemoryServer.Refusal(code: "bad_request", description: "bad_request: \(verb)")
            }
        }
    }

    private func make(_ type: String, _ name: String) -> Entity {
        next += 1
        let entity = Entity(ref: "e\(next)", type: type, name: name)
        entities.append(entity)
        return entity
    }
}
