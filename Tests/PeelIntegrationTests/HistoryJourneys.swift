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
            let balance = try #require(try await alice.settledBalance())

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
            let seen1 = try await second.balance(settlingAt: balance)
            #expect(seen1 == balance)

            await second.close()
            await alice.close()
            await bob.close()
        }

        /// Alice's link goes while Bob writes, so his messages wait in her
        /// history. Her catch-up has begun when a live one from Bob lands
        /// above those still to fetch, and she quits. Her next launch
        /// fetches the rest: no server index is missing.
        @Test func aCatchUpCutShortByAQuitLeavesNoGap() async throws {
            let alice = try await Person.create("alice", throughTap: true)
            let bob = try await Person.create("bob")
            try await Bank.shared.give(1_000, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            await alice.engine.start()
            let (aliceKey, bobKey) = (try alice.pubkey, try bob.pubkey)

            try await Stack.shared.tap(.down)
            try await eventually("Alice to see the connection go") { await alice.engine.connection != .connected }
            let tag = UUID().uuidString.prefix(6)
            let missed = (1...400).map { "while away \($0) \(tag)" }
            for text in missed {
                try await bob.engine.sendText(text, to: aliceKey)
            }
            let away = Set(missed)
            func fetched() throws -> Int { try alice.messages(in: bobKey).filter { away.contains($0.content ?? "") }.count }
            try await Stack.shared.tap(.up)
            try await eventually("Alice's catch-up to begin", timeout: .seconds(60)) { try fetched() > 0 }
            let live = "while catching up \(tag)"
            try await bob.engine.sendText(live, to: aliceKey)
            try await eventually("Alice to receive it live") {
                try alice.messages(in: bobKey).contains { $0.content == live }
            }
            // The gap this guards against: a live row above messages not yet fetched.
            let cutShort = try fetched() < missed.count
            await alice.engine.close()

            let relaunched = Person(
                name: alice.name, profile: alice.profile,
                engine: try Engine(mnemonic: alice.mnemonic, storage: alice.storage), mnemonic: alice.mnemonic
            )
            try await relaunched.engine.connect()
            try await eventually("the catch-up to finish", timeout: .seconds(60)) {
                await !relaunched.engine.isSyncingHistory
            }
            let rows = try relaunched.messages(in: bobKey)
            let stored = Set(rows.compactMap(\.content))
            let lost = missed.filter { !stored.contains($0) }
            #expect(lost.isEmpty, "\(lost.count) of Bob's messages never came (cut short: \(cutShort))")
            #expect(stored.contains(live))
            // Nothing else reached Alice from the first of them to the live one.
            let indices = rows.filter { away.contains($0.content ?? "") || $0.content == live }
                .compactMap(\.serverIndex).sorted()
            if let first = indices.first, let last = indices.last {
                #expect(indices.count == Int(last - first) + 1, "server indices \(first)...\(last) have gaps")
            }

            await relaunched.close()
            await bob.close()
        }
    }
}
