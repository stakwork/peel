import GRDB
import Testing
@testable import PeelCore

/// The schema every real database has after v17, as SQLite keeps it. A failure
/// against this means a shipped migration was edited; later migrations do not
/// touch it, since the tests migrate only up to v17 before comparing.
private let shippedSchema = #"""
    index invite_tag: CREATE INDEX invite_tag ON invite (tag) WHERE tag IS NOT NULL
    index invoice_tag: CREATE INDEX invoice_tag ON invoice (tag) WHERE tag IS NOT NULL
    index message_chat_serverIndex: CREATE INDEX "message_chat_serverIndex" ON "message"("chat", "serverIndex")
    index message_chat_timestamp: CREATE INDEX "message_chat_timestamp" ON "message"("chat", "timestamp")
    index message_mentions: CREATE INDEX message_mentions ON message (chat, serverIndex) WHERE mentionsMe = 1
    index message_money: CREATE INDEX message_money ON message (timestamp)
        WHERE type IN (5, 29, 7, 9, 3)
    index message_on_serverIndex: CREATE INDEX "message_on_serverIndex" ON "message"("serverIndex")
    index message_on_tag: CREATE INDEX "message_on_tag" ON "message"("tag")
    index message_payment: CREATE INDEX message_payment ON message (timestamp)
        WHERE type IN (5, 29)
    index message_paymentHash: CREATE INDEX message_paymentHash ON message (paymentHash) WHERE paymentHash IS NOT NULL
    index message_pending: CREATE INDEX message_pending ON message (id)
        WHERE fromMe = 1 AND status = 'PENDING' AND tag IS NOT NULL
    index message_purchase: CREATE INDEX message_purchase ON message (chat)
        WHERE type IN (7, 8, 9)
    index message_reply: CREATE INDEX message_reply ON message (chat, replyUUID) WHERE replyUUID IS NOT NULL
    index message_senderTZ: CREATE INDEX message_senderTZ ON message (chat, timestamp) WHERE senderTZ IS NOT NULL AND fromMe = 0
    index message_thread: CREATE INDEX message_thread ON message (chat, threadUUID, timestamp) WHERE threadUUID IS NOT NULL
    index message_unread: CREATE INDEX message_unread ON message (chat, fromMe, type, serverIndex, noWords)
    index message_upload: CREATE INDEX message_upload ON message (upload) WHERE upload IS NOT NULL
    index payment_msgIndex: CREATE INDEX payment_msgIndex ON payment (msgIndex) WHERE msgIndex IS NOT NULL
    index payment_ts: CREATE INDEX "payment_ts" ON "payment"("ts")
    table chatState: CREATE TABLE "chatState" ("chat" TEXT PRIMARY KEY NOT NULL, "lastRead" INTEGER, "muteLevel" INTEGER NOT NULL DEFAULT 0, "readPending" INTEGER NOT NULL DEFAULT 0)
    table chatTimeZone: CREATE TABLE "chatTimeZone" ("chat" TEXT PRIMARY KEY NOT NULL, "enabled" BOOLEAN NOT NULL DEFAULT 0, "identifier" TEXT, "updatedAt" INTEGER NOT NULL)
    table contact: CREATE TABLE "contact" ("pubkey" TEXT PRIMARY KEY NOT NULL, "alias" TEXT, "photoURL" TEXT, "ready" BOOLEAN NOT NULL DEFAULT 0, "isNew" BOOLEAN NOT NULL DEFAULT 0)
    table coreState: CREATE TABLE "coreState" ("key" TEXT PRIMARY KEY NOT NULL, "value" BLOB NOT NULL)
    table invite: CREATE TABLE "invite" ("code" TEXT PRIMARY KEY NOT NULL, "link" TEXT NOT NULL, "amountMsat" INTEGER NOT NULL, "nickname" TEXT, "message" TEXT, "tag" TEXT, "status" TEXT NOT NULL, "createdAt" INTEGER NOT NULL, "usedBy" TEXT)
    table invoice: CREATE TABLE "invoice" ("paymentHash" TEXT NOT NULL, "incoming" BOOLEAN NOT NULL, "bolt11" TEXT NOT NULL, "amountMsat" INTEGER NOT NULL, "memo" TEXT NOT NULL DEFAULT '', "payee" TEXT NOT NULL, "createdAt" INTEGER NOT NULL, "expiresAt" INTEGER, "status" TEXT NOT NULL, "paidAt" INTEGER, "paidMsat" INTEGER, "tag" TEXT, "chat" TEXT, "error" TEXT, PRIMARY KEY ("paymentHash", "incoming"))
    table message: CREATE TABLE "message" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "uuid" TEXT UNIQUE, "serverIndex" INTEGER, "type" INTEGER NOT NULL, "chat" TEXT NOT NULL, "fromMe" BOOLEAN NOT NULL, "sender" TEXT, "body" TEXT, "content" TEXT, "msat" INTEGER, "timestamp" INTEGER, "tag" TEXT, "paymentHash" TEXT, "status" TEXT, "mentionsMe" BOOLEAN NOT NULL DEFAULT 0, "replyUUID" TEXT, "threadUUID" TEXT, "mediaType" TEXT, "fileName" TEXT, "fileSize" INTEGER, "upload" TEXT, "deleted" BOOLEAN NOT NULL DEFAULT 0, "amountMsat" INTEGER, senderTZ TEXT GENERATED ALWAYS AS (CASE
        WHEN body IS NULL OR body NOT LIKE '%metadata%' OR NOT json_valid(body) THEN NULL
        WHEN json_type(body, '$.metadata') IS NOT 'text' THEN NULL
        WHEN NOT json_valid(json_extract(body, '$.metadata')) THEN NULL
        WHEN json_type(json_extract(body, '$.metadata'), '$.tz') IS NOT 'text' THEN NULL
        WHEN length(json_extract(json_extract(body, '$.metadata'), '$.tz')) BETWEEN 1 AND 64
        THEN json_extract(json_extract(body, '$.metadata'), '$.tz') END) VIRTUAL, noWords BOOLEAN NOT NULL DEFAULT 0)
    table payment: CREATE TABLE "payment" ("rhash" TEXT NOT NULL, "ts" INTEGER NOT NULL, "amountMsat" INTEGER NOT NULL, "incoming" BOOLEAN NOT NULL, "msgIndex" INTEGER, "remote" BOOLEAN NOT NULL DEFAULT 0, "error" TEXT, PRIMARY KEY ("rhash", "incoming", "ts"))
    table paymentPing: CREATE TABLE "paymentPing" ("rhash" TEXT PRIMARY KEY NOT NULL, "forHash" TEXT NOT NULL)
    table setting: CREATE TABLE "setting" ("key" TEXT PRIMARY KEY NOT NULL, "value" TEXT NOT NULL)
    table tribe: CREATE TABLE "tribe" ("pubkey" TEXT PRIMARY KEY NOT NULL, "name" TEXT, "photoURL" TEXT, "summary" TEXT, "host" TEXT, "pricePerMessageMsat" INTEGER NOT NULL DEFAULT 0, "escrowMsat" INTEGER NOT NULL DEFAULT 0, "isPrivate" BOOLEAN NOT NULL DEFAULT 0, "isOwner" BOOLEAN NOT NULL DEFAULT 0, "left" BOOLEAN NOT NULL DEFAULT 0, "status" INTEGER NOT NULL DEFAULT 0, "pin" TEXT, "appURL" TEXT, "secondBrainURL" TEXT)
    """#

struct MigrationTests {
    let profile = TempProfile()

    /// The schema as SQLite keeps it, without GRDB's own bookkeeping.
    private func schema(_ queue: DatabaseQueue) throws -> String {
        try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT type || ' ' || name || ': ' || sql FROM sqlite_master
                WHERE sql IS NOT NULL AND name NOT IN ('grdb_migrations', 'sqlite_sequence')
                ORDER BY type, name
                """)
        }.joined(separator: "\n")
    }

    @Test func aNewDatabaseGetsTheShippedSchema() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v17")
        #expect(try schema(queue) == shippedSchema)
    }

    /// Covers the v2 contact backfill; v8 and v11 have their own tests too.
    @Test func aVersionOneDatabaseMigratesThroughEveryStep() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO message (uuid, type, chat, fromMe, sender, body, msat) VALUES
                    ('a', 0, '02aa', 0, '{"pubkey":"02aa","alias":"Old","photo_url":"p1"}', '{"content":"hi"}', NULL),
                    ('b', 0, '02aa', 0, '{"pubkey":"02aa","alias":"Ann","photo_url":"p2"}',
                        '{"content":"re","replyUuid":"a","threadUuid":"a"}', NULL),
                    ('c', 5, '02aa', 0, NULL, '{"content":"","amount":9000}', 8000),
                    ('d', 29, '02aa', 1, NULL, '{"content":"","amount":4000,"replyUuid":"a"}', NULL),
                    ('e', 0, '02bb', 0, '{"pubkey":"02zz","alias":"Imposter"}', '{"content":"x"}', NULL),
                    ('f', 0, '02cc', 1, '{"pubkey":"02cc","alias":"Me"}', '{"content":"x"}', NULL),
                    ('g', 0, '02dd', 0, 'not json', '{"content":"x"}', NULL);
                """)
        }
        try Storage.migrator.migrate(queue, upTo: "v17")
        #expect(try schema(queue) == shippedSchema)
        try queue.close()

        _ = try profile.storage()
        // Only a sender naming the chat itself becomes its contact, from the latest message.
        let contacts = try rows(profile, "SELECT pubkey, alias, photoURL FROM contact")
        #expect(contacts.count == 1)
        #expect(contacts.first?["pubkey"] as String? == "02aa")
        #expect(contacts.first?["alias"] as String? == "Ann")
        #expect(contacts.first?["photoURL"] as String? == "p2")

        let storage = try profile.storage(readOnly: true)
        #expect(try storage.message(uuid: "b", in: "02aa")?.threadUUID == "a")
        #expect(try storage.message(uuid: "c", in: "02aa")?.amountMsat == 8000)
        let d = try storage.message(uuid: "d", in: "02aa")
        #expect(d?.replyUUID == "a")
        #expect(d?.amountMsat == 4000)
    }

    /// v14 takes each stored message's `tz` from a `metadata` string holding
    /// a JSON object, and a malformed one (or a body that is not JSON) leaves
    /// the row without one rather than failing the migration.
    @Test func timeZonesAreBackfilledFromStoredBodies() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v13")
        let bodies = [
            #"{"content":"a","metadata":"{\"tz\":\"GMT+1\"}"}"#,
            #"{"content":"b","metadata":"{\"tz\":\"Europe/London\"}"}"#,
            #"{"content":"c","metadata":{"tz":"GMT+1"}}"#,
            #"{"content":"d","metadata":"not json"}"#,
            #"{"content":"e","metadata":"[\"GMT+1\"]"}"#,
            #"{"content":"f","metadata":"{\"tz\":5}"}"#,
            #"{"content":"g","metadata":"{\"tz\":\"\#(String(repeating: "x", count: 65))\"}"}"#,
            #"{"content":"h","metadata":"{\"tz\":\"\"}"}"#,
            #"not json, metadata"#,
            #"{"content":"i"}"#,
            #"{"content":"j","metadata":"\"GMT+1\""}"#,
        ]
        try queue.write { db in
            for (n, body) in bodies.enumerated() {
                try db.execute(
                    sql: "INSERT INTO message (uuid, type, chat, fromMe, body) VALUES (?, 0, '02aa', 0, ?)",
                    arguments: [String(n), body]
                )
            }
        }
        try Storage.migrator.migrate(queue, upTo: "v14")
        let found = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT uuid, senderTZ FROM message ORDER BY id")
                .map { $0["senderTZ"] as String? }
        }
        #expect(found == ["GMT+1", "Europe/London"] + Array(repeating: nil, count: bodies.count - 2))
        let schema = try schema(queue)
        #expect(schema.contains(#"table chatTimeZone: CREATE TABLE "chatTimeZone" ("chat" TEXT PRIMARY KEY NOT NULL, "enabled" BOOLEAN NOT NULL DEFAULT 0, "identifier" TEXT, "updatedAt" INTEGER NOT NULL)"#))
        #expect(schema.contains("index message_senderTZ: CREATE INDEX message_senderTZ ON message (chat, timestamp) WHERE senderTZ IS NOT NULL AND fromMe = 0"))
    }

    /// v16 adds the invites made here, with an index on the funding payment's
    /// tag, and marks contacts who added this account.
    @Test func invitesGetTheirTable() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v16")
        let schema = try schema(queue)
        #expect(schema.contains(#"table invite: CREATE TABLE "invite" ("code" TEXT PRIMARY KEY NOT NULL, "link" TEXT NOT NULL, "amountMsat" INTEGER NOT NULL, "nickname" TEXT, "message" TEXT, "tag" TEXT, "status" TEXT NOT NULL, "createdAt" INTEGER NOT NULL, "usedBy" TEXT)"#))
        #expect(schema.contains("index invite_tag: CREATE INDEX invite_tag ON invite (tag) WHERE tag IS NOT NULL"))
        #expect(schema.contains(#""isNew" BOOLEAN NOT NULL DEFAULT 0)"#))
    }

    /// v17 adds `noWords` and puts it in `message_unread`; opening the
    /// profile then marks the rows stored before that have no words, by
    /// `Message.hasNoWords`, and only once per `Storage.noWordsVersion`.
    @Test func messagesWithNoWordsAreBackfilled() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v16")
        // uuid, type, content, deleted, fromMe, status, and whether it has no words.
        let cases: [(String, Int, String?, Bool, Bool, String?, Bool)] = [
            ("empty", 0, "", false, false, nil, true),
            ("null", 0, nil, false, false, nil, true),
            ("spaces", 0, " \n\t ", false, false, nil, true),
            ("invisible", 0, " \u{200B}\u{FEFF}\u{3000}", false, false, nil, true),
            ("call", 32, "  ", false, false, nil, true),
            ("pending", 0, "", false, true, "PENDING", true),
            ("words", 0, "hi", false, false, nil, false),
            ("spacedWords", 0, "  hi", false, false, nil, false),
            ("control", 0, "\u{1}", false, false, nil, false),
            ("emoji", 0, "\u{3000}😀", false, false, nil, false),
            ("cjk", 0, "你好", false, false, nil, false),
            ("callLink", 32, "https://meet.example/x", false, false, nil, false),
            ("callForm", 32, #"call::{"link":" "}"#, false, false, nil, true),
            ("deleted", 0, nil, true, false, nil, false),
            ("attachment", 6, "", false, false, nil, false),
            ("payment", 5, "", false, false, nil, false),
        ]
        try queue.write { db in
            for (uuid, type, content, deleted, fromMe, status, _) in cases {
                try db.execute(
                    sql: "INSERT INTO message (uuid, type, chat, fromMe, content, deleted, status) VALUES (?, ?, '02aa', ?, ?, ?, ?)",
                    arguments: [uuid, type, fromMe, content, deleted, status]
                )
            }
        }
        try Storage.migrator.migrate(queue, upTo: "v17")
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE noWords = 1") } == 0)
        try queue.close()

        func noWords() throws -> [String: Bool] {
            try rows(profile, "SELECT uuid, noWords FROM message")
                .reduce(into: [:]) { found, row in found[row["uuid"]] = row["noWords"] }
        }
        let expected = Dictionary(uniqueKeysWithValues: cases.map { ($0.0, $0.6) })
        _ = try profile.storage()
        #expect(try noWords() == expected)
        #expect(try profile.storage(readOnly: true).value(for: .noWordsScan) == Storage.noWordsVersion)

        // Checked once per version: a row set wrongly stays until the version changes.
        try profile.queue().write { db in
            try db.execute(sql: "UPDATE message SET noWords = 1 WHERE uuid = 'words'")
            try db.execute(sql: "UPDATE message SET noWords = 0 WHERE uuid = 'empty'")
        }
        let storage = try profile.storage()
        #expect(try noWords()["words"] == true)
        // A new version checks them again, a chunk at a time.
        try storage.set("0", for: .noWordsScan)
        try storage.markNoWords(chunk: 2)
        #expect(try noWords() == expected)
        #expect(try storage.value(for: .noWordsScan) == Storage.noWordsVersion)
    }

    /// v18 makes public every joined tribe whose "private" came from a host
    /// other than the account's own tribes host; owned tribes keep theirs.
    @Test func privateFlagsFromOtherHostsAreCleared() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v17")
        // pubkey, host, isOwner, and whether it stays private.
        let cases: [(String, String?, Bool, Bool)] = [
            ("own", "tribes.example.com", false, true),
            ("ownCase", "Tribes.Example.com", false, true),
            ("other", "fake.example.net", false, false),
            ("otherPort", "tribes.example.com:8443", false, false),
            ("noHost", nil, false, false),
            ("owned", "fake.example.net", true, true),
        ]
        try queue.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('tribeHost', 'tribes.example.com')")
            for (pubkey, host, isOwner, _) in cases {
                try db.execute(
                    sql: "INSERT INTO tribe (pubkey, host, isOwner, isPrivate) VALUES (?, ?, ?, 1)",
                    arguments: [pubkey, host, isOwner]
                )
            }
        }
        try Storage.migrator.migrate(queue, upTo: "v18")
        let found = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT pubkey, isPrivate FROM tribe")
                .reduce(into: [String: Bool]()) { found, row in found[row["pubkey"]] = row["isPrivate"] }
        }
        #expect(found == Dictionary(uniqueKeysWithValues: cases.map { ($0.0, $0.3) }))
    }

    /// Unread counts and Mark as unread still search `message_unread`, which
    /// holds `noWords`, so only a boost reads its row.
    @Test func unreadCountsStillSearchTheUnreadIndex() throws {
        let storage = try profile.storage()
        let plan = try storage.pool.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT COUNT(*) FROM message m
                WHERE m.chat = '02aa' AND \(Storage.countsAsUnreadSQL) AND m.serverIndex > 5
                """).map { $0["detail"] as String }
        }
        #expect(plan.first == "SEARCH m USING INDEX message_unread (chat=? AND fromMe=? AND type=? AND serverIndex>?)")
    }

    /// The live constants that shipped migrations froze as literals. Queries build
    /// their `type IN (...)` lists from `MessageType`, and SQLite uses a partial
    /// index only when the list matches its predicate. If one changes, add a
    /// migration with a new index and update this test; never edit the old one.
    @Test func liveConstantsStillMatchTheFrozenLiterals() {
        #expect(MessageType.sqlList(MessageType.payments) == "5, 29")
        #expect(MessageType.sqlList(MessageType.moneySends + [MessageType.invoicePayment]) == "5, 29, 7, 9, 3")
        #expect(MessageType.sqlList([MessageType.purchase, MessageType.purchaseAccept, MessageType.purchaseDeny]) == "7, 8, 9")
        #expect(MessageType.boost == 29)
        #expect(Tribe.Status.active.rawValue == 0)
        #expect(Message.Delivery.pending.rawValue == "PENDING")
    }
}
