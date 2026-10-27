import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// A call server on this machine that never answers: each watch's feed says
/// `.unknown` once and nothing more, so a test says who is on.
private let server = "127.0.0.1:9"

/// What the sidebar and the cards know of calls, on a real engine and profile.
@MainActor
struct CallStoreTests {
    let profile = TempProfile()

    private func link(_ n: Int) throws -> CallLink {
        try #require(CallLink(link: "http://\(server)/rooms/sphinx.call.\(n)", server: server))
    }

    private func attached() throws -> (CallStore, Engine, Storage) {
        let storage = try profile.storage()
        try storage.set(server, for: .callServer)
        let engine = try testEngine(storage)
        let calls = CallStore(provider: NoCalls())
        calls.attach(engine, server: server)
        return (calls, engine, storage)
    }

    /// Starts a watch and waits for its feed's first word, so nothing the
    /// feed says later overwrites the presence a test sets.
    private func watch(_ link: CallLink, in chat: String, on calls: CallStore) async throws -> Task<Void, Never> {
        calls.presence[link.room] = .ended
        let task = Task { await calls.watch(link, in: chat) }
        try await until { calls.presence[link.room] == .unknown }
        return task
    }

    @Test func eachChatShowsItsBusiestWatchedCall() async throws {
        let (calls, engine, _) = try attached()
        let small = try link(1), big = try link(2)
        let quiet = try await watch(small, in: "02aa", on: calls)
        let bigHere = try await watch(big, in: "02aa", on: calls)
        // The same call posted in another chat lights that chat too.
        let bigThere = try await watch(big, in: "02bb", on: calls)

        calls.presence[small.room] = .live(people(2))
        calls.presence[big.room] = .live(people(3))
        #expect(calls.liveCounts == ["02aa": 3, "02bb": 3])
        #expect(calls.liveCount(in: "02aa") == 3)

        calls.presence[big.room] = .ended
        #expect(calls.liveCounts == ["02aa": 2])
        #expect(calls.liveCount(in: "02bb") == 0)

        // A watch stopped (its card scrolled away) takes its count with it.
        quiet.cancel()
        try await until { calls.presence[small.room] == nil }
        #expect(calls.liveCounts.isEmpty)
        bigHere.cancel()
        bigThere.cancel()
        await engine.close()
    }

    @Test func theCallYouAreOnCountsInItsChatUntilItDrops() throws {
        let (calls, _, _) = try attached()
        let room = try link(1)
        let call = OnCall(link: room, chat: "02aa", people: people(4))
        calls.call = call
        #expect(calls.isOnCall(room.room))
        #expect(!calls.isOnCall(try link(2).room))
        // No watch of its own, and more than any watched call there.
        #expect(calls.liveCount(in: "02aa") == 4)
        #expect(calls.liveCount(in: "02bb") == 0)
        #expect(calls.otherCall(than: try link(2).room) == "#tribe")
        #expect(calls.otherCall(than: room.room) == nil)

        call.isOn = false
        #expect(!calls.isOnCall(room.room))
        #expect(calls.liveCount(in: "02aa") == 0)
        #expect(calls.otherCall(than: nil) == nil)
    }

    @Test func lockingStopsTheRecentCallsWatchesAndUnlockingStartsThemAgain() async throws {
        let (calls, engine, storage) = try attached()
        let room = try link(1).room
        _ = try storage.apply(Storage.Commit(
            contacts: [(pubkey: "02dm", ready: true)],
            messages: [(.fixture(
                uuid: "call", type: MessageType.call, chat: "02dm", content: "http://\(server)/rooms/\(room)",
                timestamp: Date.now.addingTimeInterval(-60).millisecondsSince1970
            ), false, nil)]
        ))
        calls.watchesRecent = true
        let observing = Task { try? await calls.observeRecent(storage) }
        try await until { calls.presence[room] == .unknown }

        calls.watchesRecent = false
        try await until { calls.presence[room] == nil }

        calls.watchesRecent = true
        try await until { calls.presence[room] == .unknown }
        observing.cancel()
        await engine.close()
    }
}

private func people(_ count: Int) -> [CallParticipant] {
    (1...count).map { CallParticipant(identity: "person-\($0)", nickname: "Person \($0)", avatarURL: nil) }
}

/// Waits for `condition`, up to two seconds.
@MainActor
private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
}

/// Joins nothing: these tests never join.
private struct NoCalls: CallProvider {
    func join(_ ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) throws -> any OngoingCall {
        throw PeelError("no calls here")
    }
}

/// A call this device is on, as the platform would report it.
@MainActor
private final class OnCall: OngoingCall {
    let link: CallLink
    let chat: String
    let title = "#tribe"
    let identity = "me"
    var isOn = true
    var isRecording = false
    let wantsCamera = false
    let people: [CallParticipant]

    init(link: CallLink, chat: String, people: [CallParticipant]) {
        self.link = link
        self.chat = chat
        self.people = people
    }

    func leave() async {}
}
