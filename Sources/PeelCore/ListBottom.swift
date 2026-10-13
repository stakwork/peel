/// Where a message list stands against its bottom, for its jump button's
/// "N new messages" (the app's `MessageList`). Kept from the list's own
/// reports, and crossings judged against the last one it took, not against
/// a report's `old`: reports can be coalesced, so a return to the bottom can
/// arrive with `old` already there.
public struct ListBottom: Equatable, Sendable {
    public enum Crossing: Equatable, Sendable {
        case reached, left
    }

    /// Whether the last crossing left it at the bottom.
    public private(set) var atBottom = true
    /// The newest message in the list the last time it sat at its bottom
    /// with nothing moving it: everything down to it was in view.
    public private(set) var seenAtBottom: Int64?
    /// What counted as seen when the list left the bottom; nil at it.
    public private(set) var seenUpTo: Int64?

    public init() {}

    /// A report of where the list is. At the bottom nothing below counts as
    /// new; `settled` (not opening, not scrolling) there, everything down
    /// to `newest` has been in view. Read whatever the crossing.
    public mutating func report(atBottom: Bool, settled: Bool, newest: @autoclosure () -> Int64?) {
        guard atBottom else { return }
        seenUpTo = nil
        if settled, let newest = newest() { seenAtBottom = newest }
    }

    /// The crossing this report makes, if any, against the last one taken.
    public mutating func cross(atBottom: Bool) -> Crossing? {
        guard atBottom != self.atBottom else { return nil }
        self.atBottom = atBottom
        return atBottom ? .reached : .left
    }

    /// Left the bottom. Moved off it by itself (a message that did not
    /// take it down, a row that grew), only what was in view at the bottom
    /// counts as seen, so neither a message on the screen nor one that
    /// moved it is miscounted; otherwise (by hand, or on its way back
    /// down), what was there had been read up to `otherwiseSeen`.
    public mutating func left(byItself: Bool, otherwiseSeen: @autoclosure () -> Int64) {
        guard seenUpTo == nil else { return }
        seenUpTo = byItself ? seenAtBottom ?? otherwiseSeen() : otherwiseSeen()
    }

    /// The messages below, newest run first, that count as unread and
    /// came after what was seen; stops at the first run that does not.
    public func newBelow<Runs: Sequence>(newestFirst runs: Runs) -> Int where Runs.Element == [Message] {
        guard let seenUpTo else { return 0 }
        var count = 0
        for run in runs {
            guard let newest = run.last?.serverIndex, newest > seenUpTo else { break }
            count += run.filter { $0.countsAsUnread(after: seenUpTo) }.count
        }
        return count
    }
}
