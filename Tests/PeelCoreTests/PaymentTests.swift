import Foundation
import GRDB
import Testing
@testable import PeelCore

private let other = "02bb"

struct PaymentTests {
    let profile = TempProfile()

    private func text(_ n: Int, chat: String = dm, fromMe: Bool = false) -> Message {
        .fixture(uuid: uuid(n), chat: chat, fromMe: fromMe, content: "m\(n)", timestamp: Int64(n) * 1_000)
    }

    private func boost(
        _ n: Int, on parent: Int, chat: String = dm, fromMe: Bool = false, sats: Int64, alias: String? = nil,
        status: Message.Delivery? = nil, paid: Bool = true
    ) -> Message {
        .fixture(
            uuid: uuid(n), type: MessageType.boost, chat: chat, fromMe: fromMe,
            sender: alias.map { #"{"pubkey":"02cc","alias":"\#($0)"}"# }, content: "",
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
        let row = try #require(try storage.apply(Storage.Commit(messages: [(paid, false, nil)])).first)
        #expect(row.amountMsat == 10_000)
    }

    @Test func amountIsKeptFromTheFirstCopy() throws {
        let storage = try storage([payment(1, sats: 10)])
        var echo = payment(1, sats: 99)
        echo.serverIndex = 5
        let row = try #require(try storage.apply(Storage.Commit(messages: [(echo, false, nil)])).first)
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

    @Test func moneyForMeIsReportedOnceForNotifications() throws {
        let storage = try storage([text(1), text(2, fromMe: true)])
        func paid(_ message: Message, index: Int64) -> Message {
            var message = message
            message.serverIndex = index
            message.msat = message.amountMsat
            return message
        }
        let incoming = [
            paid(payment(3, sats: 10), index: 3), paid(boost(4, on: 2, sats: 5), index: 4),
            // Someone else's boost on someone else's message, and an unpaid "payment".
            paid(boost(5, on: 1, sats: 5), index: 5), payment(6, sats: 99),
        ]
        var purged: [String] = [], received: [Message] = []
        _ = try storage.apply(Storage.Commit(messages: incoming.map { ($0, false, nil) }), purged: &purged,
                              received: &received)
        #expect(received.map(\.uuid) == [uuid(3), uuid(4)])
        // The same copies again (history, the server's echo) are not news.
        received = []
        _ = try storage.apply(Storage.Commit(messages: incoming.map { ($0, false, nil) }), purged: &purged,
                              received: &received)
        #expect(received.isEmpty)
        // Nor is what was already read when it arrived.
        received = []
        _ = try storage.apply(
            Storage.Commit(messages: [(paid(payment(7, sats: 1), index: 7), false, nil)], reads: [dm: 7]),
            purged: &purged, received: &received
        )
        #expect(received.isEmpty)
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
        let queue = try DatabaseQueue(path: profile.url.appendingPathComponent("peel.sqlite").path)
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
            resend: (id, dm, uuid(2), "t2", "hash2", 5_000)
        ))
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

    @Test func theDeclaredAmountIsReadOnItsOwn() {
        #expect(DeclaredAmount.decode(#"{"content":"","amount":21000,"replyUuid":"r"}"#) == 21_000)
        // An odd amount is no amount, and the rest of the message still reads.
        let odd = #"{"content":"hi","amount":-1,"replyUuid":"r"}"#
        #expect(DeclaredAmount.decode(odd) == nil)
        #expect(BodyFields.decode(odd)?.replyUuid == "r")
    }
}
