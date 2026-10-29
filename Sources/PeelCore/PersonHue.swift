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
    /// and sync it as `chat_color`; Peel takes those colours from the file
    /// (import-only, never writes one) and a person who has one shows in
    /// its nearest hue (`init(nearestTo:)`, `init(pubkey:alias:inTribe:synced:)`)
    /// instead of the hash.
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

extension PersonHue {
    /// The avatar fills, in this enum's order (`Apps/Shared/Theme.swift`
    /// `PersonHue.fills`), as the palette a synced colour is matched to.
    private static let palette: [UInt32] = [0xBA4A36, 0x587900, 0x007F3D, 0x007C70, 0x007893, 0x765DC1, 0x9951A9, 0xB44778]

    /// The hue angle in degrees, 0 to 360, of an RGB colour (HSL's hue; 0
    /// for a grey, which has none).
    private static func angle(red: Double, green: Double, blue: Double) -> Double {
        let (high, low) = (max(red, green, blue), min(red, green, blue))
        let spread = high - low
        guard spread > 0 else { return 0 }
        let sector: Double
        switch high {
        case red: sector = ((green - blue) / spread).truncatingRemainder(dividingBy: 6)
        case green: sector = (blue - red) / spread + 2
        default: sector = (red - green) / spread + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The hue closest to a synced colour (`#rrggbb` or `rrggbb`) by hue
    /// angle, going the short way round the wheel: a colour beyond the
    /// palette (a blue, an amber) still lands on its nearest hue, the lower
    /// one on a tie. Nil if the text is not a colour.
    public init?(nearestTo hex: String) {
        guard let (red, green, blue) = ChatColour.channels(hex) else { return nil }
        let target = Self.angle(red: red, green: green, blue: blue)
        let distances = Self.palette.map { rgb -> Double in
            let hue = Self.angle(red: Double((rgb >> 16) & 0xFF), green: Double((rgb >> 8) & 0xFF), blue: Double(rgb & 0xFF))
            let gap = abs(hue - target)
            return min(gap, 360 - gap)
        }
        guard let nearest = distances.indices.min(by: { distances[$0] < distances[$1] || (distances[$0] == distances[$1] && $0 < $1) })
        else { return nil }
        self = Self.allCases[nearest]
    }

    /// A person's hue: the colour another device gave them (`synced`, by
    /// colour key: `<alias>-color` for a tribe member, then
    /// `<pubkey>-color`, then `chat-<pubkey>-color`, the first that is a
    /// colour), else the hash. A member of a tribe with a name is never
    /// coloured by the tribe's own `chat-` key, which names the chat.
    public init(pubkey: String, alias: String?, inTribe: Bool, synced: [String: String]) {
        var keys: [String] = []
        let named = inTribe && alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
        if named { keys.append(Self.colourKey(pubkey: pubkey, alias: alias, inTribe: true)) }
        if !pubkey.isEmpty {
            keys.append("\(pubkey)-color")
            if !named { keys.append("chat-\(pubkey)-color") }
        }
        if let hue = keys.lazy.compactMap({ synced[$0].flatMap(PersonHue.init(nearestTo:)) }).first {
            self = hue
        } else {
            self = PersonHue(pubkey: pubkey, alias: alias, inTribe: inTribe)
        }
    }
}
