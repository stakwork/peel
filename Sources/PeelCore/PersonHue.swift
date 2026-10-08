import Foundation

/// A person's colour on their initials avatar and their name (direction D,
/// Tom, 2026-10-08): one of eight hues, no blues (links, mentions, unread)
/// and no ambers (money, @you). The client picks the shade per theme.
public enum PersonHue: Int, CaseIterable, Sendable {
    case coral, lime, green, teal, cyan, violet, orchid, pink

    /// The official apps' colour key (sphinx-mac-v2
    /// `ChatHelper.getSenderColorFor`): a tribe member by alias, trimmed,
    /// anyone else by their key. They key contacts by a local id; Peel uses
    /// the pubkey, which every device agrees on.
    static func colourKey(pubkey: String, alias: String?, inTribe: Bool) -> String {
        if inTribe, let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return "\(alias)-color"
        }
        return "\(pubkey)-color"
    }

    /// FNV-1a (32-bit) over the key's UTF-8, mod 8: the same hue on every
    /// launch and every Mac. The official apps pick a random colour per key
    /// and sync it as `chat_color`; once Peel reads that, a synced colour
    /// maps to its nearest hue here instead of the hash.
    public init(colourKey key: String) {
        var hash: UInt32 = 0x811C_9DC5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        self = Self.allCases[Int(hash % UInt32(Self.allCases.count))]
    }

    public init(pubkey: String, alias: String?, inTribe: Bool) {
        self.init(colourKey: Self.colourKey(pubkey: pubkey, alias: alias, inTribe: inTribe))
    }
}
