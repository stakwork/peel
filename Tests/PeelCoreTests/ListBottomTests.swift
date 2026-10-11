import Testing
@testable import PeelCore

/// The jump button's count (`ListBottom`): what counts as seen at the
/// bottom and when the list leaves it.
struct ListBottomTests {
    /// Someone's message the server numbered `n`; `fromMe` for your own.
    private func numbered(_ n: Int64, fromMe: Bool = false) -> Message {
        var message = text(Int(n), fromMe: fromMe)
        message.serverIndex = n
        return message
    }

    /// One run per message, newest first, as the list counts them.
    private func runs(_ indexes: ClosedRange<Int64>) -> [[Message]] {
        indexes.reversed().map { [numbered($0)] }
    }

    @Test func atTheBottomNothingCounts() {
        var bottom = ListBottom()
        bottom.report(atBottom: true, settled: true, newest: 10)
        #expect(bottom.seenUpTo == nil)
        #expect(bottom.newBelow(newestFirst: runs(1...12)) == 0)
    }

    /// Opened from a notification or a search at the bottom (not following),
    /// with "New messages" still marked: a message that arrives and moves
    /// the list off its bottom counts alone, not the unread rows that were
    /// on the screen above it.
    @Test func leftByItselfCountsOnlyWhatCameAfterTheBottom() {
        var bottom = ListBottom()
        bottom.report(atBottom: true, settled: true, newest: 10)
        #expect(bottom.cross(atBottom: false) == .left)
        bottom.left(byItself: true, otherwiseSeen: 7)  // "New messages" above 8
        #expect(bottom.seenUpTo == 10)
        #expect(bottom.newBelow(newestFirst: runs(1...11)) == 1)
    }

    /// Opened at "New messages" already at the bottom, unmarked: the same
    /// arrival still counts (it used to take everything in the list as
    /// seen, the arrival included).
    @Test func anArrivalThatMovedTheListCounts() {
        var bottom = ListBottom()
        bottom.report(atBottom: true, settled: true, newest: 10)
        _ = bottom.cross(atBottom: false)
        bottom.left(byItself: true, otherwiseSeen: 11)
        #expect(bottom.newBelow(newestFirst: runs(1...11)) == 1)
    }

    /// Scrolled away by hand: what you scrolled through was read.
    @Test func leftByHandTakesWhatWasRead() {
        var bottom = ListBottom()
        bottom.report(atBottom: true, settled: true, newest: 10)
        _ = bottom.cross(atBottom: false)
        bottom.left(byItself: false, otherwiseSeen: 12)
        #expect(bottom.seenUpTo == 12)
        #expect(bottom.newBelow(newestFirst: runs(1...13)) == 1)
    }

    /// While opening (the initial anchor shows the bottom before the list
    /// goes to "New messages"), the bottom was not read: leaving it then
    /// keeps the divider's place.
    @Test func theBottomBeforeOpeningIsNotRead() {
        var bottom = ListBottom()
        bottom.report(atBottom: true, settled: false, newest: 10)
        #expect(bottom.seenAtBottom == nil)
        _ = bottom.cross(atBottom: false)
        bottom.left(byItself: true, otherwiseSeen: 7)
        #expect(bottom.newBelow(newestFirst: runs(1...10)) == 3)
    }

    /// A return to the bottom whose crossing a coalesced report hid (the
    /// report's own `old` already at the bottom) still clears the count,
    /// and the next crossing is judged against the one last taken.
    @Test func aReturnTheReportsHidStillClears() {
        var bottom = ListBottom()
        _ = bottom.cross(atBottom: false)
        bottom.left(byItself: false, otherwiseSeen: 10)
        #expect(bottom.newBelow(newestFirst: runs(1...12)) == 2)
        bottom.report(atBottom: true, settled: true, newest: 12)
        #expect(bottom.newBelow(newestFirst: runs(1...12)) == 0)
        #expect(bottom.cross(atBottom: true) == .reached)
        #expect(bottom.cross(atBottom: true) == nil)
    }

    /// Only the first leave sets what was seen, until the bottom again.
    @Test func aSecondLeaveKeepsTheFirst() {
        var bottom = ListBottom()
        _ = bottom.cross(atBottom: false)
        bottom.left(byItself: false, otherwiseSeen: 10)
        bottom.left(byItself: false, otherwiseSeen: 15)
        #expect(bottom.seenUpTo == 10)
    }

    /// Your own messages and runs older than what was seen are not counted.
    @Test func countsOthersUnreadOnlyBelowWhatWasSeen() {
        var bottom = ListBottom()
        _ = bottom.cross(atBottom: false)
        bottom.left(byItself: false, otherwiseSeen: 10)
        let newestFirst = [[numbered(13), numbered(14, fromMe: true)], [numbered(11), numbered(12)], [numbered(9)]]
        #expect(bottom.newBelow(newestFirst: newestFirst) == 3)
    }
}
