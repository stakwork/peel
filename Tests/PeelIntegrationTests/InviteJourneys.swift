import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Invites {
        /// Alice makes an invite with 1,000 sats; Dana signs up with it, gets
        /// the sats and Alice as a contact, and Alice sees it used.
        @Test func makeAndRedeem() async throws {
            let alice = try await Person.create("alice")
            try await Bank.shared.give(5_000, to: alice)
            let a0 = try #require(try await alice.settledBalance())

            let invite = try await alice.engine.makeInvite(
                amountMsat: 1_000_000, nickname: "dana", confirmedMsat: 1_000_000
            )
            #expect(invite.status == .ready)
            let afterMaking = try await alice.balance(settlingAt: a0 - 1_000)
            #expect(afterMaking == a0 - 1_000)

            let dana = try await Person.signup("dana", invite: invite.link)
            #expect(await dana.engine.isRegistered)
            try await expectRedeemed(invite.code, alice: alice, dana: dana)
            // Alice lost the invite's sats and no more (Dana's key exchange may add some).
            let alices = try #require(try await alice.settledBalance())
            #expect(alices >= a0 - 1_000)

            await alice.close()
            await dana.close()
        }

        /// Dana signs up with Alice's invite through the wire tap, and the
        /// server's reply to her register is lost. The server has redeemed
        /// the invite, so her words stay; her next connect registers again
        /// and finds the account, with the invite's sats, and adds Alice as
        /// the signup would have.
        @Test func aSignupWhoseReplyIsLostKeepsTheWords() async throws {
            let alice = try await Person.create("alice")
            try await Bank.shared.give(5_000, to: alice)
            let invite = try await alice.engine.makeInvite(
                amountMsat: 1_000_000, nickname: "dana", confirmedMsat: 1_000_000
            )

            try await Stack.shared.tap(.deafen)
            let signedUp = await Result { try await Person.signup("dana", invite: invite.link, throughTap: true) }
            try await Stack.shared.tap(.hear)
            let dana = try signedUp.get()
            #expect(await !dana.engine.isRegistered)
            #expect(try dana.profile.loadMnemonic(pin: "") == dana.mnemonic)

            try await dana.engine.connect()
            #expect(await dana.engine.isRegistered)
            try await expectRedeemed(invite.code, alice: alice, dana: dana)

            await alice.close()
            await dana.close()
        }

        /// Dana redeemed Alice's 1,000-sat invite. Her first act is the key
        /// exchange with Alice, which carries a few sats (Peel attaches 5),
        /// so she holds the invite's 1,000 less at most those; the two are
        /// contacts, and Alice sees the invite used by Dana.
        private func expectRedeemed(_ code: String, alice: Person, dana: Person) async throws {
            let danas = try #require(try await dana.settledBalance())
            #expect((995...1_000).contains(danas), "Dana holds \(danas) sats from a 1,000-sat invite")
            try await eventually("Alice and Dana to be contacts") {
                try alice.isReadyContact(dana) && dana.isReadyContact(alice)
            }
            try await eventually("Alice to see the invite used") {
                try alice.storage.invite(code: code)?.status == .used
            }
            #expect(try alice.storage.invite(code: code)?.usedBy == dana.pubkey)
        }

        /// Alice cancels an invite and gets its sats back; nobody can sign
        /// up with it afterwards and take them.
        @Test func cancelRefunds() async throws {
            let alice = try await Person.create("alice")
            try await Bank.shared.give(5_000, to: alice)
            let a0 = try #require(try await alice.settledBalance())

            let invite = try await alice.engine.makeInvite(amountMsat: 500_000, confirmedMsat: 500_000)
            let afterMaking = try await alice.balance(settlingAt: a0 - 500)
            #expect(afterMaking == a0 - 500)
            let cancelled = try await alice.engine.cancelInvite(code: invite.code)
            #expect(cancelled.status == .cancelled)
            let afterCancel = try await alice.balance(settlingAt: a0)
            #expect(afterCancel == a0)

            // Signing up with the cancelled invite must not pay out again.
            do {
                let eve = try await Person.signup("eve", invite: invite.link)
                let eves = try await eve.settledBalance() ?? 0
                #expect(eves == 0, "a cancelled invite paid out \(eves) sats")
                await eve.close()
            } catch {
                // Refused outright: also fine.
            }
            let atEnd = try await alice.settledBalance()
            #expect(atEnd == a0)
            await alice.close()
        }
    }
}
