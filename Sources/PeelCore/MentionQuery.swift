import Foundation

/// The `@word` being typed in a composer and who it can mention, as the Mac
/// app finds and matches them: the Mac's composer and the iPhone's share it.
public enum MentionQuery {
    /// The word ending at `cursor` (a UTF-16 offset, as text views count),
    /// if it starts with `@`, or with `commands` a `/` opening the message:
    /// its range in `text`, the trigger included, what follows it, and the
    /// trigger. Nil with a selection, or with no such word.
    public static func word(
        in text: String, cursor: Int, selectionLength: Int = 0, commands: Bool = false
    ) -> (range: NSRange, query: String, trigger: Character)? {
        let string = text as NSString
        guard selectionLength == 0, cursor >= 0, cursor <= string.length else { return nil }
        let before = string.substring(to: cursor)
        let start = before.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
            .map { $0.upperBound } ?? before.startIndex
        let word = before[start...]
        guard let trigger = word.first, trigger == "@" || (commands && trigger == "/" && start == before.startIndex) else {
            return nil
        }
        let length = (String(word) as NSString).length
        return (NSRange(location: cursor - length, length: length), String(word.dropFirst()), trigger)
    }

    /// Aliases starting with `typed`, ignoring case; an exact match first,
    /// so taking the first never swaps a finished `@ann` for `@anna`. At
    /// most `limit`.
    public static func suggestions(_ members: [TribeMember], typed: String, limit: Int = 20) -> [TribeMember] {
        suggestions(members, names: { [$0.alias] }, typed: typed, limit: limit)
    }

    /// The same over anything with names (a workspace's id and label): one
    /// matches when any of its names starts with `typed`; one with a name
    /// that is exactly `typed` first.
    public static func suggestions<Item>(_ items: [Item], names: (Item) -> [String], typed: String, limit: Int = 20) -> [Item] {
        let lowered = typed.lowercased()
        let matches = items.filter { names($0).contains { $0.lowercased().hasPrefix(lowered) } }
        let exact = matches.filter { names($0).contains(typed) }
        let rest = matches.filter { !names($0).contains(typed) }
        return Array((exact + rest).prefix(limit))
    }
}
