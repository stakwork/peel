import GRDB
import Testing
@testable import PeelCore

/// The schema every real database has after v13, as SQLite keeps it. A failure
/// against this means a shipped migration was edited; later migrations do not
/// touch it, since the tests migrate only up to v13 before comparing.
private let shippedSchema = #"""
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
    index message_thread: CREATE INDEX message_thread ON message (chat, threadUUID, timestamp) WHERE threadUUID IS NOT NULL
    index message_unread: CREATE INDEX "message_unread" ON "message"("chat", "fromMe", "type", "serverIndex")
    index message_upload: CREATE INDEX message_upload ON message (upload) WHERE upload IS NOT NULL
    index payment_msgIndex: CREATE INDEX payment_msgIndex ON payment (msgIndex) WHERE msgIndex IS NOT NULL
    index payment_ts: CREATE INDEX "payment_ts" ON "payment"("ts")
    table chatState: CREATE TABLE "chatState" ("chat" TEXT PRIMARY KEY NOT NULL, "lastRead" INTEGER, "muteLevel" INTEGER NOT NULL DEFAULT 0, "readPending" INTEGER NOT NULL DEFAULT 0)
    table contact: CREATE TABLE "contact" ("pubkey" TEXT PRIMARY KEY NOT NULL, "alias" TEXT, "photoURL" TEXT, "ready" BOOLEAN NOT NULL DEFAULT 0)
    table coreState: CREATE TABLE "coreState" ("key" TEXT PRIMARY KEY NOT NULL, "value" BLOB NOT NULL)
    table invoice: CREATE TABLE "invoice" ("paymentHash" TEXT NOT NULL, "incoming" BOOLEAN NOT NULL, "bolt11" TEXT NOT NULL, "amountMsat" INTEGER NOT NULL, "memo" TEXT NOT NULL DEFAULT '', "payee" TEXT NOT NULL, "createdAt" INTEGER NOT NULL, "expiresAt" INTEGER, "status" TEXT NOT NULL, "paidAt" INTEGER, "paidMsat" INTEGER, "tag" TEXT, "chat" TEXT, "error" TEXT, PRIMARY KEY ("paymentHash", "incoming"))
    table message: CREATE TABLE "message" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "uuid" TEXT UNIQUE, "serverIndex" INTEGER, "type" INTEGER NOT NULL, "chat" TEXT NOT NULL, "fromMe" BOOLEAN NOT NULL, "sender" TEXT, "body" TEXT, "content" TEXT, "msat" INTEGER, "timestamp" INTEGER, "tag" TEXT, "paymentHash" TEXT, "status" TEXT, "mentionsMe" BOOLEAN NOT NULL DEFAULT 0, "replyUUID" TEXT, "threadUUID" TEXT, "mediaType" TEXT, "fileName" TEXT, "fileSize" INTEGER, "upload" TEXT, "deleted" BOOLEAN NOT NULL DEFAULT 0, "amountMsat" INTEGER)
    table payment: CREATE TABLE "payment" ("rhash" TEXT NOT NULL, "ts" INTEGER NOT NULL, "amountMsat" INTEGER NOT NULL, "incoming" BOOLEAN NOT NULL, "msgIndex" INTEGER, "remote" BOOLEAN NOT NULL DEFAULT 0, "error" TEXT, PRIMARY KEY ("rhash", "incoming", "ts"))
    table paymentPing: CREATE TABLE "paymentPing" ("rhash" TEXT PRIMARY KEY NOT NULL, "forHash" TEXT NOT NULL)
    table setting: CREATE TABLE "setting" ("key" TEXT PRIMARY KEY NOT NULL, "value" TEXT NOT NULL)
    table tribe: CREATE TABLE "tribe" ("pubkey" TEXT PRIMARY KEY NOT NULL, "name" TEXT, "photoURL" TEXT, "summary" TEXT, "host" TEXT, "pricePerMessageMsat" INTEGER NOT NULL DEFAULT 0, "escrowMsat" INTEGER NOT NULL DEFAULT 0, "isPrivate" BOOLEAN NOT NULL DEFAULT 0, "isOwner" BOOLEAN NOT NULL DEFAULT 0, "left" BOOLEAN NOT NULL DEFAULT 0, "status" INTEGER NOT NULL DEFAULT 0, "pin" TEXT)
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
        try Storage.migrator.migrate(queue, upTo: "v13")
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
        try Storage.migrator.migrate(queue, upTo: "v13")
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
