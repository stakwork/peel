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

    /// `text` as a block of at most `max` characters that keeps its line
    /// breaks, tabs and indentation: every other control character dropped,
    /// the hidden controls `clean` drops dropped too, a run of blank lines
    /// cut to one, and no run of three "<" left. For words someone else wrote that are
    /// read in full (a proposal's summary, a field's value), where one line
    /// would lose their shape.
    public static func block(_ text: String, max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where scalar == "\n" || scalar == "\t": scalars.append(scalar)
            case .lineSeparator, .paragraphSeparator: scalars.append("\n")
            case .control: continue
            case _ where hiddenControls.contains(scalar.value): continue
            default: scalars.append(scalar)
            }
        }
        // Each line's trailing whitespace goes; its indentation (code, JSON) stays.
        var block = String(scalars).split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
            .joined(separator: "\n")
        while block.contains("\n\n\n") { block = block.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while block.contains("<<<") { block = block.replacingOccurrences(of: "<<<", with: "<< <") }
        block = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return block.count > max ? String(block.prefix(max - 1)) + "…" : block
    }

    /// The marks, embeddings, overrides and isolates of the bidirectional
    /// algorithm, and the invisible characters that could split a marker
    /// unseen (zero width space, word joiner, byte order mark, soft hyphen)
    /// or hide text from the person while the model reads it (tags).
    private static let hiddenControls = Set<UInt32>([0x200E, 0x200F, 0x061C, 0x200B, 0x2060, 0xFEFF, 0x00AD])
        .union(0x202A...0x202E).union(0x2066...0x2069).union(0xE0000...0xE007F)
}
