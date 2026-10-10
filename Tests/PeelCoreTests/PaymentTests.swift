import Foundation
import GRDB
import Testing
@testable import PeelCore

private let other = "02bb"
/// A photo URL too long to go with any payment.
private let longPhoto = "https://" + String(repeating: "p", count: 600)

struct PaymentTests {
    let profile = TempProfile()

    private func boost(
        _ n: Int, on parent: Int, chat: String = dm, fromMe: Bool = false, sats: Int64, alias: String? = nil,
        status: Message.Delivery? = nil, paid: Bool = true
    ) -> Message {
        .fixture(
            uuid: uuid(n), type: MessageType.boost, chat: chat, fromMe: fromMe,
            sender: alias.map { sender(alias: $0) }, content: "",
            msat: !fromMe && paid ? sats * 1000 : nil,
            timestamp: Int64(n) * 1_000, status: status?.rawValue, replyUUID: uuid(parent), amountMsat: sats * 1000
        )
    }

    private func payment(_ n: Int, chat: String = dm, fromMe: Bool = false, sats: Int64) -> Message {
        .fixture(
            uuid: uuid(n), type: MessageType.directPayment, chat: chat, fromMe: fromMe, content: "for lunch",
            timestamp: Int64(n) * 1_000, amountMsat: sats * 1000
        )
    }

    private func storage(_ messages: [Message]) throws -> Storage {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            contacts: [(dm, true), (other, true)], messages: messages.map { ($0, false, nil) }
        ))
        return storage
    }

    @Test func timelineSumsBoostsPerMessage() async throws {
        let storage = try storage([
            text(1), text(2, fromMe: true),
            boost(10, on: 1, fromMe: true, sats: 100),
            boost(11, on: 2, sats: 21, alias: "bob"),
            boost(12, on: 2, sats: 5, alias: "bob"),
            // Our own failed boost is not counted; a boost in another chat never is.
            boost(13, on: 1, fromMe: true, sats: 50, status: .failed),
            boost(14, on: 1, chat: other, sats: 7),
        ])
        let timeline = try #require(try await first(storage.timeline(in: dm)))
        // Boosts are not rows of their own.
        #expect(timeline.messages.map(\.uuid) == [uuid(1), uuid(2)])
        let mine = try #require(timeline.boosts[uuid(1)])
        #expect(mine.count == 1)
        #expect(mine.totalMsat == 100_000)
        #expect(mine.boostedByMe)
        // Kept apart, for Retry.
        #expect(mine.failed.map(\.uuid) == [uuid(13)])
        let theirs = try #require(timeline.boosts[uuid(2)])
        #expect(theirs.count == 2)
        #expect(theirs.totalMsat == 26_000)
        #expect(theirs.boosts.map(\.alias) == ["bob", "bob"])
        #expect(!theirs.boostedByMe)
    }

    /// Someone else's boost on our message shows what reached us, not the
    /// amount its sender declared (a tribe boost may arrive without sats).
    @Test func aBoostOnOurMessageCountsOnlyTheSatsThatArrived() async throws {
        let storage = try storage([text(1, fromMe: true), boost(2, on: 1, sats: 100_000, alias: "mallory", paid: false)])
        let timeline = try #require(try await first(storage.timeline(in: dm)))
        #expect(timeline.boosts[uuid(1)]?.totalMsat == 0)
    }

    @Test func threadViewSumsBoostsToo() async throws {
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: other)])
        var reply = text(2, chat: other)
        reply.threadUUID = uuid(1)
        _ = try storage.apply(Storage.Commit(messages: [
            (text(1, chat: other), false, nil), (reply, false, nil),
            (boost(10, on: 1, chat: other, sats: 3, alias: "carol"), false, nil),
            (boost(11, on: 2, chat: other, sats: 4, alias: "dave"), false, nil),
        ]))
        let thread = try #require(try await first(storage.thread(uuid(1), in: other)))
        #expect(thread.boosts[uuid(1)]?.totalMsat == 3_000)
        #expect(thread.boosts[uuid(2)]?.boosts.first?.alias == "dave")
    }

    @Test func paymentsInAChatAndInAll() async throws {
        let storage = try storage([
            text(1), payment(2, sats: 10), boost(3, on: 1, fromMe: true, sats: 20),
            payment(4, chat: other, fromMe: true, sats: 30),
        ])
        let inChat = try #require(try await first(storage.payments(in: dm)))
        #expect(inChat.map(\.uuid) == [uuid(3), uuid(2)])
        let all = try #require(try await first(storage.payments()))
        #expect(all.map(\.amountMsat) == [30_000, 20_000, 10_000])
    }

    @Test func aPaidCopyCorrectsAnUnpaidOne() throws {
        var unpaid = payment(1, sats: 99)
        unpaid.amountMsat = nil
        let storage = try storage([unpaid])
        var paid = payment(1, sats: 10)
        paid.msat = 10_000
        let row = try #require(try storage.apply(Storage.Commit(messages: [(paid, false, nil)])).stored.first)
        #expect(row.amountMsat == 10_000)
    }

    @Test func amountIsKeptFromTheFirstCopy() throws {
        let storage = try storage([payment(1, sats: 10)])
        var echo = payment(1, sats: 99)
        echo.serverIndex = 5
        let row = try #require(try storage.apply(Storage.Commit(messages: [(echo, false, nil)])).stored.first)
        #expect(row.serverIndex == 5)
        #expect(row.amountMsat == 10_000)
    }

    /// Payments to us and boosts on our messages are unread; someone else's
    /// boost on someone else's message is not (Tom, 2026-10-07).
    @Test func onlyMoneyForMeCountsAsUnread() async throws {
        let rows = [
            text(1), text(2, fromMe: true), payment(3, sats: 1),
            boost(4, on: 1, sats: 1), boost(5, on: 2, sats: 1), payment(6, fromMe: true, sats: 1),
        ].enumerated().map { offset, message in
            var message = message
            message.serverIndex = Int64(offset + 1)
            return message
        }
        let storage = try storage(rows)
        let states = try #require(try await first(storage.readStates()))
        // Their text, their payment, their boost on our message.
        #expect(states[dm]?.unread == 3)
    }

    /// Someone's payment with its sats: told once the server's history has
    /// its incoming row (payments review F2), never on the message alone.
    private func paid(_ message: Message, index: Int64) -> Message {
        var message = message
        message.serverIndex = index
        message.msat = message.amountMsat
        message.paymentHash = uuid(1_000 + Int(index))
        return message
    }

    private func arrivedRows(_ indexes: [Int64], ts: Int64 = 50_000) -> [PaymentRecord] {
        indexes.map {
            PaymentRecord(rhash: uuid(1_000 + Int($0)), ts: ts, amountMsat: 1, incoming: true, msgIndex: $0, remote: false)
        }
    }

    @Test func moneyForMeIsReportedOnceForNotifications() throws {
        let storage = try storage([text(1), text(2, fromMe: true)])
        let incoming = [
            paid(payment(3, sats: 10), index: 3), paid(boost(4, on: 2, sats: 5), index: 4),
            // Someone else's boost on someone else's message, and an unpaid "payment".
            paid(boost(5, on: 1, sats: 5), index: 5), payment(6, sats: 99),
        ]
        let commit = Storage.Commit(messages: incoming.map { ($0, false, nil) })
        let stored = try storage.apply(commit)
        // News when it came; told only once confirmed.
        #expect(stored.confirmed.isEmpty && stored.newMoney)
        let ids = try [uuid(3), uuid(4)].map { try storage.message(uuid: $0, in: dm)?.id }
        #expect(stored.announceable == ids.compactMap { $0 })
        // The same copies again (history, the server's echo) are not news.
        #expect(try storage.apply(commit).announceable.isEmpty)
        // Nor is what was already read when it arrived.
        #expect(try storage.apply(
            Storage.Commit(messages: [(paid(payment(7, sats: 1), index: 7), false, nil)], reads: [dm: 7])
        ).announceable.isEmpty)
        let rows = Storage.Commit(payments: arrivedRows([3, 4, 5]))
        #expect(try storage.apply(rows).confirmed.map(\.uuid) == [uuid(3), uuid(4), uuid(5)])
        // The same rows again (the next refresh) confirm nothing new.
        #expect(try storage.apply(rows).confirmed.isEmpty)
    }

    /// Review F-A: a payment in the chat open on screen is marked read as it
    /// lands, before the history confirms it; it was news when it came, so
    /// it is still told.
    @Test func moneyInTheOpenChatIsStillToldOnceConfirmed() throws {
        let storage = try storage([text(1)])
        let stored = try storage.apply(Storage.Commit(messages: [(paid(payment(3, sats: 10), index: 3), false, nil)]))
        let id = try #require(stored.announceable.first)
        #expect(try storage.setRead(chat: dm, index: 3, as: .read))
        let confirmed = try storage.apply(Storage.Commit(payments: arrivedRows([3])))
        #expect(confirmed.confirmed.map(\.id) == [id])
    }

    /// Review F-F: the history row was fetched before the message came; the
    /// message is confirmed as it is stored.
    @Test func aRowAlreadyStoredConfirmsTheMessageAsItLands() throws {
        let storage = try storage([text(1)])
        _ = try storage.apply(Storage.Commit(payments: arrivedRows([3])))
        let stored = try storage.apply(Storage.Commit(messages: [(paid(payment(3, sats: 10), index: 3), false, nil)]))
        #expect(stored.confirmed.map(\.uuid) == [uuid(3)] && stored.announceable.count == 1)
    }

    /// Review F-D: a row with no index never vouches for a message the
    /// server delivered (every one has an index), whatever hash it claims.
    @Test func aHashAloneNeverConfirmsADeliveredMessage() throws {
        let storage = try storage([paid(payment(3, sats: 10), index: 3)])
        let hashOnly = PaymentRecord(rhash: uuid(1_003), ts: 50_000, amountMsat: 1, incoming: true, remote: false)
        #expect(try storage.apply(Storage.Commit(payments: [hashOnly])).confirmed.isEmpty)
        try storage.markNotArrived(storedThrough: try #require(try storage.highestMessageID()), since: 0)
        #expect(try storage.message(uuid: uuid(3), in: dm)?.arrived == false)
    }

    /// Two payments came, the server's history has one (review F2, journey
    /// 1): the other never arrived, in the chat, Payments and boost totals.
    @Test func aPaymentWhoseSatsNeverCameIsNotReceived() async throws {
        let storage = try storage([
            text(1, fromMe: true), paid(payment(2, sats: 4), index: 2), paid(payment(3, sats: 4), index: 3),
            paid(boost(4, on: 1, sats: 5), index: 4),
        ])
        _ = try storage.apply(Storage.Commit(payments: arrivedRows([2])))
        let stored = try #require(try storage.highestMessageID())
        // Judged only from where the fetch reached, and only what was stored by then.
        try storage.markNotArrived(storedThrough: stored, since: 3_500)
        func arrived(_ n: Int) throws -> Bool? { try storage.message(uuid: uuid(n), in: dm)?.arrived }
        #expect(try arrived(2) == true && arrived(3) == nil && arrived(4) == false)
        try storage.markNotArrived(storedThrough: stored, since: 0)
        #expect(try arrived(3) == false)

        let items = try await storage.pool.read { db in try Storage.paymentItems(limit: 50, db) }.filter(\.incoming)
        #expect(items.filter { $0.status == .complete }.map(\.paymentHash) == [uuid(1_002)])
        #expect(items.first { $0.message?.uuid == uuid(3) }?.error == PaymentItem.notArrived)
        let timeline = try #require(try await first(storage.timeline(in: dm)))
        #expect(timeline.boosts[uuid(1)]?.totalMsat == 0)

        // A row that turns up after all still counts it, and tells it.
        #expect(try storage.apply(Storage.Commit(payments: arrivedRows([4]))).confirmed.map(\.uuid) == [uuid(4)])
        #expect(try arrived(4) == true)
    }

    @Test func aPaymentMovesItsConversationUp() async throws {
        let storage = try storage([text(1), payment(2, sats: 1_000), text(1_500, chat: other)])
        let conversations = try #require(try await first(storage.conversations()))
        #expect(conversations.first { $0.chat == dm }?.lastTimestamp == 2_000)
        // A boost does not.
        _ = try storage.apply(Storage.Commit(messages: [(boost(3_000, on: 1, chat: other, sats: 1), false, nil)]))
        let after = try #require(try await first(storage.conversations()))
        #expect(after.first { $0.chat == other }?.lastTimestamp == 1_500_000)
    }

    @Test func migrationFillsAmountsStoredBefore() throws {
        do { _ = try profile.storage() }
        let queue = try profile.queue()
        try queue.write { db in
            try db.execute(sql: """
                DROP INDEX message_payment;
                ALTER TABLE message DROP COLUMN amountMsat;
                DROP INDEX message_pending;
                DELETE FROM grdb_migrations WHERE identifier = 'v11';
                INSERT INTO tribe (pubkey) VALUES ('02bb');
                INSERT INTO message (uuid, type, chat, fromMe, body, msat) VALUES
                    ('a', 5, '02aa', 0, '{"content":"x","amount":9000}', 8000),
                    ('b', 29, '02bb', 0, '{"content":"","amount":3000,"replyUuid":"r"}', NULL),
                    ('f', 5, '02aa', 0, '{"content":"unpaid","amount":9000}', NULL),
                    ('g', 29, '02aa', 1, '{"content":"","amount":4000,"replyUuid":"r"}', NULL),
                    ('c', 0, '02aa', 0, '{"content":"text","amount":3000}', 3000),
                    ('d', 29, '02aa', 0, 'not json', NULL),
                    ('e', 29, '02aa', 0, '{"content":"","amount":"abc"}', NULL);
                """)
        }
        let storage = try profile.storage()
        #expect(try storage.message(uuid: "a", in: dm)?.amountMsat == 8000)
        #expect(try storage.message(uuid: "b", in: other)?.amountMsat == 3000)
        // A declared amount counts only for our own and tribe boosts: an
        // unpaid "payment" from a contact is worth nothing.
        #expect(try storage.message(uuid: "f", in: dm)?.amountMsat == nil)
        #expect(try storage.message(uuid: "g", in: dm)?.amountMsat == 4000)
        #expect(try storage.message(uuid: "c", in: dm)?.amountMsat == nil)
        #expect(try storage.message(uuid: "d", in: dm)?.amountMsat == nil)
        #expect(try storage.message(uuid: "e", in: dm)?.amountMsat == nil)
    }

    @Test func aRetriedPaymentTakesTheNewSend() throws {
        var failed = payment(1, fromMe: true, sats: 10)
        failed.tag = "t1"
        failed.status = Message.Delivery.failed.rawValue
        let storage = try storage([failed])
        let id = try #require(try storage.message(uuid: uuid(1), in: dm)?.id)
        let rows = try storage.apply(Storage.Commit(
            resend: (id, dm, uuid(2), "t2", "hash2", 5_000, false)
        )).stored
        let row = try #require(rows.first)
        #expect(row.uuid == uuid(2))
        #expect(row.tag == "t2")
        #expect(row.paymentHash == "hash2")
        #expect(row.delivery == .pending)
        #expect(row.amountMsat == 10_000)
    }

    @Test func onlyAFailedPaymentIsRetryable() {
        let old = Date(timeIntervalSince1970: 0)
        var row = payment(1, fromMe: true, sats: 1)
        row.status = Message.Delivery.pending.rawValue
        // Unconfirmed may have paid: never sent again, however long it waits.
        #expect(!row.isRetryable(now: old.addingTimeInterval(3600)))
        row.status = Message.Delivery.failed.rawValue
        // Ours from history or another device (no sats kept): failed, never paid again from here.
        #expect(!row.isRetryable())
        row.msat = 1_000
        #expect(row.isRetryable())
        #expect(!payment(1, sats: 1).isRetryable())
    }

    @Test func onlySomeoneElsesTextIsBoostable() {
        #expect(text(1).isBoostable)
        #expect(!text(1, fromMe: true).isBoostable)
        #expect(!payment(1, sats: 1).isBoostable)
        #expect(!Message.fixture(uuid: nil).isBoostable)
    }

    @Test func aLongNoteWouldBeSplit() {
        #expect(!Engine.wouldBeSplit(#"{"content":"lunch"}"#, alias: "alice", photoURL: ""))
        let long = #"{"content":"\#(String(repeating: "x", count: 500))"}"#
        #expect(Engine.wouldBeSplit(long, alias: "alice", photoURL: ""))
        // A long photo URL leaves less room.
        let medium = #"{"content":"\#(String(repeating: "x", count: 300))"}"#
        #expect(!Engine.wouldBeSplit(medium, alias: "alice", photoURL: ""))
        #expect(Engine.wouldBeSplit(medium, alias: "alice", photoURL: "https://" + String(repeating: "p", count: 200)))
    }

    /// A boost has no note: a photo URL too long for it goes, the boost does not stop.
    @Test func aPaymentGoesWithoutAPhotoThatWouldSplitIt() throws {
        let boost = #"{"content":"","replyUuid":"\#(uuid(1))"}"#
        #expect(try Engine.fittingPayment(boost, alias: "alice", photoURL: "https://a/p.png") == (boost, "https://a/p.png"))
        #expect(try Engine.fittingPayment(boost, alias: "alice", photoURL: longPhoto) == (boost, ""))
        // The offset goes before the photo.
        let note = #"{"content":"\#(String(repeating: "x", count: 300))","metadata":"{\"tz\":\"\#(String(repeating: "x", count: 200))\"}"}"#
        let (withoutOffset, kept) = try Engine.fittingPayment(note, alias: "alice", photoURL: "https://a/p.png")
        #expect(!withoutOffset.contains("metadata"))
        #expect(kept == "https://a/p.png")
    }

    @Test func whatStillDoesNotFitNamesTheNoteOrTheName() {
        #expect(throws: Engine.Failure.noteTooLong) {
            try Engine.fittingPayment(#"{"content":"\#(String(repeating: "x", count: 600))"}"#, alias: "alice", photoURL: longPhoto)
        }
        #expect(throws: Engine.Failure.nameTooLong) {
            try Engine.fittingPayment(#"{"content":""}"#, alias: String(repeating: "a", count: 600), photoURL: longPhoto)
        }
        // A short note is not to blame for a name that fits nowhere.
        #expect(throws: Engine.Failure.nameTooLong) {
            try Engine.fittingPayment(#"{"content":"hi"}"#, alias: String(repeating: "a", count: 600), photoURL: "")
        }
    }

    /// The threshold rule for the custom boost, payments and saving a boost
    /// amount (a one-tap boost is never asked): over it asks, a confirmation
    /// covers exactly its amount, and 0 asks for everything.
    @Test func overTheThresholdAsksForThatAmount() {
        #expect(!Engine.needsConfirmation(10_000, confirmedMsat: nil, thresholdMsat: 10_000))
        #expect(Engine.needsConfirmation(10_001, confirmedMsat: nil, thresholdMsat: 10_000))
        #expect(!Engine.needsConfirmation(10_001, confirmedMsat: 10_001, thresholdMsat: 10_000))
        #expect(Engine.needsConfirmation(10_002, confirmedMsat: 10_001, thresholdMsat: 10_000))
        #expect(Engine.needsConfirmation(1_000, confirmedMsat: nil, thresholdMsat: 0))
    }

    /// The double-tap guard reads our newest boost on a message, failed ones too.
    @Test func ourLastBoostOnAMessage() throws {
        let storage = try storage([
            text(1), boost(2, on: 1, fromMe: true, sats: 1), boost(3, on: 1, fromMe: true, sats: 1, status: .failed),
            boost(4, on: 1, sats: 1),
        ])
        #expect(try storage.lastOwnBoost(on: uuid(1), in: dm) == Date(millisecondsSince1970: 3_000))
        #expect(try storage.lastOwnBoost(on: uuid(9), in: dm) == nil)
    }

    @Test func theDeclaredAmountIsReadOnItsOwn() {
        #expect(DeclaredAmount.decode(#"{"content":"","amount":21000,"replyUuid":"r"}"#) == 21_000)
        // An odd amount is no amount, and the rest of the message still reads.
        let odd = #"{"content":"hi","amount":-1,"replyUuid":"r"}"#
        #expect(DeclaredAmount.decode(odd) == nil)
        #expect(BodyFields.decode(odd)?.replyUuid == "r")
    }
}

/// Which rows a send status moves (`Engine.liveStatus`,
/// `Engine.recordedStatuses`), and that payments only ever move forward.
struct SendStatusTests {
    let profile = TempProfile()

    private func status(_ tag: String?, _ status: String) -> SentStatus {
        SentStatus(tag: tag, status: status)
    }

    private func live(_ tag: String?, _ value: String) -> String? {
        Engine.liveStatus(status(tag, value)).map { "\($0.tag) \($0.status)" }
    }

    private func recorded(_ records: [SentStatus], unrecorded: Set<String> = []) -> [String] {
        Engine.recordedStatuses(records, unrecorded: unrecorded).map { "\($0.tag) \($0.status)" }
    }

    @Test func liveFinalStatusesApplyAsSent() {
        #expect(live("t1", "COMPLETE") == "t1 COMPLETE")
        #expect(live("t1", "FAILED") == "t1 FAILED")
    }

    // The mixer's last word on a payment whose recipient it reached but that
    // did not settle in its window; it never sends another for that tag.
    @Test func livePendingIsUnsettled() {
        #expect(live("t1", "PENDING") == "t1 UNSETTLED")
    }

    @Test func liveStatusWithoutTagOrUnknownChangesNothing() {
        #expect(live(nil, "COMPLETE") == nil)
        #expect(live("t1", "SETTLED") == nil)
        #expect(live("t1", "UNSETTLED") == nil)
    }

    // A recorded PENDING may be an async payment still held for an offline
    // recipient: not an answer.
    @Test func recordsApplyOnlyFinalStatuses() {
        let records = [
            status("t1", "COMPLETE"), status("t2", "PENDING"), status("t3", "FAILED"), status("t4", "UNSETTLED"),
        ]
        #expect(recorded(records) == ["t1 COMPLETE", "t3 FAILED"])
    }

    /// The connect-time check reads the three tables that track a send by
    /// tag in one go: our payments and boosts at once and text only once it
    /// has waited, the invoices we pay, and the payments funding invites.
    @Test func pendingSendsAreReadFromAllThreeTables() throws {
        let storage = try profile.storage()
        let pending = Message.Delivery.pending.rawValue
        var commit = Storage.Commit(contacts: [(dm, true)], messages: [
            (.fixture(uuid: uuid(1), type: MessageType.boost, chat: dm, fromMe: true, timestamp: 5_000, tag: "boost",
                      status: pending), false, nil),
            (.fixture(uuid: uuid(2), chat: dm, fromMe: true, timestamp: 1_000, tag: "old", status: pending), false, nil),
            (.fixture(uuid: uuid(3), chat: dm, fromMe: true, timestamp: 9_000, tag: "new", status: pending), false, nil),
            // Restored, with no status (review F4): asked about, never failed for want of a record.
            (.fixture(uuid: uuid(4), type: MessageType.directPayment, chat: dm, fromMe: true, timestamp: 7_000,
                      tag: "restored"), false, nil),
            (.fixture(uuid: uuid(5), chat: dm, fromMe: true, timestamp: 7_000, tag: "restored text"), false, nil),
        ])
        commit.invoices = [InvoiceRecord(
            paymentHash: coffeeHash, incoming: false, bolt11: coffee, amountMsat: 1, memo: "", payee: coffeePayee,
            createdAt: 2_000, status: .pending, tag: "invoice"
        )]
        commit.invites = [InviteRecord(
            code: String(repeating: "ab", count: 32), link: "sphinx.chat://?action=i&d=x", amountMsat: 1,
            tag: "invite", status: .sending, createdAt: 3_000
        )]
        _ = try storage.apply(commit)
        #expect(Set(try storage.pendingSendTags(textBefore: 2_000)) == [
            .init(tag: "boost", createdAt: 5_000, movesMoney: true),
            .init(tag: "old", createdAt: 1_000, movesMoney: false),
            .init(tag: "restored", createdAt: 7_000, movesMoney: false),
            .init(tag: "invoice", createdAt: 2_000, movesMoney: true),
            .init(tag: "invite", createdAt: 3_000, movesMoney: true),
        ])
    }

    @Test func unrecordedOldPaymentsFailWhenTheServerHasNoRecord() {
        #expect(recorded([status("t1", "PENDING")], unrecorded: ["t1", "t2"]) == ["t2 FAILED"])
    }

    private func storedBoost(_ storage: Storage) throws -> Message? {
        let boost = Message.fixture(
            uuid: uuid(2), type: MessageType.boost, chat: dm, fromMe: true, content: "", msat: 21_000, tag: "t1",
            status: Message.Delivery.pending.rawValue, replyUUID: uuid(1), amountMsat: 21_000
        )
        _ = try storage.apply(Storage.Commit(
            contacts: [(dm, true)], messages: [(.fixture(uuid: uuid(1), chat: dm), false, nil), (boost, false, nil)]
        ))
        let unsettled = try #require(Engine.liveStatus(status("t1", "PENDING")))
        _ = try storage.apply(Storage.Commit(statuses: [unsettled]))
        return try storage.message(uuid: uuid(2), in: dm)
    }

    @Test func anUnsettledBoostIsNeitherPendingNorRetryable() async throws {
        let storage = try profile.storage()
        let stored = try #require(try storedBoost(storage))
        #expect(stored.delivery == .unsettled)
        #expect(!stored.isRetryable())
        // Not asked about again: the mixer's records say PENDING for good.
        #expect(try storage.pendingSendTags(textBefore: .max).isEmpty)
        let summary = try #require(try await first(storage.timeline(in: dm))?.boosts[uuid(1)])
        #expect(summary.count == 1)
        #expect(summary.pendingSince == nil)
        #expect(summary.unsettled.map(\.amountMsat) == [21_000])
    }

    @Test func anUnsettledBoostMovesOnToDeliveredOrFailed() throws {
        let storage = try profile.storage()
        _ = try storedBoost(storage)
        _ = try storage.apply(Storage.Commit(statuses: [(tag: "t1", status: "COMPLETE")]))
        // Delivered stays delivered whatever comes after.
        _ = try storage.apply(Storage.Commit(statuses: [(tag: "t1", status: "FAILED"), (tag: "t1", status: "UNSETTLED")]))
        #expect(try storage.message(uuid: uuid(2), in: dm)?.delivery == .delivered)
    }

    @Test func onlyAPaymentCanBeUnsettled() throws {
        let storage = try profile.storage()
        let text = Message.fixture(uuid: uuid(3), chat: dm, fromMe: true, tag: "t3", status: "PENDING")
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [(text, false, nil)]))
        _ = try storage.apply(Storage.Commit(statuses: [(tag: "t3", status: "UNSETTLED")]))
        #expect(try storage.message(uuid: uuid(3), in: dm)?.delivery == .pending)
    }

    @Test func aFailureAfterUnsettledAllowsRetry() throws {
        let storage = try profile.storage()
        _ = try storedBoost(storage)
        _ = try storage.apply(Storage.Commit(statuses: [(tag: "t1", status: "FAILED")]))
        #expect(try storage.message(uuid: uuid(2), in: dm)?.isRetryable() == true)
    }
}
