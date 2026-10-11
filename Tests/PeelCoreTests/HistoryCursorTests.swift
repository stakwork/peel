import Foundation
import Sphinxrs
import Synchronization
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

    /// An empty page, or one past any real index, ends the run with no
    /// progress: never an endless loop.
    @Test(arguments: [[], [UInt64(Int64.max)]])
    func aPageThatDoesNotAdvanceEndsTheRun(indices: [UInt64]) throws {
        var cursor = catchingUp()
        let page = try advance(&cursor, indices, total: 50)
        #expect(page.progress == nil)
        #expect(page.step == .ended)
        #expect(!cursor.isSyncing)
    }

    /// Pages carry no request ID: after a reconnect asks for the page in
    /// flight again, the same page comes twice. The second is behind the
    /// cursor and ignored, and the run goes on (a restore ended there).
    @Test func theSamePageTwiceDoesNotEndTheRun() throws {
        var cursor = catchingUp()
        _ = try advance(&cursor, [5, 6, 7], total: 40)
        let again = cursor.advance(indices: [5, 6, 7], total: 40)
        #expect(again == nil)
        #expect(cursor.active == Run(phase: .messages, next: 8, end: 40))
        let next = try advance(&cursor, [8, 9], total: 40)
        #expect(next.step == .request(Run(phase: .messages, next: 10, end: 40)))
    }

    /// The index fetched through moves only with a messages run that
    /// started just after it: a contacts page (one message per key) skips
    /// the messages between, and so does a run from further on.
    @Test(arguments: [
        (Run(phase: .messages, next: 5, end: nil), UInt64(9)),
        (Run(phase: .messages, next: 3, end: nil), UInt64(9)),
        (Run(phase: .contacts, next: 5, end: nil), UInt64(4)),
        (Run(phase: .messages, next: 6, end: nil), UInt64(4)),
    ])
    func onlyAMessagesRunFromTheIndexMovesIt(run: HistoryCursor.Run, through: UInt64) {
        var cursor = HistoryCursor()
        cursor.through = 4
        _ = cursor.start([run])
        _ = cursor.advance(indices: [7, 9], total: 40)
        #expect(cursor.through == through)
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

/// The index each history request asks from, in order.
private final class Asked: Sendable {
    let since = Mutex<[UInt64]>([])
}

/// A connected broker that keeps the history requests the engine sends.
private func recordingTransport() -> (Transport, Asked) {
    struct Request: Decodable { let since: UInt64 }
    let asked = Asked()
    let transport = Transport(publishing: { topic, payload in
        guard topic.hasSuffix("/batch"), let request = try? JSONDecoder().decode(Request.self, from: payload) else { return }
        asked.since.withLock { $0.append(request.since) }
    })
    return (transport, asked)
}

/// A text from `keyG` at server index `index`.
private func fromG(_ index: UInt64) -> Msg {
    Msg(message: #"{"content":"m\#(index)"}"#, type: 0, uuid: uuid(Int(index) + 1), tag: nil, index: String(index),
        sender: sender(keyG), msat: nil, timestamp: 1_000 * (index + 1), sentTo: nil, fromMe: false,
        paymentHash: nil, error: nil)
}

/// The core's reply to a page of history, or to a live message (no total).
private func reply(_ msgs: [Msg], total: UInt64?) -> RunReturn {
    var result = coreResult()
    result.msgs = msgs
    result.msgsTotal = total
    return result
}

/// Where catching up starts, through the engine: from the index history
/// was fetched through with no gap, whatever came live meanwhile.
struct HistorySyncTests {
    let profile = TempProfile()

    private func engine(_ storage: Storage, on transport: Transport) async throws -> Engine {
        let engine = try testEngine(storage)
        await engine.useTransportForTesting(transport)
        return engine
    }

    private func setUp() throws -> Storage {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            state: registeredState.merging(coreContact(keyG, contactKey: key3G)) { $1 },
            settings: [.server: "mqtt://127.0.0.1:1"], contacts: [(keyG, true)]
        ))
        return storage
    }

    /// A live message stored during a catch-up sits above messages not
    /// fetched yet. Peel quits before the catch-up ends; the next launch
    /// asks from the end of the last page, not from the live message.
    @Test func aLiveMessageDoesNotMoveWhereTheNextCatchUpStarts() async throws {
        let storage = try setUp()
        let (transport, asked) = recordingTransport()
        let first = try await engine(storage, on: transport)
        try await first.syncMessages()
        try await first.take(reply([fromG(0), fromG(1), fromG(2)], total: 20))
        try await first.take(reply([fromG(10)], total: nil), from: keyG)
        #expect(try storage.highestServerIndex() == 10)
        #expect(asked.since.withLock { $0 } == [0, 3])
        await first.disconnect()

        let next = try await engine(storage, on: transport)
        try await next.syncMessages()
        #expect(asked.since.withLock { $0 } == [0, 3, 3])
        await next.disconnect()
    }

    /// A page whose every onion the core refuses (it leaves them out of its
    /// reply) still moves the catch-up past them, by the indices the
    /// server sent; the next launch starts after them too.
    @Test func aPageTheCoreCannotReadMovesTheCatchUpOn() async throws {
        let storage = try setUp()
        let (transport, asked) = recordingTransport()
        let first = try await engine(storage, on: transport)
        try await first.syncMessages()
        // Unreadable onions as the server frames them (`encode_onion`): a
        // message at index 0, a payment at 1, a message at 2.
        func onion(_ index: UInt64, payment: Bool) -> Data {
            Data(count: payment ? 1366 : 1401) + be64(index) + be64(1_000) + be64(1)
                + (payment ? be64(5_000) + Data(count: 32) : Data())
        }
        var payload = Data([0x93])
        for item in [onion(0, payment: false), onion(1, payment: true), onion(2, payment: false)] {
            payload += Data([0xC5, UInt8(item.count >> 8), UInt8(item.count & 0xFF)]) + item
        }
        await first.receive(Inbound(topic: "root/pk/0/res/dev/batch/_/20", payload: payload))
        #expect(try storage.highestServerIndex() == nil)
        #expect(asked.since.withLock { $0 } == [0, 3])
        #expect(await first.isSyncingHistory)
        await first.disconnect()

        let next = try await engine(storage, on: transport)
        try await next.syncMessages()
        #expect(asked.since.withLock { $0 } == [0, 3, 3])
        await next.disconnect()
    }
}

private extension Engine {
    /// A core reply as `receive` takes one (`sender`, the contact a live
    /// message's topic names): committed, then followed up.
    func take(_ result: RunReturn, from sender: String? = nil) async throws {
        try await run(expectedSender: sender) { _, _ in result }
    }
}
