import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Contacts {
        /// Alice adds Bob by his contact info: the key exchange completes on
        /// both sides, and each knows the other's name.
        @Test func keyExchangeByContactInfo() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(100, to: alice)

            let (pubkey, added) = try await alice.engine.addContact(code: try bob.contactInfo)
            #expect(added)
            #expect(try pubkey == bob.pubkey)
            try await eventually("both sides to hold the other's key") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
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
    }
}
