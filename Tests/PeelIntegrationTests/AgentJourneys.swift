import AgentKit
import Foundation
@testable import PeelAgent
import Synchronization
import Testing
@testable import PeelCore

extension Journeys {
    /// The agent over a real account: the Sphinx tools read and send
    /// through the real core, broker and storage, and the send waits on the
    /// approval gate in the agent chat's session. Only the model is a
    /// script (`ScriptedModel`), which asks for the calls a model would.
    @MainActor @Suite struct Agent {
        /// Bob writes to Alice and posts in her tribe, in a thread. Her
        /// agent's read tools, called side by side as a model would, see
        /// exactly what arrived: his messages with their real uuids and chat
        /// ids, the unseen counts, a search hit, and the thread whole.
        @Test func readToolsSeeWhatArrived() async throws {
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

            let model = ScriptedModel([
                .calls([("c1", "read_unseen_messages", [:]), ("c2", "search_messages", ["query": "heron"]),
                        ("c3", "get_contacts_and_tribes", [:])]),
                .calls([("c4", "read_threads", ["tribe": .string(clubName), "thread_uuid": .string(root)])]),
                .text("Bob wrote twice and started a thread."),
            ])
            let agent = try Self.session(for: alice, model: model)
            agent.send("What did I miss?")
            try await eventually("the reply") { !agent.isRunning }

            #expect(agent.problem == nil)
            let rows = try #require(agent.turns.last?.tools)
            #expect(rows.map { $0.name } == ["read_unseen_messages", "search_messages", "get_contacts_and_tribes", "read_threads"])
            #expect(rows.allSatisfy { !$0.failed })

            let step1 = model.results(after: 0), step2 = model.results(after: 1)
            let unseen = try #require(step1["c1"]), search = try #require(step1["c2"])
            let directory = try #require(step1["c3"]), thread = try #require(step2["c4"])
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
            // Other people's words reach the model only between the markers.
            for result in [unseen, search, thread] { #expect(result.contains(ChatData.begin) && result.contains(ChatData.end)) }

            agent.close()
            for person in [alice, bob] { await person.close() }
        }

        /// Alice's agent asks to message Bob. Allowed once, Bob receives
        /// exactly the words on the card, and the row links to that message.
        /// Denied, nothing leaves: Bob gets nothing, Alice keeps no row, and
        /// the model is told.
        @Test func aSendGoesOnlyOnceAllowed() async throws {
            let (alice, bob) = try await Journeys.Payments.pair()
            let tag = UUID().uuidString.prefix(6)
            let bobKey = try bob.pubkey
            let allowed = "running ten minutes late \(tag)", denied = "never mind, cancel everything \(tag)"
            let model = ScriptedModel([
                .calls([("s1", "send_sphinx_message", ["chat": "bob", "text": .string(allowed)])]),
                .text("Sent."),
                .calls([("s2", "send_sphinx_message", ["chat": .string(bobKey), "text": .string(denied)])]),
                .text("Not sent."),
            ])
            let agent = try Self.session(for: alice, model: model)

            agent.send("Tell Bob I'm late")
            let card = try await eventually("the card") { agent.waiting }
            #expect(card.intent.content == allowed)
            #expect(card.intent.cost == nil)
            #expect(card.intent.target?.id == bobKey)
            #expect(try alice.messages(in: bobKey).allSatisfy { !$0.fromMe }, "sent before it was allowed")
            agent.answer(.allowOnce)
            try await eventually("the reply") { !agent.isRunning }

            let received = try await eventually("Bob to receive the allowed message") {
                try bob.messages(in: try alice.pubkey).first { $0.content == allowed && !$0.fromMe }
            }
            let row = try #require(agent.turns.last?.tools.first)
            #expect(row.approval?.outcome == .allowedOnce)
            let link = try #require(AgentMessageLink(summary: row.summary ?? ""), "\(row.summary ?? "no summary")")
            #expect(link.chat == bobKey)
            #expect(link.uuid == received.uuid)
            #expect(try alice.messages(in: bobKey).filter { $0.fromMe && $0.content == allowed }.count == 1)

            agent.send("Actually, tell him to cancel")
            _ = try await eventually("the second card") { agent.waiting }
            agent.answer(.deny)
            try await eventually("the reply") { !agent.isRunning }
            #expect(agent.turns.last?.tools.first?.approval?.outcome == .denied)
            #expect(model.results(after: 2)["s2"]?.hasPrefix("The user declined") == true)
            // Alice keeps no row of it (checked last, decisive: a send writes
            // its row before the turn ends); Bob, by the time a later message
            // reached him, had nothing of it either.
            let after = "after the card \(tag)"
            try await alice.engine.sendText(after, to: bobKey)
            try await eventually("Bob to receive the message after the card") {
                try bob.messages(in: try alice.pubkey).contains { $0.content == after }
            }
            #expect(try bob.messages(in: try alice.pubkey).allSatisfy { $0.content != denied })
            #expect(try alice.messages(in: bobKey).allSatisfy { $0.content != denied })

            agent.close()
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
            let model = ScriptedModel([
                .calls([("t1", "send_sphinx_message", ["chat": .string(clubName), "text": .string(paid)])]),
                .text("Posted."),
                .calls([("t2", "send_sphinx_message", ["chat": .string(clubName), "text": .string(refused)])]),
                .text("Done."),
            ])
            let agent = try Self.session(for: alice, model: model)
            let price = try #require(try await alice.engine.messagePrice(to: club.pubkey))
            #expect(price.msat == 10_000)

            let before = try #require(try await alice.settledBalance())
            agent.send("Say gm in the paid club")
            let card = try await eventually("the card") { agent.waiting }
            #expect(card.intent.cost == "Costs \(price.described). Paid from your balance.")
            #expect(card.intent.mayBeAlwaysAllowed == false)
            agent.answer(.allowOnce)
            try await eventually("the reply") { !agent.isRunning }
            #expect(agent.turns.last?.tools.first?.failed == false)
            try await eventually("Bob to see the agent's post") {
                try bob.messages(in: club.pubkey).contains { $0.content == paid && !$0.fromMe }
            }
            let after = try await alice.balance(settlingAt: before - price.msat / 1000)
            #expect(after == before - price.msat / 1000)

            // A second post; while its card waits, Bob doubles the price and
            // Alice's Mac learns it as the tribe's refresh would.
            agent.send("And post again")
            let second = try await eventually("the second card") { agent.waiting }
            #expect(second.intent.cost == card.intent.cost)
            settings = try await bob.engine.tribeSettings(club.pubkey)
            settings.pricePerMessageMsat = 20_000
            try await bob.engine.updateTribe(club.pubkey, settings: settings)
            try await eventually("Alice's Mac to know the new price", every: .seconds(1)) {
                _ = try await alice.engine.tribeDetails(club.pubkey)
                return try await alice.engine.messagePrice(to: club.pubkey)?.msat == 20_000
            }
            agent.answer(.allowOnce)
            try await eventually("the reply") { !agent.isRunning }

            let row = try #require(agent.turns.last?.tools.first)
            #expect(row.failed)
            // Refused in the engine's words, which the row and the model read.
            #expect(row.summary?.contains("charges more per message") == true, "\(row.summary ?? "")")
            #expect(model.results(after: 2)["t2"]?.contains("charges more per message") == true)
            #expect(try await alice.settledBalance(quiet: .seconds(3)) == after)
            #expect(try alice.messages(in: club.pubkey).allSatisfy { $0.content != refused })
            #expect(try bob.messages(in: club.pubkey).allSatisfy { $0.content != refused })

            agent.close()
            for person in [alice, bob] { await person.close() }
        }

        // MARK: - Helpers

        /// The agent chat on `person`'s account: its `agent.sqlite`, as the
        /// app and the CLI open it, the tools the app gives it (the time,
        /// the read tools and the send tool over its engine) and their
        /// prompts; `model` in place of the provider.
        static func session(for person: Person, model: ScriptedModel) throws -> AgentSession {
            let setup = AgentSetup(sending: person.engine)
            let credentials = KeptInMemory(AgentCredential(provider: .anthropic, model: "scripted", apiKey: "unused"))
            return AgentSession(
                store: try SQLiteAgentStore.open(for: person.profile, storage: person.storage), credentials: credentials,
                tools: setup.tools, systemPrompt: setup.systemPrompt(), makeClient: { _ in model })
        }
    }
}

/// The model, scripted: each request is answered by the next reply, as a
/// provider streams it. Keeps every request, so a journey can read the tool
/// results the model was sent.
final class ScriptedModel: ModelProvider {
    enum Reply: Sendable {
        case calls([(id: String, name: String, input: AgentKit.JSONValue)])
        case text(String)
    }

    private let replies: Mutex<[Reply]>
    private let requests = Mutex<[ModelRequest]>([])

    init(_ replies: [Reply]) {
        self.replies = Mutex(replies)
    }

    /// The tool results sent in the request after reply `index`, by call id.
    func results(after index: Int) -> [String: String] {
        let sent = requests.withLock { $0.count > index + 1 ? $0[index + 1] : nil }
        var results: [String: String] = [:]
        for case .toolResult(let result) in sent?.messages.last?.content ?? [] { results[result.toolCallID] = result.content }
        return results
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        requests.withLock { $0.append(request) }
        let reply = replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            switch reply {
            case .calls(let calls)?:
                for call in calls { continuation.yield(.toolCallCompleted(ToolCall(id: call.id, name: call.name, input: call.input))) }
                continuation.yield(.finished(.toolUse))
            case .text(let text)?:
                continuation.yield(.textDelta(text))
                continuation.yield(.finished(.endTurn))
            case nil:
                continuation.finish(throwing: ModelError.malformed("no reply scripted"))
                return
            }
            continuation.finish()
        }
    }
}

/// The connected model's credential, kept in memory: the journeys never
/// touch the Keychain.
final class KeptInMemory: AgentCredentialStore {
    private let kept: Mutex<AgentCredential?>
    init(_ credential: AgentCredential) { kept = Mutex(credential) }
    func read() throws -> AgentCredential? { kept.withLock { $0 } }
    func write(_ credential: AgentCredential) throws { kept.withLock { $0 = credential } }
    func delete() throws { kept.withLock { $0 = nil } }
}
