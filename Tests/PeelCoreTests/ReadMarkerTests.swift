import Foundation
import Testing
@testable import PeelCore

/// Read markers: the server's are the truth unless one set here is still pending.
struct ReadMarkerTests {
    let profile = TempProfile()
    let chat = "02aa"

    private func marker() throws -> (lastRead: Int64?, pending: Int)? {
        try rows(profile, "SELECT lastRead, readPending FROM chatState WHERE chat = '\(chat)'").first
            .map { ($0["lastRead"], $0["readPending"]) }
    }

    @Test func serverMarkerReplacesOursEvenWhenLower() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(reads: [chat: 10]))
        #expect(try marker()! == (10, 0))
        // Marked unread on another device.
        _ = try storage.apply(Storage.Commit(reads: [chat: 4]))
        #expect(try marker()! == (4, 0))
        #expect(try storage.pendingReads().isEmpty)
    }

    @Test func pendingMarkerSurvivesTheServerUntilSent() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(reads: [chat: 10]))
        #expect(try storage.setRead(chat: chat, index: 7, as: .unread))
        _ = try storage.apply(Storage.Commit(reads: [chat: 10]))
        #expect(try marker()! == (7, 2))
        #expect(try storage.pendingReads() == [chat: 7])

        try storage.readSent(chat: chat, index: 7)
        #expect(try storage.pendingReads().isEmpty)
        _ = try storage.apply(Storage.Commit(reads: [chat: 12]))
        #expect(try marker()! == (12, 0))
    }

    @Test func sentClearsPendingOnlyForTheSameMarker() throws {
        let storage = try profile.storage()
        #expect(try storage.setRead(chat: chat, index: 7, as: .unread))
        #expect(try storage.setRead(chat: chat, index: 9, as: .read))
        try storage.readSent(chat: chat, index: 7)
        #expect(try storage.pendingReads() == [chat: 9])
    }

    @Test func readMovesOnlyForwardUnreadEitherWay() throws {
        let storage = try profile.storage()
        #expect(try storage.setRead(chat: chat, index: 10, as: .read))
        #expect(try !storage.setRead(chat: chat, index: 10, as: .unread))
        #expect(try !storage.setRead(chat: chat, index: 5, as: .read))
        #expect(try marker()!.lastRead == 10)
        #expect(try storage.setRead(chat: chat, index: 5, as: .unread))
        #expect(try marker()! == (5, 2))
        #expect(try storage.setRead(chat: chat, index: 6, as: .read))
        #expect(try marker()! == (6, 1))
    }

    @Test func pendingReadGivesWayToAServerMarkerPastIt() throws {
        let storage = try profile.storage()
        // Read to 9 offline; another device read further meanwhile.
        #expect(try storage.setRead(chat: chat, index: 9, as: .read))
        _ = try storage.apply(Storage.Commit(reads: [chat: 15]))
        #expect(try marker()! == (15, 0))
        #expect(try storage.pendingReads().isEmpty)
        // A server marker behind a pending read leaves it to be sent.
        #expect(try storage.setRead(chat: chat, index: 20, as: .read))
        _ = try storage.apply(Storage.Commit(reads: [chat: 15]))
        #expect(try storage.pendingReads() == [chat: 20])
    }

    @Test func sendingReadsTheChatAndDropsPending() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "a", serverIndex: 3, chat: chat), false, nil),
            (.fixture(uuid: "b", serverIndex: 8, chat: chat), false, nil),
        ]))
        #expect(try storage.setRead(chat: chat, index: 2, as: .unread))
        try storage.readBySending(in: chat)
        #expect(try marker()! == (8, 0))
    }

    @Test func newestIncomingIndexSkipsOurs() throws {
        let storage = try profile.storage()
        #expect(try storage.newestIncomingIndex(in: chat) == nil)
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "a", serverIndex: 3, chat: chat), false, nil),
            (.fixture(uuid: "b", serverIndex: 8, chat: chat, fromMe: true), false, nil),
        ]))
        #expect(try storage.newestIncomingIndex(in: chat) == 3)
    }

    @Test func timelineReachesBackToAnAnchor() async throws {
        let storage = try profile.storage()
        let messages = (1...250).map { i in
            (Message.fixture(uuid: "u\(i)", serverIndex: Int64(i), chat: chat, timestamp: Int64(i)), false, String?.none)
        }
        _ = try storage.apply(Storage.Commit(messages: messages))
        let newest = try #require(try await first(storage.timeline(in: chat)))
        #expect(newest.messages.count == 200)
        #expect(newest.messages.first?.uuid == "u51")
        let old = try #require(try storage.message(id: 10))
        let limit = try storage.timelineLimit(reaching: old)
        #expect(limit == 261)
        let anchored = try #require(try await first(storage.timeline(in: chat, limit: limit)))
        #expect(anchored.messages.contains { $0.id == old.id })
        #expect(anchored.messages.last?.uuid == "u250")
    }

    @Test func aWindowStartsJustBeforeAnAnchor() async throws {
        let storage = try profile.storage()
        let messages = (1...500).map { i in
            (Message.fixture(uuid: "u\(i)", serverIndex: Int64(i), chat: chat, timestamp: Int64(i)), false, String?.none)
        }
        _ = try storage.apply(Storage.Commit(messages: messages))
        let old = try #require(try storage.message(uuid: "u100", in: chat))
        let start = try #require(try storage.timelineStart(reaching: old))
        let window = try #require(try await first(storage.timeline(in: chat, from: start, limit: 200)))
        // 50 older, then the anchor and what follows, oldest first.
        #expect(window.messages.map(\.uuid) == (50..<250).map { "u\($0)" })
        // Taking in more below, up to the newest.
        let longer = try #require(try await first(storage.timeline(in: chat, from: start, limit: 600)))
        #expect(longer.messages.first?.uuid == "u50")
        #expect(longer.messages.last?.uuid == "u500")
        #expect(longer.messages.count == 451)

        // Fewer than 50 older: the window starts at the chat's first.
        let early = try #require(try storage.message(uuid: "u10", in: chat))
        let earliest = try #require(try storage.timelineStart(reaching: early))
        let opening = try #require(try await first(storage.timeline(in: chat, from: earliest, limit: 200)))
        #expect(opening.messages.first?.uuid == "u1")
    }

    @Test func unreadCountFollowsAMarkerMovedBack() async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            contacts: [(chat, true)],
            messages: [
                (.fixture(uuid: "a", serverIndex: 3, chat: chat), false, nil),
                (.fixture(uuid: "b", serverIndex: 8, chat: chat), false, nil),
            ],
            reads: [chat: 8]
        ))
        #expect(try await first(storage.readStates())?[chat]?.unread == 0)
        #expect(try storage.setRead(chat: chat, index: 7, as: .unread))
        #expect(try await first(storage.readStates())?[chat]?.unread == 1)
    }
}
