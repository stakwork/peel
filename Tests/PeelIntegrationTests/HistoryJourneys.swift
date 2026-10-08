import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct History {
        /// Alice talks with Bob, is paid by him and posts in his tribe; her
        /// words on a second device bring all of it back: the contact, the
        /// messages both ways, the payment, the tribe and its post.
        @Test func restoreOnASecondDevice() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(1_000, to: alice)
            try await Bank.shared.give(1_000, to: bob)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            let tag = UUID().uuidString.prefix(6)
            let said = [
                ("alice", "are you at the harbour \(tag)"), ("bob", "by the blue boat \(tag)"),
                ("alice", "five minutes \(tag)"), ("bob", "bring the charts \(tag)"),
            ]
            for (who, text) in said {
                let (from, to) = who == "alice" ? (alice, bob) : (bob, alice)
                try await from.engine.sendText(text, to: try to.pubkey)
                try await eventually("\(to.name) to receive \"\(text)\"") {
                    try to.messages(in: from.pubkey).contains { $0.content == text }
                }
            }
            try await bob.engine.sendPayment(to: try alice.pubkey, amountMsat: 42_000, text: "charts", confirmedMsat: 42_000)
            try await eventually("Alice to receive Bob's payment") {
                try alice.messages(in: bob.pubkey).contains { $0.type == MessageType.directPayment }
            }
            let tribe = try await bob.engine.createTribe(TribeSettings(name: "harbour \(tag)"))
            try await alice.engine.joinTribe(link: try #require(tribe.link))
            try await Tribes.waitUntilIn(tribe.pubkey, alice)
            let post = "tide is turning \(tag)"
            try await alice.engine.sendText(post, to: tribe.pubkey)
            try await eventually("Bob to see Alice's post") {
                try bob.messages(in: tribe.pubkey).contains { $0.content == post }
            }
            let balance = try await alice.settledBalance()

            let second = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) {
                await !second.engine.isSyncingHistory
            }
            #expect(try second.isReadyContact(bob))
            let restored = try second.messages(in: bob.pubkey)
            for (who, text) in said {
                let row = restored.first { $0.content == text }
                #expect(row != nil, "\"\(text)\" was not restored")
                #expect(row?.fromMe == (who == "alice"))
            }
            let payment = restored.first { $0.type == MessageType.directPayment }
            #expect(payment?.amountMsat == 42_000 && payment?.fromMe == false)
            let restoredTribe = try second.storage.tribes().first { $0.pubkey == tribe.pubkey }
            #expect(restoredTribe != nil && restoredTribe?.left == false && restoredTribe?.status == .active)
            #expect(try second.messages(in: tribe.pubkey).contains { $0.content == post && $0.fromMe })
            let seen1 = try await second.balance(settlingAt: balance ?? 0)
            #expect(seen1 == balance)

            await second.close()
            await alice.close()
            await bob.close()
        }
    }
}
