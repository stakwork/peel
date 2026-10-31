import Foundation
import PeelPush
import Testing
@testable import PeelCore

/// Which names a push can show: the core's contacts by child index (`my_idx`),
/// named from the stored chats.
struct PushNamesTests {
    private func contact(_ pubkey: String, index: UInt64) throws -> Engine.Contact {
        try JSONDecoder().decode(
            Engine.Contact.self, from: Data("{\"pubkey\":\"\(pubkey)\",\"my_idx\":\(index)}".utf8))
    }

    private func chat(_ key: String, _ alias: String?, tribe: Bool) -> Conversation {
        Conversation(chat: key, alias: alias, photoURL: nil, isTribe: tribe, lastContent: nil, lastTimestamp: nil, lastFromMe: nil)
    }

    @Test func contactsAndTribesAreNamedByTheirChildIndex() throws {
        let entries = PushNames.entries(
            contacts: [try contact("k1", index: 1), try contact("k2", index: 2)],
            chats: [chat("k1", "Bob", tribe: false), chat("k2", "Peelers", tribe: true)])
        #expect(entries == [
            PushNameEntry(kind: .contact, index: 1, name: "Bob"),
            PushNameEntry(kind: .tribe, index: 2, name: "Peelers"),
        ])
    }

    @Test func aKeyWithNoChatOrNoNameIsLeftOut() throws {
        let entries = PushNames.entries(
            contacts: [try contact("k1", index: 1), try contact("k2", index: 2), try contact("k3", index: 3)],
            chats: [chat("k1", nil, tribe: false), chat("k2", "  ", tribe: false), chat("other", "Eve", tribe: false)])
        #expect(entries.isEmpty)
    }

    @Test func aChatTheCoreDoesNotKnowGetsNoEntry() throws {
        #expect(PushNames.entries(contacts: [], chats: [chat("k1", "Bob", tribe: false)]).isEmpty)
    }

    @Test func theSignatureIgnoresMessagesAndFollowsNames() {
        var bob = chat("k1", "Bob", tribe: false)
        let before = PushNames.signature([bob])
        bob.lastContent = "hello"
        bob.lastTimestamp = 5
        #expect(PushNames.signature([bob]) == before)
        bob.alias = "Robert"
        #expect(PushNames.signature([bob]) != before)
        #expect(PushNames.signature([chat("k1", "Bob", tribe: true)]) != before)
        #expect(PushNames.signature([]) != before)
    }
}
