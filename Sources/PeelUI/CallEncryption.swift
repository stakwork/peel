import Foundation

/// A group call's encryption as it goes (docs/hive-calls.md, "From a box"),
/// and what its screen says of it (`notice`). On an encrypted call: the
/// tracks LiveKit says will not encrypt or decrypt, and whose they are;
/// whether a data packet would not decrypt; and the tracks published in the
/// clear, which LiveKit plays without a word (someone on an app that cannot
/// encrypt: what they say is not private, and they hear nothing). On a call
/// in the clear: whether others on it encrypt, so a link without its key
/// is said rather than heard as silence. Talk's own, one agent and one
/// person, is `TalkEncryption`.
public struct CallEncryption: Equatable, Sendable {
    /// Whose track it is: yours, or someone else's by the name they joined with.
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
    /// Who publishes in the clear on an encrypted call, in the room's order.
    private var clear: [Whose] = []
    /// On a call in the clear, someone else publishes encrypted.
    private var othersEncrypt = false

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

    /// What the room publishes now: on an encrypted call, whose tracks are
    /// in the clear; on a call in the clear, whether anyone else encrypts.
    public mutating func published(clear: [Whose], othersEncrypt: Bool) {
        self.clear = clear
        self.othersEncrypt = othersEncrypt
    }

    /// What the call screen says, nil while nothing is wrong, the worst
    /// first: you in the clear, who can't be heard, who is in the clear, no
    /// one hears you, unreadable messages; and on a call in the clear, that
    /// others encrypt it.
    public var notice: String? {
        if clear.contains(.yours) {
            return String(localized: "This call's encryption failed: what you say isn't private.", table: "Shared")
        }
        if let list = Self.names(order.compactMap { failing[$0] }) {
            return String(localized: "This call's encryption failed: you can't hear \(list).", table: "Shared")
        }
        if let list = Self.names(clear) {
            return String(localized: "\(list) joined without encryption: what they say isn't private, and they can't hear the call.", table: "Shared")
        }
        if failing.values.contains(.yours) {
            return String(localized: "This call's encryption failed: no one can hear you.", table: "Shared")
        }
        if dataFailed {
            return String(localized: "This call's encryption failed: some messages can't be read.", table: "Shared")
        }
        if othersEncrypt {
            return String(localized: "This call is encrypted, and this link has no key: join from the one that has it.", table: "Shared")
        }
        return nil
    }

    /// Others by the names they joined with, each once in order, "someone"
    /// last for those with none; nil when there are none.
    private static func names(_ whose: [Whose]) -> String? {
        var names: [String] = []
        var someone = false
        for case .theirs(let name) in whose {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if !names.contains(name) { names.append(name) }
            } else {
                someone = true
            }
        }
        if someone { names.append(String(localized: "someone", table: "Shared")) }
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }
}
