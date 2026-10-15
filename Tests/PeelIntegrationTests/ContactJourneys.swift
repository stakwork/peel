import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Contacts {
        /// Alice adds Bob by his contact info: the key exchange completes on
        /// both sides, and each knows the other's name. Its sats (review F6):
        /// Alice pays 5 and a 1-sat ping, Bob's core pays 3 back with its own
        /// ping, so Alice is down 3 and Bob up 1; Payments names each row
        /// for the key exchange, pings folded in, instead of keysends.
        @Test func keyExchangeByContactInfo() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(100, to: alice)
            let a0 = try #require(try await alice.settledBalance())
            let b0 = try await bob.settledBalance() ?? 0

            let (pubkey, added) = try await alice.engine.addContact(code: try bob.contactInfo)
            #expect(added)
            #expect(try pubkey == bob.pubkey)
            try await eventually("both sides to hold the other's key") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            #expect(try await alice.balance(settlingAt: a0 - 3) == a0 - 3)
            #expect(try await bob.balance(settlingAt: b0 + 1) == b0 + 1)
            let five = Int64(Engine.keyExchangeMsat), three = Int64(Engine.priceToMeetMsat)
            #expect(try await keyExchangeRows(alice, with: "bob") == [Row(false, five, ping: true), Row(true, three, ping: false)])
            #expect(try await keyExchangeRows(bob, with: "alice") == [Row(false, three, ping: true), Row(true, five, ping: false)])
            #expect(try await bob.storage.pool.read { db in try Storage.paymentItems(limit: 50, db) }.allSatisfy { $0.kind == .keyExchange })
            #expect(try Engine.contacts(in: bob.storage).contains { $0.pubkey == (try alice.pubkey) && $0.contactKey != nil })
            try await eventually("Bob to see Alice's name") {
                try bob.messages(in: alice.pubkey).contains { $0.senderAlias == "alice" }
            }
            // Adding again starts no second key exchange (it would cost sats).
            let again = try await alice.engine.addContact(code: try bob.contactInfo)
            #expect(!again.added)

            await alice.close()
            await bob.close()
        }

        /// One Payments row: sent or received, its amount, and whether a ping was folded in.
        struct Row: Equatable {
            let incoming: Bool
            let msat: Int64
            let ping: Bool
            init(_ incoming: Bool, _ msat: Int64, ping: Bool) { (self.incoming, self.msat, self.ping) = (incoming, msat, ping) }
        }

        /// `person`'s key exchange rows with `name`, from the server's history, sent first.
        func keyExchangeRows(_ person: Person, with name: String) async throws -> [Row] {
            try await person.engine.refreshPaymentHistory()
            return try await person.storage.pool.read { db in try Storage.paymentItems(limit: 50, db) }
                .filter { $0.kind == .keyExchange && $0.counterpart == name }
                .map { Row($0.incoming, $0.amountMsat, ping: $0.pingMsat == Storage.pingPriceMsat) }
                .sorted { !$0.incoming && $1.incoming }
        }

        /// Dana adds Carol from an invite Carol made: the invite names its
        /// inviter, who is added as anyone would be, and the invite's sats
        /// stay where they are.
        @Test func keyExchangeByInvite() async throws {
            let carol = try await Person.create("carol")
            let dana = try await Person.create("dana")
            try await Bank.shared.give(1_000, to: carol)
            try await Bank.shared.give(100, to: dana)

            let invite = try await carol.engine.makeInvite(amountMsat: 200_000, confirmedMsat: 200_000)
            let (pubkey, added) = try await dana.engine.addContact(code: invite.link)
            #expect(added)
            #expect(try pubkey == carol.pubkey)
            try await eventually("both sides to hold the other's key") {
                try carol.isReadyContact(dana) && dana.isReadyContact(carol)
            }
            #expect(try carol.storage.invite(code: invite.code)?.status == .ready)

            _ = try await carol.engine.cancelInvite(code: invite.code)
            await carol.close()
            await dana.close()
        }

        /// Erin removes Frank after a word each way: his chat goes here and
        /// on the server, so her words on a second device do not bring him
        /// back. Frank keeps his copy, and Erin can add him again.
        @Test func removingAContact() async throws {
            let erin = try await Person.create("erin")
            let frank = try await Person.create("frank")
            try await Bank.shared.give(1_000, to: erin)
            try await erin.engine.addContact(code: try frank.contactInfo)
            try await eventually("Erin and Frank to be contacts") {
                try erin.isReadyContact(frank) && frank.isReadyContact(erin)
            }
            let tag = UUID().uuidString.prefix(6)
            try await erin.engine.sendText("hello \(tag)", to: try frank.pubkey)
            try await frank.engine.sendText("hi back \(tag)", to: try erin.pubkey)
            try await eventually("Erin to receive Frank's reply") {
                try erin.messages(in: frank.pubkey).contains { $0.content == "hi back \(tag)" }
            }

            try await erin.engine.deleteContact(try frank.pubkey)
            #expect(try erin.messages(in: frank.pubkey).isEmpty)
            #expect(try !Engine.contacts(in: erin.storage).contains { $0.pubkey == (try frank.pubkey) })
            #expect(try frank.messages(in: erin.pubkey).contains { $0.content == "hello \(tag)" })

            let second = try await Person.restore("erin", mnemonic: erin.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) {
                await !second.engine.isSyncingHistory
            }
            #expect(try !Engine.contacts(in: second.storage).contains { $0.pubkey == (try frank.pubkey) })
            #expect(try second.messages(in: frank.pubkey).isEmpty)
            await second.close()

            let (_, added) = try await erin.engine.addContact(code: try frank.contactInfo)
            #expect(added)
            try await eventually("Erin and Frank to be contacts again") {
                try erin.isReadyContact(frank) && frank.isReadyContact(erin)
            }
            await erin.close()
            await frank.close()
        }

        /// Bob, Alice's contact, sends her a contact record (type 33) naming
        /// Carol, her other contact, with his own server and key
        /// (`Engine.isForeignContactRecord`): Alice keeps Carol as she was and
        /// stores nothing of it.
        @Test func aContactRecordSomeoneElseSentChangesNothing() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            let carol = try await Person.create("carol")
            try await Bank.shared.give(1_000, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await alice.engine.addContact(code: try carol.contactInfo)
            try await eventually("Alice, Bob and Carol to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice) && alice.isReadyContact(carol)
            }
            let carolsKey = try carol.pubkey
            let before = try #require(try alice.storage.loadCoreState()["c/\(carolsKey)"])

            let bobs = try #require(Engine.contactInfoParts(try bob.contactInfo))
            let body = #"{"content":"","fullContactInfo":"\#(carolsKey)_\#(bobs[1])_\#(bobs[2])_\#(bobs[0])"}"#
            let sent = try await bob.engine.deliver(
                body: body, to: try alice.pubkey, type: MessageType.contactKeyRecord, replacing: nil
            )
            let tag = try #require(sent)
            // Once the server has handed the record to Alice, a word follows
            // it; when the word is in, Alice has read the record, which came first.
            try await eventually("the server to hand Bob's record to Alice") {
                try bob.messages(in: alice.pubkey).first { $0.tag == tag }?.delivery == .delivered
            }
            let word = "after the record \(UUID().uuidString.prefix(6))"
            try await bob.engine.sendText(word, to: try alice.pubkey)
            try await eventually("Alice to receive Bob's word") {
                try alice.messages(in: bob.pubkey).contains { $0.content == word }
            }
            #expect(try alice.storage.loadCoreState()["c/\(carolsKey)"] == before)
            #expect(try alice.messages(in: bob.pubkey).allSatisfy { $0.type != MessageType.contactKeyRecord })

            await alice.close()
            await bob.close()
            await carol.close()
        }

        /// Bob, already Alice's contact, sends her the first message of a key
        /// exchange (ContactKey, type 10) with no sats. Answering it pays 3
        /// sats and a ping, so a core that answers an unpaid one lets anyone
        /// drain an account a few sats at a time (upstream SR-016): Alice's
        /// core must pay nothing. Fixed in sphinx v0.6.29; the core Peel links
        /// (`bd9e140`) still answers, so this is a known issue until the lock
        /// moves, and then fails until the `withKnownIssue` goes. A paid key
        /// exchange still completing is `keyExchangeByContactInfo`.
        @Test func anUnpaidContactKeyPaysNothing() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(100, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            let a0 = try #require(try await alice.settledBalance())
            let b0 = try #require(try await bob.settledBalance())
            let rows = try await keyExchangeRows(alice, with: "bob")

            let sent = try await bob.engine.deliver(
                body: #"{"content":""}"#, to: try alice.pubkey, type: MessageType.contactKey, replacing: nil
            )
            let tag = try #require(sent)
            // As for the contact record above: once Bob's word is in, Alice
            // has read the ContactKey, and published any answer, before it.
            try await eventually("the server to hand Bob's ContactKey to Alice") {
                try bob.messages(in: alice.pubkey).first { $0.tag == tag }?.delivery == .delivered
            }
            let word = "after the key \(UUID().uuidString.prefix(6))"
            try await bob.engine.sendText(word, to: try alice.pubkey)
            try await eventually("Alice to receive Bob's word") {
                try alice.messages(in: bob.pubkey).contains { $0.content == word }
            }
            let rowsAfter = try await keyExchangeRows(alice, with: "bob")
            let a1 = try await alice.settledBalance()
            let b1 = try await bob.settledBalance()
            withKnownIssue("the linked core bd9e140 pays back an unpaid ContactKey (SR-016, fixed in sphinx v0.6.29)") {
                #expect(rowsAfter == rows)
                #expect(a1 == a0)
                #expect(b1 == b0)
            }

            await alice.close()
            await bob.close()
        }

        /// Alice's words on a second device, then Alice adds Bob on the
        /// first: the contact record the first device signs reaches the
        /// second as it happens, and Bob is a contact there too.
        @Test func aContactRecordFromTheAccountsOtherDeviceAddsTheContact() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(100, to: alice)
            let second = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) {
                await !second.engine.isSyncingHistory
            }
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Bob to be a contact on both of Alice's devices") {
                try alice.isReadyContact(bob) && second.isReadyContact(bob)
            }
            await second.close()
            await alice.close()
            await bob.close()
        }
    }
}
