import AgentKit
import Foundation
import PeelCore

/// Where "What it learned" keeps Causes and Concepts: the person's own graph
/// on Peel's own strut (the memory the assistant already has), one graph for
/// work and personal habits. Never a workspace's graph, never Hive.
public protocol LearnedStore: Sendable {
    func causes() async throws -> [PersonalCause]
    func concepts() async throws -> [PersonalConcept]
    func rejections() async throws -> [RejectedGrouping]
    /// Rejected habits' identity keys: never proposed as a habit again.
    func rejectedHabits() async throws -> Set<String>

    /// A leaf kept (it needs evidence: only a leaf has any): a repeat (same
    /// `identityKey`) attaches its evidence to the Cause that exists, and a
    /// rejected one is not brought back.
    func keep(_ leaf: PersonalCause) async throws -> PersonalCause
    /// A theme approved: its parent Cause (made, or the existing one) and
    /// `CAUSE_CHILD_OF` from each leaf to it. Returns the parent.
    func group(_ grouping: Grouping) async throws -> PersonalCause
    /// Takes a theme apart: the leaves stay, the parent made for it goes
    /// (an existing one only loses these children).
    func ungroup(parent: String, leaves: [String]) async throws
    func reject(grouping: RejectedGrouping) async throws
    func reject(habit identityKey: String) async throws
    /// Writes a Concept (its `prior` is the one that was there, set here).
    func save(_ concept: PersonalConcept) async throws -> PersonalConcept
    /// Undo: the prior state back, or the Concept gone when the write made it.
    func undo(_ concept: PersonalConcept) async throws
}

/// The graph's own verbs, which is all the store needs from strut.
public protocol LearnedGraph: Sendable {
    func run(_ verb: String, _ arguments: AgentKit.JSONValue) async throws -> AgentKit.JSONValue
}

extension MemoryServer: LearnedGraph {}

/// Words for a Concept's keywords and for the recall query a related task makes.
public enum LearnedWords {
    static let skip: Set<String> = ["that", "this", "with", "from", "when", "then", "than", "them", "they", "have", "will", "your", "what",
                                    "should", "would", "could", "about", "into", "just", "also", "the", "and", "for", "assistant",
                                    "please", "need", "want", "make", "some", "more", "like", "does", "only", "keep", "mind"]

    /// The significant words of `texts`, commonest first, at most `limit`.
    public static func keywords(_ texts: [String], limit: Int = 8) -> [String] {
        var counts: [String: Int] = [:], order: [String: Int] = [:]
        for text in texts {
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) where word.count >= 4 && !skip.contains(word) {
                counts[word, default: 0] += 1
                if order[word] == nil { order[word] = order.count }
            }
        }
        return counts.keys.sorted { (counts[$0]!, order[$1]!) > (counts[$1]!, order[$0]!) }.prefix(limit).map { $0 }
    }

    /// What `memory/recall` is asked for a task: its significant words.
    public static func recallQuery(for task: String) -> String {
        var seen = Set<String>()
        return task.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count >= 4 && !skip.contains($0) && seen.insert($0).inserted }.prefix(8).joined(separator: " ")
    }
}

/// The store over Peel's strut's memory steps (`memory/remember`, `get`,
/// `recall`, `forget`), and nothing else. What it writes, in the memory's own
/// model of entities and facts (no per-edge properties):
/// - a Cause is an entity of type `Cause` named by its statement, with one
///   `learned_record` fact (its fields as JSON: `cause_type`, `severity`,
///   `mechanism`, `identity_key`, `status`; never its evidence or parent);
/// - evidence is a real edge: a fact with predicate `EVIDENCED_BY`, subject
///   the leaf Cause, object an entity of type `Turn` named by the
///   orchestrator turn (the run's id on Peel's strut; for a dictation fix,
///   `dictation/<time>`, which has no orchestrator turn). The fact's text is
///   the excerpt and its `value` is the edge's other fields as JSON
///   (`EvidencePayload`: confidence, kind, why, previous_ref, turn_at);
/// - a theme is the same: a parent Cause with no evidence, and each child's
///   fact `CAUSE_CHILD_OF` (subject child, object parent);
/// - a Concept is an entity of type `Concept` named by its short name, with a
///   `statement` fact, a `keywords` fact, `about` facts to `Topic` entities, an
///   `answers` fact to the theme it answers, and a `learned_record` (live,
///   prior state). Only an approved Concept is ever written;
/// - an index entity lists the ids, since the memory steps have no list verb.
/// The types and the predicates `EVIDENCED_BY`, `CAUSE_CHILD_OF`, `answers`,
/// `about` are not in strut's ontology until its migration (docs/learned.md);
/// until then strut keeps them as proposed. `init(server:)` takes a
/// MemoryServer and nothing else: the personal path can reach no other strut
/// and no workspace.
public actor GraphLearnedStore: LearnedStore {
    private let graph: any LearnedGraph

    public init(server: MemoryServer) { graph = server }
    init(graph: any LearnedGraph) { self.graph = graph }

    static let record = "learned_record"
    static let indexName = "What it learned"

    // MARK: Wire

    /// What the person is told when strut's memory refuses the types or edges Peel
    /// writes (its migration is not in yet): plain words, never a crash.
    public static let unsupported = "Your assistant's memory on this Mac cannot keep habits yet. It needs an update first."

    /// One memory step. A refusal other than "not found" means strut does not
    /// know the types or edges, said in plain words (`unsupported`).
    private func run(_ verb: String, _ arguments: AgentKit.JSONValue) async throws -> AgentKit.JSONValue {
        do { return try await graph.run(verb, arguments) } catch let refusal as MemoryServer.Refusal {
            if refusal.code == "not_found" { throw refusal }
            throw LearnedRefusal(Self.unsupported)
        }
    }

    private struct Index { var refs: [String: String] = [:] }   // ref_id: type

    /// One node as stored.
    private struct Node {
        var ref: String
        var record: AgentKit.JSONValue?
        var facts: [AgentKit.JSONValue]
        func facts(_ predicate: String) -> [AgentKit.JSONValue] { facts.filter { $0["predicate"]?.string == predicate } }
    }

    /// One fact to write: about the node, or an edge to `object`.
    private struct Edge {
        var predicate: String
        var text: String
        var object: (type: String, name: String)?
        /// Carried in the fact's `value` as JSON.
        var payload: AgentKit.JSONValue?
    }

    private func read(_ ref: String) async throws -> Node? {
        let output: AgentKit.JSONValue
        do { output = try await run("get", ["ref_id": .string(ref)]) } catch let refusal as MemoryServer.Refusal where refusal.code == "not_found" {
            return nil
        }
        let facts = output["facts"]?.array ?? []
        // A newer record is last; an older one is dropped on the next write.
        let record = facts.last { $0["predicate"]?.string == Self.record }.flatMap { $0["text"]?.string }
            .flatMap { try? AgentKit.JSONValue(parsing: $0) }
        return Node(ref: ref, record: record, facts: facts)
    }

    private func index() async throws -> (ref: String?, index: Index) {
        let output: AgentKit.JSONValue
        do { output = try await run("recall", ["q": .string(Self.indexName)]) } catch let refusal as MemoryServer.Refusal where refusal.code == "not_found" {
            return (nil, Index())
        }
        let found = (output.array ?? []).first { $0["name"]?.string == Self.indexName && $0["node_type"]?.string == "LearnedIndex" }
        guard let ref = found?["ref_id"]?.string, let node = try await read(ref),
              let refs = node.record?["refs"]?.object else { return (found?["ref_id"]?.string, Index()) }
        return (ref, Index(refs: refs.compactMapValues(\.string)))
    }

    /// Writes one node: its record (when given) and facts, then drops the
    /// older facts of the predicates in `replacing` that these replace.
    /// Returns the node's ref_id.
    @discardableResult
    private func write(type: String, name: String, ref: String?, record: [String: AgentKit.JSONValue]?, edges: [Edge] = [],
                       replacing: Set<String> = []) async throws -> String {
        let old: Node? = if let ref, !replacing.isEmpty { try await read(ref) } else { nil }
        var entities: [AgentKit.JSONValue] = [["name": .string(name), "type": .string(type)]]
        var facts: [AgentKit.JSONValue] = []
        if let record {
            facts.append(["subject": .string(name), "predicate": .string(Self.record), "text": .string(AgentKit.JSONValue.object(record).jsonString)])
        }
        for edge in edges {
            var fact: [String: AgentKit.JSONValue] = ["subject": .string(name), "predicate": .string(edge.predicate), "text": .string(edge.text)]
            if let object = edge.object {
                entities.append(["name": .string(object.name), "type": .string(object.type)])
                fact["object"] = .string(object.name)
            }
            if let payload = edge.payload { fact["value"] = .string(payload.jsonString) }
            facts.append(.object(fact))
        }
        guard !facts.isEmpty else { return ref ?? "" }
        let output = try await run("remember", ["episode": .string("What it learned: \(name)"),
                                                      "entities": .array(entities), "facts": .array(facts)])
        guard let node = (output["entities"]?.array ?? []).first(where: { $0["name"]?.string == name && $0["type"]?.string == type }),
              let id = node["ref_id"]?.string else { throw PeelError("Memory did not keep that.") }
        let kept = Set((output["facts"]?.array ?? []).compactMap { $0["ref_id"]?.string })
        for stale in old?.facts ?? [] where replacing.contains(stale["predicate"]?.string ?? "") {
            if let staleRef = stale["ref_id"]?.string, !kept.contains(staleRef) { _ = try? await run("forget", ["ref_id": .string(staleRef)]) }
        }
        var (_, list) = try await index()
        if list.refs[id] != type {
            list.refs[id] = type
            try await writeIndex(list)
        }
        return id
    }

    private func writeIndex(_ list: Index) async throws {
        let record: [String: AgentKit.JSONValue] = ["refs": .object(list.refs.mapValues(AgentKit.JSONValue.string))]
        let (ref, _) = try await index()
        let old: Node? = if let ref { try await read(ref) } else { nil }
        let output = try await run("remember", [
            "episode": "What it learned: the list of what is kept",
            "entities": [["name": .string(Self.indexName), "type": "LearnedIndex"]],
            "facts": [["subject": .string(Self.indexName), "predicate": .string(Self.record),
                       "text": .string(AgentKit.JSONValue.object(record).jsonString)]],
        ])
        let kept = Set((output["facts"]?.array ?? []).compactMap { $0["ref_id"]?.string })
        for stale in old?.facts(Self.record) ?? [] {
            if let staleRef = stale["ref_id"]?.string, !kept.contains(staleRef) { _ = try? await run("forget", ["ref_id": .string(staleRef)]) }
        }
    }

    // MARK: Records

    static func json(_ cause: PersonalCause) -> [String: AgentKit.JSONValue] {
        var record: [String: AgentKit.JSONValue] = [
            "kind": "cause", "statement": .string(cause.statement), "cause_type": .string(cause.causeType.rawValue),
            "severity": .string(cause.severity.rawValue), "identity_key": .string(cause.identityKey),
            "status": .string(cause.status.rawValue), "theme": .bool(cause.isTheme),
        ]
        if let mechanism = cause.mechanism { record["mechanism"] = .string(mechanism) }
        return record
    }

    /// An `EVIDENCED_BY` edge's fields beyond its excerpt (the fact's text),
    /// as the fact's `value`.
    static func payload(_ evidence: CauseEvidence) -> AgentKit.JSONValue {
        var value: [String: AgentKit.JSONValue] = [
            "edge": "EVIDENCED_BY", "turn": .string(evidence.turn), "confidence": .number(evidence.confidence),
            "kind": .string(evidence.kind), "why": .string(evidence.why),
        ]
        if let ref = evidence.previousRef { value["previous_ref"] = .string(ref) }
        if let at = evidence.turnAt { value["turn_at"] = .number(at.timeIntervalSince1970) }
        return .object(value)
    }

    private func edge(_ evidence: CauseEvidence) -> Edge {
        Edge(predicate: "EVIDENCED_BY", text: evidence.excerpt, object: ("Turn", evidence.turn), payload: Self.payload(evidence))
    }

    static func evidence(from fact: AgentKit.JSONValue) -> CauseEvidence? {
        let payload = fact["value"]?.string.flatMap { try? AgentKit.JSONValue(parsing: $0) }
        guard let turn = fact["object"]?["name"]?.string ?? payload?["turn"]?.string, let excerpt = fact["text"]?.string else { return nil }
        var confidence = 0.5
        if case .number(let number)? = payload?["confidence"] { confidence = number }
        var at: Date?
        if case .number(let seconds)? = payload?["turn_at"] { at = Date(timeIntervalSince1970: seconds) }
        return CauseEvidence(turn: turn, excerpt: excerpt, confidence: confidence, kind: payload?["kind"]?.string ?? "",
                             why: payload?["why"]?.string ?? "", previousRef: payload?["previous_ref"]?.string, turnAt: at)
    }

    private static func cause(_ node: Node) -> PersonalCause? {
        guard let record = node.record, record["kind"]?.string == "cause", let statement = record["statement"]?.string,
              let type = record["cause_type"]?.string.flatMap(CauseType.init), let severity = record["severity"]?.string.flatMap(CauseSeverity.init)
        else { return nil }
        return PersonalCause(id: node.ref, statement: statement, causeType: type, severity: severity, mechanism: record["mechanism"]?.string,
                             status: record["status"]?.string.flatMap(CauseStatus.init) ?? .active,
                             parent: node.facts("CAUSE_CHILD_OF").last?["object"]?["ref_id"]?.string,
                             evidence: node.facts("EVIDENCED_BY").compactMap(evidence(from:)),
                             isTheme: record["theme"] == .bool(true))
    }

    private static func concept(_ node: Node) -> PersonalConcept? {
        guard let record = node.record, record["kind"]?.string == "concept", let name = record["name"]?.string,
              let statement = record["statement"]?.string, let cause = record["cause"]?.string else { return nil }
        var live = false
        if case .bool(let value)? = record["live"] { live = value }
        var prior: PersonalConcept.Prior?
        if let before = record["prior"], let name = before["name"]?.string, let statement = before["statement"]?.string {
            var was = false
            if case .bool(let value)? = before["live"] { was = value }
            prior = .init(name: name, statement: statement, live: was)
        }
        let keywords = (record["keywords"]?.array ?? []).compactMap(\.string)
        return PersonalConcept(id: node.ref, name: name, statement: statement, cause: cause, live: live, keywords: keywords, prior: prior)
    }

    // MARK: Reads

    private func nodes(of type: String) async throws -> [Node] {
        var out: [Node] = []
        for (ref, kind) in try await index().index.refs where kind == type {
            if let node = try await read(ref) { out.append(node) }
        }
        return out
    }

    public func causes() async throws -> [PersonalCause] {
        try await nodes(of: "Cause").compactMap(Self.cause)
    }

    public func concepts() async throws -> [PersonalConcept] {
        try await nodes(of: "Concept").compactMap(Self.concept)
    }

    /// The live Concepts memory brings back for a task: what the assistant's
    /// own `memory/recall` of the task's words finds. An unapproved one is
    /// never written, so never found.
    public func related(to task: String) async throws -> [PersonalConcept] {
        let query = LearnedWords.recallQuery(for: task)
        guard !query.isEmpty else { return [] }
        let found = try await run("recall", ["q": .string(query)])
        var out: [PersonalConcept] = []
        for hit in found.array ?? [] where hit["node_type"]?.string == "Concept" {
            if let ref = hit["ref_id"]?.string, let node = try await read(ref), let concept = Self.concept(node), concept.live { out.append(concept) }
        }
        return out
    }

    public func rejections() async throws -> [RejectedGrouping] {
        try await nodes(of: "LearnedRejection").compactMap { node in
            guard node.record?["rejected"]?.string == "grouping", let keys = node.record?["leaf_keys"]?.array else { return nil }
            return RejectedGrouping(leafKeys: Set(keys.compactMap(\.string)), parent: node.record?["parent"]?.string)
        }
    }

    public func rejectedHabits() async throws -> Set<String> {
        Set(try await nodes(of: "LearnedRejection").compactMap { $0.record?["rejected"]?.string == "habit" ? $0.record?["identity_key"]?.string : nil })
    }

    // MARK: Writes

    public func keep(_ leaf: PersonalCause) async throws -> PersonalCause {
        try CauseRules.validate(leaf.statement)
        // Evidence is on leaves alone: a habit with none is a theme, made by `group`.
        guard !leaf.evidence.isEmpty else { throw LearnedRefusal("A habit needs something that showed it.") }
        let all = try await causes()
        if try await rejectedHabits().contains(leaf.identityKey) { throw LearnedRefusal("You said no to this one before.") }
        guard var cause = all.first(where: { $0.identityKey == leaf.identityKey }) else {
            var made = leaf
            made.status = .active
            made.id = try await write(type: "Cause", name: made.statement, ref: nil, record: Self.json(made), edges: made.evidence.map(edge))
            return made
        }
        // A repeat attaches to the Cause it names, one edge per turn.
        let new = leaf.evidence.filter { e in !cause.evidence.contains { $0.turn == e.turn && $0.kind == e.kind } }
        try await write(type: "Cause", name: cause.statement, ref: cause.id, record: nil, edges: new.map(edge))
        cause.evidence += new
        return cause
    }

    public func group(_ grouping: Grouping) async throws -> PersonalCause {
        let all = try await causes()
        var parent: PersonalCause
        if let existing = grouping.theme.existing, let found = all.first(where: { $0.id == existing }) {
            parent = found
        } else {
            let made = PersonalCause(id: "", statement: grouping.theme.statement, causeType: grouping.theme.causeType,
                                     severity: grouping.theme.severity, mechanism: CauseRules.mechanism(grouping.theme.mechanism),
                                     status: .active, isTheme: true)
            try CauseRules.validate(made.statement)
            // A parent has no evidence: that stays on the leaves.
            parent = made
            parent.id = try await write(type: "Cause", name: made.statement, ref: nil, record: Self.json(made))
        }
        for leaf in grouping.leaves {
            guard let current = all.first(where: { $0.id == leaf.id }), current.parent == nil else { continue }
            try await write(type: "Cause", name: current.statement, ref: current.id, record: nil,
                            edges: [Edge(predicate: "CAUSE_CHILD_OF", text: "\(current.statement) \u{2192} \(parent.statement)",
                                         object: ("Cause", parent.statement))])
        }
        return parent
    }

    public func ungroup(parent: String, leaves: [String]) async throws {
        let all = try await causes()
        for id in leaves {
            guard let leaf = all.first(where: { $0.id == id }), leaf.parent == parent, let node = try await read(id) else { continue }
            for edge in node.facts("CAUSE_CHILD_OF") {
                if let ref = edge["ref_id"]?.string { _ = try await run("forget", ["ref_id": .string(ref)]) }
            }
        }
        // A theme goes once none is left under it.
        if !all.contains(where: { $0.parent == parent && !leaves.contains($0.id) }) { try await forget(parent) }
    }

    private func forget(_ ref: String) async throws {
        _ = try await run("forget", ["ref_id": .string(ref)])
        var (_, list) = try await index()
        list.refs[ref] = nil
        try await writeIndex(list)
    }

    public func reject(grouping: RejectedGrouping) async throws {
        let key = GroupingRules.key(leafKeys: Array(grouping.leafKeys), parent: grouping.parent)
        try await write(type: "LearnedRejection", name: "grouping \(key)", ref: nil, record: [
            "kind": "rejection", "rejected": "grouping", "leaf_keys": .array(grouping.leafKeys.sorted().map(AgentKit.JSONValue.string)),
            "parent": grouping.parent.map(AgentKit.JSONValue.string) ?? .null,
        ])
    }

    public func reject(habit identityKey: String) async throws {
        try await write(type: "LearnedRejection", name: "habit \(identityKey)", ref: nil,
                        record: ["kind": "rejection", "rejected": "habit", "identity_key": .string(identityKey)])
    }

    /// Writes a Concept (only ever one the person approved).
    public func save(_ concept: PersonalConcept) async throws -> PersonalConcept {
        var saved = concept
        let existing = try await concepts().first { $0.name == concept.name }
        saved.prior = existing.map { .init(name: $0.name, statement: $0.statement, live: $0.live) }
        let theme = try await causes().first { $0.id == concept.cause }
        if saved.keywords.isEmpty { saved.keywords = LearnedWords.keywords([concept.name, concept.statement, theme?.statement ?? ""]) }
        saved.id = try await write(type: "Concept", name: saved.name, ref: existing?.id, record: Self.json(saved),
                                   edges: Self.facts(of: saved, theme: theme), replacing: Self.conceptPredicates)
        return saved
    }

    static let conceptPredicates: Set<String> = [record, "statement", "keywords", "about", "answers"]

    /// What makes a Concept found by a related task: its statement and
    /// keywords as facts, topics it is about, and the theme it answers.
    private static func facts(of concept: PersonalConcept, theme: PersonalCause?) -> [Edge] {
        let keywords = concept.keywords.isEmpty ? LearnedWords.keywords([concept.name, concept.statement, theme?.statement ?? ""]) : concept.keywords
        var edges = [Edge(predicate: "statement", text: concept.statement, object: nil),
                     Edge(predicate: "keywords", text: "Keywords: " + keywords.joined(separator: ", "), object: nil)]
        edges += keywords.prefix(5).map { Edge(predicate: "about", text: "\(concept.name) is about \($0)", object: ("Topic", $0)) }
        if let theme { edges.append(Edge(predicate: "answers", text: "\(concept.name) answers: \(theme.statement)", object: ("Cause", theme.statement))) }
        return edges
    }

    static func json(_ concept: PersonalConcept) -> [String: AgentKit.JSONValue] {
        var record: [String: AgentKit.JSONValue] = [
            "kind": "concept", "name": .string(concept.name), "statement": .string(concept.statement),
            "cause": .string(concept.cause), "live": .bool(concept.live),
            "keywords": .array(concept.keywords.map(AgentKit.JSONValue.string)),
        ]
        if let prior = concept.prior {
            record["prior"] = ["name": .string(prior.name), "statement": .string(prior.statement), "live": .bool(prior.live)]
        }
        return record
    }

    public func undo(_ concept: PersonalConcept) async throws {
        guard let prior = concept.prior else { try await forget(concept.id); return }
        var restored = concept
        restored.name = prior.name
        restored.statement = prior.statement
        restored.live = prior.live
        restored.prior = nil
        let theme = try await causes().first { $0.id == concept.cause }
        restored.keywords = LearnedWords.keywords([restored.name, restored.statement, theme?.statement ?? ""])
        try await write(type: "Concept", name: restored.name, ref: concept.id, record: Self.json(restored),
                        edges: Self.facts(of: restored, theme: theme), replacing: Self.conceptPredicates)
    }
}
