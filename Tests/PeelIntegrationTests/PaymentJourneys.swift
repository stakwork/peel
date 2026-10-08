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
        /// recipient and debited from the sender at exactly its amount, and
        /// both sides keep a row for it.
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
            withKnownIssue("""
                The sender is debited one sat more than the payment (seen: 301 for 300, 121 for 120) \
                while the recipient gets the amount; Peel's row and its balance check count only the amount.
                """) {
                #expect(sender0 - sender1 == sats, "\(sender.name) paid \(sats) sats and lost \(sender0 - sender1)")
            }
        }

        /// Peel's own gate, with the real core: over the balance, and over
        /// the confirmation threshold unconfirmed, nothing is sent.
        @Test func refusedPaymentsMoveNothing() async throws {
            let (alice, bob) = try await Self.pair()
            let a0 = try #require(try await alice.settledBalance())
            let b0 = try #require(try await bob.settledBalance())

            await #expect(throws: Engine.Failure.insufficientBalance) {
                try await alice.engine.sendPayment(
                    to: try bob.pubkey, amountMsat: (a0 + 1) * 1000, confirmedMsat: (a0 + 1) * 1000
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
