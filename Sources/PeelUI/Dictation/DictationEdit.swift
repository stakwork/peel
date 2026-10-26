import Foundation

/// What the user did to the text dictation just typed, from the field read
/// again and again (`DictationEditWatch` on the Mac): the span between the
/// text that was before and after Peel's. Plain strings and times, so when
/// the edit counts as done is decided (and tested) without a field.
///
/// Strut runs a model on each edit (`dictation/correction`), so it is sent
/// once, when it has settled: left alone for `settled`, the field emptied
/// (Return sending a chat message, whose last reading before it stands),
/// words written on after it, or the watch ended by the caller (the focus
/// left, the next dictation, the time cap). What is written after the
/// dictation is never part of the edit.
public struct DictationEdit: Sendable {
    /// An edit left alone this long is done.
    public static let settled: Duration = .seconds(2)
    /// A span this many UTF-16 units longer than the dictation is new
    /// writing, whatever its words: the backstop to `writesOn`.
    static let longer = 200

    public enum Next: Equatable, Sendable {
        case watch
        case done
    }

    private let prefix: String
    private let suffix: String
    /// The UTF-16 lengths of `prefix` and `suffix`, `typed` and the field's value.
    private let prefixLength: Int
    private let suffixLength: Int
    private let typedLength: Int
    private let before: String
    private var latest: String
    private var changedAt: Duration = .zero

    /// The field's `value` right after `typed` went in, the caret at its
    /// end (UTF-16 units); nil when the typed text is not there.
    public init?(value: String, typed: String, caret: Int) {
        let text = value as NSString
        let length = (typed as NSString).length
        guard let start = Self.start(of: typed, in: text, caret: caret) else { return nil }
        prefix = text.substring(to: start)
        suffix = text.substring(from: start + length)
        prefixLength = start
        suffixLength = text.length - start - length
        typedLength = length
        before = value
        latest = value
    }

    /// Where `typed` starts in the field: just before the caret, as Peel
    /// left it; else the copy the caret is in (the user already clicked into
    /// it to fix a word); else the last copy. Nil when it isn't there at all.
    static func start(of typed: String, in text: NSString, caret: Int) -> Int? {
        let length = (typed as NSString).length
        guard length > 0, length <= text.length else { return nil }
        if caret >= length, caret <= text.length,
           text.substring(with: NSRange(location: caret - length, length: length)) == typed { return caret - length }
        var found: [Int] = []
        var from = 0
        while from <= text.length - length {
            let range = text.range(of: typed, range: NSRange(location: from, length: text.length - from))
            guard range.location != NSNotFound else { break }
            found.append(range.location)
            from = range.location + 1
        }
        return found.first { $0 <= caret && caret <= $0 + length } ?? found.last
    }

    /// One reading of the field, `time` after the watch began.
    public mutating func read(_ value: String, at time: Duration) -> Next {
        // Emptied: sent (Return in a chat). The reading before it stands.
        if value.isEmpty, !before.isEmpty { return .done }
        // The text around Peel's changed too: not this edit's; wait for it back.
        guard surrounds(value) else { return .watch }
        let now = span(value)
        // Writing on past the dictation (or past the fix of it): the edit,
        // if any, is the reading before; what was added is never sent.
        if Self.writesOn(span(latest), now) || (now as NSString).length > typedLength + Self.longer { return .done }
        if value != latest {
            latest = value
            changedAt = time
            return .watch
        }
        return latest != before && time - changedAt >= Self.settled ? .done : .watch
    }

    /// The user's version of the typed text; nil while it is unchanged.
    public var edited: String? {
        latest == before ? nil : span(latest)
    }

    /// `now` is `was` with words added after it: the same words first
    /// (punctuation on them aside, so "team." then "Thanks" counts), then more.
    private static func writesOn(_ was: String, _ now: String) -> Bool {
        let was = words(was), now = words(now)
        return now.count > was.count && now.starts(with: was)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private func surrounds(_ value: String) -> Bool {
        (value as NSString).length >= prefixLength + suffixLength && value.hasPrefix(prefix) && value.hasSuffix(suffix)
    }

    private func span(_ value: String) -> String {
        let length = (value as NSString).length
        return (value as NSString).substring(with: NSRange(location: prefixLength, length: length - prefixLength - suffixLength))
    }
}
