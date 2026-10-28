import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Tribes {
        /// Alice creates a free tribe and a paid one. Bob joins the free one
        /// (1 sat, as the official apps pay), Carol and Bob the paid one at
        /// its price. Carol posts there and pays the price per message, once
        /// for a text and once for a file, whose row the tribe's copy finds;
        /// Bob boosts her post, paying the tip plus the price, all of it to her.
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

            // A file pays the price too, once, and its row takes the send.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-\(tag).pdf")
            try Data("%PDF-1.4\n% ridge \(tag)\n%%EOF\n".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let caption = "the ridge at dawn \(tag)"
            let fileID = try await carol.engine.sendAttachment(file, text: caption, to: paid.pubkey)
            try await eventually("Carol's file to come back from the tribe") {
                try carol.storage.message(id: fileID)?.delivery == .delivered
            }
            #expect(try carol.messages(in: paid.pubkey).filter { $0.type == MessageType.attachment }.count == 1)
            let seenFile = try await carol.balance(settlingAt: c0 - 70)
            #expect(seenFile == c0 - 70)
            try await eventually("Alice to see Carol's file") {
                try alice.messages(in: paid.pubkey).contains { $0.type == MessageType.attachment && $0.content == caption }
            }

            // A boost of 20 sats on her post, plus the tribe's 10.
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

            // Her file is boosted the same way, as the Mac app allows.
            let fileTarget = try #require(try bob.messages(in: paid.pubkey).first { $0.type == MessageType.attachment })
            try await bob.engine.boost(messageID: try #require(fileTarget.id), amountMsat: 20_000)
            let seen8 = try await bob.balance(settlingAt: b1 - 60)
            #expect(seen8 == b1 - 60)
            let seen9 = try await carol.balance(settlingAt: c1 + 60)
            #expect(seen9 == c1 + 60)
            try await eventually("Carol to see the boost on her file") {
                try carol.messages(in: paid.pubkey).contains { $0.type == MessageType.boost && $0.replyUUID == fileTarget.uuid }
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

        /// Alice on two devices, as the official apps keep a tribe across
        /// them: she joins Carol's tribe on the first, and the second, which
        /// has never seen it, shows it joined (from our own tribes registry),
        /// with her post there as hers. She leaves on the first, and the
        /// second shows it left. The second pays nothing for either.
        @Test func aTribeJoinedAndLeftOnOneDeviceFollowsOnTheOther() async throws {
            let carol = try await Person.create("carol")
            let alice = try await Person.create("alice")
            for person in [alice, carol] { try await Bank.shared.give(500, to: person) }
            let club = try await carol.engine.createTribe(TribeSettings(name: "both \(UUID().uuidString.prefix(6))"))
            let second = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) {
                await !second.engine.isSyncingHistory ? true : nil
            }
            #expect(try second.storage.tribes().isEmpty)

            try await alice.engine.joinTribe(link: try #require(club.link))
            try await Self.waitUntilIn(club.pubkey, alice)
            // Posted at once, before the second Mac has asked the registry:
            // held there, and kept once the tribe is known.
            let post = "from the first Mac \(UUID().uuidString.prefix(6))"
            try await alice.engine.sendText(post, to: club.pubkey)
            try await Self.waitUntilIn(club.pubkey, second)
            let joined = try #require(try second.storage.tribes().first { $0.pubkey == club.pubkey })
            #expect(joined.name == club.name && !joined.isOwner)
            try await eventually("Alice's post to show as hers on her second Mac") {
                try second.messages(in: club.pubkey).contains { $0.content == post && $0.fromMe }
            }

            try await alice.engine.leaveTribe(club.pubkey)
            try await eventually("the second Mac to show the tribe left") {
                try second.storage.tribes().contains { $0.pubkey == club.pubkey && $0.left }
            }
            // The second Mac sent nothing, so paid nothing: every row it holds
            // there came from the network (a send of its own is pending until
            // the server takes it); a copy of ours the server indexed twice may
            // be marked COMPLETE, never PENDING or FAILED.
            try await Task.sleep(for: .seconds(2))
            #expect(try second.messages(in: club.pubkey).allSatisfy { $0.status == nil || $0.delivery == .delivered })

            for person in [alice, second, carol] { await person.close() }
        }

        static func waitUntilIn(_ tribe: String, _ person: Person) async throws {
            try await eventually("\(person.name) to be in the tribe") {
                try person.storage.tribes().contains { $0.pubkey == tribe && !$0.left && $0.status == .active }
            }
        }
    }
}
