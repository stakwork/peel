import CryptoKit
import Foundation

/// "What it learned" (docs/learned.md): the same Cause / theme process
/// Hive's Glimmer uses, on the person's own graph. The fields and edges are
/// Hive's, not a second schema: a Cause is one repeated way the assistant
/// falls short, a leaf carries `EVIDENCED_BY` edges to the person's own
/// orchestrator turns, a theme is a parent Cause its children point at
/// (`CAUSE_CHILD_OF`, child to parent). Nothing here reaches Hive.

/// Hive's `cause_type`.
public enum CauseType: String, Sendable, CaseIterable, Codable {
    case promptGap = "prompt_gap"
    case reasoningError = "reasoning_error"
    case missingContext = "missing_context"
    case formatViolation = "format_violation"
    case correction
    case inefficiency
    case conceptIssue = "concept_issue"
}

/// Hive's `severity`.
public enum CauseSeverity: String, Sendable, CaseIterable, Codable {
    case critical, high, medium, low
}

/// One `EVIDENCED_BY {excerpt, confidence, kind, why, previous_ref, turn_at}`
/// edge, from a leaf Cause to the person's own orchestrator turn (`turn`: the
/// run's id on Peel's own strut, or the assistant DM message it answered).
public struct CauseEvidence: Sendable, Equatable, Codable {
    public var turn: String
    public var excerpt: String
    public var confidence: Double
    /// Where the correction came from (`SignalKind.rawValue`).
    public var kind: String
    public var why: String
    public var previousRef: String?
    public var turnAt: Date?

    public init(turn: String, excerpt: String, confidence: Double, kind: String, why: String,
                previousRef: String? = nil, turnAt: Date? = nil) {
        self.turn = turn
        self.excerpt = excerpt
        self.confidence = confidence
        self.kind = kind
        self.why = why
        self.previousRef = previousRef
        self.turnAt = turnAt
    }
}

/// Where a Cause stands for the person.
public enum CauseStatus: String, Sendable, Codable {
    /// A theme waiting for the person's yes (never written before it).
    case proposed
    /// Kept: a leaf, or a theme the person approved.
    case active
    /// The person said no: never proposed again.
    case rejected
}

/// One Cause in the person's own graph (an entity of type `Cause`).
public struct PersonalCause: Sendable, Equatable, Identifiable {
    /// The graph's ref_id.
    public var id: String
    public var statement: String
    public var causeType: CauseType
    public var severity: CauseSeverity
    public var mechanism: String?
    public var identityKey: String
    public var status: CauseStatus
    /// The theme this one belongs to (`CAUSE_CHILD_OF`, pointing at the parent).
    public var parent: String?
    /// Only a leaf has evidence.
    public var evidence: [CauseEvidence]

    public init(id: String, statement: String, causeType: CauseType, severity: CauseSeverity, mechanism: String? = nil,
                status: CauseStatus = .active, parent: String? = nil, evidence: [CauseEvidence] = []) {
        self.id = id
        self.statement = statement
        self.causeType = causeType
        self.severity = severity
        self.mechanism = mechanism
        self.identityKey = CauseRules.identityKey(type: causeType, statement: statement)
        self.status = status
        self.parent = parent
        self.evidence = evidence
    }
}

/// A Concept: what the person approved the assistant to keep in mind, the
/// live record in the local graph (an entity of type `Concept`).
public struct PersonalConcept: Sendable, Equatable, Identifiable {
    public var id: String
    /// A short name the person sees ("Check before sending").
    public var name: String
    /// One plain sentence the assistant reads.
    public var statement: String
    /// The theme (parent Cause) it answers.
    public var cause: String
    public var live: Bool
    /// The words that find it: what `memory/recall` of a related task matches.
    /// Written as a fact and as `about` edges to Topic entities.
    public var keywords: [String]
    /// What it was before the last write, so Undo restores it; nil when the
    /// write made it.
    public var prior: Prior?

    public struct Prior: Sendable, Equatable, Codable {
        public var name: String
        public var statement: String
        public var live: Bool
    }

    public init(id: String, name: String, statement: String, cause: String, live: Bool = false, keywords: [String] = [],
                prior: Prior? = nil) {
        self.id = id
        self.name = name
        self.statement = statement
        self.cause = cause
        self.live = live
        self.keywords = keywords
        self.prior = prior
    }
}

/// Why a statement, theme or concept is refused, in words for the person.
public struct LearnedRefusal: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// Hive's rules for a Cause, as pure functions.
public enum CauseRules {
    public static let maxWords = 25
    /// Words that are never in a statement: the person's products and the
    /// people the assistant works with.
    static let banned: Set<String> = ["peel", "sphinx", "hive", "stadeum", "strut", "glimmer", "jamie", "tribe", "tribes"]

    /// Lower case, letters, digits and single spaces only: so a repeat
    /// worded with another case or punctuation is the same Cause.
    public static func normalize(_ statement: String) -> String {
        let folded = statement.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// The statement as the identity key reads it: lower case, whitespace
    /// collapsed, trailing punctuation off.
    static func keyText(_ statement: String) -> String {
        var text = statement.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = text.last, last.isPunctuation || last.isWhitespace { text.removeLast() }
        return text
    }

    /// `"ck1_" + the first 16 hex characters of SHA-256(cause_type + "|" +
    /// normalized statement)`: Hive's key's shape, so a repeat attaches to the
    /// Cause it names. The one place the key is made. **UNVERIFIED**: it is NOT
    /// known to equal the key Hive's `cause/primitive` step writes for the same
    /// words (that step is closed). Seven known Hive keys were tried against
    /// SHA-256/SHA-1/MD5/SHA-512/SHA-3/BLAKE2/CRC over cause_type (all seven
    /// types and a few labels) and statement in both orders, many separators,
    /// JSON forms, and normalizations (case, whitespace, punctuation, token
    /// sets, stop words, first words); none reproduced any of them.
    public static func identityKey(type: CauseType, statement: String) -> String {
        let digest = SHA256.hash(data: Data((type.rawValue + "|" + keyText(statement)).utf8))
        return "ck1_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "When <situation>, the assistant <wrong behaviour>.": one sentence,
    /// at most 25 words, no product or person names.
    public static func validate(_ statement: String) throws {
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { throw LearnedRefusal("A habit needs a sentence.") }
        guard words.count <= maxWords else { throw LearnedRefusal("A habit is one sentence of at most \(maxWords) words.") }
        let lower = text.lowercased()
        guard lower.hasPrefix("when "), lower.contains(", the assistant ") else {
            throw LearnedRefusal("A habit reads \u{201C}When …, the assistant ….\u{201D}")
        }
        let body = text.dropLast(text.hasSuffix(".") ? 1 : 0)
        guard !body.contains(where: { ".!?\n".contains($0) }) else { throw LearnedRefusal("A habit is one sentence.") }
        guard !text.contains("@"), !lower.contains("http") else { throw LearnedRefusal("A habit names no one and no address.") }
        for (index, word) in words.enumerated() {
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            if banned.contains(bare.lowercased()) { throw LearnedRefusal("A habit names no product or person.") }
            // A capital past the first word is a name ("I" is the person, not a name).
            if index > 0, let first = bare.first, first.isUppercase, bare != "I", !bare.hasPrefix("I'"), !bare.hasPrefix("I\u{2019}") {
                throw LearnedRefusal("A habit names no product or person.")
            }
        }
    }

    /// How alike two statements are, 0 to 1, by their words.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(normalize(a).split(separator: " ")), y = Set(normalize(b).split(separator: " "))
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Statements this close, under other keys, are reported, never merged.
    public static let nearDuplicate = 0.8
}
