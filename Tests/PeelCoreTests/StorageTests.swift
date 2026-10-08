import Foundation
import GRDB
import Testing
@testable import PeelCore

/// A fresh profile directory per test, removed afterwards.
final class TempProfile {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeelCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func storage(readOnly: Bool = false) throws -> Storage {
        try Storage(directory: url, readOnly: readOnly)
    }

    /// The database file, opened directly, bypassing Storage.
    func queue() throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try DatabaseQueue(path: url.appendingPathComponent("peel.sqlite").path)
    }
}

/// Reads rows straight from the database file, bypassing Storage.
func rows(_ profile: TempProfile, _ sql: String) throws -> [Row] {
    try profile.queue().read { try Row.fetchAll($0, sql: sql) }
}

func first<S: AsyncSequence>(_ sequence: S) async throws -> S.Element? {
    var iterator = sequence.makeAsyncIterator()
    return try await iterator.next()
}

struct StorageTests {
    let profile = TempProfile()

    // MARK: State and settings

    @Test func commitWritesStateAndSettings() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            state: ["a": Data([1]), "b": Data([2])],
            settings: [.alias: "Ann", .network: "regtest"]
        ))
        #expect(try storage.loadCoreState() == ["a": Data([1]), "b": Data([2])])
        #expect(try storage.value(for: .alias) == "Ann")
        #expect(try storage.value(for: .network) == "regtest")

        _ = try storage.apply(Storage.Commit(state: ["a": Data([3])], deleteState: ["b"]))
        #expect(try storage.loadCoreState() == ["a": Data([3])])
    }

    @Test func commitIsOneTransaction() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(state: ["a": Data([1])]))
        // Make one message insert fail; the state and setting written earlier in
        // the same commit must roll back with it.
        let queue = try profile.queue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail BEFORE INSERT ON message WHEN NEW.content = 'boom'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        #expect(throws: (any Error).self) {
            try storage.apply(Storage.Commit(
                state: ["a": Data([2])],
                settings: [.alias: "Bob"],
                messages: [(.fixture(content: "boom"), false, nil)]
            ))
        }
        #expect(try storage.loadCoreState() == ["a": Data([1])])
        #expect(try storage.value(for: .alias) == nil)
    }

    @Test func settingsPersistAcrossReopen() throws {
        do {
            let storage = try profile.storage()
            try storage.set("mqtts://broker.example.com:8883", for: .server)
        }
        let reopened = try profile.storage()
        #expect(try reopened.value(for: .server) == "mqtts://broker.example.com:8883")
    }

    // MARK: Messages

    @Test func upsertDedupesOnUUIDAndFillsServerFields() throws {
        let storage = try profile.storage()
        let first = Message.fixture(
            uuid: "u1", fromMe: true, body: #"{"content":"original"}"#, content: "original",
            timestamp: 1_000, tag: "tag-1", status: "PENDING"
        )
        let echo = Message.fixture(
            uuid: "u1", serverIndex: 42, fromMe: true, body: #"{"content":"changed"}"#, content: "changed",
            msat: 3_000, timestamp: 2_000, tag: "tag-2", paymentHash: "hash"
        )
        let stored = try storage.apply(Storage.Commit(messages: [(first, false, nil)]))
        #expect(stored.count == 1)
        let updated = try #require(try storage.apply(Storage.Commit(messages: [(echo, false, nil)])).first)

        #expect(updated.id == stored.first?.id)
        #expect(updated.serverIndex == 42)
        #expect(updated.timestamp == 2_000)
        #expect(updated.msat == 3_000)
        #expect(updated.paymentHash == "hash")
        // What the message says, and our own tag, come from the first copy.
        #expect(updated.content == "original")
        #expect(updated.body == #"{"content":"original"}"#)
        #expect(updated.tag == "tag-1")
        #expect(updated.status == "PENDING")
        #expect(try rows(profile, "SELECT * FROM message").count == 1)
        #expect(try storage.highestServerIndex() == 42)
    }

    @Test func laterCopyFillsMissingBodyFields() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: [(.fixture(uuid: "u1", content: nil), false, nil)]))
        let row = try #require(try storage.apply(Storage.Commit(messages: [(.fixture(uuid: "u1", content: "late"), false, nil)])).first)
        #expect(row.content == "late")
    }

    @Test func uuidFromAnotherChatIsRejected() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: [(.fixture(uuid: "u1", chat: "02aa", content: "mine"), false, nil)]))
        let stored = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u1", serverIndex: 9, chat: "02bb", content: "hijack"), false, nil),
            (.fixture(uuid: "u2", chat: "02bb", content: "fine"), false, nil),
        ]))
        #expect(stored.map(\.uuid) == ["u2"])
        let original = try rows(profile, "SELECT chat, content, serverIndex FROM message WHERE uuid = 'u1'")
        #expect(original.count == 1)
        #expect(original[0]["chat"] == "02aa")
        #expect(original[0]["content"] == "mine")
        #expect((original[0]["serverIndex"] as Int64?) == nil)
    }

    @Test func uuidReusedWithOtherDirectionIsRejected() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: [(.fixture(uuid: "u1", fromMe: true), false, nil)]))
        let stored = try storage.apply(Storage.Commit(messages: [(.fixture(uuid: "u1", fromMe: false, content: "x"), false, nil)]))
        #expect(stored.isEmpty)
    }

    @Test func statusUpdatesByTag() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u1", fromMe: true, tag: "t1", status: "PENDING"), false, nil),
            (.fixture(uuid: "u2", fromMe: true, tag: "t2", status: "PENDING"), false, nil),
        ]))
        _ = try storage.apply(Storage.Commit(statuses: [(tag: "t1", status: "COMPLETE"), (tag: "unknown", status: "FAILED")]))
        let statuses = try rows(profile, "SELECT uuid, status FROM message ORDER BY uuid")
            .map { ($0["uuid"] as String, $0["status"] as String) }
        #expect(statuses.map(\.0) == ["u1", "u2"])
        #expect(statuses.map(\.1) == ["COMPLETE", "PENDING"])
    }

    // MARK: Contacts

    private func contact(_ pubkey: String) throws -> Row? {
        try rows(profile, "SELECT * FROM contact WHERE pubkey = '\(pubkey)'").first
    }

    @Test func trustedSenderFillsContact() throws {
        let storage = try profile.storage()
        let message = Message.fixture(uuid: "u1", chat: "02aa", sender: sender("02aa", alias: "Ann", photo: "https://img/a.png"))
        _ = try storage.apply(Storage.Commit(messages: [(message, true, nil)]))
        let row = try #require(try contact("02aa"))
        #expect(row["alias"] == "Ann")
        #expect(row["photoURL"] == "https://img/a.png")
    }

    @Test func untrustedSenderIsIgnored() throws {
        let storage = try profile.storage()
        let message = Message.fixture(uuid: "u1", chat: "02aa", sender: sender("02aa", alias: "Ann", photo: nil))
        _ = try storage.apply(Storage.Commit(messages: [(message, false, nil)]))
        #expect(try contact("02aa") == nil)
    }

    @Test(arguments: ["http://img/a.png", "javascript:alert(1)", "file:///etc/passwd", "not a url"])
    func nonHTTPSPhotoIsDropped(photo: String) throws {
        let storage = try profile.storage()
        let message = Message.fixture(uuid: "u1", chat: "02aa", sender: sender("02aa", alias: "Ann", photo: photo))
        _ = try storage.apply(Storage.Commit(messages: [(message, true, nil)]))
        let row = try #require(try contact("02aa"))
        #expect(row["alias"] == "Ann")
        #expect((row["photoURL"] as String?) == nil)
    }

    @Test func emptyOrMissingFieldsKeepWhatIsKnown() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u1", chat: "02aa", sender: sender("02aa", alias: "Ann", photo: "https://img/a.png")), true, nil),
        ]))
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u2", chat: "02aa", sender: sender("02aa", alias: "", photo: "http://img/b.png")), true, nil),
        ]))
        try storage.upsertContact(pubkey: "02aa", alias: nil)
        let row = try #require(try contact("02aa"))
        #expect(row["alias"] == "Ann")
        #expect(row["photoURL"] == "https://img/a.png")

        try storage.upsertContact(pubkey: "02aa", alias: "Annie")
        #expect(try contact("02aa")?["alias"] == "Annie")
    }

    /// A payment or boost may go without the photo; a restore looks past it.
    @Test func ourPhotoIsNotTakenFromAPayment() throws {
        let storage = try profile.storage()
        let me = sender("02bb", alias: "Me", photo: "https://img/me.png")
        let noPhoto = sender("02bb", alias: "Me", photo: "")
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u1", serverIndex: 1, chat: "02aa", fromMe: true, sender: me), false, nil),
            (.fixture(uuid: "u2", serverIndex: 2, type: MessageType.boost, chat: "02aa", fromMe: true, sender: noPhoto), false, nil),
            (.fixture(uuid: "u3", serverIndex: 3, type: MessageType.directPayment, chat: "02aa", fromMe: true, sender: noPhoto),
             false, nil),
        ]))
        #expect(try storage.newestOwnPhotoURL() == "https://img/me.png")
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u4", serverIndex: 4, chat: "02aa", fromMe: true, sender: noPhoto), false, nil),
        ]))
        #expect(try storage.newestOwnPhotoURL() == nil)
    }

    @Test func contactReadinessUpdatesWithoutTouchingAlias() throws {
        let storage = try profile.storage()
        try storage.upsertContact(pubkey: "02aa", alias: "Ann")
        _ = try storage.apply(Storage.Commit(contacts: [(pubkey: "02aa", ready: true), (pubkey: "02bb", ready: false)]))
        let aa = try #require(try contact("02aa"))
        #expect(aa["alias"] == "Ann")
        #expect(aa["ready"] == true)
        #expect(try contact("02bb")?["ready"] == false)
    }

    // MARK: Live queries

    @Test func conversationsOrderAndReadiness() async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            contacts: [
                (pubkey: "02old", ready: true),
                (pubkey: "02new", ready: true),
                (pubkey: "02quiet", ready: true),
                (pubkey: "02pending", ready: false),
            ],
            messages: [
                (.fixture(uuid: "u1", chat: "02old", content: "old", timestamp: 1_000), false, nil),
                (.fixture(uuid: "u2", chat: "02new", fromMe: true, content: "older", timestamp: 1_500), false, nil),
                (.fixture(uuid: "u3", chat: "02new", fromMe: true, content: "newest", timestamp: 3_000), false, nil),
                // Not text: never the preview.
                (.fixture(uuid: "u4", type: MessageType.contactKeyRecord, chat: "02old", content: "record", timestamp: 9_000), false, nil),
                (.fixture(uuid: "u5", chat: "02pending", content: "hidden", timestamp: 5_000), false, nil),
            ]
        ))
        try storage.upsertContact(pubkey: "02new", alias: "Nina")

        let conversations = try #require(try await first(storage.conversations()))
        #expect(conversations.map(\.chat) == ["02new", "02old", "02quiet"])
        #expect(conversations[0].name == "Nina")
        #expect(conversations[0].lastContent == "newest")
        #expect(conversations[0].lastFromMe == true)
        #expect(conversations[0].lastDate == Date(millisecondsSince1970: 3_000))
        #expect(conversations[1].lastContent == "old")
        #expect(conversations[1].name == "02old")
        #expect(conversations[2].lastContent == nil)
    }

    @Test func timelineFirstEmission() async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u2", chat: "02aa", content: "second", timestamp: 2_000), false, nil),
            (.fixture(uuid: "u1", chat: "02aa", content: "first", timestamp: 1_000), false, nil),
            (.fixture(uuid: "u3", chat: "02bb", content: "other chat", timestamp: 1_500), false, nil),
            (.fixture(uuid: "u4", type: MessageType.contactKeyRecord, chat: "02aa", content: "record", timestamp: 1_200), false, nil),
        ]))
        let messages = try #require(try await first(storage.timeline(in: "02aa"))).messages
        #expect(messages.map(\.content) == ["first", "second"])
    }

    @Test func timelineKeepsTheNewestTwoHundred() async throws {
        let storage = try profile.storage()
        let batch = (0..<250).map { index in
            (Message.fixture(uuid: "u\(index)", chat: "02aa", content: "m\(index)", timestamp: Int64(index)), false, String?.none)
        }
        _ = try storage.apply(Storage.Commit(messages: batch))
        let messages = try #require(try await first(storage.timeline(in: "02aa"))).messages
        #expect(messages.count == 200)
        #expect(messages.first?.content == "m50")
        #expect(messages.last?.content == "m249")
    }

    // MARK: Profile lock

    @Test func secondWritableStorageIsRejected() throws {
        let storage = try profile.storage()
        #expect(throws: PeelError.self) { try profile.storage() }
        // A read-only Storage does not take the lock.
        _ = try profile.storage(readOnly: true)
        withExtendedLifetime(storage) {}
    }

    @Test func lockIsReleasedWhenStorageGoesAway() throws {
        do { _ = try profile.storage() }
        _ = try profile.storage()
    }
}
