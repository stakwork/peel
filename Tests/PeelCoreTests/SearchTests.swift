import Foundation
import GRDB
import Testing
@testable import PeelCore
@testable import PeelTestSupport

private let tribe = "02tribe"

/// Search in a chat (`Storage+Search.swift`) over the v19 index.
struct SearchTests {
    let profile = TempProfile()

    private func message(
        _ n: Int, _ content: String?, type: Int = MessageType.text, chat: String = dm, thread: Int? = nil,
        from alias: String? = nil
    ) -> (Message, Bool, String?) {
        (.fixture(uuid: uuid(n), type: type, chat: chat, sender: alias.map { sender(chat, alias: $0) },
                  content: content, timestamp: Int64(n) * 1_000, threadUUID: thread.map(uuid)), false, nil)
    }

    private func storage(_ messages: [(Message, Bool, String?)]) throws -> Storage {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(contacts: [(pubkey: dm, ready: true)], messages: messages))
        return storage
    }

    private func search(_ storage: Storage, _ text: String, in chat: String? = dm) async throws -> [String?] {
        try await storage.searchMessages(MessageQuery(text), in: chat, limit: 100).map(\.uuid)
    }

    /// Rows the index holds for `text`, whatever the message table says now.
    private func indexed(_ text: String) throws -> Int {
        try profile.queue().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageText WHERE messageText MATCH ?",
                             arguments: [MessageQuery(text).ftsMatch]) ?? 0
        }
    }

    private func sqliteVersion() throws -> Int {
        try profile.queue().read(Storage.sqliteVersion)
    }

    private func storeBeforeV19() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v18")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO message (uuid, type, chat, fromMe, content, timestamp, deleted) VALUES
                    ('text', 0, '02aa', 0, 'Lunch at noon?', 1, 0),
                    ('caption', 6, '02aa', 0, 'noon light', 2, 0),
                    ('payment', 5, '02aa', 0, 'for noon', 3, 0),
                    ('call', 32, '02aa', 0, 'https://call.example/noon', 4, 0),
                    ('deleted', 0, '02aa', 0, NULL, 5, 1),
                    ('other', 0, '02bb', 0, 'noon elsewhere', 6, 0);
                """)
        }
        try queue.close()
    }

    /// v19 indexes the text and captions stored before it, not a payment's
    /// note, a call link or a deleted row's empty content.
    @Test func migrationIndexesStoredMessages() async throws {
        try storeBeforeV19()
        let storage = try profile.storage()
        #expect(try await search(storage, "NOON") == ["caption", "text"])
        #expect(try await search(storage, "noon", in: nil) == ["other", "caption", "text"])
        #expect(try indexed("noon") == 3)
    }

    /// The triggers keep the index in step: a stored message is found at
    /// once, and one deleted for everyone (content gone) or removed is not,
    /// in the results or in the index.
    @Test func indexFollowsInsertsAndDeletes() async throws {
        let storage = try storage([message(1, "first banana"), message(2, "second banana"), message(3, "   ")])
        #expect(try await search(storage, "banana") == [uuid(2), uuid(1)])

        // The contact deletes their first for everyone.
        let delete = Message.fixture(
            uuid: uuid(4), serverIndex: 4, type: MessageType.delete, chat: dm, content: "", timestamp: 4_000,
            replyUUID: uuid(1)
        )
        _ = try storage.apply(Storage.Commit(messages: [(delete, false, nil)]))
        #expect(try await search(storage, "banana") == [uuid(2)])
        #expect(try indexed("first") == 0)

        // A row dropped outright (a discarded send).
        let second = try #require(try storage.message(uuid: uuid(2), in: dm)?.id)
        try storage.deleteMessage(id: second)
        #expect(try await search(storage, "banana") == [])
        #expect(try indexed("banana") == 0)
    }

    /// With secure-delete (SQLite 3.44 and later) a deleted message's text
    /// is gone from the index's own pages, not only from its results.
    @Test func deletedTextLeavesNoTraceInTheIndex() async throws {
        let storage = try storage([message(1, "keep this"), message(2, "QQQQQQ")])
        let version = try sqliteVersion()
        try #require(version >= 3_044_000, "secure-delete needs SQLite 3.44; this is \(version)")
        func traces() throws -> Int {
            try profile.queue().read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageText_data WHERE instr(block, CAST('qqq' AS BLOB)) > 0") ?? 0
            }
        }
        #expect(try traces() > 0)
        let id = try #require(try storage.message(uuid: uuid(2), in: dm)?.id)
        try storage.deleteMessage(id: id)
        #expect(try traces() == 0)
    }

    /// Each word matches on its own, anywhere and in any order, and all of
    /// them must; text in double quotes is one phrase.
    @Test func wordsMatchInAnyOrderAndQuotesMakeAPhrase() async throws {
        let storage = try storage([
            message(1, "the release plan for friday"), message(2, "friday: plan the release"),
            message(3, "release notes only"), message(4, "planning a releases party"),
        ])
        #expect(try await search(storage, "plan release") == [uuid(4), uuid(2), uuid(1)])
        #expect(try await search(storage, "friday   release plan") == [uuid(2), uuid(1)])
        #expect(try await search(storage, #""release plan""#) == [uuid(1)])
        #expect(try await search(storage, #""plan the" friday"#) == [uuid(2)])
        // An unclosed quote runs to the end.
        #expect(try await search(storage, #"notes "release"#) == [uuid(3)])
    }

    /// Accents and case aside, from SQLite 3.45 (`remove_diacritics`).
    @Test func accentsDoNotMatter() async throws {
        let storage = try storage([message(1, "Café au lait, s'il vous plaît"), message(2, "naïve résumé")])
        let version = try sqliteVersion()
        try #require(version >= 3_045_000, "accent-insensitive search needs SQLite 3.45; this is \(version)")
        #expect(try await search(storage, "cafe PLAIT") == [uuid(1)])
        #expect(try await search(storage, "CAFÉ") == [uuid(1)])
        #expect(try await search(storage, "naive resume") == [uuid(2)])
    }

    /// `from:` narrows to senders whose name contains it, case aside, with
    /// words or alone; LIKE's wildcards in it are only text.
    @Test func fromNarrowsToASender() async throws {
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: tribe)])
        _ = try storage.apply(Storage.Commit(messages: [
            message(1, "lunch today?", chat: tribe, from: "Ann Lee"),
            message(2, "lunch sounds good", chat: tribe, from: "bob"),
            message(3, "anyone for coffee", chat: tribe, from: "ann"),
            message(4, "100% done", chat: tribe, from: "50%_off"),
        ]))
        #expect(try await search(storage, "lunch from:ANN", in: tribe) == [uuid(1)])
        #expect(try await search(storage, "from:ann", in: tribe) == [uuid(3), uuid(1)])
        #expect(try await search(storage, #"from:"ann lee""#, in: tribe) == [uuid(1)])
        #expect(try await search(storage, "from:%", in: tribe) == [uuid(4)])
        #expect(try await search(storage, "from:_", in: tribe) == [uuid(4)])
        #expect(try await search(storage, "from:carol lunch", in: tribe) == [])
    }

    @Test func queriesAreReadAsTyped() {
        let query = MessageQuery(#"  plan from:"Ann Lee" "next week" go  "#)
        #expect(query.terms == ["plan", "next week"])
        #expect(query.from == "Ann Lee")
        #expect(query.hasShortTerms)
        #expect(query.ftsMatch == #""plan" AND "next week""#)
        #expect(MessageQuery(#"say "hi""#).terms == ["say"])
        #expect(MessageQuery("from:").isEmpty)
        #expect(MessageQuery("ab\u{0}c").terms == ["abc"])
        #expect(MessageQuery(#"a"b"c"#).ftsMatch == #""a""b""c""#)
    }

    @Test func snippetsStartNearTheMatch() {
        let query = MessageQuery("lunch")
        #expect(query.snippet(of: "lunch first") == "lunch first")
        let long = "We spent the whole morning talking about the budget, and then lunch came"
        #expect(query.snippet(of: long) == "…talking about the budget, and then lunch came")
        #expect(MessageQuery("from:ann").snippet(of: long) == long)
    }

    /// The text is searched as typed: FTS5 syntax in it is only text, and
    /// nothing in it makes the query fail.
    @Test func searchTextIsNeverQuerySyntax() async throws {
        let texts = [
            #"she said "hi there" now"#, "a*b wildcard", "-x- minus", "NEAR(a b)", "col:value", "AND OR NOT",
            "it's", "(paren", "^caret", "**bold** and _it_",
        ]
        let storage = try storage(texts.enumerated().map { message($0 + 1, $1) })
        #expect(try await search(storage, #""hi there" said"#) == [uuid(1)])
        #expect(try await search(storage, "a*b") == [uuid(2)])
        #expect(try await search(storage, "-x-") == [uuid(3)])
        #expect(try await search(storage, "NEAR(") == [uuid(4)])
        #expect(try await search(storage, "col:") == [uuid(5)])
        #expect(try await search(storage, "AND NOT") == [uuid(6)])
        #expect(try await search(storage, "it's") == [uuid(7)])
        #expect(try await search(storage, "**bold**") == [uuid(10)])
        for odd in [#"""#, #""""#, "***", "---", "\u{0}\u{0}\u{0}", #""a" OR "b""#, "' OR 1=1 --", "))))",
                    "from:'", "from:\\"] {
            _ = try await storage.searchMessages(MessageQuery(odd), in: dm, limit: 10)
        }
        // Under three characters finds nothing, as the official app.
        #expect(try await search(storage, "hi") == [])
        #expect(try await search(storage, "  hi  ") == [])
    }

    /// Messages inside a tribe's threads are found, though the timeline
    /// folds them away, and only in their own chat.
    @Test func threadMessagesAreFound() async throws {
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: tribe)])
        _ = try storage.apply(Storage.Commit(messages: [
            message(1, "release plan", chat: tribe),
            message(2, "plan looks good", chat: tribe, thread: 1),
            message(3, "ship the plan", chat: tribe, thread: 1),
            message(4, "unrelated", chat: tribe),
            message(5, "my plan", chat: dm),
        ]))
        let found = try await storage.searchMessages(MessageQuery("plan"), in: tribe, limit: 100)
        #expect(found.map(\.uuid) == [uuid(3), uuid(2), uuid(1)])
        #expect(found.map(\.threadUUID) == [uuid(1), uuid(1), nil])
        #expect(try await storage.searchMessages(MessageQuery("plan"), in: tribe, limit: 2).count == 2)
    }
}
