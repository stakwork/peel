import Foundation
import GRDB
import Testing
@testable import PeelCore

private let tribe = "02tribe"

struct ThreadTests {
    let profile = TempProfile()

    /// A text message in `chat`; `reply` and `thread` are uuid numbers.
    private func text(
        _ n: Int, chat: String = tribe, fromMe: Bool = false, reply: Int? = nil, thread: Int? = nil,
        index: Int64? = nil, at timestamp: Int64? = nil
    ) -> (Message, Bool, String?) {
        let message = Message.fixture(
            uuid: uuid(n), serverIndex: index, chat: chat, fromMe: fromMe, content: "m\(n)",
            timestamp: timestamp ?? Int64(n) * 1_000, replyUUID: reply.map(uuid), threadUUID: thread.map(uuid)
        )
        return (message, false, nil)
    }

    private func storage(tribes: [String] = [tribe], _ messages: [(Message, Bool, String?)]) throws -> Storage {
        let storage = try profile.storage()
        try storage.save(tribes.map { Tribe(pubkey: $0) })
        _ = try storage.apply(Storage.Commit(messages: messages))
        return storage
    }

    @Test func uuidsMustBeWhatTheCorePacks() {
        #expect(MessageUUID.isValid(uuid(1)))
        #expect(!MessageUUID.isValid(String(uuid(1).dropLast())))
        #expect(!MessageUUID.isValid(uuid(1).uppercased().replacingOccurrences(of: "0", with: "A")))
        #expect(!MessageUUID.isValid(String(repeating: "g", count: 64)))
        #expect(!MessageUUID.isValid(""))
    }

    @Test func bodyFieldsReadTheMacKeys() {
        let fields = BodyFields.decode(#"{"content":"hi","replyUuid":"r","threadUuid":"t"}"#)
        #expect(fields?.replyUuid == "r")
        #expect(fields?.threadUuid == "t")
    }

    @Test func linksAreKeptFromTheFirstCopy() throws {
        let storage = try storage([text(2, reply: 1, thread: 1)])
        var echo = text(2, index: 7).0
        echo.replyUUID = uuid(9)
        let row = try #require(try storage.apply(Storage.Commit(messages: [(echo, false, nil)])).first)
        #expect(row.serverIndex == 7)
        #expect(row.replyUUID == uuid(1))
        #expect(row.threadUUID == uuid(1))
    }

    @Test func migrationLinksMessagesStoredBefore() throws {
        do { _ = try profile.storage() }
        let queue = try DatabaseQueue(path: profile.url.appendingPathComponent("peel.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
                DROP INDEX message_reply;
                DROP INDEX message_thread;
                ALTER TABLE message DROP COLUMN replyUUID;
                ALTER TABLE message DROP COLUMN threadUUID;
                DELETE FROM grdb_migrations WHERE identifier = 'v8';
                INSERT INTO message (uuid, type, chat, fromMe, body) VALUES
                    ('a', 0, '02aa', 0, '{"content":"x","replyUuid":"r1","threadUuid":"t1"}'),
                    ('b', 0, '02aa', 0, '{"content":"plain"}'),
                    ('c', 0, '02aa', 0, 'not json replyUuid');
                """)
        }
        let storage = try profile.storage()
        let a = try #require(try storage.message(uuid: "a", in: dm))
        #expect(a.replyUUID == "r1")
        #expect(a.threadUUID == "t1")
        #expect(try storage.message(uuid: "b", in: dm)?.replyUUID == nil)
        #expect(try storage.message(uuid: "c", in: dm)?.threadUUID == nil)
    }

    @Test func parentIsFoundOutsideTheNewestTwoHundredAndOnlyInItsChat() async throws {
        var messages = [text(1, chat: dm, at: 0), text(2, chat: "02bb", at: 0)]
        messages += (10..<260).map { text($0, chat: dm) }
        messages.append(text(300, chat: dm, reply: 1))
        messages.append(text(301, chat: dm, reply: 2))
        let storage = try storage(tribes: [], messages)
        let timeline = try #require(try await first(storage.timeline(in: dm)))
        #expect(timeline.messages.count == 200)
        #expect(timeline.parents[uuid(1)]?.content == "m1")
        #expect(timeline.parents[uuid(2)] == nil)
        #expect(try storage.message(uuid: uuid(1), in: dm)?.content == "m1")
        #expect(try storage.message(uuid: uuid(2), in: dm) == nil)
    }

    @Test func directMessagesShowEveryReply() async throws {
        let storage = try storage(tribes: [], [
            text(1, chat: dm), text(2, chat: dm, reply: 1, thread: 1), text(3, chat: dm, reply: 2, thread: 1),
        ])
        let timeline = try #require(try await first(storage.timeline(in: dm)))
        #expect(timeline.messages.map(\.content) == ["m1", "m2", "m3"])
        #expect(timeline.threads.isEmpty)
    }

    @Test func tribeShowsALoneReplyInline() async throws {
        let storage = try storage([text(1), text(2, reply: 1, thread: 1), text(3)])
        let timeline = try #require(try await first(storage.timeline(in: tribe)))
        #expect(timeline.messages.map(\.content) == ["m1", "m2", "m3"])
        #expect(timeline.parents[uuid(1)]?.content == "m1")
        #expect(timeline.threads.isEmpty)
    }

    @Test func tribeCollapsesAThreadOfTwoOrMore() async throws {
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: tribe)])
        _ = try storage.apply(Storage.Commit(
            messages: [
                text(1, index: 1), text(2, reply: 1, thread: 1, index: 2), text(3, index: 3),
                text(4, thread: 1, index: 4), text(5, fromMe: true, reply: 2, thread: 1, index: 5), text(6, index: 6),
            ],
            reads: [tribe: 2]
        ))
        let timeline = try #require(try await first(storage.timeline(in: tribe)))
        // The original and the older thread messages give way to the newest.
        #expect(timeline.messages.map(\.content) == ["m3", "m5", "m6"])
        let thread = try #require(timeline.threads[uuid(1)])
        #expect(thread.original.content == "m1")
        #expect(thread.count == 3)
        #expect(thread.lastTimestamp == 5_000)
        // m4 is past the read marker; m5 is ours.
        #expect(thread.unread == 1)
        #expect(timeline.parents[uuid(2)]?.content == "m2")
    }

    @Test func threadWithoutItsOriginalIsNotCollapsed() async throws {
        let storage = try storage([text(2, thread: 1), text(3, thread: 1)])
        let timeline = try #require(try await first(storage.timeline(in: tribe)))
        #expect(timeline.messages.map(\.content) == ["m2", "m3"])
        #expect(timeline.threads.isEmpty)
    }

    @Test func threadViewHasItsOriginalAndMessagesInOrder() async throws {
        let storage = try storage([
            text(1), text(4, thread: 1, at: 4_000), text(2, reply: 1, thread: 1, at: 2_000), text(3),
            text(5, thread: 9), text(6, chat: "02other", thread: 1),
        ])
        let thread = try #require(try await first(storage.thread(uuid(1), in: tribe)))
        #expect(thread.original?.content == "m1")
        #expect(thread.messages.map(\.content) == ["m2", "m4"])
        #expect(thread.parents[uuid(1)]?.content == "m1")

        let missing = try #require(try await first(storage.thread(uuid(9), in: tribe)))
        #expect(missing.original == nil)
        #expect(missing.messages.map(\.content) == ["m5"])
    }

    @Test func threadsListIsMineInJoinedTribesNewestFirst() async throws {
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: tribe), Tribe(pubkey: "02left", left: true)])
        _ = try storage.apply(Storage.Commit(messages: [
            // Started by me, replies from others.
            text(1, fromMe: true), text(2, thread: 1), text(3, thread: 1),
            // Started by someone else, I wrote in it; newest activity.
            text(10), text(11, thread: 10), text(12, fromMe: true, thread: 10),
            // Nothing to do with me.
            text(20), text(21, thread: 20), text(22, thread: 20),
            // Mine, but only one message: not a thread yet.
            text(30, fromMe: true), text(31, thread: 30),
            // Mine, in a tribe I left.
            text(40, chat: "02left", fromMe: true), text(41, chat: "02left", thread: 40),
            text(42, chat: "02left", thread: 40),
        ]))
        let threads = try #require(try await first(storage.threads()))
        #expect(threads.map(\.uuid) == [uuid(10), uuid(1)])
        #expect(threads.map(\.count) == [2, 2])
        #expect(threads[0].chat == tribe)
    }

    @Test func threadsListHasDirectMessagesWithLatestAndParticipants() async throws {
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: tribe)])
        func from(_ alias: String, _ n: Int, thread: Int) -> (Message, Bool, String?) {
            let message = Message.fixture(
                uuid: uuid(n), chat: tribe, sender: sender("02tribe", alias: alias), content: "m\(n)",
                timestamp: Int64(n) * 1_000, threadUUID: uuid(thread)
            )
            return (message, false, nil)
        }
        _ = try storage.apply(Storage.Commit(
            contacts: [(pubkey: dm, ready: true)],
            messages: [
                text(1, fromMe: true), from("ann", 2, thread: 1), from("bob", 3, thread: 1), from("ann", 4, thread: 1),
                from("cat", 5, thread: 1), from("dan", 6, thread: 1),
                text(10, chat: dm), text(11, chat: dm, fromMe: true, reply: 10, thread: 10),
                text(12, chat: dm, reply: 11, thread: 10),
                // A contact's thread with a single reply of ours is listed too.
                text(7, chat: dm, fromMe: true), text(8, chat: dm, reply: 7, thread: 7),
            ]
        ))
        let threads = try #require(try await first(storage.threads()))
        #expect(threads.map(\.uuid) == [uuid(10), uuid(7), uuid(1)])
        #expect(threads[0].chat == dm)
        #expect(threads[0].latest?.content == "m12")
        let tribeThread = threads[1]
        #expect(tribeThread.latest?.content == "m6")
        #expect(tribeThread.participants.map(\.alias) == ["dan", "cat", "ann"])
    }

    @Test func messagePreviewNamesAnAttachmentWithoutCaption() {
        var image = Message.fixture(type: MessageType.attachment, content: "")
        image.mediaType = "image/jpg"
        #expect(image.preview == "Image")
        var file = image
        file.mediaType = "application/pdf"
        file.fileName = "a.pdf"
        #expect(file.preview == "File: a.pdf")
        #expect(Message.fixture(content: " hi ").preview == "hi")
    }

    @Test func deletesComeOnlyFromTheSenderOrTheTribesOwner() throws {
        func member(_ alias: String, _ n: Int, type: Int = MessageType.text, role: Int? = nil, reply: Int? = nil)
            -> (Message, Bool, String?) {
            let message = Message.fixture(
                uuid: uuid(n), type: type, chat: tribe, sender: sender("02tribe", alias: alias, role: role),
                content: "m\(n)", timestamp: Int64(n) * 1_000, replyUUID: reply.map(uuid)
            )
            return (message, false, nil)
        }
        // Our own delete counts once the server has it: the copy with an index.
        func delete(_ n: Int, of target: Int, chat: String, fromMe: Bool = false, sent: Bool = true)
            -> (Message, Bool, String?) {
            let message = Message.fixture(
                uuid: uuid(n), serverIndex: sent ? Int64(n) : nil, type: MessageType.delete, chat: chat,
                fromMe: fromMe, content: "", timestamp: Int64(n) * 1_000, replyUUID: uuid(target)
            )
            return (message, false, nil)
        }
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: tribe)])
        _ = try storage.apply(Storage.Commit(
            contacts: [(pubkey: dm, ready: true)],
            messages: [
                // Direct messages: the contact deletes their own; their delete of mine is ignored; I delete mine.
                text(1, chat: dm), text(2, chat: dm, fromMe: true), text(3, chat: dm, fromMe: true),
                delete(4, of: 1, chat: dm), delete(5, of: 2, chat: dm), delete(6, of: 3, chat: dm, fromMe: true),
                // Ours, not yet on the server: nothing happens until it is.
                text(7, chat: dm, fromMe: true), delete(8, of: 7, chat: dm, fromMe: true, sent: false),
                // Tribe: ann deletes her own; bob's delete of ann's is ignored; the owner (role 0) deletes cat's.
                member("ann", 10), member("ann", 11), member("cat", 12),
                member("ann", 13, type: MessageType.delete, reply: 10),
                member("bob", 14, type: MessageType.delete, reply: 11),
                member("owner", 15, type: MessageType.delete, role: 0, reply: 12),
            ]
        ))
        func deleted(_ n: Int, in chat: String) throws -> Bool? { try storage.message(uuid: uuid(n), in: chat)?.deleted }
        #expect(try deleted(1, in: dm) == true)
        #expect(try deleted(2, in: dm) == false)
        #expect(try deleted(3, in: dm) == true)
        #expect(try deleted(7, in: dm) == false)
        #expect(try deleted(10, in: tribe) == true)
        #expect(try deleted(11, in: tribe) == false)
        #expect(try deleted(12, in: tribe) == true)
        #expect(try storage.message(uuid: uuid(1), in: dm)?.content == nil)
    }

    @Test func answeredRequestIsFoundByItsReplyColumn() throws {
        let request = Message.fixture(uuid: uuid(1), type: MessageType.memberRequest, chat: tribe)
        let approval = Message.fixture(
            uuid: uuid(2), type: MessageType.memberApprove, chat: tribe, fromMe: true, replyUUID: uuid(1)
        )
        let storage = try storage([(request, false, nil), (approval, false, nil)])
        #expect(try storage.isAnswered(request: uuid(1), in: tribe))
        #expect(try !storage.isAnswered(request: uuid(1), in: "02other"))
        #expect(try !storage.isAnswered(request: uuid(3), in: tribe))
    }

    @Test func replyCountsByParent() throws {
        let storage = try storage([
            text(1), text(2, reply: 1, thread: 1), text(3, reply: 1, thread: 1), text(4, reply: 2, thread: 1),
            text(5, chat: "02other", reply: 1),
        ])
        #expect(try storage.replyCounts(in: tribe) == [uuid(1): 2, uuid(2): 1])
    }
}
