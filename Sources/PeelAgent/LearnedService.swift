import Foundation

/// What a check found, none of it written.
public struct LearnedReport: Sendable, Equatable {
    /// New habits, each one the person may keep.
    public var habits: [PersonalCause] = []
    public var groupings: [Grouping] = []
    public var concepts: [ConceptProposal] = []
    /// A new habit and the one that already says nearly the same: reported, never merged.
    public var duplicates: [Duplicate] = []
    /// Corrections the model's words for were refused by the rules (count only).
    public var refused = 0

    public struct Duplicate: Sendable, Equatable {
        public var new: PersonalCause
        public var existing: PersonalCause
    }

    public var isEmpty: Bool { habits.isEmpty && groupings.isEmpty && concepts.isEmpty }
}

/// A concept the person may make live for an approved theme.
public struct ConceptProposal: Sendable, Equatable, Identifiable {
    public var theme: PersonalCause
    public var name: String
    public var guidance: String
    public var id: String { theme.id }
}

public enum ConceptRules {
    public static let maxWords = 40
    public static func validate(name: String, guidance: String) throws {
        let words = guidance.split(whereSeparator: \.isWhitespace)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !words.isEmpty, words.count <= maxWords,
              name.split(whereSeparator: \.isWhitespace).count <= 5 else {
            throw LearnedRefusal("A concept is a short name and one sentence of at most \(maxWords) words.")
        }
        let lower = (name + " " + guidance).lowercased()
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard tokens.isDisjoint(with: CauseRules.banned), !lower.contains("@"), !lower.contains("http") else {
            throw LearnedRefusal("A concept names no product, person or address.")
        }
    }
}

/// The check and the person's answers, over one store and one judge: both
/// the person's own, on Peel's own strut. Nothing here takes a Hive peer, a
/// workspace or any other strut; the only way out is the `MemoryServer` the
/// store and judge were made from.
///
/// A check (`check`) is a dry run: it reads, judges and returns what it
/// would do, and writes nothing. Each write waits for the person's answer
/// (`approve…`), and each can be undone.
public actor LearnedService {
    let store: any LearnedStore
    let judge: any LearnedJudge
    let signals: @Sendable () async -> [LearnedSignal]
    /// Called with the live concepts' line whenever it changes.
    let changed: @Sendable (String?) -> Void

    public init(store: any LearnedStore, judge: any LearnedJudge, signals: @escaping @Sendable () async -> [LearnedSignal],
                changed: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.store = store
        self.judge = judge
        self.signals = signals
        self.changed = changed
    }

    /// The Mac's way in: the person's own strut's memory and nothing else.
    public init(server: MemoryServer, signals: @escaping @Sendable () async -> [LearnedSignal],
                changed: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.init(store: GraphLearnedStore(server: server), judge: StrutLearnedJudge(server: server), signals: signals, changed: changed)
    }

    static let newPrefix = "new:"

    // MARK: Check (dry run)

    public func check(now: Date = .now) async throws -> LearnedReport {
        let causes = try await store.causes()
        let concepts = try await store.concepts()
        let rejections = try await store.rejections()
        let rejectedKeys = try await store.rejectedHabits()
        var report = LearnedReport()

        // Corrections not yet evidence of any Cause.
        let known = Set(causes.flatMap(\.evidence).compactMap { evidence in
            SignalKind(rawValue: evidence.kind).map { LearnedDetector.candidateID(kind: $0, turn: evidence.turn) }
        })
        let candidates = LearnedDetector.candidates(from: await signals(), known: known, now: now)
        var fresh: [PersonalCause] = []
        if !candidates.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            for draft in try await judge.word(candidates) {
                guard let candidate = byID[draft.candidate] else { continue }
                var statement = draft.statement.trimmingCharacters(in: .whitespacesAndNewlines)
                if !statement.hasSuffix(".") { statement += "." }
                do { try CauseRules.validate(statement) } catch { report.refused += 1; continue }
                let evidence = CauseEvidence(turn: candidate.turn, excerpt: candidate.excerpt, confidence: candidate.confidence,
                                             kind: candidate.kind.rawValue, why: candidate.why, previousRef: candidate.previousRef,
                                             turnAt: candidate.turnAt)
                var leaf = PersonalCause(id: Self.newPrefix + candidate.id, statement: statement, causeType: draft.causeType,
                                         severity: draft.severity, mechanism: draft.mechanism, evidence: [evidence])
                guard !rejectedKeys.contains(leaf.identityKey) else { continue }
                if let same = causes.first(where: { $0.identityKey == leaf.identityKey }) {
                    // A repeat: it attaches to the Cause that exists.
                    leaf.id = same.id
                    leaf.evidence = same.evidence + [evidence]
                    leaf.parent = same.parent
                }
                if let twin = fresh.firstIndex(where: { $0.identityKey == leaf.identityKey }) {
                    let have = fresh[twin].evidence
                    fresh[twin].evidence += leaf.evidence.filter { e in !have.contains { $0.turn == e.turn && $0.kind == e.kind } }
                } else {
                    fresh.append(leaf)
                }
            }
        }
        let activeLeaves = causes.filter { $0.status == .active && !$0.evidence.isEmpty }
        let themes = causes.filter { $0.status == .active && $0.evidence.isEmpty }
        for leaf in fresh {
            for twin in GroupingRules.nearDuplicates(of: leaf, in: activeLeaves + themes) {
                report.duplicates.append(.init(new: leaf, existing: twin))
            }
        }

        // Grouping: fresh and kept leaves not under a theme yet.
        let loose = (fresh + activeLeaves.filter { kept in !fresh.contains { $0.id == kept.id } }).filter { $0.parent == nil }
        var grouped = Set<String>()
        if loose.count >= 2 || (!loose.isEmpty && !themes.isEmpty) {
            let proposed = try await judge.group(leaves: loose, themes: themes, rejected: rejections)
            let admitted = GroupingRules.admit(proposed, leaves: loose, themes: themes, rejected: rejections)
            report.groupings = admitted.groupings
            grouped = Set(admitted.groupings.flatMap { $0.leaves.map(\.id) })
        }
        report.habits = fresh.filter { !grouped.contains($0.id) }

        // Concepts: an approved theme with none yet, and none refused.
        for theme in themes {
            let children = activeLeaves.filter { $0.parent == theme.id }
            guard !children.isEmpty, !concepts.contains(where: { $0.cause == theme.id }),
                  !rejectedKeys.contains(Self.conceptRejection(theme.id)) else { continue }
            let draft = try await judge.concept(for: theme, leaves: children)
            do { try ConceptRules.validate(name: draft.name, guidance: draft.guidance) } catch { report.refused += 1; continue }
            report.concepts.append(ConceptProposal(theme: theme, name: draft.name, guidance: draft.guidance))
        }
        return report
    }

    static func conceptRejection(_ theme: String) -> String { "concept:" + theme }

    // MARK: The person's answers

    /// Keeps a new habit.
    @discardableResult
    public func approve(habit: PersonalCause) async throws -> PersonalCause {
        try await store.keep(habit)
    }

    public func reject(habit: PersonalCause) async throws {
        try await store.reject(habit: habit.identityKey)
    }

    /// Makes a theme: its new leaves are kept first (a repeat attaches), then
    /// the parent and the edges.
    @discardableResult
    public func approve(grouping: Grouping) async throws -> PersonalCause {
        var kept: [PersonalCause] = []
        for leaf in grouping.leaves {
            kept.append(leaf.id.hasPrefix(Self.newPrefix) ? try await store.keep(leaf) : leaf)
        }
        var made = grouping
        made.leaves = kept
        made.theme.leaves = kept.map(\.id)
        return try await store.group(made)
    }

    public func reject(grouping: Grouping) async throws {
        try await store.reject(grouping: RejectedGrouping(leafKeys: Set(grouping.leaves.map(\.identityKey)), parent: grouping.theme.existing))
    }

    /// Takes an approved theme apart (the leaves stay as habits).
    public func undo(theme: PersonalCause) async throws {
        let children = try await store.causes().filter { $0.parent == theme.id }.map(\.id)
        try await store.ungroup(parent: theme.id, leaves: children)
        try await refresh()
    }

    /// Makes a concept live: written to the graph, and its line passed on.
    @discardableResult
    public func approve(concept: ConceptProposal) async throws -> PersonalConcept {
        try ConceptRules.validate(name: concept.name, guidance: concept.guidance)
        let saved = try await store.save(PersonalConcept(id: "", name: concept.name, guidance: concept.guidance, cause: concept.theme.id,
                                                         live: true))
        try await refresh()
        return saved
    }

    public func reject(concept: ConceptProposal) async throws {
        try await store.reject(habit: Self.conceptRejection(concept.theme.id))
    }

    /// Undo: the concept as it was before it was written.
    public func undo(concept: PersonalConcept) async throws {
        try await store.undo(concept)
        try await refresh()
    }

    // MARK: What is kept

    public func causes() async throws -> [PersonalCause] { try await store.causes() }
    public func concepts() async throws -> [PersonalConcept] { try await store.concepts() }

    /// Passes the live concepts' line to the personal-instructions slot.
    public func refresh() async throws {
        changed(LearnedInstructions.line(for: try await store.concepts()))
    }
}

/// The line the personal-instructions slot (`Orchestrator.hostConfig`'s
/// `learned`) carries: the live concepts by name. The graph is the store of
/// record; the line points at it and the assistant may read the Concepts.
public enum LearnedInstructions {
    static let file = "learned-instructions.txt"

    public static func line(for concepts: [PersonalConcept]) -> String? {
        let live = concepts.filter(\.live).sorted { $0.name < $1.name }
        guard !live.isEmpty else { return nil }
        let items = live.map { "\($0.name): \($0.guidance)" }.joined(separator: " ")
        return "The person approved these habits to keep in mind, kept in your memory as Concepts (memory/recall \"What it learned\"). " + items
    }

    public static func write(_ line: String?, in data: URL) {
        let url = data.appending(path: file)
        guard let line else { try? FileManager.default.removeItem(at: url); return }
        try? Data(line.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(in data: URL) -> String? {
        (try? String(contentsOf: data.appending(path: file), encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }
}
