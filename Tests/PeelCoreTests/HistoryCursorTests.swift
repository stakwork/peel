import Foundation
import GRDB
import Sphinxrs
import Synchronization
import Testing
@testable import PeelCore
@testable import PeelTestSupport

private typealias Run = HistoryCursor.Run

private func counts(total: UInt64, highest: UInt64, keys: UInt64, keysHighest: UInt64) -> Engine.MessageCounts {
    Engine.MessageCounts(
        total: total, firstForEachKey: keys, totalHighestIndex: highest, firstForEachKeyHighestIndex: keysHighest
    )
}

/// A page for a run in flight.
private func advance(_ cursor: inout HistoryCursor, _ indices: [UInt64], total: UInt64?) throws -> HistoryCursor.Page {
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

    /// Where history stands moves only with a messages page that starts no
    /// further than it: a contacts page (one message per key) skips the
    /// messages between, and so does a run from further on.
    @Test(arguments: [
        (Run(phase: .messages, next: 5, end: nil), UInt64(10)),
        (Run(phase: .messages, next: 3, end: nil), UInt64(10)),
        (Run(phase: .contacts, next: 5, end: nil), UInt64(5)),
        (Run(phase: .messages, next: 6, end: nil), UInt64(5)),
    ])
    func onlyAMessagesRunFromWhereHistoryStandsMovesIt(run: HistoryCursor.Run, from: UInt64) {
        var cursor = HistoryCursor()
        cursor.from = 5
        _ = cursor.start([run])
        _ = cursor.advance(indices: [7, 9], total: 40)
        #expect(cursor.from == from)
    }

    /// A live message moves where history stands when it is the next
    /// index; one above a gap waits until the gap fills, by a later live
    /// message or a page.
    @Test func aLiveMessageMovesWhereHistoryStandsOnlyOverNoGap() throws {
        var cursor = HistoryCursor()
        cursor.from = 5
        cursor.cameLive(7)
        #expect(cursor.from == 5)
        cursor.cameLive(5)
        #expect(cursor.from == 6)
        cursor.cameLive(6)
        #expect(cursor.from == 8)
        cursor.cameLive(10)
        _ = cursor.start([Run(phase: .messages, next: 8, end: nil)])
        _ = try advance(&cursor, [8, 9], total: 20)
        #expect(cursor.from == 11)
        #expect(cursor.liveAbove.isEmpty)
        // No real index is that high: one that is is the server's mistake.
        cursor.cameLive(UInt64.max)
        #expect(cursor.liveAbove.isEmpty)
    }

    /// A page the core refused whole is asked about in halves: what it
    /// reads is kept, and what it refuses on its own left out.
    @Test(arguments: [
        ([], Array(0..<8)),
        ([3], [0, 1, 2, 4, 5, 6, 7]),
        ([0, 7], Array(1..<7)),
        (Array(0..<8), []),
    ])
    func aRefusedPageKeepsWhatTheCoreReads(refused: [Int], kept: [Int]) {
        #expect(Engine.readable(Array(0..<8)) { !Set(refused).isDisjoint(with: $0) } == kept)
    }

    /// A page the core refuses whole is read again without what it refuses
    /// on its own, which the error names, or with nothing when it refuses
    /// the rest together. A refusal of no message in particular (of an
    /// empty page too) is thrown as it came.
    @Test func aRefusedPageIsReadAgainWithoutWhatTheCoreRefuses() throws {
        let page = try #require(StateCodec.onions(inBatch: batchPage((0..<8).map { batchOnion(index: $0) })))
        func read(refusing refused: (Set<UInt64>) -> Bool) throws -> (kept: [String], error: String?) {
            let result = try Engine.readablePart(of: page, refusal: PeelError("refused")) { payload in
                let indices = (StateCodec.onions(inBatch: payload) ?? []).map(StateCodec.index(of:))
                if refused(Set(indices)) { throw PeelError("refused") }
                return coreResult(msgs: indices.map { .fixture(index: String($0)) })
            }
            return (result.msgs.compactMap(\.index), result.error)
        }
        let alone = try read { $0.contains(3) }
        #expect(alone.kept == ["0", "1", "2", "4", "5", "6", "7"])
        #expect(alone.error?.contains("(server index 3)") == true)
        let together = try read { $0.isSuperset(of: [2, 5]) }
        #expect(together.kept.isEmpty)
        #expect(together.error?.contains("(server index 0, 1, 2, 3, 4, 5, 6, 7)") == true)
        #expect(throws: PeelError.self) { try read { _ in true } }
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

/// Someone who writes to this account: their child key 1 to its child
/// key 1, where `coreContact` keeps them.
private let theirSeed = String(repeating: "22", count: 32)

private func theirKey() throws -> String {
    try Sphinxrs.pubkeyFromSeed(seed: theirSeed, idx: 1, time: "1000", network: "bitcoin")
}

/// A real Sphinx message of `type` from them, its onion as the server
/// keeps it (`createOnionMsg`), for the core to open with this account's key.
private func messageFromThem(type: Int, _ message: String) throws -> Data {
    let ours = try Sphinxrs.mnemonicToSeed(mnemonic: abandon.joined(separator: " "))
    let to = try Sphinxrs.pubkeyFromSeed(seed: ours, idx: 1, time: "1000", network: "bitcoin")
    let onion = try Sphinxrs.createOnionMsg(
        seed: theirSeed, idx: 1, time: "1000", network: "bitcoin", hops: #"[{"pubkey":"\#(to)"}]"#,
        json: #"{"type":\#(type),"sender":{"pubkey":""},"message":\#(message)}"#
    )
    try #require(onion.count == 1401)
    return onion
}

/// Their text at server index `index`, as the core reports one.
private func theirText(_ index: UInt64, from them: String) -> Msg {
    .fixture(message: #"{"content":"m\#(index)"}"#, uuid: uuid(Int(index) + 1), index: String(index), sender: sender(them),
             timestamp: 1_000 * (index + 1))
}

/// A page of history as the server sends it, its highest index 20.
private func page(_ onions: [Data]) -> Inbound {
    Inbound(topic: "root/pk/0/res/dev/batch/_/20", payload: batchPage(onions))
}

/// Where catching up starts, through the engine: where history stands,
/// every message below it handled, by a page or as it came live.
struct HistorySyncTests {
    let profile = TempProfile()

    /// A registered account with them as a contact.
    private func setUp(_ commit: Storage.Commit = Storage.Commit()) throws -> Storage {
        try registeredStorage(profile, contact: try theirKey(), commit)
    }

    /// A live message moves where the next catch-up starts only when no
    /// message below it is still to fetch. One stored during a catch-up
    /// above messages not fetched yet leaves it, so after a quit the next
    /// launch asks from the end of the last page, not after the live one
    /// (bug hunt N4); one just after it moves it, so the next catch-up
    /// does not fetch it again.
    @Test(arguments: [(UInt64(10), UInt64(3)), (3, 4)])
    func aLiveMessageMovesWhereTheNextCatchUpStartsOnlyOverNoGap(live: UInt64, nextStart: UInt64) async throws {
        let storage = try setUp()
        let them = try theirKey()
        let (transport, asked) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            try await engine.take(coreResult(msgs: (0...2).map { theirText($0, from: them) }, msgsTotal: 20))
            let message = try messageFromThem(type: MessageType.text, #"{"content":"live"}"#)
            await engine.receive(Inbound(topic: "root/pk/1/res/_/stream/\(live)/1000", payload: message))
            #expect(try storage.highestServerIndex() == Int64(live))
        }
        try await withTestEngine(storage, on: transport) { try await $0.syncMessages() }
        #expect(asked.since.withLock { $0 } == [0, 3, nextStart])
    }

    /// A profile from before the index was kept starts from its newest
    /// message stored (or dropped from a left tribe), as it did then:
    /// read before it connects, so a live message stored while it comes
    /// online cannot move that start past messages not fetched yet.
    @Test func aProfileFromBeforeStartsFromItsNewestMessageWhateverComesLive() async throws {
        let them = try theirKey()
        let stored = Message.fixture(uuid: uuid(1), serverIndex: 10, chat: them)
        let storage = try setUp(Storage.Commit(settings: [.droppedIndex: "12"], messages: [(stored, false, nil)]))
        let (transport, asked) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            let message = try messageFromThem(type: MessageType.text, #"{"content":"live"}"#)
            await engine.receive(Inbound(topic: "root/pk/1/res/_/stream/20/1000", payload: message))
            #expect(try storage.highestServerIndex() == 20)
            try await engine.syncMessages()
        }
        #expect(asked.since.withLock { $0 } == [13])
        #expect(try storage.value(for: .historyFrom) == "13")
    }

    /// A page whose every onion the core refuses (it leaves them out of its
    /// reply) still moves the catch-up past them, by the indices the
    /// server sent; the next launch starts after them too.
    @Test func aPageTheCoreCannotReadMovesTheCatchUpOn() async throws {
        let storage = try setUp()
        let (transport, asked) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            // Onions no key of this account opens: a message, a payment, a message.
            await engine.receive(page([batchOnion(index: 0), batchOnion(index: 1, paidMsat: 5_000), batchOnion(index: 2)]))
            #expect(try storage.highestServerIndex() == nil)
            #expect(await engine.isSyncingHistory)
        }
        try await withTestEngine(storage, on: transport) { try await $0.syncMessages() }
        #expect(asked.since.withLock { $0 } == [0, 3, 3])
    }

    /// One message can fail its whole page in the core: a malformed chunk
    /// (type 34), which any contact or tribe member can send, fails the
    /// call. The page is read again without it: the rest is kept, the
    /// catch-up goes on past it and names what it left out, where it once
    /// stopped there at every launch.
    @Test func aMessageThatFailsItsWholePageIsLeftOutAlone() async throws {
        let storage = try setUp()
        let (transport, asked) = recordingTransport()
        var errors: [String] = []
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            await engine.receive(page([
                batchOnion(index: 0, data: try messageFromThem(type: MessageType.text, #"{"content":"before"}"#)),
                batchOnion(index: 1, data: try messageFromThem(type: 34, #"{"content":"not a chunk"}"#)),
                batchOnion(index: 2, data: try messageFromThem(type: MessageType.text, #"{"content":"after"}"#)),
            ]))
            await engine.close()
            for await case .coreError(let error) in engine.events { errors.append(error) }
        }
        let kept = try rows(profile, "SELECT content FROM message ORDER BY serverIndex").map { $0["content"] as String? }
        #expect(kept == ["before", "after"])
        #expect(asked.since.withLock { $0 } == [0, 3])
        #expect(errors.contains { $0.contains("server index 1)") })
    }
}

private extension Engine {
    /// A core reply as `receive` takes one: committed, then followed up.
    func take(_ result: RunReturn) async throws {
        try await run { _, _ in result }
    }
}
