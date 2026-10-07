import Foundation
import GRDB
import Sphinxrs

/// Everything Peel keeps on disk for one account.
public final class Storage: Sendable {
    private let pool: DatabasePool

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pool = try DatabasePool(path: directory.appendingPathComponent("peel.sqlite").path)
        try Self.migrator.migrate(pool)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // Opaque entries owned by the core; see StateCodec.
            try db.create(table: "coreState") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).unique()
                t.column("serverIndex", .integer).indexed()
                t.column("type", .integer).notNull()
                t.column("chat", .text).notNull()
                t.column("fromMe", .boolean).notNull()
                t.column("sender", .text)
                t.column("body", .text)
                t.column("content", .text)
                t.column("msat", .integer)
                t.column("timestamp", .integer)
                t.column("tag", .text).indexed()
                t.column("paymentHash", .text)
                t.column("status", .text)
            }
            try db.create(index: "message_chat_timestamp", on: "message", columns: ["chat", "timestamp"])
        }
        migrator.registerMigration("v2") { db in
            // Names and photos are not core state; they come with messages and invites.
            try db.create(table: "contact") { t in
                t.primaryKey("pubkey", .text)
                t.column("alias", .text)
                t.column("photoURL", .text)
            }
            try db.execute(sql: """
                INSERT INTO contact (pubkey, alias, photoURL)
                SELECT chat, json_extract(sender, '$.alias'), json_extract(sender, '$.photo_url')
                FROM message
                WHERE fromMe = 0 AND json_valid(sender) AND json_extract(sender, '$.pubkey') = chat
                GROUP BY chat HAVING id = MAX(id)
                """)
        }
        return migrator
    }
}

// MARK: - Core state

extension Storage {
    func loadCoreState() throws -> [String: Data] {
        try pool.read { db in
            var state: [String: Data] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM coreState") {
                state[row["key"]] = row["value"]
            }
            return state
        }
    }

    func commitCoreState(set: [String: Data], delete: [String]) throws {
        try pool.write { db in
            for (key, value) in set {
                try db.execute(
                    sql: """
                        INSERT INTO coreState (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [key, value]
                )
            }
            for key in delete {
                try db.execute(sql: "DELETE FROM coreState WHERE key = ?", arguments: [key])
            }
        }
    }
}

// MARK: - Settings

public enum Setting: String, Sendable {
    case network
    case server
    case deviceID
    case alias
    case photoURL
    case contactInfo
    case balanceMsat
}

extension Storage {
    public func value(for setting: Setting) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [setting.rawValue])
        }
    }

    public func set(_ value: String, for setting: Setting) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO setting (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [setting.rawValue, value]
            )
        }
    }
}

// MARK: - Messages

extension Storage {
    /// Stores a message we are sending, before the server has seen it. The server
    /// later echoes it to all our devices; `record` then fills in the same row.
    func recordOutgoing(uuid: String?, tag: String?, type: Int, chat: String, body: String, content: String?) throws -> Message? {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message (uuid, type, chat, fromMe, body, content, timestamp, tag, status)
                    VALUES (?, ?, ?, 1, ?, ?, ?, ?, 'PENDING')
                    ON CONFLICT(uuid) DO NOTHING
                    """,
                arguments: [uuid, type, chat, body, content, Int64(Date().timeIntervalSince1970 * 1000), tag]
            )
            if let uuid {
                return try Message.fetchOne(db, sql: "SELECT * FROM message WHERE uuid = ?", arguments: [uuid])
            }
            return try Message.fetchOne(db, key: db.lastInsertedRowID)
        }
    }

    /// Stores a message from the core. The same message can arrive live and again
    /// from history, so rows are matched on uuid and only filled in, never blanked.
    /// Returns nil for entries that are not messages, such as the bare tag the core
    /// returns from a send.
    func record(_ msg: Msg) throws -> Message? {
        let fromMe = msg.fromMe ?? false
        let sender = msg.sender.flatMap { try? JSONDecoder().decode(SenderFields.self, from: Data($0.utf8)) }
        guard let chat = fromMe ? msg.sentTo : sender?.pubkey, let type = msg.type else {
            return nil
        }
        let body = msg.message.flatMap { try? JSONDecoder().decode(BodyFields.self, from: Data($0.utf8)) }

        return try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message
                        (uuid, serverIndex, type, chat, fromMe, sender, body, content, msat, timestamp, tag, paymentHash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(uuid) DO UPDATE SET
                        serverIndex = COALESCE(excluded.serverIndex, serverIndex),
                        sender = COALESCE(excluded.sender, sender),
                        body = COALESCE(excluded.body, body),
                        content = COALESCE(excluded.content, content),
                        msat = COALESCE(excluded.msat, msat),
                        timestamp = COALESCE(excluded.timestamp, timestamp),
                        tag = COALESCE(excluded.tag, tag),
                        paymentHash = COALESCE(excluded.paymentHash, paymentHash)
                    """,
                arguments: [
                    msg.uuid, msg.index.flatMap { Int64($0) }, Int(type), chat, fromMe, msg.sender, msg.message,
                    body?.content, msg.msat.map { Int64(clamping: $0) }, msg.timestamp.map { Int64(clamping: $0) }, msg.tag,
                    msg.paymentHash,
                ]
            )
            if !fromMe, let sender, sender.pubkey == chat {
                try Self.upsertContact(db, pubkey: chat, alias: sender.alias, photoURL: sender.photoURL)
            }
            if let uuid = msg.uuid {
                return try Message.fetchOne(db, sql: "SELECT * FROM message WHERE uuid = ?", arguments: [uuid])
            }
            return try Message.fetchOne(db, key: db.lastInsertedRowID)
        }
    }

    func setStatus(_ status: String, forTag tag: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE message SET status = ? WHERE tag = ?", arguments: [status, tag])
        }
    }

    public func messages(in chat: String, limit: Int = 50) throws -> [Message] {
        try pool.read { db in
            try Message.fetchAll(
                db,
                sql: "SELECT * FROM message WHERE chat = ? ORDER BY timestamp DESC, id DESC LIMIT ?",
                arguments: [chat, limit]
            ).reversed()
        }
    }

    public func highestServerIndex() throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(serverIndex) FROM message")
        }
    }
}

private struct SenderFields: Decodable {
    let pubkey: String
    let alias: String?
    let photoURL: String?

    enum CodingKeys: String, CodingKey {
        case pubkey, alias
        case photoURL = "photo_url"
    }
}

private struct BodyFields: Decodable {
    let content: String?
}

// MARK: - Contacts and conversations

/// One chat in the sidebar: the contact plus the newest text message.
public struct Conversation: Codable, Sendable, Identifiable, Equatable, FetchableRecord {
    public var chat: String
    public var alias: String?
    public var photoURL: String?
    public var lastContent: String?
    public var lastTimestamp: Int64?
    public var lastFromMe: Bool?

    public var id: String { chat }

    public var name: String {
        if let alias, !alias.isEmpty { return alias }
        return String(chat.prefix(12))
    }
}

extension Storage {
    /// Makes sure a contact row exists; fills in a name or photo when given one.
    func upsertContact(pubkey: String, alias: String?, photoURL: String?) throws {
        try pool.write { db in
            try Self.upsertContact(db, pubkey: pubkey, alias: alias, photoURL: photoURL)
        }
    }

    private static func upsertContact(_ db: Database, pubkey: String, alias: String?, photoURL: String?) throws {
        try db.execute(
            sql: """
                INSERT INTO contact (pubkey, alias, photoURL) VALUES (?, ?, ?)
                ON CONFLICT(pubkey) DO UPDATE SET
                    alias = COALESCE(NULLIF(excluded.alias, ''), alias),
                    photoURL = COALESCE(NULLIF(excluded.photoURL, ''), photoURL)
                """,
            arguments: [pubkey, alias, photoURL]
        )
    }

    private static let conversationsSQL = """
        SELECT c.pubkey AS chat, c.alias, c.photoURL,
               m.content AS lastContent, m.timestamp AS lastTimestamp, m.fromMe AS lastFromMe
        FROM contact c
        LEFT JOIN message m ON m.id = (
            SELECT id FROM message WHERE chat = c.pubkey AND type = 0 ORDER BY timestamp DESC, id DESC LIMIT 1
        )
        ORDER BY m.timestamp IS NULL, m.timestamp DESC, c.alias
        """

    /// Every conversation, newest first, re-emitted whenever anything changes.
    public func conversations() -> AsyncThrowingStream<[Conversation], Error> {
        observe { db in try Conversation.fetchAll(db, sql: Self.conversationsSQL) }
    }

    /// The messages of one chat, oldest first, re-emitted whenever they change.
    public func messages(in chat: String) -> AsyncThrowingStream<[Message], Error> {
        observe { db in
            try Message.fetchAll(
                db, sql: "SELECT * FROM message WHERE chat = ? AND type = 0 ORDER BY timestamp, id", arguments: [chat]
            )
        }
    }

    private func observe<Value: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in ValueObservation.tracking(fetch).values(in: pool) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
