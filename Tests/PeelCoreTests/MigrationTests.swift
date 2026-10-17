import Foundation
import GRDB
import Testing
@testable import PeelCore
@testable import PeelTestSupport

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

/// The schema after v23, frozen the same way for the migrations after v17:
/// the search table, its triggers and the indexes up to v23. The search
/// table's tokenizer is written as plain `trigram`; with SQLite 3.45 and
/// later it also removes diacritics (`remove_diacritics 1`). When a later
/// migration ships, freeze the schema after it as well.
private let shippedSchemaV23 = #"""
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
    index message_preview: CREATE INDEX message_preview ON message (chat, timestamp)
    WHERE noWords = 0 AND (type IN (0, 6) OR (type IN (5, 32) AND deleted = 0))
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
        THEN json_extract(json_extract(body, '$.metadata'), '$.tz') END) VIRTUAL, noWords BOOLEAN NOT NULL DEFAULT 0, "arrived" BOOLEAN, "firstSentAt" INTEGER, "autoResentAt" INTEGER)
    table messageText: CREATE VIRTUAL TABLE messageText USING fts5(
        content, content = 'message', content_rowid = 'id', tokenize = 'trigram')
    table messageText_config: CREATE TABLE 'messageText_config'(k PRIMARY KEY, v) WITHOUT ROWID
    table messageText_data: CREATE TABLE 'messageText_data'(id INTEGER PRIMARY KEY, block BLOB)
    table messageText_docsize: CREATE TABLE 'messageText_docsize'(id INTEGER PRIMARY KEY, sz BLOB)
    table messageText_idx: CREATE TABLE 'messageText_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID
    table payment: CREATE TABLE "payment" ("rhash" TEXT NOT NULL, "ts" INTEGER NOT NULL, "amountMsat" INTEGER NOT NULL, "incoming" BOOLEAN NOT NULL, "msgIndex" INTEGER, "remote" BOOLEAN NOT NULL DEFAULT 0, "error" TEXT, PRIMARY KEY ("rhash", "incoming", "ts"))
    table paymentPing: CREATE TABLE "paymentPing" ("rhash" TEXT PRIMARY KEY NOT NULL, "forHash" TEXT NOT NULL)
    table setting: CREATE TABLE "setting" ("key" TEXT PRIMARY KEY NOT NULL, "value" TEXT NOT NULL)
    table tribe: CREATE TABLE "tribe" ("pubkey" TEXT PRIMARY KEY NOT NULL, "name" TEXT, "photoURL" TEXT, "summary" TEXT, "host" TEXT, "pricePerMessageMsat" INTEGER NOT NULL DEFAULT 0, "escrowMsat" INTEGER NOT NULL DEFAULT 0, "isPrivate" BOOLEAN NOT NULL DEFAULT 0, "isOwner" BOOLEAN NOT NULL DEFAULT 0, "left" BOOLEAN NOT NULL DEFAULT 0, "status" INTEGER NOT NULL DEFAULT 0, "pin" TEXT, "appURL" TEXT, "secondBrainURL" TEXT, "myAlias" TEXT, "myPhotoURL" TEXT)
    trigger messageText_delete: CREATE TRIGGER messageText_delete AFTER DELETE ON message
    WHEN old.type IN (0, 6) AND old.content IS NOT NULL BEGIN
        INSERT INTO messageText (messageText, rowid, content) VALUES ('delete', old.id, old.content);
    END
    trigger messageText_insert: CREATE TRIGGER messageText_insert AFTER INSERT ON message
    WHEN new.type IN (0, 6) AND new.content IS NOT NULL BEGIN
        INSERT INTO messageText (rowid, content) VALUES (new.id, new.content);
    END
    trigger messageText_update: CREATE TRIGGER messageText_update AFTER UPDATE OF type, content ON message
    WHEN old.type IS NOT new.type OR old.content IS NOT new.content BEGIN
        INSERT INTO messageText (messageText, rowid, content)
            SELECT 'delete', old.id, old.content WHERE old.type IN (0, 6) AND old.content IS NOT NULL;
        INSERT INTO messageText (rowid, content)
            SELECT new.id, new.content WHERE new.type IN (0, 6) AND new.content IS NOT NULL;
    END
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

    @Test func v23GetsTheShippedSchema() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v23")
        let found = try schema(queue)
            .replacingOccurrences(of: "tokenize = 'trigram remove_diacritics 1'", with: "tokenize = 'trigram'")
        #expect(found == shippedSchemaV23)
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
        // v19's search triggers and v23's preview index.
        #expect(MessageType.contentSQL == "0, 6")
        #expect(MessageType.directPayment == 5)
        #expect(MessageType.call == 32)
        #expect(Tribe.Status.active.rawValue == 0)
        #expect(Message.Delivery.pending.rawValue == "PENDING")
        // v24's keys.
        #expect(Preference<UInt64>.boostAmountMsat.key == "tip_amount")
        #expect(Preference<UInt64>.paymentConfirmationMsat.key == "peel.payment_confirmation_msat")
        #expect(Preference<String>.timeZone.key == "peel.time_zone")
        #expect(Preference<TimeZoneSharing>.timeZoneSharing.key == "timezone")
        #expect(Preference<Int>.pinTimeoutHours.key == "device.pin_timeout_hours")
        #expect(Preference<Bool>.notificationText.key == "device.notification_text")
        #expect(Preference<UInt64>.boostConfirmedMsat.key == "device.boost_confirmed_msat")
        #expect(Preference<UInt64>.preferencesSince.key == "device.preferences_since")
    }

    /// v24 moves every user setting of a v22 database into `preference`,
    /// in the preferences file's encodings: what came from before sync dated
    /// 0 (so the file wins), the per-chat time zone rows with their dates.
    /// Garbage is left behind rather than failing the migration, and the
    /// account's other settings stay where they were.
    @Test func settingsMoveIntoPreferences() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v22")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO setting (key, value) VALUES
                    ('boostAmountMsat', '250000'), ('paymentConfirmationMsat', '0'), ('timeZone', 'Europe/London'),
                    ('pinTimeoutHours', '4'), ('notificationText', '0'), ('alias', 'Tom'), ('callServer', 'x.example'),
                    ('sidebarLayout', '{}');
                INSERT INTO chatTimeZone (chat, enabled, identifier, updatedAt) VALUES
                    ('02aa', 0, NULL, 1760000000), ('02bb', 1, 'Asia/Bangkok', 1760000100);
                """)
        }
        try queue.close()

        let before = UInt64(Date.now.timeIntervalSince1970)
        let storage = try profile.storage()
        let since = try #require(try storage.preference(.preferencesSince))
        #expect(since >= before && since <= UInt64(Date.now.timeIntervalSince1970) + 1)
        let moved = try storage.preferenceRows().filter { $0.key != "device.preferences_since" }
            .map { "\($0.key) \($0.identifier) \($0.value) \(Int($0.updatedAt))" }
        #expect(moved == [
            #"device.boost_confirmed_msat 0 "250000" 0"#,
            #"device.notification_text 0 "false" 0"#,
            #"device.pin_timeout_hours 0 "4" 0"#,
            #"peel.payment_confirmation_msat 0 "0" 0"#,
            #"peel.time_zone 0 "Europe/London" 0"#,
            #"timezone 02aa {"timezone_enabled":"false","timezone_identifier":""} 1760000000"#,
            #"timezone 02bb {"timezone_enabled":"true","timezone_identifier":"Asia/Bangkok"} 1760000100"#,
            #"tip_amount 0 "250" 0"#,
        ])
        #expect(try storage.preference(.boostAmountMsat) == 250_000)
        #expect(try storage.preference(.paymentConfirmationMsat) == 0)
        #expect(try storage.preference(.timeZone) == "Europe/London")
        #expect(try storage.preference(.pinTimeoutHours) == 4)
        #expect(try storage.preference(.notificationText) == false)
        #expect(try storage.chatTimeZone("02aa") == TimeZoneSharing(enabled: false, identifier: nil))
        #expect(try storage.chatTimeZone("02bb") == TimeZoneSharing(enabled: true, identifier: "Asia/Bangkok"))
        let left = try rows(profile, "SELECT key FROM setting ORDER BY key").map { $0["key"] as String }
        #expect(left.filter { $0 != Setting.noWordsScan.rawValue } == ["alias", "callServer", "sidebarLayout"])
        #expect(try rows(profile, "SELECT name FROM sqlite_master WHERE name = 'chatTimeZone'").isEmpty)
    }

    /// A boost amount under a sat (which no input of Peel's could make)
    /// becomes one sat, the nearest the file can hold, not the default.
    @Test func aBoostAmountUnderASatBecomesOne() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v22")
        try queue.write { db in try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('boostAmountMsat', '500')") }
        try queue.close()
        let storage = try profile.storage()
        #expect(try storage.preference(.boostAmountMsat) == 1000)
        #expect(try storage.preference(.boostConfirmedMsat) == 1000)
    }

    /// Values earlier builds could not have meant are not carried over:
    /// the engine read them as unset, and so does the layer.
    @Test func unreadableSettingsAreLeftBehind() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v22")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO setting (key, value) VALUES
                    ('boostAmountMsat', '0'), ('paymentConfirmationMsat', 'lots'), ('timeZone', ''),
                    ('pinTimeoutHours', '-1'), ('notificationText', '1');
                """)
        }
        try queue.close()
        let storage = try profile.storage()
        #expect(try storage.preferenceRows().map(\.key) == ["device.notification_text", "device.preferences_since"])
        #expect(try storage.preference(.notificationText) == true)
        #expect(try storage.preference(.boostAmountMsat) == nil)
    }

    /// v24 does not depend on v23 (#158's indexes): a database may have
    /// recorded a v23 from a build before #158 landed. With an unrelated
    /// v23 already recorded, v24 still runs and moves the settings, and
    /// that v23's index is left alone.
    @Test func runsAfterAnUnrelatedV23() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v22")
        var other = DatabaseMigrator()
        other.registerMigration("v23") { db in
            try db.execute(sql: "CREATE INDEX other_v23 ON setting (value)")
        }
        try other.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO setting (key, value) VALUES ('boostAmountMsat', '7000'), ('pinTimeoutHours', '2');
                INSERT INTO chatTimeZone (chat, enabled, identifier, updatedAt) VALUES ('02aa', 0, NULL, 1760000000);
                """)
        }
        try queue.close()

        let storage = try profile.storage()
        #expect(try storage.preference(.boostAmountMsat) == 7000)
        #expect(try storage.preference(.pinTimeoutHours) == 2)
        #expect(try storage.chatTimeZone("02aa") == TimeZoneSharing(enabled: false, identifier: nil))
        let applied = try rows(profile, "SELECT identifier FROM grdb_migrations").map { $0["identifier"] as String }
        #expect(applied.contains("v23") && applied.contains("v24"))
        #expect(try !rows(profile, "SELECT name FROM sqlite_master WHERE name = 'other_v23'").isEmpty)
    }

    /// A development build registered this migration as "v23" (before #158
    /// took the name): `preference` exists with rows, `chatTimeZone` is gone
    /// and #158's v23 indexes were skipped. v24 keeps the rows and puts the
    /// indexes back, so the profile opens and the sidebar's query (which
    /// names `message_preview`) runs.
    @Test func runsAfterAnEarlierBuildsV23() async throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v22")
        var earlier = DatabaseMigrator()
        earlier.registerMigration("v23") { db in try Self.earlierPreferences(db) }
        try earlier.migrate(queue)
        try queue.close()

        let storage = try profile.storage()
        #expect(try storage.preference(.boostAmountMsat) == 5000)
        #expect(try storage.preferenceRows().first { $0.key == "tip_amount" }?.updatedAt == 1_760_000_000)
        #expect(try storage.chatTimeZone("02aa") == TimeZoneSharing(enabled: true, identifier: nil))
        #expect(try storage.preference(.preferencesSince) != nil)
        let indexes = try rows(profile, "SELECT name FROM sqlite_master WHERE type = 'index'").map { $0["name"] as String }
        #expect(indexes.contains("message_preview") && !indexes.contains("message_serverIndex"))
        #expect(try #require(try await first(storage.conversations())).isEmpty)
    }

    /// An earlier build registered it as "v22", so the real v22 (resend
    /// dates) never ran there: v24 adds its two columns.
    @Test func runsAfterAnEarlierBuildsV22() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v21")
        var earlier = DatabaseMigrator()
        earlier.registerMigration("v22") { db in try Self.earlierPreferences(db) }
        try earlier.migrate(queue)
        try queue.close()

        let storage = try profile.storage()
        #expect(try storage.preference(.boostAmountMsat) == 5000)
        // That build wrote no confirmation: the amount it kept was set here.
        #expect(try storage.preference(.boostConfirmedMsat) == 5000)
        let columns = try rows(profile, "SELECT name FROM pragma_table_info('message')").map { $0["name"] as String }
        #expect(columns.contains("firstSentAt") && columns.contains("autoResentAt"))
        #expect(try rows(profile, "SELECT name FROM sqlite_master WHERE name = 'chatTimeZone'").isEmpty)
    }

    /// v25's ledger as it shipped, and its rules: a request is its id
    /// within its agent; a copy seen before is not new; only a request not
    /// done is claimed, only a running one finished; one not done, or done
    /// and not sent, is owed; requests long expired are forgotten.
    @Test func v25KeepsOneRowPerRequestOfAnAgent() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v25")
        let sql = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE tbl_name = 'deviceRequest' AND sql IS NOT NULL ORDER BY name")
        }
        #expect(sql == [
            """
            CREATE TABLE deviceRequest (
                agent TEXT NOT NULL,
                id TEXT NOT NULL,
                kind TEXT NOT NULL,
                args TEXT NOT NULL,
                notAfter INTEGER NOT NULL,
                state TEXT NOT NULL,
                status TEXT,
                result TEXT,
                error TEXT,
                messages TEXT NOT NULL,
                sent BOOLEAN NOT NULL DEFAULT 0,
                receivedAt INTEGER NOT NULL,
                PRIMARY KEY (agent, id))
            """,
            "CREATE INDEX deviceRequest_owed ON deviceRequest (agent, receivedAt) WHERE state != 'done' OR sent = 0",
        ])

        let storage = try profile.storage()
        func request(_ id: String, of agent: String = "02a", kind: String = "chats.unseen", notAfter: Int64 = 2_000) -> DeviceRequestRow {
            DeviceRequestRow(agent: agent, id: id, kind: kind, args: "{}", notAfter: notAfter, state: .received, messages: [],
                             receivedAt: 1)
        }
        let (first, new) = try storage.admit(request("r1"), copy: "u1")
        #expect(new && first.messages == ["u1"])
        // The same copy again is not new; another copy is, and the stored row stands.
        #expect(try storage.admit(request("r1", kind: "chats.list"), copy: "u1") == (first, false))
        let second = try storage.admit(request("r1", kind: "chats.list"), copy: "u2")
        #expect(second.newCopy && second.row.kind == "chats.unseen" && second.row.messages == ["u1", "u2"])
        #expect(try storage.admit(request("r1"), copy: "u1").newCopy == false)
        // Another agent's request of the same id is its own.
        #expect(try storage.admit(request("r1", of: "02b"), copy: "u1").newCopy)

        #expect(try storage.finishDeviceRequest("r1", of: "02a", with: .done("x")) == nil)
        #expect(try storage.claimDeviceRequest("r1", of: "02a")?.state == .running)
        let done = try #require(try storage.finishDeviceRequest("r1", of: "02a", with: .done("text")))
        #expect(done.state == .done && done.status == .done && done.result == "text" && !done.sent)
        #expect(try storage.claimDeviceRequest("r1", of: "02a") == nil)
        _ = try storage.admit(request("r2", notAfter: 1_000), copy: "u3")
        #expect(try storage.owedDeviceRequests(of: "02a").map(\.id) == ["r1", "r2"])
        try storage.markDeviceRequestSent("r1", of: "02a")
        #expect(try storage.owedDeviceRequests(of: "02a").map(\.id) == ["r2"])
        try storage.forgetDeviceRequests(expiredBefore: 1_500)
        #expect(try storage.pool.read { try String.fetchAll($0, sql: "SELECT id FROM deviceRequest WHERE agent = '02a'") } == ["r1"])
    }

    /// What the earlier builds' preferences migration left: the table with
    /// a row and a chat's switch, `chatTimeZone` gone.
    private static func earlierPreferences(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE preference (
                key TEXT NOT NULL, identifier TEXT NOT NULL, value TEXT NOT NULL,
                updatedAt REAL NOT NULL DEFAULT 0, PRIMARY KEY (key, identifier)
            );
            INSERT INTO preference (key, identifier, value, updatedAt) VALUES
                ('tip_amount', '0', '"5"', 1760000000),
                ('timezone', '02aa', '{"timezone_enabled":"true","timezone_identifier":""}', 1760000000);
            DROP TABLE chatTimeZone;
            """)
    }
}
