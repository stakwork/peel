import Testing
@testable import PeelCore

private typealias Run = HistoryCursor.Run

private func counts(total: UInt64, highest: UInt64, keys: UInt64, keysHighest: UInt64) -> Engine.MessageCounts {
    Engine.MessageCounts(
        total: total, firstForEachKey: keys, totalHighestIndex: highest, firstForEachKeyHighestIndex: keysHighest
    )
}

/// A page for a run in flight.
private func advance(
    _ cursor: inout HistoryCursor, _ indices: [UInt64], total: UInt64?
) throws -> (progress: HistoryCursor.Progress?, step: HistoryCursor.Step) {
    let page = cursor.advance(indices: indices, total: total)
    return try #require(page)
}

/// The history machine: what each page moves, when a run ends, what queues,
/// and which stall counts.
struct HistoryCursorTests {
    /// A catch-up from index 5, already in flight.
    private func catchingUp() -> HistoryCursor {
        var cursor = HistoryCursor()
        let started = cursor.start([Run(phase: .messages, next: 5, end: nil)])
        #expect(started == Run(phase: .messages, next: 5, end: nil))
        return cursor
    }

    @Test func aPageMovesTheRunPastItsHighestIndex() throws {
        var cursor = catchingUp()
        let page = try advance(&cursor, [7, 5, 9], total: 40)
        #expect(page.progress == HistoryCursor.Progress(phase: .messages, reached: 9, end: 40))
        #expect(page.step == .request(Run(phase: .messages, next: 10, end: 40)))
        #expect(cursor.active == Run(phase: .messages, next: 10, end: 40))
        #expect(cursor.isSyncing)
    }

    /// The first total the server gives is the end; a later one does not move it.
    @Test func theFirstTotalIsTheEnd() throws {
        var cursor = catchingUp()
        _ = cursor.advance(indices: [6], total: 20)
        let page = try advance(&cursor, [8], total: 99)
        #expect(page.progress?.end == 20)
        #expect(cursor.active?.end == 20)
    }

    @Test func aPageAtTheEndEndsHistory() throws {
        var cursor = catchingUp()
        let page = try advance(&cursor, [12], total: 12)
        #expect(page.progress == HistoryCursor.Progress(phase: .messages, reached: 12, end: 12))
        #expect(page.step == .ended)
        #expect(cursor.active == nil)
        #expect(!cursor.isSyncing)
    }

    /// An empty page, or one whose messages are all behind the cursor (an
    /// unreadable one), ends the run with no progress: never an endless loop.
    @Test(arguments: [[], [3, 4], [UInt64(Int64.max)]])
    func aPageThatDoesNotAdvanceEndsTheRun(indices: [UInt64]) throws {
        var cursor = catchingUp()
        let page = try advance(&cursor, indices, total: 50)
        #expect(page.progress == nil)
        #expect(page.step == .ended)
        #expect(!cursor.isSyncing)
    }

    @Test func aPageWithNoRunInFlightIsIgnored() {
        var cursor = HistoryCursor()
        let page = cursor.advance(indices: [1], total: 1)
        #expect(page == nil)
        #expect(cursor == HistoryCursor())
    }

    /// A restore is contacts first, then messages, both from the start; the
    /// messages run waits for the contacts run to end.
    @Test func aRestoreQueuesMessagesBehindContacts() throws {
        let runs = HistoryCursor.plan(counts(total: 30, highest: 31, keys: 2, keysHighest: 11))
        #expect(runs == [Run(phase: .contacts, next: 0, end: 11), Run(phase: .messages, next: 0, end: 31)])
        var cursor = HistoryCursor()
        let started = cursor.start(runs)
        #expect(started == runs[0])
        #expect(cursor.queued == [runs[1]])
        let page = try advance(&cursor, [11], total: nil)
        #expect(page.progress == HistoryCursor.Progress(phase: .contacts, reached: 11, end: 11))
        #expect(page.step == .request(runs[1]))
        #expect(cursor.active == runs[1])
        #expect(cursor.queued.isEmpty)
    }

    /// A run started while another is in flight waits its turn.
    @Test func aRunStartedDuringAnotherQueues() throws {
        var cursor = catchingUp()
        let later = Run(phase: .messages, next: 0, end: 3)
        let started = cursor.start([later])
        #expect(started == nil)
        #expect(cursor.queued == [later])
        let page = try advance(&cursor, [], total: nil)
        #expect(page.step == .request(later))
    }

    /// Counts with nothing on the server plan no runs; one kind alone plans that one.
    @Test func emptyCountsPlanNothing() {
        #expect(HistoryCursor.plan(counts(total: 0, highest: 0, keys: 0, keysHighest: 0)).isEmpty)
        #expect(HistoryCursor.plan(counts(total: 4, highest: 7, keys: 0, keysHighest: 0))
            == [Run(phase: .messages, next: 0, end: 7)])
        var cursor = HistoryCursor()
        let started = cursor.start([])
        #expect(started == nil)
        #expect(!cursor.isSyncing)
    }

    @Test func awaitingCountsIsSyncing() {
        var cursor = HistoryCursor()
        cursor.awaitingCounts = true
        #expect(cursor.isSyncing)
    }

    /// A stall drops the run and its queue only when it is for the page
    /// still awaited; a watchdog left from a page that came is ignored.
    @Test func aStallAppliesOnlyToThePageStillAwaited() throws {
        var cursor = HistoryCursor()
        let runs = HistoryCursor.plan(counts(total: 30, highest: 31, keys: 2, keysHighest: 11))
        _ = cursor.start(runs)
        _ = cursor.advance(indices: [4], total: nil)
        let early = cursor.stalled(at: 0)
        #expect(early == nil)
        #expect(cursor.active == Run(phase: .contacts, next: 5, end: 11))
        let stalled = cursor.stalled(at: 5)
        #expect(stalled == Run(phase: .contacts, next: 5, end: 11))
        #expect(cursor.active == nil)
        #expect(cursor.queued.isEmpty)
        #expect(!cursor.isSyncing)
        let again = cursor.stalled(at: 5)
        #expect(again == nil)
    }
}
