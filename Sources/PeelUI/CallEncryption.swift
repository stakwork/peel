import Foundation

/// An encrypted group call's encryption as it goes (docs/hive-calls.md,
/// "From a box"): the tracks LiveKit says will not encrypt or decrypt, and
/// whose they are, and whether a data packet would not decrypt. Someone
/// joining from an app that cannot encrypt, or with another key, is heard
/// as silence; `notice` is what the call screen says instead. Talk's own,
/// one agent and one person, is `TalkEncryption`.
public struct CallEncryption: Equatable, Sendable {
    /// Whose track is failing: yours (it will not encrypt), or someone
    /// else's by the name they joined with (it will not decrypt).
    public enum Whose: Equatable, Sendable {
        case yours
        case theirs(String?)
    }

    /// The tracks failing now, by publication id.
    private var failing: [String: Whose] = [:]
    /// The order tracks first failed in, so names are said in that order.
    private var order: [String] = []
    /// A data packet would not decrypt. No later state clears it.
    private var dataFailed = false

    public init() {}

    /// A call meant to be encrypted that the room would not encrypt: left
    /// before anything was sent.
    public static let unavailable = String(localized: "This call is encrypted, and Peel couldn't encrypt it here.", table: "Shared")

    /// A track's state from LiveKit.
    public mutating func track(_ id: String, whose: Whose, failed: Bool) {
        if failed {
            if failing[id] == nil { order.append(id) }
            failing[id] = whose
        } else {
            failing[id] = nil
            order.removeAll { $0 == id }
        }
    }

    /// A data packet (the call's chat, Jamie's replies) would not decrypt.
    public mutating func dataFailedToDecrypt() { dataFailed = true }

    /// What the call screen says, nil while nothing fails: who can't be
    /// heard first, then that no one hears you, then unreadable messages.
    public var notice: String? {
        var names: [String] = []
        var someone = false
        for id in order {
            guard case .theirs(let name) = failing[id] else { continue }
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if !names.contains(name) { names.append(name) }
            } else {
                someone = true
            }
        }
        if someone { names.append(String(localized: "someone", table: "Shared")) }
        if !names.isEmpty {
            let list = names.formatted(.list(type: .and))
            return String(localized: "This call's encryption failed: you can't hear \(list).", table: "Shared")
        }
        if failing.values.contains(.yours) {
            return String(localized: "This call's encryption failed: no one can hear you.", table: "Shared")
        }
        if dataFailed {
            return String(localized: "This call's encryption failed: some messages can't be read.", table: "Shared")
        }
        return nil
    }
}
