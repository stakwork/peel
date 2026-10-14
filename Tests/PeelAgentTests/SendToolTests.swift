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
            try await body(SphinxTools(storage: storage).send(through: engine), engine, storage)
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
