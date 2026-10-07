import Foundation
import GRDB

/// Everything Peel keeps on disk for one account.
///
/// A writable Storage holds an exclusive lock on the profile directory, because
/// two processes running core calls against their own copies of the core state
/// would corrupt the account.
public final class Storage: Sendable {
    private let pool: DatabasePool
    private let lock: Int32?
    /// The profile directory; attachments are kept under `media/`.
    let directory: URL

    public init(directory: URL, readOnly: Bool = false) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        lock = readOnly ? nil : try Self.lock(directory)
        var configuration = Configuration()
        configuration.readonly = readOnly
        pool = try DatabasePool(path: directory.appendingPathComponent("peel.sqlite").path, configuration: configuration)
        if !readOnly {
            try Self.migrator.migrate(pool)
        }
    }

    deinit {
        if let lock { close(lock) }
    }

    private static func lock(_ directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent("lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PeelError("could not open \(path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw PeelError("another Peel process is using \(directory.path)")
        }
        return fd
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
        migrator.registerMigration("v3") { db in
            // A contact is ready once the core holds their key; only those are conversations.
            try db.alter(table: "contact") { t in
                t.add(column: "ready", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v4") { db in
            // Read markers and mute levels, mirrored from the server so other
            // devices agree. `lastRead` is a server message index.
            try db.create(table: "chatState") { t in
                t.primaryKey("chat", .text)
                t.column("lastRead", .integer)
                t.column("muteLevel", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v5") { db in
            // Unread counts and read markers look up a chat's server indexes.
            try db.create(index: "message_chat_serverIndex", on: "message", columns: ["chat", "serverIndex"])
        }
        migrator.registerMigration("v6") { db in
            // Tribes are core contacts too; this says which, and what the registry says about them.
            try db.create(table: "tribe") { t in
                t.primaryKey("pubkey", .text)
                t.column("name", .text)
                t.column("photoURL", .text)
                t.column("summary", .text)
                t.column("host", .text)
                t.column("pricePerMessageMsat", .integer).notNull().defaults(to: 0)
                t.column("escrowMsat", .integer).notNull().defaults(to: 0)
                t.column("isPrivate", .boolean).notNull().defaults(to: false)
                t.column("isOwner", .boolean).notNull().defaults(to: false)
                t.column("left", .boolean).notNull().defaults(to: false)
            }
            // Unread counts read only the index: a tribe's whole history can be unread.
            try db.create(
                index: "message_unread", on: "message", columns: ["chat", "fromMe", "type", "serverIndex"]
            )
        }
        migrator.registerMigration("v7") { db in
            // Where this account stands in each tribe, and the pinned message.
            try db.alter(table: "tribe") { t in
                t.add(column: "status", .integer).notNull().defaults(to: Tribe.Status.active.rawValue)
                t.add(column: "pin", .text)
            }
            // Tribe messages that mention this account, for the Mentions list
            // and the unread count of a chat set to mentions only.
            try db.alter(table: "message") { t in
                t.add(column: "mentionsMe", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: """
                CREATE INDEX message_mentions ON message (chat, serverIndex) WHERE mentionsMe = 1
                """)
        }
        migrator.registerMigration("v8") { db in
            // Replies and threads: what a message answers and the thread it is in.
            try db.alter(table: "message") { t in
                t.add(column: "replyUUID", .text)
                t.add(column: "threadUUID", .text)
            }
            try db.execute(sql: """
                UPDATE message SET
                    replyUUID = json_extract(body, '$.replyUuid'),
                    threadUUID = json_extract(body, '$.threadUuid')
                WHERE (body LIKE '%replyUuid%' OR body LIKE '%threadUuid%') AND json_valid(body);
                CREATE INDEX message_reply ON message (chat, replyUUID) WHERE replyUUID IS NOT NULL;
                CREATE INDEX message_thread ON message (chat, threadUUID, timestamp) WHERE threadUUID IS NOT NULL;
                """)
        }
        migrator.registerMigration("v9") { db in
            // Attachments: what the message's JSON declares, and for ours,
            // whether the memes server has the file yet.
            try db.alter(table: "message") { t in
                t.add(column: "mediaType", .text)
                t.add(column: "fileName", .text)
                t.add(column: "fileSize", .integer)
                t.add(column: "upload", .text)
            }
            // Only our own attachments have an upload, so this stays tiny.
            try db.execute(sql: "CREATE INDEX message_upload ON message (upload) WHERE upload IS NOT NULL")
        }
        migrator.registerMigration("v10") { db in
            // Messages deleted for everyone keep their row, without content.
            try db.alter(table: "message") { t in
                t.add(column: "deleted", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }
}

// MARK: - Rows

private struct CoreStateRow: Codable, PersistableRecord {
    static let databaseTableName = "coreState"
    var key: String
    var value: Data
}

private struct SettingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"
    var key: String
    var value: String
}

public enum Setting: String, Sendable {
    case network
    case server
    case deviceID
    case alias
    case photoURL
    case contactInfo
    case balanceMsat
    case clock
    /// "1" while an account brought back from its words still needs its history.
    case needsRestore
    /// Hours before the app asks for the PIN again; "0" means only at launch.
    case pinTimeoutHours
    /// The tribes server this account's own tribes are listed on, as `host[:port]`.
    case tribeHost
    /// The memes server attachments go to, as `host[:port]`; `memes.sphinx.chat` when unset.
    case memesHost
    /// The highest server index of a message dropped unstored (from a left
    /// tribe), so catching up does not fetch it again.
    case droppedIndex
    /// "0" when notifications should say only "New message"; text is shown otherwise.
    case notificationText
    /// The aliases stored tribe messages were last checked for mentions of
    /// this account (`MentionScan`); a change checks them again.
    case mentionScan
}

/// One chat in the sidebar: a contact or a tribe, plus the newest text message or attachment.
public struct Conversation: Codable, Sendable, Identifiable, Equatable, FetchableRecord {
    public var chat: String
    /// The contact's alias or the tribe's name.
    public var alias: String?
    public var photoURL: String?
    public var isTribe: Bool
    public var lastContent: String?
    public var lastTimestamp: Int64?
    public var lastFromMe: Bool?

    public var id: String { chat }

    public var name: String {
        if let alias, !alias.isEmpty { return alias }
        return String(chat.prefix(12))
    }

    public var lastDate: Date? { lastTimestamp.map(Date.init(millisecondsSince1970:)) }
}

/// How loud a chat is allowed to be, as the server stores it.
public enum MuteLevel: Int, Sendable {
    case all = 0
    case mentionsOnly = 1
    case muted = 2
}

/// Unread count and mute level for one chat.
public struct ChatReadState: Codable, Sendable, Equatable, FetchableRecord {
    public var chat: String
    public var unread: Int
    /// Unread messages that mention this account.
    public var mentions: Int
    public var muteLevel: Int
    /// The server index of the newest message read, if any.
    public var lastRead: Int64? = nil

    public var mute: MuteLevel { MuteLevel(rawValue: muteLevel) ?? .all }

    /// What the sidebar counts: every unread message, only mentions, or
    /// nothing, by the chat's mute level.
    public var shownUnread: Int {
        switch mute {
        case .all: unread
        case .mentionsOnly: mentions
        case .muted: 0
        }
    }

    /// Unread mentions, unless the chat is muted.
    public var shownMentions: Int { mute == .muted ? 0 : mentions }
}

/// What a chat's main conversation shows.
public struct Timeline: Sendable, Equatable {
    /// The newest 200 messages shown, oldest first. In a tribe, a thread of
    /// two or more messages is one row, its newest message (see `threads`);
    /// the rest of the thread and its original are left out.
    public var messages: [Message]
    /// The messages replied to, by uuid, however far back they are.
    public var parents: [String: Message]
    /// The collapsed threads among `messages`, by the original's uuid.
    public var threads: [String: ThreadSummary]

    /// Before the first emission.
    public static let empty = Timeline(messages: [], parents: [:], threads: [:])
}

/// One thread: the message that started it and what has been said in it.
public struct ThreadSummary: Sendable, Identifiable, Equatable {
    public var original: Message
    /// Messages in the thread, not counting the original.
    public var count: Int
    public var lastTimestamp: Int64?
    /// Other people's thread messages past the chat's read marker.
    public var unread: Int
    /// The newest thread message.
    public var latest: Message?
    /// Who wrote in the thread, most recent first, at most three.
    public var participants: [ThreadParticipant] = []

    public var chat: String { original.chat }
    /// The original's uuid, which every message in the thread names.
    public var uuid: String { original.uuid ?? "" }
    public var id: String { "\(chat)/\(uuid)" }
}

/// A thread as its own view shows it.
public struct ChatThread: Sendable, Equatable {
    /// Nil until the original is stored (it may come later in history).
    public var original: Message?
    /// The newest 200 thread messages, oldest first.
    public var messages: [Message]
    /// The messages replied to inside the thread, by uuid.
    public var parents: [String: Message]
}

// MARK: - Reading

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

    public func value(for setting: Setting) throws -> String? {
        try pool.read { db in try SettingRow.fetchOne(db, key: setting.rawValue)?.value }
    }

    public func set(_ value: String, for setting: Setting) throws {
        try pool.write { db in try SettingRow(key: setting.rawValue, value: value).upsert(db) }
    }

    /// The photo on this account's newest direct message that says one, as
    /// the server returns it to every device: where a restore finds the
    /// account's own photo, as the official apps do. Records without sender
    /// details (payments, key exchanges) are passed over; an empty photo on
    /// the newest one that has the field means none. Nil unless https.
    func newestOwnPhotoURL() throws -> String? {
        let senders = try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT sender FROM message
                WHERE fromMe = 1 AND sender IS NOT NULL AND serverIndex IS NOT NULL
                  AND chat NOT IN (SELECT pubkey FROM tribe)
                ORDER BY serverIndex DESC LIMIT 50
                """)
        }
        let decoder = JSONDecoder()
        let photo = senders.lazy.compactMap { try? decoder.decode(SenderInfo.self, from: Data($0.utf8)).photoURL }.first
        return photo?.httpsOnly
    }

    /// The aliases the tribes echoed back on this account's own messages, by tribe.
    func echoedOwnAliases() throws -> [String: Set<String>] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT chat, json_extract(sender, '$.alias') AS alias FROM message
                WHERE fromMe = 1 AND chat IN (SELECT pubkey FROM tribe) AND json_valid(sender)
                  AND IFNULL(json_extract(sender, '$.alias'), '') != ''
                """
            ).reduce(into: [:]) { aliases, row in aliases[row["chat"] as String, default: []].insert(row["alias"]) }
        }
    }

    /// Checks the stored tribe text messages and attachments from others (in
    /// `chats`, or every tribe) for a mention of this account, by the aliases
    /// that name it in that tribe, and sets `mentionsMe` to match. In chunks,
    /// each its own transaction, so other writes go on alongside.
    func rescanMentions(
        sent: String, echoed: [String: Set<String>], in chats: Set<String>? = nil, chunk: Int = 500
    ) throws {
        if chats?.isEmpty == true { return }
        let only = chats.map { "AND chat IN (\(databaseQuestionMarks(count: $0.count)))" } ?? ""
        let plain: Set = [sent]
        let aliasesByChat = echoed.mapValues { ownTribeAliases(sent: sent, echoed: $0) }
        var after: Int64 = 0
        while true {
            let arguments: StatementArguments = [after] + StatementArguments(Array(chats ?? [])) + [chunk]
            let last: Int64? = try pool.write { db in
                let rows = try Row.fetchAll(
                    db, sql: """
                        SELECT id, chat, content, mentionsMe FROM message
                        WHERE id > ? AND fromMe = 0 AND deleted = 0 AND content IS NOT NULL
                          AND type IN (\(MessageType.contentSQL)) AND chat IN (SELECT pubkey FROM tribe) \(only)
                        ORDER BY id LIMIT ?
                        """,
                    arguments: arguments
                )
                for row in rows {
                    let mentioned = PeelCore.mentions(row["content"], aliases: aliasesByChat[row["chat"]] ?? plain)
                    if mentioned != row["mentionsMe"] {
                        try db.execute(
                            sql: "UPDATE message SET mentionsMe = ? WHERE id = ?",
                            arguments: [mentioned, row["id"] as Int64]
                        )
                    }
                }
                return rows.count < chunk ? nil : rows.last?["id"]
            }
            guard let last else { return }
            after = last
        }
    }

    /// The newest server index stored.
    func highestServerIndex() throws -> Int64? {
        try pool.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(serverIndex) FROM message") }
    }

    /// Every conversation: ready contacts and joined tribes. A tribe is a core
    /// contact with no contact key, so it is never a ready contact.
    private static let chatsSQL = """
        SELECT pubkey AS chat, alias, photoURL, 0 AS isTribe FROM contact WHERE ready = 1
        UNION ALL
        SELECT pubkey, name, photoURL, 1 FROM tribe WHERE left = 0
        """

    private static let conversationsSQL = """
        SELECT c.*, m.content AS lastContent, m.timestamp AS lastTimestamp, m.fromMe AS lastFromMe
        FROM (\(chatsSQL)) c
        LEFT JOIN message m ON m.id = (
            SELECT id FROM message WHERE chat = c.chat AND type IN (\(MessageType.contentSQL))
            ORDER BY timestamp DESC, id DESC LIMIT 1
        )
        ORDER BY lastTimestamp IS NULL, lastTimestamp DESC, alias
        """

    /// Text and attachments, plus the membership notes only tribes send. The owner's own
    /// removals are left out, as in the Mac app: the tribe's copy does not
    /// say whom they were for. (Only the owner can send them.)
    private static let messagesSQL = messagesSQL(also: "")

    /// What a tribe's main conversation hides, as the Mac app does: every
    /// message of a thread of two or more but the newest, and the thread's
    /// original. A thread whose original is not stored is not collapsed.
    private static let tribeTimelineSQL = messagesSQL(also: """
        AND NOT (m.threadUUID IS NOT NULL AND m.type IN (\(MessageType.contentSQL))
            AND EXISTS (SELECT 1 FROM message o WHERE o.uuid = m.threadUUID AND o.chat = m.chat)
            AND EXISTS (
                SELECT 1 FROM message n
                WHERE n.chat = m.chat AND n.threadUUID = m.threadUUID AND n.type IN (\(MessageType.contentSQL))
                    AND (n.timestamp, n.id) > (m.timestamp, m.id)
            ))
        AND NOT (m.uuid IS NOT NULL AND EXISTS (
            SELECT 1 FROM message n
            WHERE n.chat = m.chat AND n.threadUUID = m.uuid AND n.type IN (\(MessageType.contentSQL))
            LIMIT 1 OFFSET 1
        ))
        """)

    private static func messagesSQL(also condition: String) -> String {
        """
        SELECT * FROM (
            SELECT * FROM message m
            WHERE chat = ? AND type IN (\(MessageType.shownInChats.map(String.init).joined(separator: ", ")))
                AND NOT (fromMe = 1 AND type = \(MessageType.groupKick))
            \(condition)
            ORDER BY timestamp DESC, id DESC LIMIT 200
        ) ORDER BY timestamp, id
        """
    }

    /// A thread's newest 200 messages, oldest first.
    private static let threadMessagesSQL = messagesSQL(also: "AND threadUUID = ? AND type IN (\(MessageType.contentSQL))")

    /// Threads of two or more messages with their original stored, each with
    /// its original's columns plus `threadCount`, `threadLast` and
    /// `threadUnread`. `filter` narrows the thread messages `t`.
    private static func threadsSQL(where filter: String) -> String {
        """
        SELECT o.*, g.threadCount, g.threadLast, g.threadUnread, g.latestID
        FROM (
            SELECT t.chat, t.threadUUID, COUNT(*) AS threadCount, MAX(t.timestamp) AS threadLast,
                SUM(t.fromMe = 0 AND t.serverIndex > COALESCE(s.lastRead, -1)) AS threadUnread,
                (SELECT l.id FROM message l
                 WHERE l.chat = t.chat AND l.threadUUID = t.threadUUID AND l.type IN (\(MessageType.contentSQL))
                 ORDER BY l.timestamp DESC, l.id DESC LIMIT 1) AS latestID
            FROM message t
            LEFT JOIN chatState s ON s.chat = t.chat
            WHERE t.threadUUID IS NOT NULL AND t.type IN (\(MessageType.contentSQL)) AND \(filter)
            GROUP BY t.chat, t.threadUUID
            -- A tribe thread is one from two messages (what collapses); with a
            -- contact, from the first reply (Tom, 2026-10-07).
            HAVING COUNT(*) >= 2 OR NOT EXISTS (SELECT 1 FROM tribe WHERE tribe.pubkey = t.chat)
        ) g
        JOIN message o ON o.uuid = g.threadUUID AND o.chat = g.chat
        """
    }

    /// Incoming text messages and attachments past the read marker count as
    /// unread, one row per conversation; each count is a range on
    /// `message_unread`, and the mentions among them a range on `message_mentions`.
    private static let readStatesSQL = """
        SELECT c.chat, COALESCE(s.muteLevel, 0) AS muteLevel, s.lastRead, (
            SELECT COUNT(*) FROM message m
            WHERE m.chat = c.chat AND m.fromMe = 0 AND m.type IN (\(MessageType.contentSQL))
                AND m.serverIndex > COALESCE(s.lastRead, -1)
        ) AS unread, (
            SELECT COUNT(*) FROM message m
            WHERE m.chat = c.chat AND m.mentionsMe = 1 AND m.serverIndex > COALESCE(s.lastRead, -1)
        ) AS mentions
        FROM (\(chatsSQL)) c
        LEFT JOIN chatState s ON s.chat = c.chat
        """

    /// Unread counts and mute levels by chat, re-emitted whenever they change.
    public func readStates() -> some AsyncSequence<[String: ChatReadState], any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                let rows = try ChatReadState.fetchAll(db, sql: Self.readStatesSQL)
                return Dictionary(rows.map { ($0.chat, $0) }, uniquingKeysWith: { $1 })
            }
            .removeDuplicates()
            .values(in: pool)
    }

    func lastReads() throws -> [String: Int64] {
        try pool.read { db in
            var reads: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT chat, lastRead FROM chatState WHERE lastRead IS NOT NULL") {
                reads[row["chat"]] = row["lastRead"]
            }
            return reads
        }
    }

    /// The newest server index in one chat, which is what a read marker points at.
    func highestServerIndex(in chat: String) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(serverIndex) FROM message WHERE chat = ?", arguments: [chat])
        }
    }

    public func message(id: Int64) throws -> Message? {
        try pool.read { db in try Message.fetchOne(db, sql: "SELECT * FROM message WHERE id = ?", arguments: [id]) }
    }

    func chat(forTag tag: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT chat FROM message WHERE tag = ? LIMIT 1", arguments: [tag])
        }
    }

    /// One tribe's record, re-emitted whenever it changes.
    public func tribe(_ pubkey: String) -> some AsyncSequence<Tribe?, any Error> {
        ValueObservation
            .trackingConstantRegion { db in try Tribe.fetchOne(db, key: pubkey) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Every tribe this account knows, joined or left.
    public func tribes() throws -> [Tribe] {
        try pool.read { db in try Tribe.fetchAll(db) }
    }

    /// The people seen posting in a tribe, with the newest photo per alias.
    func tribeSenders(_ tribe: String) throws -> [TribeMember] {
        try seenInTribe(tribe, types: MessageType.content, since: 0).map(\.member)
    }

    /// Who can be mentioned in a tribe, as the Mac app offers them: everyone
    /// heard from in the last three months, minus those whose last word was
    /// leaving. Sorted by alias.
    public func mentionCandidates(in tribe: String, now: Date = .now) throws -> [TribeMember] {
        try seenInTribe(
            tribe, types: [MessageType.text, MessageType.groupJoin, MessageType.groupLeave, MessageType.memberApprove],
            since: now.addingTimeInterval(-90 * 24 * 3600).millisecondsSince1970
        ).filter { $0.lastType != MessageType.groupLeave }.map(\.member)
    }

    /// Each alias seen in a tribe's messages of `types` from `since` on (all
    /// of them, timeless ones too, when `since` is 0), from its newest such message
    /// (photo https only, and that message's type), sorted by alias.
    private func seenInTribe(
        _ tribe: String, types: [Int], since: Int64
    ) throws -> [(member: TribeMember, lastType: Int)] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT json_extract(sender, '$.alias') AS alias, json_extract(sender, '$.photo_url') AS photo,
                        type, MAX(id)
                    FROM message
                    WHERE chat = ? AND fromMe = 0 AND type IN (\(types.map(String.init).joined(separator: ", ")))
                        \(since > 0 ? "AND timestamp >= ?" : "") AND json_valid(sender) AND IFNULL(json_extract(sender, '$.alias'), '') != ''
                    GROUP BY alias
                    ORDER BY alias COLLATE NOCASE
                    """,
                arguments: since > 0 ? [tribe, since] : [tribe]
            ).map { row in
                let photo: String? = row["photo"]
                return (TribeMember(alias: row["alias"], photoURL: photo?.httpsOnly, pubkey: nil, pending: false), row["type"])
            }
        }
    }

    /// The newest request to join a tribe from `alias`, which an answer names.
    /// The tribes server makes aliases unique within a tribe.
    func joinRequest(in tribe: String, from alias: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT uuid FROM message
                    WHERE chat = ? AND fromMe = 0 AND type = \(MessageType.memberRequest) AND json_valid(sender)
                        AND json_extract(sender, '$.alias') = ?
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [tribe, alias]
            )
        }
    }

    /// Whether an approval or rejection naming this request is stored.
    func isAnswered(request uuid: String, in tribe: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM message
                        WHERE chat = ? AND replyUUID = ?
                            AND type IN (\(MessageType.memberApprove), \(MessageType.memberReject))
                    )
                    """,
                arguments: [tribe, uuid]
            ) ?? false
        }
    }

    /// The newest 200 messages that mention this account in tribes it still
    /// shows, newest first, re-emitted whenever they change.
    public func mentions() -> some AsyncSequence<[Message], any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                try Message.fetchAll(
                    db, sql: """
                    SELECT * FROM message
                    WHERE mentionsMe = 1 AND chat IN (SELECT pubkey FROM tribe WHERE left = 0)
                    ORDER BY timestamp DESC, id DESC LIMIT 200
                    """
                )
            }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Every conversation, newest first, re-emitted whenever one changes.
    public func conversations() -> some AsyncSequence<[Conversation], any Error> {
        ValueObservation
            .trackingConstantRegion { db in try Conversation.fetchAll(db, sql: Self.conversationsSQL) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// The newest 200 messages of one chat, oldest first, re-emitted whenever they change.
    public func messages(in chat: String) -> some AsyncSequence<[Message], any Error> {
        ValueObservation
            .trackingConstantRegion { db in try Message.fetchAll(db, sql: Self.messagesSQL, arguments: [chat]) }
            .removeDuplicates()
            .values(in: pool)
    }
}

// MARK: - Replies and threads

extension Storage {
    /// A chat's main conversation, re-emitted whenever it changes: in a tribe
    /// with threads collapsed as the Mac app shows them, in a DM every
    /// message; plus the parents quoted and the collapsed threads.
    public func timeline(in chat: String) -> some AsyncSequence<Timeline, any Error> {
        // Not a constant region: read markers are read only once there are threads.
        ValueObservation
            .tracking { db in
                let isTribe = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM tribe WHERE pubkey = ?)", arguments: [chat]
                ) ?? false
                let messages = try Message.fetchAll(
                    db, sql: isTribe ? Self.tribeTimelineSQL : Self.messagesSQL, arguments: [chat]
                )
                var threads: [String: ThreadSummary] = [:]
                let threadUUIDs = Set(messages.compactMap(\.threadUUID))
                if isTribe, !threadUUIDs.isEmpty {
                    let summaries = try Self.threadSummaries(
                        db,
                        where: "t.chat = ? AND t.threadUUID IN (\(databaseQuestionMarks(count: threadUUIDs.count)))",
                        arguments: StatementArguments([chat] + Array(threadUUIDs))
                    )
                    for summary in summaries { threads[summary.uuid] = summary }
                }
                return Timeline(messages: messages, parents: try Self.parents(of: messages, in: chat, db), threads: threads)
            }
            .removeDuplicates()
            .values(in: pool)
    }

    /// One thread: its original and its newest 200 messages, re-emitted
    /// whenever they change.
    public func thread(_ uuid: String, in chat: String) -> some AsyncSequence<ChatThread, any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                let messages = try Message.fetchAll(db, sql: Self.threadMessagesSQL, arguments: [chat, uuid])
                return ChatThread(
                    original: try Self.message(uuid: uuid, in: chat, db),
                    messages: messages,
                    parents: try Self.parents(of: messages, in: chat, db)
                )
            }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Threads in joined tribes (two or more messages) and with contacts (a
    /// single reply is enough), that this account started or wrote in,
    /// newest activity first, re-emitted whenever they change.
    public func threads() -> some AsyncSequence<[ThreadSummary], any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                try Self.threadSummaries(
                    db,
                    // Only threads with a message of ours are grouped at all.
                    where: """
                        t.chat IN (SELECT chat FROM (\(Self.chatsSQL))) AND t.threadUUID IN (
                            SELECT threadUUID FROM message WHERE fromMe = 1 AND threadUUID IS NOT NULL
                            UNION SELECT uuid FROM message WHERE fromMe = 1 AND uuid IS NOT NULL
                        )
                        """,
                    also: "ORDER BY g.threadLast DESC, o.id DESC LIMIT 200"
                )
            }
            .removeDuplicates()
            .values(in: pool)
    }

    /// How many text messages reply to each message of a chat, by the
    /// replied-to uuid.
    public func replyCounts(in chat: String) throws -> [String: Int] {
        try pool.read { db in
            var counts: [String: Int] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT replyUUID, COUNT(*) AS count FROM message
                    WHERE chat = ? AND replyUUID IS NOT NULL AND type = \(MessageType.text)
                    GROUP BY replyUUID
                    """,
                arguments: [chat]
            )
            for row in rows { counts[row["replyUUID"]] = row["count"] }
            return counts
        }
    }

    /// A message of one chat by uuid, such as the parent of a reply, however
    /// old. Only the same chat: a reply cannot quote another conversation.
    public func message(uuid: String, in chat: String) throws -> Message? {
        try pool.read { db in try Self.message(uuid: uuid, in: chat, db) }
    }

    private static func message(uuid: String, in chat: String, _ db: Database) throws -> Message? {
        try Message.fetchOne(db, sql: "SELECT * FROM message WHERE uuid = ? AND chat = ?", arguments: [uuid, chat])
    }

    private static func parents(of messages: [Message], in chat: String, _ db: Database) throws -> [String: Message] {
        let uuids = Set(messages.compactMap(\.replyUUID))
        guard !uuids.isEmpty else { return [:] }
        let parents = try Message.fetchAll(
            db,
            sql: "SELECT * FROM message WHERE chat = ? AND uuid IN (\(databaseQuestionMarks(count: uuids.count)))",
            arguments: StatementArguments([chat] + Array(uuids))
        )
        return Dictionary(parents.compactMap { parent in parent.uuid.map { ($0, parent) } }, uniquingKeysWith: { $1 })
    }

    private static func threadSummaries(
        _ db: Database, where filter: String, arguments: StatementArguments = [], also tail: String = ""
    ) throws -> [ThreadSummary] {
        let rows = try Row.fetchAll(db, sql: threadsSQL(where: filter) + "\n" + tail, arguments: arguments)
        guard !rows.isEmpty else { return [] }
        let latestIDs: [Int64] = rows.compactMap { $0["latestID"] }
        let latest = Dictionary(
            try Message.fetchAll(
                db, sql: "SELECT * FROM message WHERE id IN (\(databaseQuestionMarks(count: latestIDs.count)))",
                arguments: StatementArguments(latestIDs)
            ).compactMap { message in message.id.map { ($0, message) } },
            uniquingKeysWith: { $1 }
        )
        var summaries = try rows.map { row in
            ThreadSummary(
                original: try Message(row: row), count: row["threadCount"], lastTimestamp: row["threadLast"],
                unread: row["threadUnread"] ?? 0, latest: (row["latestID"] as Int64?).flatMap { latest[$0] }
            )
        }
        let participants = try threadParticipants(
            db, chats: Set(summaries.map(\.chat)), threads: Set(summaries.map(\.uuid))
        )
        for index in summaries.indices {
            summaries[index].participants = participants[summaries[index].id] ?? []
        }
        return summaries
    }

    /// The last three people to write in each thread, by `ThreadSummary.id`:
    /// one row per distinct sender, each sender's JSON decoded once.
    private static func threadParticipants(
        _ db: Database, chats: Set<String>, threads: Set<String>
    ) throws -> [String: [ThreadParticipant]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT chat, threadUUID, fromMe, sender, MAX(timestamp) AS last FROM message
                WHERE type IN (\(MessageType.contentSQL))
                    AND chat IN (\(databaseQuestionMarks(count: chats.count)))
                    AND threadUUID IN (\(databaseQuestionMarks(count: threads.count)))
                GROUP BY chat, threadUUID, fromMe, sender
                ORDER BY last DESC
                """,
            arguments: StatementArguments(Array(chats) + Array(threads))
        )
        var result: [String: [ThreadParticipant]] = [:]
        for row in rows {
            let key = "\(row["chat"] as String)/\(row["threadUUID"] as String)"
            guard result[key, default: []].count < 3 else { continue }
            let fromMe: Bool = row["fromMe"]
            let info = (row["sender"] as String?).flatMap { try? JSONDecoder().decode(SenderInfo.self, from: Data($0.utf8)) }
            let participant = ThreadParticipant(
                alias: fromMe ? nil : info?.alias?.nilIfEmpty, photoURL: fromMe ? nil : info?.photoURL?.httpsOnly,
                fromMe: fromMe
            )
            // The same person under a newer photo or name is one participant.
            if !result[key, default: []].contains(where: { $0.fromMe == fromMe && $0.alias == participant.alias }) {
                result[key, default: []].append(participant)
            }
        }
        return result
    }
}

// MARK: - Writing

extension Storage {
    /// Everything one core call changed. Written in a single transaction so the
    /// account can never be half-updated.
    struct Commit {
        var state: [String: Data] = [:]
        var deleteState: [String] = []
        var settings: [Setting: String] = [:]
        /// Core contacts, when the call changed them: pubkey and whether their key is held.
        var contacts: [(pubkey: String, ready: Bool)]?
        /// Messages to store; `trustSender` means the engine matched the sender to
        /// the key that decrypted the message, so its name and photo can be kept.
        /// `replaces` is the uuid of our own row that a tribe's copy of it takes over.
        var messages: [(message: Message, trustSender: Bool, replaces: String?)] = []
        var statuses: [(tag: String, status: String)] = []
        /// Read markers from the server; a marker only ever moves forward.
        var reads: [String: Int64] = [:]
        var mutes: [String: Int] = [:]
        /// An outgoing row sent again: it takes the new send's uuid and tag.
        var resend: Resend?
        typealias Resend = (id: Int64, chat: String, uuid: String?, tag: String?, timestamp: Int64)
        var tribes: [Tribe] = []
    }

    /// Returns the stored rows; messages the upsert rejected are left out.
    func apply(_ commit: Commit) throws -> [Message] {
        var purged: [String] = []
        return try apply(commit, purged: &purged)
    }

    /// As `apply`, also giving the bodies of attachments a delete emptied, so
    /// their decrypted copies can be removed from the cache.
    func apply(_ commit: Commit, purged: inout [String]) throws -> [Message] {
        try pool.write { db in
            for (key, value) in commit.state {
                try CoreStateRow(key: key, value: value).upsert(db)
            }
            if !commit.deleteState.isEmpty {
                try CoreStateRow.deleteAll(db, keys: commit.deleteState)
            }
            for (setting, value) in commit.settings {
                try SettingRow(key: setting.rawValue, value: value).upsert(db)
            }
            if let contacts = commit.contacts {
                let statement = try db.cachedStatement(sql: """
                    INSERT INTO contact (pubkey, ready) VALUES (?, ?)
                    ON CONFLICT(pubkey) DO UPDATE SET ready = excluded.ready
                    """)
                for contact in contacts {
                    try statement.execute(arguments: [contact.pubkey, contact.ready])
                }
            }
            for tribe in commit.tribes {
                try tribe.upsert(db)
            }
            var stored: [Message] = []
            for (message, trustSender, replaces) in commit.messages {
                guard let row = try Self.store(message, replacing: replaces, in: db) else { continue }
                stored.append(row)
                if trustSender, let info = message.senderInfo {
                    try Self.upsertContact(db, pubkey: row.chat, alias: info.alias, photoURL: info.photoURL)
                }
            }
            // After every message of the batch, so a delete finds its target
            // even when both came in the same history page.
            // Our own delete only once the server has it (its echo, the
            // tribe's copy, or a delivered status below), so a delete that
            // fails to send leaves the message as everyone else still sees it.
            for (message, _, _) in commit.messages
            where message.type == MessageType.delete && !(message.fromMe && message.serverIndex == nil) {
                if let deleted = try Self.applyDelete(message, purged: &purged, in: db) { stored.append(deleted) }
            }
            for (tag, status) in commit.statuses {
                try Self.setStatus(db, status, tag: tag)
                if status == Message.Delivery.delivered.rawValue,
                   let delete = try Message.fetchOne(
                       db, sql: "SELECT * FROM message WHERE tag = ? AND fromMe = 1 AND type = ?",
                       arguments: [tag, MessageType.delete]
                   ),
                   let deleted = try Self.applyDelete(delete, purged: &purged, in: db) {
                    stored.append(deleted)
                }
            }
            for (chat, index) in commit.reads {
                try Self.setRead(db, chat: chat, index: index)
            }
            for (chat, level) in commit.mutes {
                try Self.setMute(db, chat: chat, level: level)
            }
            if let resend = commit.resend {
                let row = try Message.fetchOne(
                    db,
                    sql: """
                        UPDATE message SET uuid = ?, tag = ?, status = ?, timestamp = ?
                        WHERE id = ? AND chat = ? AND fromMe = 1 AND type IN (\(MessageType.contentSQL))
                            AND status IN (?, ?)
                        RETURNING *
                        """,
                    arguments: [
                        resend.uuid, resend.tag, Message.Delivery.pending.rawValue, resend.timestamp,
                        resend.id, resend.chat,
                        Message.Delivery.pending.rawValue, Message.Delivery.failed.rawValue,
                    ]
                )
                if let row { stored.append(row) }
            }
            return stored
        }
    }

    /// A message can arrive more than once: live, as the server's echo of our own
    /// send, and again from history. Rows are matched on uuid. Server-side facts
    /// (index, time, amount, hash) are filled in from the later copy; what the
    /// message says is kept from the first. A uuid already used in another
    /// conversation is rejected, so no contact can rewrite another's messages.
    ///
    /// A tribe gives each message it forwards a new uuid and keeps the sender's
    /// as `originalUuid`, so our own message coming back from the tribe takes
    /// over the row written when it was sent (`original`), in the same chat only.
    private static func store(_ message: Message, replacing original: String?, in db: Database) throws -> Message? {
        if let original, let uuid = message.uuid,
           let merged = try Message.fetchOne(
               db,
               sql: """
                   UPDATE message SET
                       uuid = ?,
                       serverIndex = COALESCE(?, serverIndex),
                       timestamp = COALESCE(?, timestamp),
                       sender = COALESCE(sender, ?),
                       status = ?
                   WHERE uuid = ? AND chat = ? AND fromMe = 1
                       AND NOT EXISTS (SELECT 1 FROM message WHERE uuid = ?)
                   RETURNING *
                   """,
               // The tribe forwarding it proves the server took it.
               arguments: [
                   uuid, message.serverIndex, message.timestamp, message.sender, Message.Delivery.delivered.rawValue,
                   original, message.chat, uuid,
               ]
           ) {
            return merged
        }
        return try Message.fetchOne(
            db,
            sql: """
                INSERT INTO message
                    (uuid, serverIndex, type, chat, fromMe, sender, body, content, msat, timestamp, tag, paymentHash, status,
                     mentionsMe, replyUUID, threadUUID, mediaType, fileName, fileSize, upload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(uuid) DO UPDATE SET
                    mentionsMe = CASE WHEN message.deleted THEN 0 ELSE MAX(message.mentionsMe, excluded.mentionsMe) END,
                    serverIndex = COALESCE(excluded.serverIndex, message.serverIndex),
                    timestamp = COALESCE(excluded.timestamp, message.timestamp),
                    msat = COALESCE(excluded.msat, message.msat),
                    paymentHash = COALESCE(excluded.paymentHash, message.paymentHash),
                    tag = COALESCE(message.tag, excluded.tag),
                    sender = COALESCE(message.sender, excluded.sender),
                    -- A deleted message stays empty whatever copy comes again.
                    body = CASE WHEN message.deleted THEN NULL ELSE COALESCE(message.body, excluded.body) END,
                    content = CASE WHEN message.deleted THEN NULL ELSE COALESCE(message.content, excluded.content) END,
                    replyUUID = COALESCE(message.replyUUID, excluded.replyUUID),
                    threadUUID = COALESCE(message.threadUUID, excluded.threadUUID),
                    mediaType = CASE WHEN message.deleted THEN NULL ELSE COALESCE(message.mediaType, excluded.mediaType) END
                WHERE message.chat = excluded.chat AND message.fromMe = excluded.fromMe
                RETURNING *
                """,
            arguments: [
                message.uuid, message.serverIndex, message.type, message.chat, message.fromMe, message.sender,
                message.body, message.content, message.msat, message.timestamp, message.tag, message.paymentHash,
                message.status, message.mentionsMe, message.replyUUID, message.threadUUID,
                message.mediaType, message.fileName, message.fileSize, message.upload,
            ]
        )
    }

    /// Applies a delete (type 17) to the message it names in the same chat,
    /// when its sender may: our own delete of our own message, or of anyone's
    /// in a tribe we own; in a tribe, the owner's (the tribes server stamps
    /// `role: 0` on what the owner sends) or the member who sent it (the tribes
    /// server already refuses a member deleting someone else's; the alias,
    /// unique in a tribe, must match too); in a direct message, the contact's
    /// own. Anything else is ignored. Returns the emptied row.
    private static func applyDelete(_ delete: Message, purged: inout [String], in db: Database) throws -> Message? {
        guard let uuid = delete.replyUUID, let target = try message(uuid: uuid, in: delete.chat, db),
              MessageType.content.contains(target.type), !target.deleted, let id = target.id else { return nil }
        let tribe = try Row.fetchOne(db, sql: "SELECT isOwner FROM tribe WHERE pubkey = ?", arguments: [delete.chat])
        let allowed: Bool
        if delete.fromMe {
            allowed = target.fromMe || (tribe?["isOwner"] as Bool? ?? false)
        } else if tribe != nil {
            let deleter = delete.senderInfo
            allowed = deleter?.role == 0
                || (!target.fromMe && deleter?.alias?.nilIfEmpty != nil && deleter?.alias == target.senderInfo?.alias)
        } else {
            allowed = !target.fromMe
        }
        guard allowed else { return nil }
        if target.type == MessageType.attachment, let body = target.body { purged.append(body) }
        return try Message.fetchOne(
            db,
            sql: """
                UPDATE message SET deleted = 1, content = NULL, body = NULL, mediaType = NULL, fileName = NULL,
                    fileSize = NULL, mentionsMe = 0
                WHERE id = ? RETURNING *
                """,
            arguments: [id]
        )
    }

    /// How many text messages and attachments are in a thread.
    public func threadCount(_ uuid: String, in chat: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message WHERE chat = ? AND threadUUID = ? AND type IN (\(MessageType.contentSQL))",
                arguments: [chat, uuid]
            ) ?? 0
        }
    }

    /// Fills in a contact's name or photo. Photos must be https; anything else is dropped.
    private static func upsertContact(_ db: Database, pubkey: String, alias: String?, photoURL: String?) throws {
        let photo = photoURL?.httpsOnly
        try db.execute(
            sql: """
                INSERT INTO contact (pubkey, alias, photoURL) VALUES (?, ?, ?)
                ON CONFLICT(pubkey) DO UPDATE SET
                    alias = COALESCE(NULLIF(excluded.alias, ''), alias),
                    photoURL = COALESCE(NULLIF(excluded.photoURL, ''), photoURL)
                """,
            arguments: [pubkey, alias, photo]
        )
    }

    private static func setRead(_ db: Database, chat: String, index: Int64) throws {
        try db.execute(
            sql: """
                INSERT INTO chatState (chat, lastRead) VALUES (?, ?)
                ON CONFLICT(chat) DO UPDATE SET lastRead = MAX(COALESCE(lastRead, -1), excluded.lastRead)
                """,
            arguments: [chat, index]
        )
    }

    private static func setMute(_ db: Database, chat: String, level: Int) throws {
        try db.execute(
            sql: """
                INSERT INTO chatState (chat, muteLevel) VALUES (?, ?)
                ON CONFLICT(chat) DO UPDATE SET muteLevel = excluded.muteLevel
                """,
            arguments: [chat, level]
        )
    }

    /// Returns whether the marker moved.
    func setRead(chat: String, index: Int64) throws -> Bool {
        try pool.write { db in
            let before = try Int64.fetchOne(db, sql: "SELECT lastRead FROM chatState WHERE chat = ?", arguments: [chat])
            guard (before ?? -1) < index else { return false }
            try Self.setRead(db, chat: chat, index: index)
            return true
        }
    }

    func setMute(chat: String, level: MuteLevel) throws {
        try pool.write { db in try Self.setMute(db, chat: chat, level: level.rawValue) }
    }

    func setStatus(_ status: Message.Delivery, tag: String) throws {
        try pool.write { db in try Self.setStatus(db, status.rawValue, tag: tag) }
    }

    private static func setStatus(_ db: Database, _ status: String, tag: String) throws {
        try db.execute(sql: "UPDATE message SET status = ? WHERE tag = ?", arguments: [status, tag])
    }

    /// Removes one of our own messages that never reached the server.
    func deleteMessage(id: Int64) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id]) }
    }

    /// Records where an outgoing attachment's upload stands; a failed upload
    /// fails the message. Once the memes server has the file, the body
    /// carries its token.
    func setUpload(_ upload: Message.Upload, id: Int64, body: String? = nil) throws {
        let status: String? = upload == .failed ? Message.Delivery.failed.rawValue : nil
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE message SET upload = ?, body = COALESCE(?, body), status = COALESCE(?, status)
                    WHERE id = ? AND fromMe = 1 AND type = \(MessageType.attachment)
                    """,
                arguments: [upload.rawValue, body, status, id]
            )
        }
    }

    /// Takes a failed upload for a retry. False when it is already uploading
    /// or done, so one upload of a row runs at a time.
    func claimUpload(id: Int64) throws -> Bool {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE message SET upload = ? WHERE id = ? AND upload = ?",
                arguments: [Message.Upload.pending.rawValue, id, Message.Upload.failed.rawValue]
            )
            return db.changesCount > 0
        }
    }

    /// Uploads still marked as running when the engine starts were cut off.
    func failInterruptedUploads() throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE message SET upload = ?, status = ? WHERE upload = ?",
                arguments: [Message.Upload.failed.rawValue, Message.Delivery.failed.rawValue, Message.Upload.pending.rawValue]
            )
        }
    }

    /// The file name and decrypted size a download found.
    func setFile(id: Int64, name: String?, size: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE message SET fileName = COALESCE(fileName, ?), fileSize = ? WHERE id = ?",
                arguments: [name, size, id]
            )
        }
    }

    func upsertContact(pubkey: String, alias: String?) throws {
        try pool.write { db in try Self.upsertContact(db, pubkey: pubkey, alias: alias, photoURL: nil) }
    }

    func save(_ tribes: [Tribe]) throws {
        guard !tribes.isEmpty else { return }
        try pool.write { db in
            for tribe in tribes { try tribe.upsert(db) }
        }
    }

    func deleteTribe(_ pubkey: String) throws {
        _ = try pool.write { db in try Tribe.deleteOne(db, key: pubkey) }
    }
}
