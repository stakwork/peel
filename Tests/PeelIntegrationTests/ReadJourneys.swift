import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Reads {
        /// Alice on two devices. A chat read on one reads on the other, both
        /// ways, and a mute follows, once the other asks the server again
        /// (as it does on coming to the front): the server pushes neither.
        /// In a tribe, a join after her read leaves nothing Peel counts but
        /// the chat behind the server's marker, where the official apps
        /// count it unread; reading it moves the server's marker past it.
        @Test func markersAndMutesAcrossDevices() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            let carol = try await Person.create("carol")
            for person in [alice, bob, carol] { try await Bank.shared.give(500, to: person) }
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            let second = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) { await !second.engine.isSyncingHistory }
            let bobKey = try bob.pubkey

            // Read on the first device, then on the second.
            for (reader, other) in [(alice, second), (second, alice)] {
                try await Self.send(2, from: bob, to: try alice.pubkey, reaching: [alice, second])
                #expect(try await Self.state(bobKey, other).unread == 2)
                try await reader.engine.markRead(bobKey)
                #expect(try await Self.state(bobKey, reader).isBehind == false)
                try await Task.sleep(for: .seconds(2))
                #expect(try await Self.state(bobKey, other).unread == 2, "the server pushed a read marker")
                try await eventually("the read to reach the other device") {
                    await other.engine.refreshReadsAndMutes()
                    let state = try await Self.state(bobKey, other)
                    return state.unread == 0 && !state.isBehind
                }
            }

            try await alice.engine.setMute(bobKey, level: .muted)
            try await eventually("the mute to reach the second device") {
                await second.engine.refreshReadsAndMutes()
                return try await Self.state(bobKey, second).mute == .muted
            }

            let tribe = try await bob.engine.createTribe(TribeSettings(name: "reads \(UUID().uuidString.prefix(6))"))
            let link = try #require(tribe.link)
            try await alice.engine.joinTribe(link: link)
            try await Tribes.waitUntilIn(tribe.pubkey, alice)
            try await Self.send(1, from: bob, to: tribe.pubkey, reaching: [alice])
            try await alice.engine.markRead(tribe.pubkey)
            #expect(try await Self.state(tribe.pubkey, alice).isBehind == false)
            try await carol.engine.joinTribe(link: link)
            try await eventually("Carol's join to reach Alice") {
                try await Self.state(tribe.pubkey, alice).isBehind
            }
            let behind = try await Self.state(tribe.pubkey, alice)
            #expect(behind.unread == 0 && behind.isBehind)
            try await alice.engine.markRead(tribe.pubkey)
            let marker = try await Self.state(tribe.pubkey, alice).lastRead
            try await eventually("the second device to take the marker past the join") {
                await second.engine.refreshReadsAndMutes()
                return try await Self.state(tribe.pubkey, second).lastRead == marker
            }

            for person in [second, alice, bob, carol] { await person.close() }
        }

        static func send(_ count: Int, from sender: Person, to chat: String, reaching readers: [Person]) async throws {
            for n in 1...count {
                let text = "line \(n) \(UUID().uuidString.prefix(6))"
                try await sender.engine.sendText(text, to: chat)
                for reader in readers {
                    let key = try reader.pubkey == chat ? try sender.pubkey : chat
                    try await eventually("\(reader.name) to get \"\(text)\"") {
                        try reader.messages(in: key).contains { $0.content == text }
                    }
                }
            }
        }

        static func state(_ chat: String, _ person: Person) async throws -> ChatReadState {
            for try await states in person.storage.readStates() {
                return states[chat] ?? ChatReadState(chat: chat, unread: 0, mentions: 0, muteLevel: 0)
            }
            throw StackError("no read states")
        }
    }
}
