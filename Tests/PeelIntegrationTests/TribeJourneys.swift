import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Tribes {
        /// Alice creates a free tribe and a paid one. Bob joins the free one
        /// (1 sat, as the official apps pay), Carol and Bob the paid one at
        /// its price. Carol posts there and pays the price per message; Bob
        /// boosts her post, paying the tip plus the price, all of it to her.
        @Test func createJoinFreeAndPaidPostAndBoost() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            let carol = try await Person.create("carol")
            for person in [alice, bob, carol] { try await Bank.shared.give(2_000, to: person) }
            let tag = UUID().uuidString.prefix(6)

            let free = try await alice.engine.createTribe(TribeSettings(name: "free \(tag)"))
            let paid = try await alice.engine.createTribe(
                TribeSettings(name: "paid \(tag)", pricePerMessageMsat: 10_000, priceToJoinMsat: 50_000)
            )
            #expect(free.isOwner && paid.isOwner)
            let freeLink = try #require(free.link)
            let paidLink = try #require(paid.link)
            let info = try await bob.engine.tribeInfo(link: paidLink)
            #expect(info.joinAmountMsat == 50_000)

            let b0 = try #require(try await bob.settledBalance())
            let c0 = try #require(try await carol.settledBalance())
            try await bob.engine.joinTribe(link: freeLink)
            try await Self.waitUntilIn(free.pubkey, bob)
            let seen1 = try await bob.balance(settlingAt: b0 - 1)
            #expect(seen1 == b0 - 1)

            try await bob.engine.joinTribe(link: paidLink, agreedJoinMsat: 50_000)
            try await carol.engine.joinTribe(link: paidLink, agreedJoinMsat: 50_000)
            try await Self.waitUntilIn(paid.pubkey, bob)
            try await Self.waitUntilIn(paid.pubkey, carol)
            let seen2 = try await bob.balance(settlingAt: b0 - 51)
            #expect(seen2 == b0 - 51)
            let seen3 = try await carol.balance(settlingAt: c0 - 50)
            #expect(seen3 == c0 - 50)

            // A paid message.
            let post = "first light on the ridge \(tag)"
            try await carol.engine.sendText(post, to: paid.pubkey)
            let seen4 = try await carol.balance(settlingAt: c0 - 60)
            #expect(seen4 == c0 - 60)
            for reader in [alice, bob] {
                try await eventually("\(reader.name) to see Carol's post") {
                    try reader.messages(in: paid.pubkey).contains { $0.content == post && !$0.fromMe }
                }
            }

            // A boost of 20 sats on it, plus the tribe's 10.
            let a1 = try #require(try await alice.settledBalance())
            let b1 = try #require(try await bob.settledBalance())
            let c1 = try #require(try await carol.settledBalance())
            let target = try #require(try bob.messages(in: paid.pubkey).first { $0.content == post })
            try await bob.engine.boost(messageID: try #require(target.id), amountMsat: 20_000)
            let seen5 = try await bob.balance(settlingAt: b1 - 30)
            #expect(seen5 == b1 - 30)
            let seen6 = try await carol.balance(settlingAt: c1 + 30)
            #expect(seen6 == c1 + 30)
            let seen7 = try await alice.settledBalance()
            #expect(seen7 == a1)
            try await eventually("Carol to see the boost") {
                try carol.messages(in: paid.pubkey).contains { $0.type == MessageType.boost && $0.replyUUID == target.uuid }
            }

            for person in [alice, bob, carol] { await person.close() }
        }

        /// Alice makes a tribe with tags; Bob reads its details from the
        /// registry, then sets how he appears in it. Alice sees his post
        /// under that name and photo, and her mention of that name is one
        /// of him. Alice's edit of the tags comes back as she set them.
        @Test func detailsTagsAndHowYouAppear() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            for person in [alice, bob] { try await Bank.shared.give(500, to: person) }
            let tag = UUID().uuidString.prefix(6)

            let club = try await alice.engine.createTribe(TribeSettings(name: "club \(tag)", tags: ["Bitcoin", "Tech"]))
            try await bob.engine.joinTribe(link: try #require(club.link))
            try await Self.waitUntilIn(club.pubkey, bob)
            let details = try await bob.engine.tribeDetails(club.pubkey)
            #expect(details.info.settings.tags == ["Bitcoin", "Tech"])
            #expect(details.info.ownerAlias == "alice")
            #expect(details.info.created != nil)

            var settings = try await alice.engine.tribeSettings(club.pubkey)
            #expect(settings.tags == ["Bitcoin", "Tech"])
            settings.tags = ["Music"]
            try await alice.engine.updateTribe(club.pubkey, settings: settings)
            #expect(try await alice.engine.tribeSettings(club.pubkey).tags == ["Music"])

            let photo = "https://example.com/bobby.png"
            try await bob.engine.setTribeIdentity(club.pubkey, alias: "Bobby Tables", photoURL: photo)
            let post = "hello from the club \(tag)"
            try await bob.engine.sendText(post, to: club.pubkey)
            try await eventually("Alice to see Bob as Bobby_Tables") {
                try alice.messages(in: club.pubkey).contains {
                    $0.content == post && $0.senderDetails == ("Bobby_Tables", photo)
                }
            }
            let mention = "@Bobby_Tables welcome \(tag)"
            try await alice.engine.sendText(mention, to: club.pubkey)
            try await eventually("Bob to be mentioned by his tribe alias") {
                try bob.messages(in: club.pubkey).contains { $0.content == mention && $0.mentionsMe }
            }

            for person in [alice, bob] { await person.close() }
        }

        static func waitUntilIn(_ tribe: String, _ person: Person) async throws {
            try await eventually("\(person.name) to be in the tribe") {
                try person.storage.tribes().contains { $0.pubkey == tribe && !$0.left && $0.status == .active }
            }
        }
    }
}
