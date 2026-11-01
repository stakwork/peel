import AgentKit
import Foundation

/// Where "What it learned" keeps Causes and Concepts: the person's own graph
/// on Peel's own strut (the memory the assistant already has), one graph for
/// work and personal habits. Never a workspace's graph, never Hive.
public protocol LearnedStore: Sendable {
    func causes() async throws -> [PersonalCause]
    func concepts() async throws -> [PersonalConcept]
    func rejections() async throws -> [RejectedGrouping]
    /// Rejected habits' identity keys: never proposed as a habit again.
    func rejectedHabits() async throws -> Set<String>

    /// A leaf kept: a repeat (same `identityKey`) attaches its evidence to the
    /// Cause that exists, and a rejected one is not brought back.
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

/// The store over Peel's strut's memory steps (`memory/remember`, `get`,
/// `forget`). The shapes: a Cause is an entity of type `Cause` named by its
/// statement, a Concept one of type `Concept`; each holds one `learned_record`
/// fact (its fields as JSON: the Cause's `cause_type`, `severity`, `mechanism`,
/// `identity_key`, `status` and its `EVIDENCED_BY` edges' fields) and the edges
/// are facts with the predicates `evidenced_by` (to a `Turn` entity) and
/// `cause_child_of` (child to parent), `answers` (Concept to its theme).
/// An index entity lists the ids, since the memory steps have no list verb.
/// `init(server:)` takes a MemoryServer and nothing else: the personal path
/// can reach no other strut and no workspace.
public actor GraphLearnedStore: LearnedStore {
    private let graph: any LearnedGraph

    public init(server: MemoryServer) { graph = server }
    init(graph: any LearnedGraph) { self.graph = graph }

    static let record = "learned_record"
    static let indexName = "What it learned"

    // MARK: Wire

    private struct Index: Codable { var refs: [String: String] = [:] }   // ref_id: type

    /// One node as stored: its record's JSON and its facts' ids.
    private struct Node {
        var ref: String
        var record: AgentKit.JSONValue
        var recordFacts: [String]
        var edges: [AgentKit.JSONValue]
    }

    private func read(_ ref: String) async throws -> Node? {
        let output: AgentKit.JSONValue
        do { output = try await graph.run("get", ["ref_id": .string(ref)]) } catch let refusal as MemoryServer.Refusal where refusal.code == "not_found" {
            return nil
        }
        let facts = output["facts"]?.array ?? []
        let records = facts.filter { $0["predicate"]?.string == Self.record }
        // A newer record is last; any other is an older one to drop.
        guard let last = records.last, let text = last["text"]?.string, let record = try? AgentKit.JSONValue(parsing: text) else { return nil }
        return Node(ref: ref, record: record, recordFacts: records.compactMap { $0["ref_id"]?.string },
                    edges: facts.filter { $0["predicate"]?.string != Self.record })
    }

    private func index() async throws -> (ref: String?, index: Index) {
        let output: AgentKit.JSONValue
        do { output = try await graph.run("recall", ["q": .string(Self.indexName)]) } catch let refusal as MemoryServer.Refusal where refusal.code == "not_found" {
            return (nil, Index())
        }
        let found = (output.array ?? []).first { $0["name"]?.string == Self.indexName && $0["node_type"]?.string == "LearnedIndex" }
        guard let ref = found?["ref_id"]?.string, let node = try await read(ref),
              let refs = node.record["refs"]?.object else { return (found?["ref_id"]?.string, Index()) }
        return (ref, Index(refs: refs.compactMapValues(\.string)))
    }

    /// Writes one node's record (and edges), dropping the record it replaces.
    /// Returns the node's ref_id and the ids of the edge facts written.
    @discardableResult
    private func write(type: String, name: String, ref: String?, record: [String: AgentKit.JSONValue],
                       edges: [(predicate: String, objectType: String, object: String, text: String)] = []) async throws -> (ref: String, edges: [String]) {
        let old: Node? = if let ref { try await read(ref) } else { nil }
        var entities: [AgentKit.JSONValue] = [["name": .string(name), "type": .string(type)]]
        var facts: [AgentKit.JSONValue] = [["subject": .string(name), "predicate": .string(Self.record),
                                            "text": .string(AgentKit.JSONValue.object(record).jsonString)]]
        for edge in edges {
            entities.append(["name": .string(edge.object), "type": .string(edge.objectType)])
            facts.append(["subject": .string(name), "predicate": .string(edge.predicate), "object": .string(edge.object),
                          "text": .string(edge.text)])
        }
        let output = try await graph.run("remember", ["episode": .string("What it learned: \(name)"),
                                                      "entities": .array(entities), "facts": .array(facts)])
        guard let node = (output["entities"]?.array ?? []).first(where: { $0["name"]?.string == name && $0["type"]?.string == type }),
              let id = node["ref_id"]?.string else { throw PeelError("Memory did not keep that.") }
        let written = (output["facts"]?.array ?? [])
        let newRecord = written.first { $0["predicate"]?.string == Self.record }?["ref_id"]?.string
        for stale in old?.recordFacts ?? [] where stale != newRecord { _ = try? await graph.run("forget", ["ref_id": .string(stale)]) }
        let edgeRefs = written.filter { $0["predicate"]?.string != Self.record }.compactMap { $0["ref_id"]?.string }
        var (_, list) = try await index()
        if list.refs[id] != type {
            list.refs[id] = type
            try await writeIndex(list)
        }
        return (id, edgeRefs)
    }

    private func writeIndex(_ list: Index) async throws {
        let record: [String: AgentKit.JSONValue] = ["refs": .object(list.refs.mapValues(AgentKit.JSONValue.string))]
        let (ref, _) = try await index()
        let old: Node? = if let ref { try await read(ref) } else { nil }
        let output = try await graph.run("remember", [
            "episode": "What it learned: the list of what is kept",
            "entities": [["name": .string(Self.indexName), "type": "LearnedIndex"]],
            "facts": [["subject": .string(Self.indexName), "predicate": .string(Self.record),
                       "text": .string(AgentKit.JSONValue.object(record).jsonString)]],
        ])
        let new = (output["facts"]?.array ?? []).first { $0["predicate"]?.string == Self.record }?["ref_id"]?.string
        for stale in old?.recordFacts ?? [] where stale != new { _ = try? await graph.run("forget", ["ref_id": .string(stale)]) }
    }

    // MARK: Records

    static func json(_ cause: PersonalCause) -> [String: AgentKit.JSONValue] {
        var record: [String: AgentKit.JSONValue] = [
            "kind": "cause", "statement": .string(cause.statement), "cause_type": .string(cause.causeType.rawValue),
            "severity": .string(cause.severity.rawValue), "identity_key": .string(cause.identityKey),
            "status": .string(cause.status.rawValue), "parent": cause.parent.map(AgentKit.JSONValue.string) ?? .null,
            "evidence": .array(cause.evidence.map { json($0) }),
        ]
        if let mechanism = cause.mechanism { record["mechanism"] = .string(mechanism) }
        return record
    }

    static func json(_ evidence: CauseEvidence) -> AgentKit.JSONValue {
        var value: [String: AgentKit.JSONValue] = [
            "turn": .string(evidence.turn), "excerpt": .string(evidence.excerpt), "confidence": .number(evidence.confidence),
            "kind": .string(evidence.kind), "why": .string(evidence.why),
        ]
        if let ref = evidence.previousRef { value["previous_ref"] = .string(ref) }
        if let at = evidence.turnAt { value["turn_at"] = .number(at.timeIntervalSince1970) }
        return .object(value)
    }

    static func cause(ref: String, _ record: AgentKit.JSONValue) -> PersonalCause? {
        guard record["kind"]?.string == "cause", let statement = record["statement"]?.string,
              let type = record["cause_type"]?.string.flatMap(CauseType.init), let severity = record["severity"]?.string.flatMap(CauseSeverity.init)
        else { return nil }
        let evidence = (record["evidence"]?.array ?? []).compactMap { value -> CauseEvidence? in
            guard let turn = value["turn"]?.string, let excerpt = value["excerpt"]?.string, let kind = value["kind"]?.string else { return nil }
            var confidence = 0.5
            if case .number(let number)? = value["confidence"] { confidence = number }
            var at: Date?
            if case .number(let seconds)? = value["turn_at"] { at = Date(timeIntervalSince1970: seconds) }
            return CauseEvidence(turn: turn, excerpt: excerpt, confidence: confidence, kind: kind, why: value["why"]?.string ?? "",
                                 previousRef: value["previous_ref"]?.string, turnAt: at)
        }
        return PersonalCause(id: ref, statement: statement, causeType: type, severity: severity, mechanism: record["mechanism"]?.string,
                             status: record["status"]?.string.flatMap(CauseStatus.init) ?? .active, parent: record["parent"]?.string,
                             evidence: evidence)
    }

    static func concept(ref: String, _ record: AgentKit.JSONValue) -> PersonalConcept? {
        guard record["kind"]?.string == "concept", let name = record["name"]?.string, let guidance = record["guidance"]?.string,
              let cause = record["cause"]?.string else { return nil }
        var live = false
        if case .bool(let value)? = record["live"] { live = value }
        var prior: PersonalConcept.Prior?
        if let before = record["prior"], let name = before["name"]?.string, let guidance = before["guidance"]?.string {
            var was = false
            if case .bool(let value)? = before["live"] { was = value }
            prior = .init(name: name, guidance: guidance, live: was)
        }
        return PersonalConcept(id: ref, name: name, guidance: guidance, cause: cause, live: live, prior: prior)
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
        try await nodes(of: "Cause").compactMap { Self.cause(ref: $0.ref, $0.record) }
    }

    public func concepts() async throws -> [PersonalConcept] {
        try await nodes(of: "Concept").compactMap { Self.concept(ref: $0.ref, $0.record) }
    }

    public func rejections() async throws -> [RejectedGrouping] {
        try await nodes(of: "LearnedRejection").compactMap { node in
            guard node.record["rejected"]?.string == "grouping", let keys = node.record["leaf_keys"]?.array else { return nil }
            return RejectedGrouping(leafKeys: Set(keys.compactMap(\.string)), parent: node.record["parent"]?.string)
        }
    }

    public func rejectedHabits() async throws -> Set<String> {
        Set(try await nodes(of: "LearnedRejection").compactMap { $0.record["rejected"]?.string == "habit" ? $0.record["identity_key"]?.string : nil })
    }

    // MARK: Writes

    public func keep(_ leaf: PersonalCause) async throws -> PersonalCause {
        try CauseRules.validate(leaf.statement)
        let all = try await causes()
        if try await rejectedHabits().contains(leaf.identityKey) { throw LearnedRefusal("You said no to this one before.") }
        var cause = leaf
        cause.status = .active
        if var existing = all.first(where: { $0.identityKey == leaf.identityKey }) {
            // A repeat attaches to the Cause it names, one edge per turn.
            for evidence in leaf.evidence where !existing.evidence.contains(where: { $0.turn == evidence.turn && $0.kind == evidence.kind }) {
                existing.evidence.append(evidence)
            }
            cause = existing
        }
        let edges = cause.evidence.map { (predicate: "evidenced_by", objectType: "Turn", object: $0.turn, text: $0.excerpt) }
        let written = try await write(type: "Cause", name: cause.statement, ref: all.first { $0.identityKey == leaf.identityKey }?.id,
                                      record: Self.json(cause), edges: edges)
        cause.id = written.ref
        return cause
    }

    public func group(_ grouping: Grouping) async throws -> PersonalCause {
        let all = try await causes()
        var parent: PersonalCause
        if let existing = grouping.theme.existing, let found = all.first(where: { $0.id == existing }) {
            parent = found
        } else {
            let made = PersonalCause(id: "", statement: grouping.theme.statement, causeType: grouping.theme.causeType,
                                     severity: grouping.theme.severity, mechanism: grouping.theme.mechanism, status: .active)
            try CauseRules.validate(made.statement)
            // Evidence stays on the leaves: the parent has none.
            parent = made
            parent.id = try await write(type: "Cause", name: made.statement, ref: nil, record: Self.json(made)).ref
        }
        for leaf in grouping.leaves {
            guard var current = all.first(where: { $0.id == leaf.id }), current.parent == nil else { continue }
            current.parent = parent.id
            try await write(type: "Cause", name: current.statement, ref: current.id, record: Self.json(current),
                            edges: [("cause_child_of", "Cause", parent.statement, "\(current.statement) \u{2192} \(parent.statement)")])
        }
        return parent
    }

    public func ungroup(parent: String, leaves: [String]) async throws {
        let all = try await causes()
        for id in leaves {
            guard var leaf = all.first(where: { $0.id == id }), leaf.parent == parent else { continue }
            leaf.parent = nil
            // The edge fact is superseded by the record's rewrite; drop it too.
            if let node = try await read(id) {
                for edge in node.edges where edge["predicate"]?.string == "cause_child_of" {
                    if let ref = edge["ref_id"]?.string { _ = try? await graph.run("forget", ["ref_id": .string(ref)]) }
                }
            }
            try await write(type: "Cause", name: leaf.statement, ref: id, record: Self.json(leaf))
        }
        // A theme made for these leaves goes once none is left under it.
        if !all.contains(where: { $0.parent == parent && !leaves.contains($0.id) }) { try await forget(parent) }
    }

    private func forget(_ ref: String) async throws {
        _ = try await graph.run("forget", ["ref_id": .string(ref)])
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

    public func save(_ concept: PersonalConcept) async throws -> PersonalConcept {
        var saved = concept
        let existing = try await concepts().first { $0.name == concept.name }
        saved.prior = existing.map { .init(name: $0.name, guidance: $0.guidance, live: $0.live) }
        let ref = existing?.id
        let parent = try await causes().first { $0.id == concept.cause }
        saved.id = try await write(type: "Concept", name: saved.name, ref: ref, record: Self.json(saved),
                                   edges: parent.map { [("answers", "Cause", $0.statement, "\(saved.name) answers \($0.statement)")] } ?? []).ref
        return saved
    }

    static func json(_ concept: PersonalConcept) -> [String: AgentKit.JSONValue] {
        var record: [String: AgentKit.JSONValue] = [
            "kind": "concept", "name": .string(concept.name), "guidance": .string(concept.guidance),
            "cause": .string(concept.cause), "live": .bool(concept.live),
        ]
        if let prior = concept.prior {
            record["prior"] = ["name": .string(prior.name), "guidance": .string(prior.guidance), "live": .bool(prior.live)]
        }
        return record
    }

    public func undo(_ concept: PersonalConcept) async throws {
        guard let prior = concept.prior else { try await forget(concept.id); return }
        var restored = concept
        restored.name = prior.name
        restored.guidance = prior.guidance
        restored.live = prior.live
        restored.prior = nil
        try await write(type: "Concept", name: restored.name, ref: concept.id, record: Self.json(restored))
    }
}
