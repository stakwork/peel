import AgentKit
import Foundation
import GRDB
@testable import PeelAgent
import Synchronization
import Testing
@testable import PeelCore

extension Journeys {
    /// The Mac's side of the device channel (docs/agent-on-strut.md, PR 2)
    /// through the real core and broker: Bob stands in for the agent's
    /// account, sending the envelopes the bridge sends (runner
    /// `envelope.rs`), and Carol for anyone else.
    @Suite struct DeviceRequests {
        /// Alice's Mac answers Bob's `chats.unseen` once, with her unread
        /// messages read through the Sphinx read tools; a repeat
        /// gets the stored result and reads nothing; a request past its time
        /// is `expired`, an unknown kind refused; Carol's request, and Bob's
        /// for another device, get nothing back.
        @Test func theMacAnswersItsAgentOnce() async throws {
            let (alice, bob) = try await Journeys.Payments.pair()
            let carol = try await Person.create("carol")
            try await Bank.shared.give(500, to: carol)
            try await carol.engine.addContact(code: try alice.contactInfo)
            try await eventually("Alice and Carol to be contacts") {
                try alice.isReadyContact(carol) && carol.isReadyContact(alice)
            }
            let (aliceKey, bobKey, carolKey) = (try alice.pubkey, try bob.pubkey, try carol.pubkey)
            let words = "the ferry is late \(UUID().uuidString.prefix(6))"
            try await carol.engine.sendText(words, to: aliceKey)
            try await eventually("Alice to receive Carol's message") {
                try alice.messages(in: carolKey).contains { $0.content == words }
            }

            let reads = Mutex(0)
            let handler = DeviceReads(storage: alice.storage).handler
            await alice.engine.answerDeviceRequests { request in
                reads.withLock { $0 += 1 }
                return await handler(request)
            }
            try await alice.engine.setDeviceAgent(bobKey)
            let mac = await alice.engine.deviceID
            let later = Int64(Date().timeIntervalSince1970) + 3600
            func request(_ id: String, kind: String = "chats.unseen", device: String = mac, notAfter: Int64 = later) -> ControlEnvelope {
                ControlEnvelope(op: .request, id: id, device: device, kind: kind, args: .object([:]), notAfter: notAfter)
            }
            /// What came back to `person` about `id`, oldest first.
            func answers(_ id: String, to person: Person) throws -> [ControlEnvelope] {
                try person.messages(in: aliceKey).compactMap {
                    guard !$0.fromMe, case .envelope(let envelope)? = $0.control, envelope.re == id else { return nil }
                    return envelope
                }
            }
            func result(_ id: String, count: Int = 1) async throws -> ControlEnvelope {
                try await eventually("the result for \(id)") {
                    let results = try answers(id, to: bob).filter { $0.op == .result }
                    return results.count >= count ? results.last : nil
                }
            }

            let ask = "1792159542479/turn/003-peel_device"
            try await bob.engine.sendControl(request(ask), text: "Peel asked your Mac to read your unread messages", to: aliceKey)
            let first = try await result(ask)
            #expect(try answers(ask, to: bob).first?.op == .ack)
            #expect(first.status == .done && first.error == nil)
            let text = try #require(first.result?.object?["text"]?.string)
            #expect(text.contains(ChatData.begin) && text.contains(words) && text.contains(ChatData.end))
            #expect(reads.withLock { $0 } == 1)

            // The bridge asks again with the same id: the stored result, not a second read.
            try await bob.engine.sendControl(request(ask), text: "Peel asked your Mac to read your unread messages", to: aliceKey)
            let again = try await result(ask, count: 2)
            #expect(again == first)
            #expect(reads.withLock { $0 } == 1)

            // Carol's request, and Bob's for another device: nothing back, nothing stored.
            try await carol.engine.sendControl(request("from-carol"), text: "Peel asked your Mac to read your unread messages", to: aliceKey)
            try await bob.engine.sendControl(request("other-mac", device: "mac-elsewhere"), text: "Peel asked another Mac", to: aliceKey)
            // Past its time, and a kind this Mac does not know: answered, nothing read.
            try await bob.engine.sendControl(request("too-late", notAfter: later - 7200), text: "late", to: aliceKey)
            #expect(try await result("too-late").status == .expired)
            try await bob.engine.sendControl(request("calendar", kind: "calendar.events"), text: "calendar", to: aliceKey)
            let calendar = try await result("calendar")
            #expect(calendar.status == .failed && calendar.error == "unsupported: this Mac does not answer 'calendar.events' requests")
            #expect(reads.withLock { $0 } == 2)
            try await eventually("Carol's and the other Mac's requests to reach Alice") {
                try alice.messages(in: carolKey).contains { $0.control != nil }
                    && alice.messages(in: bobKey).contains { if case .envelope(let e)? = $0.control { e.id == "other-mac" } else { false } }
            }
            // Give a wrong answer time to go out before looking for it.
            try await Task.sleep(for: .seconds(3))
            #expect(try answers("from-carol", to: carol).isEmpty && answers("from-carol", to: bob).isEmpty)
            #expect(try answers("other-mac", to: bob).isEmpty)
            #expect(try await alice.storage.pool.read {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM deviceRequest WHERE id IN ('from-carol', 'other-mac')")
            } == 0)
            #expect(try alice.messages(in: carolKey).filter { $0.fromMe && $0.control != nil }.isEmpty)

            // A stop while a read runs: acked, never answered. Relaunched,
            // with history caught up again, the Mac finishes that one and
            // answers nothing it answered before.
            // Held past the journey's end, whatever cancels the engine's work.
            await alice.engine.answerDeviceRequests { _ in
                await Task.detached { try? await Task.sleep(for: .seconds(300)) }.value
                return .failed("stopped")
            }
            try await bob.engine.sendControl(request("cut-short", kind: "chats.list"), text: "Peel asked your Mac to list your chats", to: aliceKey)
            try await eventually("the ack for cut-short") { try answers("cut-short", to: bob).contains { $0.op == .ack } }
            await alice.engine.close()
            let relaunched = try alice.relaunched()
            await relaunched.engine.answerDeviceRequests(with: DeviceReads(storage: relaunched.storage).handler)
            try await relaunched.engine.connect()
            let finished = try await result("cut-short")
            #expect(finished.status == .done && finished.result?.object?["text"]?.string?.contains("Contact 'bob'") == true)
            try await eventually("the catch-up to finish", timeout: .seconds(60)) { await !relaunched.engine.isSyncingHistory }
            try await Task.sleep(for: .seconds(3))
            #expect(try answers(ask, to: bob).filter { $0.op == .result }.count == 2)
            #expect(try answers("too-late", to: bob).filter { $0.op == .result }.count == 1)

            for person in [relaunched, bob, carol] { await person.close() }
        }

        /// Bob, as the agent, asks Alice's Mac to send to Carol as her. The
        /// card is asked (here answered by the test as a click would); allowed,
        /// Carol gets the message once, and a repeat of the request sends
        /// nothing; denied, nothing goes; a card still up at the request's
        /// time answers `expired`. A request Peel stopped on once its send
        /// was committed (the row left `sending` with a uuid, as a kill there
        /// leaves it; here without the message, which the engine's own resend
        /// would otherwise deliver) answers `unknown` after a relaunch and is
        /// not sent again.
        @Test func theMacSendsAsYouOnceAndOnlyWhenAllowed() async throws {
            let (alice, bob) = try await Journeys.Payments.pair()
            let carol = try await Person.create("carol")
            try await Bank.shared.give(500, to: carol)
            try await carol.engine.addContact(code: try alice.contactInfo)
            try await eventually("Alice and Carol to be contacts") {
                try alice.isReadyContact(carol) && carol.isReadyContact(alice)
            }
            let (aliceKey, bobKey, carolKey) = (try alice.pubkey, try bob.pubkey, try carol.pubkey)

            let replies = Mutex<[String: ApprovalDecision?]>([:])
            let asked = Mutex<[String]>([])
            func actions(for person: Person) throws -> DeviceRequestHandler {
                let path = person.profile.directory.appendingPathComponent("agent.sqlite").path
                let rules = ApprovalRules(store: try SQLiteAgentStore(path: path, device: "mac"))
                return DeviceActions(engine: person.engine, rules: rules) { request, _ in
                    asked.withLock { $0.append(request.id) }
                    if let reply = replies.withLock({ $0[request.id] }) { return reply }
                    // A card nobody answers.
                    try? await Task.sleep(for: .seconds(300))
                    return .deny
                }.handler
            }
            await alice.engine.answerDeviceRequests(with: try actions(for: alice))
            try await alice.engine.setDeviceAgent(bobKey)
            let mac = await alice.engine.deviceID
            func send(_ id: String, _ text: String, seconds: Int64 = 3600) async throws {
                let args: PeelCore.JSONValue = .object(["chat": .string(carolKey), "text": .string(text)])
                let request = ControlEnvelope(op: .request, id: id, device: mac, kind: "send", args: args,
                                              notAfter: Int64(Date().timeIntervalSince1970) + seconds)
                try await bob.engine.sendControl(request, text: "Peel asked your Mac to send a message for you", to: aliceKey)
            }
            func results(_ id: String) throws -> [ControlEnvelope] {
                try bob.messages(in: aliceKey).compactMap {
                    guard !$0.fromMe, case .envelope(let e)? = $0.control, e.re == id, e.op == .result else { return nil }
                    return e
                }
            }
            func result(_ id: String, count: Int = 1) async throws -> ControlEnvelope {
                try await eventually("the result for \(id)", timeout: .seconds(60)) {
                    let all = try results(id)
                    return all.count >= count ? all.last : nil
                }
            }
            func carolGot(_ text: String) throws -> Int {
                try carol.messages(in: aliceKey).filter { $0.content == text }.count
            }

            let words = "on my way \(UUID().uuidString.prefix(6))"
            replies.withLock { $0["allow"] = .some(.allowOnce) }
            try await send("allow", words)
            let first = try await result("allow")
            #expect(first.status == .done)
            #expect(first.result?.object?["text"]?.string?.hasPrefix("Sent to") == true)
            try await eventually("Carol to get it") { try carolGot(words) == 1 }
            // The bridge asks again: the stored answer, and no second card or send.
            try await send("allow", words)
            #expect(try await result("allow", count: 2) == first)
            #expect(asked.withLock { $0.filter { $0 == "allow" }.count } == 1)

            replies.withLock { $0["deny"] = .some(.deny) }
            try await send("deny", "no \(words)")
            #expect(try await result("deny").status == .denied)
            try await send("late", "late \(words)", seconds: 4)
            #expect(try await result("late").status == .expired)

            // The card is up when Peel stops; the row is left as a kill just
            // after the send's commit leaves it.
            try await send("cut", "cut \(words)")
            try await eventually("the card for cut") { asked.withLock { $0.contains("cut") } }
            await alice.engine.close()
            try await alice.storage.pool.write {
                try $0.execute(sql: "UPDATE deviceRequest SET state = 'sending', sentUUID = 'cut-uuid' WHERE id = 'cut'")
            }
            let relaunched = try alice.relaunched()
            await relaunched.engine.answerDeviceRequests(with: try actions(for: relaunched))
            try await relaunched.engine.connect()
            let cut = try await result("cut")
            #expect(cut.status == .unknown && cut.error?.contains("cannot tell whether it went") == true)
            #expect(cut.error?.contains("uuid=cut-uuid") == true)
            try await Task.sleep(for: .seconds(3))
            for text in ["no \(words)", "late \(words)", "cut \(words)"] { #expect(try carolGot(text) == 0) }
            #expect(try carolGot(words) == 1)

            for person in [relaunched, bob, carol] { await person.close() }
        }
    }
}

private extension PeelCore.JSONValue {
    var object: [String: PeelCore.JSONValue]? {
        if case .object(let fields) = self { fields } else { nil }
    }
}
