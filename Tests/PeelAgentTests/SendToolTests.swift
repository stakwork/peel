import AgentKit
import Foundation
import Testing
@testable import PeelAgent
@testable import PeelCore
@testable import PeelTestSupport

/// `send_sphinx_message` over a real engine on a connection that takes
/// every write: the plan (names, threads, replies, the card's words and
/// price) and the send through `Engine.sendText`.
struct SendToolTests {
    let profile = TempProfile()

    /// Kate (keyG) and Kate Moss (key3G), ready contacts, with one message
    /// from Kate; Bitcoin Devs (key2G), a joined tribe, with ann's
    /// message, the root of a thread.
    private func withTool(_ body: (Tool, Engine, Storage) async throws -> Void) async throws {
        try await withEngine { engine, storage in try await body(SphinxTools(storage: storage).send(through: engine), engine, storage) }
    }

    private func withEngine(_ body: (Engine, Storage) async throws -> Void) async throws {
        var setup = Storage.Commit()
        setup.settings[.balanceMsat] = "1000000"
        let storage = try registeredStorage(profile, contact: keyG, setup)
        try storage.upsertContact(pubkey: keyG, alias: "Kate")
        try storage.save([Tribe(pubkey: key2G, name: "Bitcoin Devs")])
        var joined = Storage.Commit()
        joined.state = registeredState.merging(coreContact(keyG, contactKey: key3G)) { $1 }
            .merging(coreContact(key3G, contactKey: key3G, index: 3)) { $1 }
            .merging(coreContact(key2G, contactKey: nil, index: 2)) { $1 }
        joined.contacts = [(key3G, true)]
        joined.messages = [
            (.fixture(uuid: uuid(1), serverIndex: 1, chat: keyG, content: "lunch?", timestamp: 1_000), false, nil),
            (.fixture(uuid: uuid(10), serverIndex: 10, chat: key2G, sender: sender(key2G, alias: "ann"),
                      content: "release plan", timestamp: 2_000), false, nil),
        ]
        _ = try storage.apply(joined)
        try storage.upsertContact(pubkey: key3G, alias: "Kate Moss")
        try await withTestEngine(storage, on: Transport(publishing: { _, _ in })) { engine in
            try await body(engine, storage)
        }
    }

    private func plan(_ tool: Tool, _ input: AgentKit.JSONValue) async throws -> Tool.Plan {
        #expect(tool.effect == .send)
        return try await tool.plan(input)
    }

    private func action(_ plan: Tool.Plan) throws -> (ToolIntent, @Sendable () async throws -> Tool.Output) {
        guard case .action(let intent, let run) = plan else { throw PeelError("expected an action, got \(plan)") }
        return (intent, run)
    }

    private func answer(_ plan: Tool.Plan) -> String? {
        if case .result(let output) = plan { output.text } else { nil }
    }

    @Test func aContactSendIsShownThenSentAndLinked() async throws {
        try await withTool { tool, _, storage in
            let (intent, run) = try action(try await plan(tool, ["chat": "Kate", "text": "Running 10 min late"]))
            #expect(intent.action == "Send to Kate")
            #expect(intent.content == "Running 10 min late")
            #expect(intent.cost == nil)
            #expect(intent.mayBeAlwaysAllowed)
            #expect(intent.target == ToolIntent.Target(id: keyG, name: "Kate"))
            // Nothing is sent by planning.
            #expect(try storage.message(uuid: uuid(1), in: keyG) != nil)
            #expect(try rows(profile, "SELECT id FROM message WHERE fromMe = 1").isEmpty)

            let summary = try await run().text
            let link = try #require(AgentMessageLink(summary: summary))
            #expect(link.chat == keyG)
            let sent = try #require(try storage.message(uuid: link.uuid, in: keyG))
            #expect(sent.content == "Running 10 min late")
            #expect(sent.fromMe)
            #expect(AgentMessageLink(try #require(link.url)) == link)
            #expect(summary.hasPrefix("Sent to 'Kate'"))
        }
    }

    /// The card names the price; the send it allows pays no more than
    /// that, even when the registry raised the price while the card waited
    /// (as the background refresh brings it in, `saveRecords`).
    @Test func aTribeSendSaysWhatItCostsAndNeverPaysMore() async throws {
        try await withTool { tool, engine, _ in
            let (intent, run) = try action(try await plan(tool, ["chat": "bitcoin devs", "text": "gm"]))
            #expect(intent.action == "Send to the tribe Bitcoin Devs")
            #expect(intent.cost == "Costs 3 sats, the minimum. Paid from your balance.")
            #expect(!intent.mayBeAlwaysAllowed)

            let raised = try #require(JSON.decode(
                TribeInfo.self, from: #"{"pubkey":"\#(key2G)","name":"Bitcoin Devs","price_per_message":5000}"#))
            await engine.saveRecords([raised], asked: .now)
            // Refused in the engine's words, which the row and the model read.
            let refusal = await #expect(throws: (any Error).self) { try await run() }
            #expect(refusal?.localizedDescription
                == "Not sent to 'Bitcoin Devs'. This tribe now charges more per message; send it as a new message."
                + " Ask the user before trying again.")
            #expect(try rows(profile, "SELECT id FROM message WHERE fromMe = 1").isEmpty)

            // Asked again, the card says the new price, and that send goes.
            let (again, send) = try action(try await plan(tool, ["chat": "bitcoin devs", "text": "gm"]))
            #expect(again.cost == "Costs 5 sats. Paid from your balance.")
            #expect(try await send().text.hasPrefix("Sent to"))
            #expect(try rows(profile, "SELECT id FROM message WHERE fromMe = 1").count == 1)
        }
    }

    @Test func aReplyAndAThreadAreShownWhenTheyExistInThatChat() async throws {
        try await withTool { tool, _, _ in
            let (reply, _) = try action(try await plan(tool, ["chat": "Kate", "text": "yes", "reply_to_uuid": .string(uuid(1))]))
            #expect(reply.details == ["In reply to Kate: 'lunch?'"])
            let (thread, _) = try action(try await plan(tool, ["chat": "Bitcoin Devs", "text": "+1", "thread_uuid": .string(uuid(10))]))
            #expect(thread.details == ["In the thread: ann: 'release plan'"])
        }
    }

    @Test func idsNotReadFromThatChatAreRefused() async throws {
        try await withTool { tool, _, _ in
            // Kate's message is not in the tribe, and no message has uuid 99.
            let elsewhere = answer(try await plan(tool, ["chat": "Bitcoin Devs", "text": "x", "reply_to_uuid": .string(uuid(1))]))
            #expect(elsewhere?.hasPrefix("Cannot send that") == true)
            let invented = answer(try await plan(tool, ["chat": "Kate", "text": "x", "reply_to_uuid": .string(uuid(99))]))
            #expect(invented?.hasPrefix("Cannot send that") == true)
            let contactThread = answer(try await plan(tool, ["chat": "Kate", "text": "x", "thread_uuid": .string(uuid(1))]))
            #expect(contactThread?.hasPrefix("Threads are only in tribes") == true)
        }
    }

    @Test func anAmbiguousNameListsTheCandidates() async throws {
        try await withTool { tool, _, _ in
            let text = try #require(answer(try await plan(tool, ["chat": "kat", "text": "hi"])))
            #expect(text.contains("Several chats match"))
            #expect(text.contains("chat=\(keyG)"))
            #expect(text.contains("chat=\(key3G)"))
            let none = answer(try await plan(tool, ["chat": "Zebra", "text": "hi"]))
            #expect(none?.hasPrefix("No contact or tribe named") == true)
        }
    }

    @Test func hiddenCharactersAndEmptyTextAreRefused() async throws {
        try await withTool { tool, _, _ in
            // Which characters hide something is `ToolIntent.isShowable`'s (ApprovalGateTests); here, that the tool asks it.
            for text in ["", "  ", "ok\u{202E}evil", "bell\u{7}", "hid\u{FFF9}den\u{FFFB}"] {
                await #expect(throws: (any Error).self) { try await tool.plan(["chat": "Kate", "text": .string(text)]) }
            }
            // Lines and tabs are fine.
            _ = try action(try await plan(tool, ["chat": "Kate", "text": "one\ntwo\tthree"]))
            // Emoji keep their joiner.
            _ = try action(try await plan(tool, ["chat": "Kate", "text": "family 👨‍👩‍👧"]))
        }
    }

    @Test func aReplyOutsideTheThreadNamedIsRefusedBeforeTheCard() async throws {
        try await withTool { tool, _, storage in
            _ = try storage.apply(Storage.Commit(messages: [
                (.fixture(uuid: uuid(20), serverIndex: 20, chat: key2G, sender: sender(key2G, alias: "bob"),
                          content: "other root", timestamp: 3_000), false, nil),
            ]))
            let text = answer(try await plan(tool, [
                "chat": "Bitcoin Devs", "text": "x", "thread_uuid": .string(uuid(10)), "reply_to_uuid": .string(uuid(20)),
            ]))
            #expect(text?.hasPrefix("Cannot send that") == true)
        }
    }
}

/// The agent's `send` and `approve` device requests (`DeviceActions`) over
/// the same engine: the send tool's plan on its card, at most once, a
/// card that runs out of time, and send grants for automations.
struct DeviceActionsTests {
    let profile = TempProfile()

    /// What the Mac's cards were asked, and how they answer.
    final class Cards: @unchecked Sendable {
        let lock = NSLock()
        private var _asked: [ToolIntent] = []
        private var _reply: ApprovalDecision?? = .some(.allowOnce)
        var asked: [ToolIntent] { lock.withLock { _asked } }
        var reply: ApprovalDecision?? {
            get { lock.withLock { _reply } }
            set { lock.withLock { _reply = newValue } }
        }

        func ask(_ approval: ApprovalRequest) async -> ApprovalDecision? {
            let reply = lock.withLock {
                _asked.append(approval.intent)
                return _reply
            }
            if let reply { return reply }
            // Never answered: up until the card is taken down.
            try? await Task.sleep(for: .seconds(60))
            return .deny
        }
    }

    private func withActions(
        publishing: @escaping @Sendable (String, Data) async throws -> Void = { _, _ in },
        _ body: (DeviceActions, Cards, Storage) async throws -> Void
    ) async throws {
        var setup = Storage.Commit()
        setup.settings[.balanceMsat] = "1000000"
        let storage = try registeredStorage(profile, contact: keyG, setup)
        try storage.upsertContact(pubkey: keyG, alias: "Kate")
        try storage.save([Tribe(pubkey: key2G, name: "Bitcoin Devs")])
        var joined = Storage.Commit()
        joined.state = registeredState.merging(coreContact(keyG, contactKey: key3G)) { $1 }
            .merging(coreContact(key2G, contactKey: nil, index: 2)) { $1 }
        _ = try storage.apply(joined)
        let rules = ApprovalRules(store: try SQLiteAgentStore.inMemory(device: "mac"))
        let cards = Cards()
        try await withTestEngine(storage, on: Transport(publishing: publishing)) { engine in
            let actions = DeviceActions(engine: engine, rules: rules, calendar: StandInCalendar()) { _, approval in await cards.ask(approval) }
            try await body(actions, cards, storage)
        }
    }

    /// A request stored and claimed, as the engine hands it over.
    private func request(
        _ id: String, _ input: AgentKit.JSONValue, kind: String = "send", in storage: Storage, for seconds: TimeInterval = 3600
    ) throws -> DeviceRequest {
        guard let args = PeelCore.JSONValue(text: input.jsonString) else { throw PeelError("not JSON: \(input)") }
        let deadline = Date().addingTimeInterval(seconds)
        let row = DeviceRequestRow(agent: "02a", id: id, kind: kind, args: try args.text, notAfter: Int64(deadline.timeIntervalSince1970),
                                   state: .received, receivedAt: 1)
        _ = try storage.admit(row, copy: id)
        _ = try storage.claimDeviceRequest(id, of: "02a")
        return DeviceRequest(agent: "02a", id: id, kind: kind, args: args, deadline: Date(timeIntervalSince1970: TimeInterval(row.notAfter)))
    }

    /// `request` answered by `actions`, as the engine's run asks it.
    private func answer(
        _ actions: DeviceActions, _ id: String, _ input: AgentKit.JSONValue, kind: String = "send", in storage: Storage,
        for seconds: TimeInterval = 3600
    ) async throws -> DeviceAnswer? {
        await actions.answer(try request(id, input, kind: kind, in: storage, for: seconds))
    }

    private func sent(_ storage: Storage) throws -> [String] {
        try rows(profile, "SELECT content FROM message WHERE fromMe = 1 ORDER BY id").map { $0["content"] }
    }

    @Test func aSendShowsTodaysCardAndGoesOnceWithItsMessageRecorded() async throws {
        try await withActions { actions, cards, storage in
            let ask = try request("s1", .object(["chat": "Kate", "text": "Running late"]), in: storage)
            let answer = try #require(await actions.answer(ask))
            #expect(answer.status == .done && answer.text?.hasPrefix("Sent to 'Kate'") == true)
            #expect(cards.asked.map(\.action) == ["Send to Kate"] && cards.asked.first?.content == "Running late")
            #expect(try sent(storage) == ["Running late"])
            let row = try #require(try storage.deviceRequest("s1", of: "02a"))
            #expect(row.state == .sending && row.sentUUID != nil)
            // The same request again (the engine never does this) cannot send.
            let again = try #require(await actions.answer(ask))
            let count = try sent(storage).count
            #expect(again.status == .failed && count == 1)
        }
    }

    @Test func aDeniedCardSendsNothingAndAClosedOneIsLeftForLater() async throws {
        try await withActions { actions, cards, storage in
            cards.reply = .some(.deny)
            let denied = try await answer(actions, "d1", .object(["chat": "Kate", "text": "no"]), in: storage)
            cards.reply = .some(nil)
            let closed = try await answer(actions, "c1", .object(["chat": "Kate", "text": "later"]), in: storage)
            #expect(denied == .denied() && closed == nil)
            let none = try sent(storage)
            #expect(none.isEmpty)
            #expect(try storage.deviceRequest("c1", of: "02a")?.state == .running)
        }
    }

    @Test func aCardStillUpAtTheRequestsTimeExpires() async throws {
        try await withActions { actions, cards, storage in
            cards.reply = nil
            let start = ContinuousClock.now
            let expired = try await answer(actions, "e1", .object(["chat": "Kate", "text": "late"]), in: storage, for: 1)
            #expect(expired == .expired && ContinuousClock.now - start < .seconds(10))
            let none = try sent(storage)
            #expect(none.isEmpty)
        }
    }

    /// "Always allow for Kate" from a device card is today's rule: the next
    /// send to Kate asks nothing. A tribe's price over the request's most is
    /// refused before any card.
    @Test func todaysRulesAndTheRequestsPriceHold() async throws {
        try await withActions { actions, cards, storage in
            cards.reply = .some(.alwaysAllow)
            _ = try await answer(actions, "a1", .object(["chat": "Kate", "text": "one"]), in: storage)
            _ = try await answer(actions, "a2", .object(["chat": "Kate", "text": "two"]), in: storage)
            let both = try sent(storage)
            #expect(cards.asked.count == 1 && both == ["one", "two"])

            let tribe = try await answer(actions, "t1", .object(["chat": "Bitcoin Devs", "text": "gm", "max_price_sats": 2]), in: storage)
            #expect(tribe?.status == .failed && tribe?.error?.contains("over the most allowed (2 sats)") == true)
            #expect(cards.asked.count == 1)
        }
    }

    /// An automation posts only through its grant, made on an `approve`
    /// card that says what it allows: its chats, `[Agent]` first, no card
    /// per message, and nothing outside it.
    @Test func anAutomationPostsOnlyWithinItsGrant() async throws {
        try await withActions { actions, cards, storage in
            let post: AgentKit.JSONValue = .object(["chat": "Kate", "text": "Monday recap", "automation": "auto-1", "max_price_sats": 5])
            let refused = try await answer(actions, "g0", post, in: storage, for: 600)
            let none = try sent(storage)
            #expect(refused?.status == .denied && refused?.error?.hasPrefix("No send grant") == true)
            #expect(cards.asked.isEmpty && none.isEmpty)

            let approve: AgentKit.JSONValue = .object([
                "intent": .object(["action": "Create the automation \u{201C}Monday recap\u{201D}", "details": .array(["Every Monday at 9:00"])]),
                "grant": .object(["automation": "auto-1", "name": "Monday recap", "chats": .array(["kate"]), "max_price_sats": 3]),
            ])
            let allowed = try await answer(actions, "p1", approve, kind: "approve", in: storage)
            #expect(allowed?.status == .done)
            let card = try #require(cards.asked.last)
            #expect(card.details.first?.contains("post as you to Kate without asking") == true)
            #expect(card.details.last == "Every Monday at 9:00")
            #expect(card.cost == "Up to 3 sats a message, paid from your balance." && !card.mayBeAlwaysAllowed)
            let grants = try SendGrants(beside: actions.rules).all()
            #expect(grants.map(\.chats) == [[ToolIntent.Target(id: keyG, name: "Kate")]] && grants.first?.maxPriceSats == 3)

            let asked = cards.asked.count
            #expect(try await answer(actions, "g1", post, in: storage, for: 600)?.status == .done)
            let posted = try sent(storage)
            #expect(posted == ["[Agent] Monday recap"] && cards.asked.count == asked)
            let elsewhere: AgentKit.JSONValue = .object(["chat": "Bitcoin Devs", "text": "hi", "automation": "auto-1", "max_price_sats": 5])
            let outside = try await answer(actions, "g2", elsewhere, in: storage, for: 600)
            // The tribe's 3 sats are within the cap: the grant's chats refuse it.
            let still = try sent(storage).count
            #expect(outside?.status == .denied && outside?.error?.contains("does not cover Bitcoin Devs") == true && still == 1)

            try SendGrants(beside: actions.rules).revoke(automation: "auto-1")
            #expect(try await answer(actions, "g3", post, in: storage, for: 600)?.status == .denied)
        }
    }

    /// Stored but not published (the connection failed as it went): never
    /// `done`. The row is `sending`, so the engine answers `unknown`.
    @Test func aSendWhosePublishFailedIsNeverAnsweredSent() async throws {
        struct Down: Error {}
        try await withActions(publishing: { _, _ in throw Down() }) { actions, _, storage in
            let answer = try await answer(actions, "f1", .object(["chat": "Kate", "text": "lost?"]), in: storage)
            #expect(answer?.status == .failed && answer?.error?.contains("may or may not have gone") == true)
            #expect(try storage.deviceRequest("f1", of: "02a")?.state == .sending)
        }
    }

    /// A grant's cap holds below the request's; a send far from any run is
    /// no automation's; an approve asked again after it was allowed finds
    /// its grant, and a denied one makes none.
    @Test func aGrantsCapAndItsRequestHold() async throws {
        try await withActions { actions, cards, storage in
            func approve(_ id: String, cap: Int) async throws -> DeviceAnswer? {
                try await answer(actions, id, .object([
                    "intent": .object(["action": "Post the recap"]),
                    "grant": .object(["automation": "auto-2", "chats": .array(["Bitcoin Devs", "Kate"]), "max_price_sats": .number(Double(cap))]),
                ]), kind: "approve", in: storage)
            }
            cards.reply = .some(.deny)
            #expect(try await approve("p0", cap: 2)?.status == .denied)
            #expect(try SendGrants(beside: actions.rules).all().isEmpty)
            cards.reply = .some(.allowOnce)
            #expect(try await approve("p1", cap: 2)?.status == .done)
            let card = try #require(cards.asked.last)
            #expect(card.cost == "Up to 2 sats a message, paid from your balance.")
            let asked = cards.asked.count
            #expect(try await approve("p1", cap: 2)?.status == .done && cards.asked.count == asked)

            let tribe: AgentKit.JSONValue = .object(["chat": "Bitcoin Devs", "text": "recap", "automation": "auto-2", "max_price_sats": 5])
            let over = try await answer(actions, "g1", tribe, in: storage, for: 600)
            #expect(over?.status == .failed && over?.error?.contains("over the most allowed (2 sats)") == true)
            let kate: AgentKit.JSONValue = .object(["chat": "Kate", "text": "recap", "automation": "auto-2"])
            let later = try await answer(actions, "g2", kate, in: storage, for: 3600)
            #expect(later?.status == .denied && later?.error?.contains("expires within 15 minutes") == true)
            #expect(try await answer(actions, "g3", kate, in: storage, for: 600)?.status == .done)
            let posted = try sent(storage)
            #expect(posted == ["[Agent] recap"])
        }
    }

    /// A grant asked with no cap is worth what its chats cost now, so its
    /// card says the price (the dearer tribe's; a contact costs nothing).
    /// One whose automation strut no longer holds goes, unless just made.
    @Test func aGrantWithNoCapTakesItsChatsPriceAndGoesWithItsAutomation() async throws {
        try await withActions { actions, cards, storage async throws in
            func approve(_ id: String, _ chats: [AgentKit.JSONValue], automation: String) async throws -> DeviceAnswer? {
                try await answer(actions, id, .object([
                    "intent": .object(["action": "Create the automation"]),
                    "grant": .object(["automation": .string(automation), "chats": .array(chats)]),
                ]), kind: "approve", in: storage)
            }
            #expect(try await approve("p1", ["Kate", "Bitcoin Devs"], automation: "g-1")?.status == .done)
            #expect(cards.asked.last?.cost == "Up to 3 sats a message, paid from your balance.")
            #expect(try await approve("p2", ["Kate"], automation: "g-2")?.status == .done)
            #expect(cards.asked.last?.cost == "No sats: only chats that cost nothing to post in.")

            // A change to it names the grant it keeps, and keeps nothing new.
            let change: AgentKit.JSONValue = .object(["intent": .object(["action": "Change it"]), "grant": .object(["automation": "g-2"])])
            #expect(try await answer(actions, "p3", change, kind: "approve", in: storage)?.status == .done)
            #expect(cards.asked.last?.details.first == "It already posts as you to Kate without asking; that stays.")
            #expect(cards.asked.last?.cost == nil)

            // One run posts at most `postsPerRun` times, whatever it read.
            for n in 1...DeviceActions.postsPerRun + 1 {
                let post: AgentKit.JSONValue = .object(["chat": "Kate", "text": .string("post \(n)"), "automation": "g-2"])
                let answered = try await answer(actions, "run-9/\(n)", post, in: storage, for: 600)
                #expect(answered?.status == (n <= DeviceActions.postsPerRun ? .done : .denied), "post \(n)")
            }
            #expect(try await answer(actions, "run-10/1", .object(["chat": "Kate", "text": "next run", "automation": "g-2"]),
                                     in: storage, for: 600)?.status == .done, "another run starts again")

            let grants = SendGrants(beside: actions.rules)
            #expect(try grants.revoke(allBut: ["g-1"], keptBefore: Date(timeIntervalSinceNow: -600)) == 0, "just made: kept")
            #expect(try grants.revoke(allBut: ["g-1"], keptBefore: Date(timeIntervalSinceNow: 1)) == 1)
            #expect(try grants.all().map(\.automation) == ["g-1"])
            // A delete card names what goes with it, and once allowed the grant is revoked.
            let delete: AgentKit.JSONValue = .object(["intent": .object(["action": "Delete \u{201C}It\u{201D}"]), "grant": .object(["automation": "g-1"])])
            #expect(try await answer(actions, "p4", delete, kind: "approve", in: storage)?.status == .done)
            #expect(cards.asked.last?.details.first == "It may no longer post as you to Kate and Bitcoin Devs, up to 3 sats a message.")
            #expect(try SendGrants(beside: actions.rules).grant(for: "g-1") == nil)
            // An automation with no grant on file gets a plain card.
            let plain: AgentKit.JSONValue = .object(["intent": .object(["action": "Run it now"]), "grant": .object(["automation": "a-none"])])
            #expect(try await answer(actions, "p5", plain, kind: "approve", in: storage)?.status == .done)
            #expect(cards.asked.last?.details.isEmpty == true)
        }
    }

    @Test func anApproveCardThatCannotBeShownWhollyIsRefused() async throws {
        try await withActions { actions, cards, storage in
            for intent: AgentKit.JSONValue in [.object([:]), .object(["action": "ok\u{202E}evil"]), .object(["action": "x", "details": .array([1])])] {
                let result = try await answer(actions, UUID().uuidString, .object(["intent": intent]), kind: "approve", in: storage)
                #expect(result?.status == .failed)
            }
            #expect(cards.asked.isEmpty)
        }
    }
}
