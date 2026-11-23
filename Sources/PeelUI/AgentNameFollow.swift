import Foundation
import PeelCore

/// How the Mac's agent name follows the alias on the agent contact (the name
/// its bridge account gives in each message). The contact's alias is the
/// single source of truth once the agent has spoken under a name: a rename
/// here shows at once and is `pending` until the alias catches up, so the
/// older alias still stored is never taken for a change.
public struct AgentNameFollow: Equatable, Sendable {
    /// The last alias seen on the contact.
    private(set) var seen: String?
    /// A name the person chose here that the alias has not reached yet.
    private(set) var pending: String?

    public init() {}

    /// The person renamed the agent here.
    public mutating func renamed(to name: String) {
        pending = name
    }

    /// Forgets everything, as an account closes.
    public mutating func reset() { self = AgentNameFollow() }

    /// The name the agent should take given the contact's `alias` now, or nil
    /// to keep `current`. Adopted when the alias changed since last seen, or
    /// on the first sight while the agent still has its default name; never
    /// while a rename waits for its alias, which ends it.
    public mutating func name(forAlias alias: String?, current: String, defaultName: String) -> String? {
        let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let first = seen == nil
        defer { if alias != nil { seen = alias } }
        guard let alias else { return nil }
        if let pending {
            // The alias reaching the new name ends the wait; any other
            // alias is the old one still, or a later rename elsewhere.
            if alias == pending { self.pending = nil }
            else if alias == seen || first { return nil }
            else { self.pending = nil }
        }
        guard alias != current else { return nil }
        if first { return current == defaultName ? alias : nil }
        return alias != seen ? alias : nil
    }
}
