import Foundation
import GRDB
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Payments {
        /// Two funded contacts.
        static func pair() async throws -> (Person, Person) {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(5_000, to: alice)
            try await Bank.shared.give(5_000, to: bob)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            return (alice, bob)
        }

        /// Keysends in a chat (type 5) both ways: each is credited to the
        /// recipient at exactly its amount and debited from the sender at
        /// its amount plus the 1-sat ping, and both sides keep a row for it.
        @Test func keysendBothWays() async throws {
            let (alice, bob) = try await Self.pair()
            try await Self.pay(300, from: alice, to: bob, note: "for the boat")
            let sent = try #require(try alice.messages(in: bob.pubkey).last { $0.type == MessageType.directPayment })
            #expect(sent.fromMe && sent.amountMsat == 300_000 && sent.content == "for the boat")
            try await eventually("Alice's payment to be delivered") {
                try alice.messages(in: bob.pubkey).last { $0.type == MessageType.directPayment }?.delivery == .delivered
            }
            let got = try await eventually("Bob's row for the payment") {
                try bob.messages(in: alice.pubkey).last { $0.type == MessageType.directPayment }
            }
            #expect(!got.fromMe && got.amountMsat == 300_000 && got.content == "for the boat")

            // A row left pending by an older Peel (Tom's 21 sats, from before
            // #26), under a tag the server has no word on: the history settles
            // it by its payment hash on the next connect.
            let unknownTag = UUID().uuidString
            try await alice.storage.pool.write { db in
                try db.execute(
                    sql: "UPDATE message SET status = 'PENDING', tag = ? WHERE uuid = ?", arguments: [unknownTag, sent.uuid]
                )
            }
            #expect(try alice.storage.waitingMsat() == 300_000)
            await alice.engine.disconnect()
            try await alice.engine.connect()
            try await eventually("the stale row to be settled by the history") {
                try alice.messages(in: bob.pubkey).last { $0.type == MessageType.directPayment }?.delivery == .delivered
            }
            #expect(try alice.storage.waitingMsat() == 0)

            try await Self.pay(120, from: bob, to: alice)
            await alice.close()
            await bob.close()
        }

        /// One keysend, with both balances checked once they settle.
        static func pay(_ sats: UInt64, from sender: Person, to recipient: Person, note: String = "") async throws {
            let sender0 = try #require(try await sender.settledBalance())
            let recipient0 = try #require(try await recipient.settledBalance())
            try await sender.engine.sendPayment(
                to: try recipient.pubkey, amountMsat: sats * 1000, text: note, confirmedMsat: sats * 1000
            )
            let recipient1 = try #require(try await recipient.balance(settlingAt: recipient0 + sats))
            #expect(recipient1 - recipient0 == sats)
            let sender1 = try #require(try await sender.settledBalance())
            // The async payment's ping (finding 1), which `checkPayment` counts.
            let ping = Engine.pingMsat(toTribe: false) / 1000
            #expect(sender0 - sender1 == sats + ping, "\(sender.name) paid \(sats) sats and lost \(sender0 - sender1)")
        }

        /// Peel's own gate, with the real core: the whole balance (which
        /// leaves nothing for the ping), and over the confirmation threshold
        /// unconfirmed, nothing is sent.
        @Test func refusedPaymentsMoveNothing() async throws {
            let (alice, bob) = try await Self.pair()
            let a0 = try #require(try await alice.settledBalance())
            let b0 = try #require(try await bob.settledBalance())

            await #expect(throws: Engine.Failure.insufficientBalance) {
                try await alice.engine.sendPayment(
                    to: try bob.pubkey, amountMsat: a0 * 1000, confirmedMsat: a0 * 1000
                )
            }
            await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 1_000_000)) {
                try await alice.engine.sendPayment(to: try bob.pubkey, amountMsat: 1_000_000)
            }
            let a1 = try await alice.settledBalance()
            let b1 = try await bob.settledBalance()
            #expect(a1 == a0)
            #expect(b1 == b0)
            #expect(try alice.messages(in: bob.pubkey).allSatisfy { $0.type != MessageType.directPayment })

            await alice.close()
            await bob.close()
        }

        /// Sats to someone offline wait at the server, still in the balance,
        /// until their app comes online (review F1). Peel counts them as
        /// spent: a second payment the balance could not also cover is
        /// refused, so Bob gets exactly one when he comes online.
        @Test func paymentsToAnOfflineContact() async throws {
            let (alice, bob) = try await Self.pair()
            let a0 = try #require(try await alice.settledBalance())
            await bob.engine.disconnect()

            let sats = a0 * 3 / 4
            try await alice.engine.sendPayment(to: try bob.pubkey, amountMsat: sats * 1000, confirmedMsat: sats * 1000)
            // Only the ping has left: the payment itself waits for Bob.
            #expect(try await alice.balance(settlingAt: a0 - 1) == a0 - 1)
            #expect(try alice.storage.waitingMsat() == sats * 1000)
            await #expect(throws: Engine.Failure.insufficientBalance) {
                try await alice.engine.sendPayment(to: try bob.pubkey, amountMsat: sats * 1000, confirmedMsat: sats * 1000)
            }

            try await bob.engine.connect()
            let got = try await eventually("Bob's row for the payment") {
                try bob.messages(in: alice.pubkey).last { $0.type == MessageType.directPayment }
            }
            #expect(got.amountMsat == Int64(sats * 1000))
            #expect(try await alice.balance(settlingAt: a0 - 1 - sats) == a0 - 1 - sats)
            try await eventually("Alice's payment to be delivered") {
                try alice.messages(in: bob.pubkey).last { $0.type == MessageType.directPayment }?.delivery == .delivered
            }
            #expect(try alice.storage.waitingMsat() == 0)
            #expect(try bob.messages(in: alice.pubkey).filter { $0.type == MessageType.directPayment }.count == 1)
            // Bob's history confirms it: one payment received, for its amount.
            try await eventually("Bob's payment to be confirmed by the history") {
                try await bob.engine.refreshPaymentHistory()
                return try bob.messages(in: alice.pubkey).last { $0.type == MessageType.directPayment }?.arrived == true
            }
            #expect(try Self.received(by: bob, from: alice) == [Int64(sats * 1000)])

            await alice.close()
            await bob.close()
        }

        /// What Payments counts as received from `payer`: the amounts.
        static func received(by person: Person, from payer: Person) throws -> [Int64] {
            let chat = try payer.pubkey
            return try person.storage.pool.read { db in try Storage.paymentItems(limit: 50, db) }
                .filter { $0.incoming && $0.kind == .payment && $0.status == .complete && $0.chat == chat }
                .map(\.amountMsat)
        }

        /// Two devices of Alice's each pay offline Bob most of her balance
        /// (each device's gate knows only its own waiting payment). Bob comes
        /// online and the server can move the sats only once; when it redeems
        /// both at once, both messages reach him. Review F2: Bob's history
        /// has one; any other reads not received, and Payments counts one. Review journey 2 (F4): on
        /// a third device restored afterwards, the failed one reads failed
        /// from the server's record of its tag, not sent.
        @Test func twoDevicesPayAnOfflineContact() async throws {
            let (alice, bob) = try await Self.pair()
            let a0 = try #require(try await alice.settledBalance())
            await bob.engine.disconnect()
            let sats = a0 * 3 / 4
            try await alice.engine.sendPayment(to: try bob.pubkey, amountMsat: sats * 1000, confirmedMsat: sats * 1000)
            #expect(try await alice.balance(settlingAt: a0 - 1) == a0 - 1)

            let second = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) { await !second.engine.isSyncingHistory }
            try await second.engine.sendPayment(to: try bob.pubkey, amountMsat: sats * 1000, confirmedMsat: sats * 1000)
            try await bob.engine.connect()

            // One of the two went through and one failed, whichever the server took first.
            // The first device hears both statuses (each by its tag).
            let sent = try await eventually("both sends to be settled") { () -> [Message]? in
                let rows = try alice.messages(in: bob.pubkey).filter { $0.type == MessageType.directPayment && $0.fromMe }
                return rows.count == 2 && Set(rows.map(\.delivery)) == [.delivered, .failed] ? rows : nil
            }
            let failedTag = try #require(sent.first { $0.delivery == .failed }?.tag)
            let paidTag = try #require(sent.first { $0.delivery == .delivered }?.tag)

            // When the server redeems both at once, both messages reach Bob
            // (review F2); taken one after the other, the second is refused
            // before it is delivered. Either way his history settles them:
            // one arrived, and a second message, if any, did not.
            let payments = { try bob.messages(in: alice.pubkey).filter { $0.type == MessageType.directPayment } }
            try await eventually("Bob's history to settle the payments") {
                try await bob.engine.refreshPaymentHistory()
                let arrived = try payments().map(\.arrived)
                return arrived.count <= 2 && arrived.filter { $0 == true }.count == 1 && !arrived.contains(nil)
            }
            #expect(try Self.received(by: bob, from: alice) == [Int64(sats * 1000)])

            // A third device, restored now: the failed send is failed, the other sent.
            let third = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) { await !third.engine.isSyncingHistory }
            try await eventually("the restored sends to take the server's word") {
                let rows = try third.messages(in: bob.pubkey).filter { $0.type == MessageType.directPayment && $0.fromMe }
                return rows.first { $0.tag == failedTag }?.delivery == .failed
                    && rows.first { $0.tag == paidTag }?.delivery == .delivered
            }
            // Failed, and never paid again from a device that did not send it.
            let failed = try third.messages(in: bob.pubkey).first { $0.tag == failedTag }
            #expect(failed?.isRetryable() == false)
            let items = try await third.storage.pool.read { db in try Storage.paymentItems(limit: 50, db) }
            #expect(items.filter { $0.kind == .payment && !$0.incoming && $0.status == .failed }.count == 1)

            await third.close()
            await second.close()
            await alice.close()
            await bob.close()
        }

        /// The local stack's mixer runs `NO_LIGHTNING`, so it never answers
        /// `request_invoice`: Peel says so and records no invoice. (Paying
        /// and receiving invoices needs a regtest CLN behind the mixer.)
        @Test func requestInvoiceWithoutLightning() async throws {
            let (alice, bob) = try await Self.pair()
            await #expect(throws: Engine.Failure.noInvoiceFromServer) {
                _ = try await alice.engine.createInvoice(amountMsat: 210_000, memo: "lunch")
            }
            let stored = try await alice.storage.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM invoice") }
            #expect(stored == 0)
            await alice.close()
            await bob.close()
        }
    }
}
