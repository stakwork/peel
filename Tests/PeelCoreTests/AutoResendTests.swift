import Foundation
import Testing
@testable import PeelCore

/// Which undelivered messages a reconnect sends again by itself
/// (`Message.isAutoResendable`, `Storage.undeliveredSends`): recent ones
/// that move no money, never a payment, a boost or anything with sats.
struct AutoResendTests {
    let profile = TempProfile()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ours(
        _ type: Int = MessageType.text, status: Message.Delivery = .failed, ago: TimeInterval = 60,
        msat: Int64? = nil, body: String? = #"{"content":"hi"}"#
    ) -> Message {
        Message.fixture(
            type: type, fromMe: true, body: body, msat: msat,
            timestamp: now.addingTimeInterval(-ago).millisecondsSince1970, tag: "t", status: status.rawValue
        )
    }

    @Test func aRecentFailedOrUnconfirmedTextGoes() {
        #expect(ours().isAutoResendable(now: now))
        #expect(ours(status: .pending).isAutoResendable(now: now))
        #expect(ours(ago: Message.autoResendWindow).isAutoResendable(now: now))
        // Not yet past the confirmation timeout: it may still be on its way.
        #expect(!ours(status: .pending, ago: 5).isAutoResendable(now: now))
        #expect(!ours(status: .delivered).isAutoResendable(now: now))
        #expect(!ours(ago: 2 * 60 * 60).isAutoResendable(now: now))
        var deleted = ours()
        deleted.deleted = true
        #expect(!deleted.isAutoResendable(now: now))
        #expect(!Message.fixture(fromMe: false, status: "FAILED").isAutoResendable(now: now))
    }

    @Test func nothingThatMovesMoneyGoes() {
        // Retryable by hand, never by itself.
        let payment = ours(MessageType.directPayment, msat: 10_000)
        #expect(payment.isRetryable(now: now))
        #expect(!payment.isAutoResendable(now: now))
        #expect(!ours(MessageType.boost, msat: 10_000).isAutoResendable(now: now))
        #expect(!ours(MessageType.purchase, msat: 10_000).isAutoResendable(now: now))
        #expect(!ours(MessageType.groupJoin).isAutoResendable(now: now))
        // A tribe message pays the tribe's price.
        let tribeText = ours(msat: 3_000)
        #expect(tribeText.isRetryable(now: now))
        #expect(!tribeText.isAutoResendable(now: now))
        // A payment request moves nothing.
        #expect(ours(MessageType.invoice).isAutoResendable(now: now))
    }

    @Test func anAttachmentGoesOnlyOnceUploadedAndNotForSale() {
        var file = ours(MessageType.attachment, body: #"{"mediaKey":"k"}"#)
        file.upload = Message.Upload.failed.rawValue
        #expect(file.isRetryable(now: now))
        #expect(!file.isAutoResendable(now: now))
        file.upload = Message.Upload.done.rawValue
        #expect(file.isAutoResendable(now: now))
        file.body = #"{"mediaKey":"k","price":"100"}"#
        #expect(!file.isAutoResendable(now: now))
    }

    @Test func theCandidatesAreRecentUndeliveredOnesOldestFirst() throws {
        let storage = try profile.storage()
        let recent = Date.now.addingTimeInterval(-120).millisecondsSince1970
        func row(_ n: Int, _ status: Message.Delivery, at timestamp: Int64, type: Int = MessageType.text) -> Message {
            Message.fixture(
                uuid: "uuid-\(n)", type: type, fromMe: true, content: "m\(n)", timestamp: timestamp, tag: "t\(n)",
                status: status.rawValue
            )
        }
        let rows = [
            row(1, .failed, at: recent + 2), row(2, .pending, at: recent + 1), row(3, .delivered, at: recent),
            row(4, .failed, at: recent - 3 * 60 * 60 * 1000),
            row(5, .failed, at: recent, type: MessageType.directPayment),
        ]
        _ = try storage.apply(Storage.Commit(messages: rows.map { ($0, false, nil) }))
        let since = Date.now.addingTimeInterval(-Message.autoResendWindow).millisecondsSince1970
        #expect(try storage.undeliveredSends(since: since).map(\.content) == ["m2", "m1"])
    }

    /// Once a reconnect has sent a message again, never by itself again (the
    /// mark is stored, so it holds across a relaunch); and the hour counts
    /// from the first send, not the last attempt.
    @Test func itGoesByItselfOnceAndOnlyWithinAnHourOfItsFirstSend() {
        var resent = ours()
        resent.autoResentAt = now.millisecondsSince1970
        #expect(!resent.isAutoResendable(now: now))
        var retried = ours(ago: 60)
        retried.firstSentAt = now.addingTimeInterval(-2 * 60 * 60).millisecondsSince1970
        #expect(retried.isRetryable(now: now))
        #expect(!retried.isAutoResendable(now: now))
    }

    @Test func aResendKeepsTheFirstSendAndMarksOnlyAReconnectsOwn() throws {
        let storage = try profile.storage()
        let row = Message.fixture(uuid: "uuid-1", fromMe: true, timestamp: 1_000, tag: "t1", status: "FAILED")
        _ = try storage.apply(Storage.Commit(messages: [(row, false, nil)]))
        let id = try #require(try storage.undeliveredSends(since: 0).first?.id)
        _ = try storage.apply(Storage.Commit(resend: (id, "02aa", "uuid-2", "t2", nil, nil, 5_000, false)))
        var stored = try #require(try storage.message(id: id))
        #expect(stored.firstSentAt == 1_000)
        #expect(stored.timestamp == 5_000)
        #expect(stored.autoResentAt == nil)
        try storage.setStatus(.failed, tag: "t2")
        _ = try storage.apply(Storage.Commit(resend: (id, "02aa", "uuid-3", "t3", nil, nil, 9_000, true)))
        stored = try #require(try storage.message(id: id))
        #expect(stored.firstSentAt == 1_000)
        #expect(stored.autoResentAt == 9_000)
        // Neither a second try nor the query offers it again.
        try storage.setStatus(.failed, tag: "t3")
        #expect(try storage.undeliveredSends(since: 0).isEmpty)
    }

    /// The per-row decision of a reconnect (`Engine.autoResends`), against
    /// what the server was asked and what its records named.
    @Test func aTaggedRowGoesOnlyIfAskedAboutAndUnrecorded() {
        func go(_ message: Message, _ gate: Engine.ResendGate?) -> Bool {
            Engine.autoResends(message, gate: gate, now: now)
        }
        let failed = ours()
        #expect(go(failed, (["t"], [])))
        #expect(go(failed, (["t"], ["other"])))
        // Recorded with any status (COMPLETE, FAILED, PENDING): the server has it.
        #expect(!go(failed, (["t"], ["t"])))
        // Not asked about, no answer yet, or never asked.
        #expect(!go(failed, ([], [])))
        #expect(!go(failed, (["t"], nil)))
        #expect(!go(failed, nil))
        // Never sent again by itself twice.
        var resent = failed
        resent.autoResentAt = now.millisecondsSince1970
        #expect(!go(resent, (["t"], [])))
    }

    @Test func aPendingRowGoesOnlyOnceItCannotStillBeOnItsWay() {
        func go(_ message: Message, _ gate: Engine.ResendGate?) -> Bool {
            Engine.autoResends(message, gate: gate, now: now)
        }
        // Unconfirmed past the timeout but maybe still in flight.
        #expect(!go(ours(status: .pending, ago: 60), (["t"], [])))
        #expect(go(ours(status: .pending, ago: Message.inFlightLimit + 1), (["t"], [])))
        // The server holds it as PENDING: it has it, however old.
        #expect(!go(ours(status: .pending, ago: Message.inFlightLimit + 1), (["t"], ["t"])))
        // The limit counts from the first send, not a later Retry.
        var retried = ours(status: .pending, ago: 60)
        retried.firstSentAt = now.addingTimeInterval(-Message.inFlightLimit - 1).millisecondsSince1970
        #expect(go(retried, (["t"], [])))
    }

    @Test func anUntaggedRowGoesOnlyIfFailed() {
        var failed = ours()
        failed.tag = nil
        #expect(Engine.autoResends(failed, gate: nil, now: now))
        var pending = ours(status: .pending, ago: Message.inFlightLimit + 1)
        pending.tag = nil
        #expect(!Engine.autoResends(pending, gate: nil, now: now))
    }

    @Test func noTribeMessageIsACandidate() throws {
        let storage = try profile.storage()
        let row = Message.fixture(uuid: "uuid-1", chat: "02bb", fromMe: true, timestamp: 1_000, tag: "t1", status: "FAILED")
        _ = try storage.apply(Storage.Commit(messages: [(row, false, nil)], tribes: [Tribe(pubkey: "02bb")]))
        #expect(try storage.undeliveredSends(since: 0).isEmpty)
    }
}
