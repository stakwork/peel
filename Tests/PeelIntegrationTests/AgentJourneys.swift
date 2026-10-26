import AgentKit
import Foundation
@testable import PeelAgent
import Testing
@testable import PeelCore

extension Journeys {
    /// The Sphinx tools the Mac answers its agent with (`DeviceReads`,
    /// `DeviceActions`) over a real account: they read and send through the
    /// real core, broker and storage: the reads as the device requests ask
    /// them (`DeviceReads`); a send's plan is its card, and only running it,
    /// once allowed, sends.
    @MainActor @Suite struct Agent {
        /// Bob writes to Alice and posts in her tribe, in a thread. Her
        /// read tools see exactly what arrived: his messages with their real
        /// uuids and chat ids, the unseen counts, a search hit, and the
        /// thread whole.
        @Test func readToolsSeeWhatArrived() async throws {
            let fixture = try await CatchUp.make()
            let (alice, bob, bobKey, dms, club, clubName, root) =
                (fixture.alice, fixture.bob, fixture.bobKey, fixture.dms, fixture.club, fixture.clubName, fixture.root)
            let (first, second, rootText, replyText) = (fixture.first, fixture.second, fixture.rootText, fixture.replyText)
            let reads = DeviceReads(storage: alice.storage, myAlias: { nil })
            func read(_ kind: String, _ args: PeelCore.JSONValue = .object([:])) async throws -> String {
                let answer = await reads.answer(kind, args)
                return try #require(answer.text, "\(kind): \(answer.error ?? "no answer")")
            }

            let unseen = try await read("chats.unseen"), search = try await read("chats.search", .object(["q": .string("heron")]))
            let directory = try await read("chats.list")
            let thread = try await read("chats.read", .object(["chat": .string(clubName), "thread": .string(root)]))
            #expect(unseen.contains("(chat=\(bobKey)), 2 unseen =="), "\(unseen)")
            #expect(unseen.contains("(chat=\(club.pubkey)), 2 unseen =="), "\(unseen)")
            for dm in dms {
                let line = "(uuid=\(dm.uuid ?? "?")): \(dm.content ?? "?")"
                #expect(unseen.contains(line), "\(unseen)")
            }
            let heron = try #require(dms.first { $0.content == first }?.uuid)
            #expect(search.contains("uuid=\(heron)") && search.contains(first))
            #expect(!search.contains(second))
            #expect(directory.contains("(chat=\(bobKey))") && directory.contains("(chat=\(club.pubkey))"))
            #expect(thread.contains("(uuid=\(root) [THREAD ROOT, 1 replies]): \(rootText)"), "\(thread)")
            #expect(thread.contains(replyText))
            // Other people's words reach the agent only between the markers.
            for result in [unseen, search, thread] { #expect(result.contains(ChatData.begin) && result.contains(ChatData.end)) }

            for person in [alice, bob] { await person.close() }
        }

        /// Alice's agent asks to message Bob. Nothing leaves while its card
        /// is up; allowed, Bob receives exactly the words on the card, and
        /// what the send answers links to that message.
        @Test func aSendGoesOnlyOnceAllowed() async throws {
            let (alice, bob) = try await Journeys.Payments.pair()
            let tag = UUID().uuidString.prefix(6)
            let bobKey = try bob.pubkey
            let allowed = "running ten minutes late \(tag)"
            let send = PeelAgent.SphinxTools(storage: alice.storage).send(through: alice.engine)

            let (card, run) = try await Self.card(send, ["chat": "bob", "text": .string(allowed)])
            #expect(card.content == allowed)
            #expect(card.cost == nil)
            #expect(card.target?.id == bobKey)
            #expect(try alice.messages(in: bobKey).allSatisfy { !$0.fromMe }, "sent before it was allowed")
            let answer = try await run().text

            let received = try await eventually("Bob to receive the allowed message") {
                try bob.messages(in: try alice.pubkey).first { $0.content == allowed && !$0.fromMe }
            }
            let link = try #require(AgentMessageLink(summary: answer), "\(answer)")
            #expect(link.chat == bobKey)
            #expect(link.uuid == received.uuid)
            #expect(try alice.messages(in: bobKey).filter { $0.fromMe && $0.content == allowed }.count == 1)

            for person in [alice, bob] { await person.close() }
        }

        /// Alice's agent posts in Bob's paid tribe. The card says the price
        /// and that is exactly what leaves her balance. When Bob raises the
        /// price while a second card waits, allowing it pays nothing: the
        /// send is refused at the price on the card, and nothing arrives.
        @Test func aTribeSendPaysWhatTheCardSaidAndNeverMore() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            for person in [alice, bob] { try await Bank.shared.give(500, to: person) }
            let tag = UUID().uuidString.prefix(6)
            let clubName = "paid club \(tag)"
            var settings = TribeSettings(name: clubName, pricePerMessageMsat: 10_000)
            let club = try await bob.engine.createTribe(settings)
            try await alice.engine.joinTribe(link: try #require(club.link))
            try await Journeys.Tribes.waitUntilIn(club.pubkey, alice)

            let paid = "gm from the agent \(tag)", refused = "second post \(tag)"
            let send = PeelAgent.SphinxTools(storage: alice.storage).send(through: alice.engine)
            let price = try #require(try await alice.engine.messagePrice(to: club.pubkey))
            #expect(price.msat == 10_000)

            let before = try #require(try await alice.settledBalance())
            let (card, run) = try await Self.card(send, ["chat": .string(clubName), "text": .string(paid)])
            #expect(card.cost == "Costs \(price.described). Paid from your balance.")
            #expect(card.mayBeAlwaysAllowed == false)
            _ = try await run()
            try await eventually("Bob to see the agent's post") {
                try bob.messages(in: club.pubkey).contains { $0.content == paid && !$0.fromMe }
            }
            let after = try await alice.balance(settlingAt: before - price.msat / 1000)
            #expect(after == before - price.msat / 1000)

            // A second post; while its card waits, Bob doubles the price and
            // Alice's Mac learns it as the tribe's refresh would.
            let (second, runSecond) = try await Self.card(send, ["chat": .string(clubName), "text": .string(refused)])
            #expect(second.cost == card.cost)
            settings = try await bob.engine.tribeSettings(club.pubkey)
            settings.pricePerMessageMsat = 20_000
            try await bob.engine.updateTribe(club.pubkey, settings: settings)
            try await eventually("Alice's Mac to know the new price", every: .seconds(1)) {
                _ = try await alice.engine.tribeDetails(club.pubkey)
                return try await alice.engine.messagePrice(to: club.pubkey)?.msat == 20_000
            }
            // Refused in the engine's words, which the agent reads.
            await #expect { _ = try await runSecond() } throws: { "\($0)".contains("charges more per message") }
            #expect(try await alice.settledBalance(quiet: .seconds(3)) == after)
            #expect(try alice.messages(in: club.pubkey).allSatisfy { $0.content != refused })
            #expect(try bob.messages(in: club.pubkey).allSatisfy { $0.content != refused })

            for person in [alice, bob] { await person.close() }
        }

        // MARK: - Helpers

        /// What there is to catch up on: Bob writes to Alice twice, and posts
        /// in her tribe, in a thread, all unseen.
        struct CatchUp {
            let alice: Person, bob: Person, bobKey: String
            let first: String, second: String, dms: [Message]
            let club: Tribe, clubName: String, root: String, rootText: String, replyText: String

            static func make() async throws -> CatchUp {
                let (alice, bob) = try await Journeys.Payments.pair()
                let tag = UUID().uuidString.prefix(6)
                let bobKey = try bob.pubkey
                let first = "the heron leaves at dawn \(tag)", second = "bring the blue map \(tag)"
                for text in [first, second] { try await bob.engine.sendText(text, to: try alice.pubkey) }
                let dms = try await eventually("Alice to receive both of Bob's messages") {
                    let got = try alice.messages(in: bobKey).filter { !$0.fromMe && [first, second].contains($0.content) }
                    return got.count == 2 ? got : nil
                }

                let clubName = "agent club \(tag)"
                let club = try await alice.engine.createTribe(TribeSettings(name: clubName))
                try await bob.engine.joinTribe(link: try #require(club.link))
                try await Journeys.Tribes.waitUntilIn(club.pubkey, bob)
                let rootText = "release plan \(tag)", replyText = "ship it friday \(tag)"
                let rootTag = try #require(try await bob.engine.sendText(rootText, to: club.pubkey))
                // The tribe's copy takes the row over, with the uuid everyone holds.
                let root = try await eventually("Bob's post to come back from the tribe") {
                    try bob.storage.message(tag: rootTag).flatMap { $0.delivery == .delivered ? $0.uuid : nil }
                }
                try await bob.engine.sendText(replyText, to: club.pubkey, inThread: root)
                try await eventually("Alice to see Bob's thread") {
                    try alice.messages(in: club.pubkey).filter { $0.content == rootText || $0.content == replyText }.count == 2
                }
                return CatchUp(alice: alice, bob: bob, bobKey: bobKey, first: first, second: second, dms: dms, club: club,
                               clubName: clubName, root: root, rootText: rootText, replyText: replyText)
            }
        }

        /// A send's card for `input`, and the send itself, run only when allowed.
        static func card(_ tool: Tool, _ input: AgentKit.JSONValue) async throws
            -> (ToolIntent, @Sendable () async throws -> Tool.Output) {
            guard case .action(let intent, let run) = try await tool.plan(input) else { throw PeelError("a send answered at once") }
            return (intent, run)
        }
    }
}
