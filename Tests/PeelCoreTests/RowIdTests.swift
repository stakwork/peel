import Foundation
import Testing
@testable import PeelCore

/// A seeded generator, so a failing timeline can be made again from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let tribe = key2G
private let room = "https://chat.sphinx.chat/rooms/sphinx.call.781603422.512"

/// The row ids a chat's list gives its messages, as `ChatRow.rows` (PeelApp)
/// works them out from what `Storage.timeline(in:)` returns: a message that
/// stands for a collapsed thread is one row named by its thread, anything
/// else a row named by its message id. `ChatRow` itself is not reachable
/// from these tests.
private func rowIDs(_ timeline: Timeline) -> [String] {
    timeline.messages.map { message in
        if message.standsForThread, let thread = message.threadUUID, timeline.threads[thread] != nil {
            return "t\(thread)"
        }
        return "m\(message.id ?? 0)"
    }
}

/// A random chat: originals, replies in threads, boosts on them, calls in
/// every form (in threads too), deletes, and messages with no words.
private func generatedChat(seed: UInt64, chat: String, count: Int = 80) -> [Message] {
    var random = SplitMix64(state: seed)
    var messages: [Message] = []
    var originals: [Int] = []
    for n in 1...count {
        let at = Int64(n) * 1_000
        let thread = originals.randomElement(using: &random).flatMap { Bool.random(using: &random) ? $0 : nil }
        var message = Message.fixture(
            uuid: uuid(n), serverIndex: Int64(n), chat: chat, fromMe: Int.random(in: 0..<4, using: &random) == 0,
            sender: sender(chat, alias: ["ann", "bob", "cat"].randomElement(using: &random)), content: "m\(n)",
            timestamp: at, replyUUID: thread.map(uuid), threadUUID: thread.map(uuid)
        )
        switch Int.random(in: 0..<10, using: &random) {
        case 0:
            message.type = MessageType.call
            message.content = #"call::{"link":"\#(room)","recurring":false,"cron":""}"#
        case 1:
            // A bare call link is a text message that the list draws as a call.
            message.content = room
        case 2 where !originals.isEmpty:
            message.type = MessageType.boost
            message.content = ""
            message.replyUUID = uuid(originals.randomElement(using: &random)!)
            message.threadUUID = nil
            message.amountMsat = 21_000
        case 3 where n > 1:
            message.type = MessageType.delete
            message.content = ""
            message.replyUUID = uuid(Int.random(in: 1..<n, using: &random))
            message.threadUUID = nil
        case 4:
            message.content = " \u{200B}"
        case 5:
            // The Mac app's call: a call message whose content is the bare link.
            message.type = MessageType.call
            message.content = room
        default:
            break
        }
        if message.type == MessageType.text, thread == nil { originals.append(n) }
        messages.append(message)
    }
    return messages
}

struct RowIdTests {
    /// Every row of a chat's list has its own id, in a tribe (threads
    /// collapsed) and a direct message alike, over many generated chats.
    @Test(arguments: [false, true])
    func rowIDsAreUniqueInGeneratedChats(inTribe: Bool) async throws {
        let chat = inTribe ? tribe : dm
        for seed in UInt64(1)...40 {
            let profile = TempProfile()
            let storage = try profile.storage()
            if inTribe { try storage.save([Tribe(pubkey: tribe)]) }
            let messages = generatedChat(seed: seed, chat: chat)
            _ = try storage.apply(Storage.Commit(
                contacts: [(dm, true)], messages: messages.map { ($0, false, nil) }
            ))
            let timeline = try #require(try await first(storage.timeline(in: chat)))
            let ids = rowIDs(timeline)
            let repeated = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            #expect(repeated.isEmpty, "seed \(seed): \(repeated)")
            // A thread's own list: its original's two rows, then one per message.
            for thread in timeline.threads.keys {
                let view = try #require(try await first(storage.thread(thread, in: chat)))
                let threadIDs = ["o\(thread)", "r\(thread)"] + view.messages.map { "m\($0.id ?? 0)" }
                #expect(Set(threadIDs).count == threadIDs.count, "seed \(seed), thread \(thread)")
            }
        }
    }

    /// The shape behind a duplicate id: a call posted in a thread of two or
    /// more. The thread collapses to its newest message with words, and the
    /// call, which names the same thread, must not stand for it a second time.
    @Test func aCallInACollapsedThreadIsNotASecondThreadRow() async throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: tribe)])
        var call = Message.fixture(
            uuid: uuid(3), serverIndex: 3, type: MessageType.call, chat: tribe,
            content: #"call::{"link":"\#(room)"}"#, timestamp: 3_000, threadUUID: uuid(1)
        )
        call.replyUUID = uuid(1)
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: uuid(1), serverIndex: 1, chat: tribe, content: "original", timestamp: 1_000), false, nil),
            (.fixture(uuid: uuid(2), serverIndex: 2, chat: tribe, content: "a", timestamp: 2_000, threadUUID: uuid(1)), false, nil),
            (call, false, nil),
            (.fixture(uuid: uuid(4), serverIndex: 4, chat: tribe, content: "b", timestamp: 4_000, threadUUID: uuid(1)), false, nil),
        ]))
        let timeline = try #require(try await first(storage.timeline(in: tribe)))
        #expect(timeline.threads[uuid(1)] != nil)
        let ids = rowIDs(timeline)
        #expect(Set(ids).count == ids.count, "\(ids)")
        // The call keeps its own row; the thread's newest stands for it.
        #expect(timeline.messages.map(\.uuid) == [uuid(3), uuid(4)])
        #expect(ids.last == "t\(uuid(1))")
    }
}
