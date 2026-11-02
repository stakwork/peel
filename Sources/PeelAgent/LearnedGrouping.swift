import CryptoKit
import Foundation

/// A grouping the judge proposed: one theme over leaves.
/// "A theme is a mechanism that explains several leaves, not a topic."
public struct ProposedTheme: Sendable, Equatable {
    /// The more general sentence (a new theme), or ignored for `existing`.
    public var statement: String
    public var causeType: CauseType
    public var severity: CauseSeverity
    /// What explains the leaves; a new theme needs one.
    public var mechanism: String?
    /// The leaves' ref_ids.
    public var leaves: [String]
    /// Join this theme instead of making one.
    public var existing: String?
    /// The judge's own word that the leaves would need different fixes, so one
    /// theme would hide that: never grouped.
    public var needsDifferentFixes: Bool

    public init(statement: String, causeType: CauseType, severity: CauseSeverity, mechanism: String? = nil,
                leaves: [String], existing: String? = nil, needsDifferentFixes: Bool = false) {
        self.statement = statement
        self.causeType = causeType
        self.severity = severity
        self.mechanism = mechanism
        self.leaves = leaves
        self.existing = existing
        self.needsDifferentFixes = needsDifferentFixes
    }
}

/// A grouping the person may approve, after the rules.
public struct Grouping: Sendable, Equatable, Identifiable {
    public var theme: ProposedTheme
    /// The leaves as they are now, for what the person sees.
    public var leaves: [PersonalCause]
    /// Same leaves and theme, same id.
    public var id: String { GroupingRules.key(leafKeys: leaves.map(\.identityKey), parent: theme.existing) }
}

/// A grouping the person said no to: never proposed again.
public struct RejectedGrouping: Sendable, Equatable {
    /// The leaves' identity keys.
    public var leafKeys: Set<String>
    /// The theme it would have joined; nil for a new one.
    public var parent: String?
    public init(leafKeys: Set<String>, parent: String? = nil) {
        self.leafKeys = leafKeys
        self.parent = parent
    }
}

public enum GroupingRules {
    /// Why a proposed theme was not kept; shown only to a developer.
    public enum Dropped: Sendable, Equatable {
        case tooFew, unknownLeaf, alreadyGrouped, differentFixes, noMechanism, badStatement(String), rejectedBefore
        /// Another habit already says it: reported, never merged.
        case duplicate(of: String)
    }

    public struct Result: Sendable, Equatable {
        public var groupings: [Grouping] = []
        public var dropped: [(ProposedTheme, Dropped)] = []
        public static func == (a: Result, b: Result) -> Bool { a.groupings == b.groupings && a.dropped.count == b.dropped.count }
    }

    /// The id a rejection and a proposal share.
    public static func key(leafKeys: [String], parent: String?) -> String {
        let text = leafKeys.sorted().joined(separator: ",") + "|" + (parent ?? "new")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Applies the rules to what the judge proposed:
    /// - at least two leaves, or one only to join an existing theme;
    /// - each leaf in at most one theme (a leaf already under a parent, or in an
    ///   earlier theme here, is left out);
    /// - a theme is a mechanism that explains its leaves, whatever their
    ///   `cause_type`: a new one has a non-empty mechanism, and one the judge
    ///   says needs different fixes is refused;
    /// - a new theme has a mechanism and a valid statement, and is not a
    ///   near-duplicate of a habit that exists (reported, not merged);
    /// - a grouping the person rejected, or any larger one that holds it, is
    ///   never proposed again.
    public static func admit(_ proposed: [ProposedTheme], leaves: [PersonalCause], themes: [PersonalCause],
                             rejected: [RejectedGrouping]) -> Result {
        var result = Result()
        let byID = Dictionary(uniqueKeysWithValues: leaves.map { ($0.id, $0) })
        let themeIDs = Set(themes.map(\.id))
        var taken = Set<String>()
        for var theme in proposed {
            // Each leaf once, in the order the judge gave them.
            var seen = Set<String>()
            theme.leaves = theme.leaves.filter { seen.insert($0).inserted }
            guard theme.leaves.allSatisfy({ byID[$0] != nil }) else { result.dropped.append((theme, .unknownLeaf)); continue }
            theme.leaves = theme.leaves.filter { byID[$0]?.parent == nil && !taken.contains($0) }
            if let existing = theme.existing {
                guard themeIDs.contains(existing) else { result.dropped.append((theme, .unknownLeaf)); continue }
                guard !theme.leaves.isEmpty else { result.dropped.append((theme, .alreadyGrouped)); continue }
            } else {
                guard theme.leaves.count >= 2 else { result.dropped.append((theme, .tooFew)); continue }
            }
            let members = theme.leaves.compactMap { byID[$0] }
            // One mechanism decides, not the leaves' types; the judge's own "different fixes" stops it.
            guard !theme.needsDifferentFixes else { result.dropped.append((theme, .differentFixes)); continue }
            if theme.existing == nil {
                guard let mechanism = theme.mechanism, !mechanism.trimmingCharacters(in: .whitespaces).isEmpty else {
                    result.dropped.append((theme, .noMechanism)); continue
                }
                do { try CauseRules.validate(theme.statement) } catch {
                    result.dropped.append((theme, .badStatement("\(error)"))); continue
                }
                let key = CauseRules.identityKey(type: theme.causeType, statement: theme.statement)
                if let same = themes.first(where: {
                    $0.identityKey == key || ($0.causeType == theme.causeType
                        && CauseRules.similarity($0.statement, theme.statement) >= CauseRules.nearDuplicate)
                }) {
                    result.dropped.append((theme, .duplicate(of: same.id))); continue
                }
            }
            let keys = Set(members.map(\.identityKey))
            if rejected.contains(where: { $0.parent == theme.existing && $0.leafKeys.isSubset(of: keys) }) {
                result.dropped.append((theme, .rejectedBefore)); continue
            }
            taken.formUnion(theme.leaves)
            result.groupings.append(Grouping(theme: theme, leaves: members))
        }
        return result
    }

    /// New leaves whose statement is close to a habit that exists under another
    /// key: reported to the caller, never merged.
    public static func nearDuplicates(of leaf: PersonalCause, in known: [PersonalCause]) -> [PersonalCause] {
        known.filter {
            $0.identityKey != leaf.identityKey && $0.causeType == leaf.causeType
                && CauseRules.similarity($0.statement, leaf.statement) >= CauseRules.nearDuplicate
        }
    }
}
