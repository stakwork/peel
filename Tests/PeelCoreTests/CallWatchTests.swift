import Foundation
import Testing
@testable import PeelCore

private let server = "chat.sphinx.chat"
private let base = "https://chat.sphinx.chat/rooms/"

/// Which recent calls the app keeps presence for, across chats.
struct CallWatchTests {
    let profile = TempProfile()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(
        _ n: Int, chat: String, age: TimeInterval = 60, type: Int = MessageType.call,
        link: String? = nil, fromMe: Bool = false, status: String? = nil
    ) -> Message {
        .fixture(
            uuid: "call-\(n)", type: type, chat: chat, fromMe: fromMe, content: link ?? "\(base)sphinx.call.\(n)",
            timestamp: Int64((now.timeIntervalSince1970 - age) * 1000), status: status
        )
    }

    @Test func watchesTheNewestValidCallInEachChatNewestFirst() {
        let messages = [
            call(1, chat: "02aa", age: 600),
            call(2, chat: "02aa", age: 60),
            call(3, chat: "02bb", age: 300),
            // Text that is only a call link is a call, as the Mac app reads it.
            call(4, chat: "02cc", age: 120, type: MessageType.text),
            // Another host's newer link does not hide the chat's real call.
            call(5, chat: "02bb", age: 10, link: "https://evil.example/rooms/sphinx.call.5"),
            call(6, chat: "02dd", age: 30, link: "https://jitsi.sphinx.chat/sphinx.call.6"),
        ]
        let newestFirst = messages.sorted { $0.date > $1.date }
        let watched = WatchedCall.watched(in: newestFirst, server: server, now: now)
        #expect(watched.map(\.chat) == ["02aa", "02cc", "02bb"])
        #expect(watched.map(\.link.room) == ["sphinx.call.2", "sphinx.call.4", "sphinx.call.3"])
    }

    @Test func skipsCallsNeverSentDeletedAndNoServer() {
        var deleted = call(2, chat: "02bb")
        deleted.deleted = true
        let messages = [
            call(1, chat: "02aa", fromMe: true, status: Message.Delivery.failed.rawValue),
            deleted,
            call(3, chat: "02cc", fromMe: true),
        ]
        #expect(WatchedCall.watched(in: messages, server: server, now: now).map(\.chat) == ["02cc"])
        #expect(WatchedCall.watched(in: messages, server: nil, now: now).isEmpty)
    }

    @Test func atMostTheNewestEight() {
        let messages = (1...12).map { call($0, chat: "02\($0)", age: TimeInterval($0) * 60) }
        let watched = WatchedCall.watched(in: messages, server: server, now: now)
        #expect(watched.count == WatchedCall.limit)
        #expect(watched.map(\.chat) == (1...8).map { "02\($0)" })
    }

    @Test func callsAgeOutAfterTwelveHours() throws {
        let fresh = call(1, chat: "02aa", age: 60)
        let old = call(2, chat: "02bb", age: CallLink.liveAge - 60)
        let future = call(3, chat: "02cc", age: -CallLink.clockSkew - 60)
        let watched = WatchedCall.watched(in: [future, fresh, old], server: server, now: now)
        #expect(watched.map(\.chat) == ["02aa", "02bb"])
        // The app wakes for the soonest to age out, or for a call dated
        // ahead to become recent.
        let soonest = try #require(WatchedCall.nextChange(of: watched, in: [future, fresh, old], now: now))
        #expect(soonest == now.addingTimeInterval(60))
        let ahead = try #require(WatchedCall.nextChange(of: [], in: [future], now: now))
        #expect(ahead == now.addingTimeInterval(60))
        #expect(WatchedCall.watched(in: [future], server: server, now: ahead).map(\.chat) == ["02cc"])
        #expect(WatchedCall.nextChange(of: [], in: [fresh], now: now) == nil)
        #expect(WatchedCall.watched(in: [fresh, old], server: server, now: soonest).map(\.chat) == ["02aa"])
        let later = now.addingTimeInterval(CallLink.liveAge)
        #expect(WatchedCall.watched(in: [fresh, old], server: server, now: later).isEmpty)
    }

    @Test func storageListsRecentCallsInShownChatsOnly() async throws {
        let storage = try profile.storage()
        let recent = Date.now.addingTimeInterval(-60).millisecondsSince1970
        let old = Date.now.addingTimeInterval(-CallLink.liveAge - 60).millisecondsSince1970
        func message(_ n: Int, chat: String, type: Int = MessageType.call, content: String? = nil, at: Int64) -> Message {
            .fixture(uuid: "u\(n)", type: type, chat: chat, content: content ?? "\(base)sphinx.call.\(n)", timestamp: at)
        }
        _ = try storage.apply(Storage.Commit(
            contacts: [(pubkey: "02dm", ready: true), (pubkey: "02pending", ready: false)],
            messages: [
                (message(1, chat: "02dm", at: recent), false, nil),
                (message(2, chat: key2G, type: MessageType.text, at: recent + 1), false, nil),
                (message(3, chat: "02dm", type: MessageType.text, content: "hello", at: recent + 2), false, nil),
                (message(4, chat: "02dm", at: old), false, nil),
                (message(5, chat: "02pending", at: recent), false, nil),
                (message(6, chat: key3G, at: recent), false, nil),
            ],
            tribes: [Tribe(pubkey: key2G), Tribe(pubkey: key3G, left: true)]
        ))
        let messages = try #require(try await first(storage.recentCallMessages()))
        // Newest first; no plain text, nothing past twelve hours, no unready
        // contact, no tribe that was left.
        #expect(messages.map(\.uuid) == ["u2", "u1"])
        #expect(WatchedCall.watched(in: messages, server: server).map(\.chat) == [key2G, "02dm"])

        // Another account's profile watches none of these.
        let other = TempProfile()
        #expect(try #require(try await first(other.storage().recentCallMessages())).isEmpty)
    }

    @Test func anotherAccountsServerWatchesNoneOfTheseCalls() {
        let messages = [call(1, chat: "02aa"), call(2, chat: "02bb")]
        #expect(WatchedCall.watched(in: messages, server: server, now: now).count == 2)
        #expect(WatchedCall.watched(in: messages, server: "calls.example.com", now: now).isEmpty)
    }

    @Test func aClosedAccountEndsItsWatchesAndStartsNoMore() async throws {
        let storage = try profile.storage()
        try storage.set("127.0.0.1:9", for: .callServer)
        let engine = try testEngine(storage)
        let link = try #require(CallLink(link: "http://127.0.0.1:9/rooms/sphinx.call.1", server: "127.0.0.1:9"))
        var watch = try await engine.callPresence(of: link).makeAsyncIterator()
        #expect(await watch.next() == .unknown)
        await engine.close()
        // The stream ends: the watch's task returns, whatever it was waiting for.
        while let presence = await watch.next() { #expect(presence == .unknown) }
        await #expect(throws: Engine.Failure.accountClosed) { try await engine.callPresence(of: link) }
    }
}
