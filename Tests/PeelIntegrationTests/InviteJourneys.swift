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
            // Dana's first act is the key exchange with Alice, which carries
            // a few sats (Peel attaches 5), so she holds the invite's 1,000
            // less at most those.
            let danas = try #require(try await dana.settledBalance())
            #expect((995...1_000).contains(danas), "Dana holds \(danas) sats from a 1,000-sat invite")
            try await eventually("Alice and Dana to be contacts") {
                try alice.isReadyContact(dana) && dana.isReadyContact(alice)
            }
            try await eventually("Alice to see the invite used") {
                try alice.storage.invite(code: invite.code)?.status == .used
            }
            #expect(try alice.storage.invite(code: invite.code)?.usedBy == dana.pubkey)
            // Alice lost the invite's sats and no more (Dana's key exchange may add some).
            let alices = try #require(try await alice.settledBalance())
            #expect(alices >= a0 - 1_000)

            await alice.close()
            await dana.close()
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
