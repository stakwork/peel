import Foundation

/// Words someone else wrote (a message, a workspace's label, a server's
/// answer) as one line that is safe to show or hand to a model: the one
/// cleaner the agent's chat data, Stadeum's workspaces and strut's app
/// listings share.
public enum TextLine {
    /// The most characters of a name (a sender, a contact, a tribe, a workspace).
    public static let maxName = 60

    /// `text` as one line of at most `max` characters: line breaks and
    /// other control characters as spaces, the direction controls that
    /// could hide or reorder text dropped, and no run of three "<" (so no
    /// marker) left.
    public static func clean(_ text: String, max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            case _ where hiddenControls.contains(scalar.value): continue
            default: scalars.append(scalar)
            }
        }
        var line = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while line.contains("<<<") { line = line.replacingOccurrences(of: "<<<", with: "<< <") }
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    /// The marks, embeddings, overrides and isolates of the bidirectional
    /// algorithm, and the invisible characters that could split a marker
    /// unseen (zero width space, word joiner, byte order mark, soft hyphen)
    /// or hide text from the person while the model reads it (tags).
    private static let hiddenControls = Set<UInt32>([0x200E, 0x200F, 0x061C, 0x200B, 0x2060, 0xFEFF, 0x00AD])
        .union(0x202A...0x202E).union(0x2066...0x2069).union(0xE0000...0xE007F)
}
