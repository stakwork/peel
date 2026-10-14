import Foundation

/// The `@word` being typed in a composer and who it can mention, as the Mac
/// app finds and matches them: the Mac's composer and the iPhone's share it.
public enum MentionQuery {
    /// The word ending at `cursor` (a UTF-16 offset, as text views count),
    /// if it starts with `@`: its range in `text`, `@` included, and what
    /// follows the `@`. Nil with a selection, or with no such word.
    public static func word(in text: String, cursor: Int, selectionLength: Int = 0) -> (range: NSRange, query: String)? {
        let string = text as NSString
        guard selectionLength == 0, cursor >= 0, cursor <= string.length else { return nil }
        let before = string.substring(to: cursor)
        let start = before.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
            .map { $0.upperBound } ?? before.startIndex
        let word = before[start...]
        guard word.hasPrefix("@") else { return nil }
        let length = (String(word) as NSString).length
        return (NSRange(location: cursor - length, length: length), String(word.dropFirst()))
    }

    /// Aliases starting with `typed`, ignoring case; an exact match first,
    /// so taking the first never swaps a finished `@ann` for `@anna`. At
    /// most `limit`.
    public static func suggestions(_ members: [TribeMember], typed: String, limit: Int = 20) -> [TribeMember] {
        let lowered = typed.lowercased()
        let matches = members.filter { $0.alias.lowercased().hasPrefix(lowered) }
        return Array((matches.filter { $0.alias == typed } + matches.filter { $0.alias != typed }).prefix(limit))
    }
}
