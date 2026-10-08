import Foundation
import GRDB

/// Everything Peel keeps on disk for one account.
///
/// A writable Storage holds an exclusive lock on the profile directory, because
/// two processes running core calls against their own copies of the core state
/// would corrupt the account.
public final class Storage: Sendable {
    /// Internal so the payments history (`PaymentHistory.swift`) can read it.
    let pool: DatabasePool
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
    /// Payments and boosts over this many msat need the person's confirmation.
    case paymentConfirmationMsat
    /// What a one-tap boost tips, in msat (the official apps' "Default tip amount").
    case boostAmountMsat
    /// The call server calls are started on and links are checked against,
    /// as `host[:port]`; `chat.sphinx.chat` when unset.
    case callServer
    /// The zone this account's offset comes from, an IANA name; unset or ""
    /// means this Mac's.
    case timeZone
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
    /// The boosts on `messages` and the collapsed threads' originals, by
    /// the boosted message's uuid.
    public var boosts: [String: BoostSummary] = [:]
    /// The payment requests among `messages` (type 2), by row id.
    public var requests: [Int64: PaymentRequest] = [:]
    /// The paid attachments among `messages`, by row id.
    public var purchases: [Int64: PurchaseState] = [:]
}

/// The boosts on one message, summed as the Mac app shows them. Deleted
/// boosts are left out, and our own failed ones are kept apart (`failed`),
/// out of the count and total.
public struct BoostSummary: Sendable, Equatable {
    public struct Boost: Sendable, Equatable {
        /// The booster's name as their message gave it; nil for our own.
        public var alias: String?
        public var photoURL: String?
        public var fromMe: Bool
        public var amountMsat: Int64
        /// For our own boost the server has not confirmed yet: when it went.
        public var pendingSince: Date?
        /// Our own boost the server passed on but never settled (`Delivery.unsettled`).
        public var unsettled = false
        /// Where it sits against the read marker.
        public var serverIndex: Int64?
    }

    /// Oldest first.
    public var boosts: [Boost] = []
    /// Our own boosts on it that failed, oldest first: each may be sent
    /// again or discarded.
    public var failed: [Message] = []
    /// When our oldest unconfirmed boost on it went, if one is.
    public var pendingSince: Date? { boosts.compactMap(\.pendingSince).min() }

    public var count: Int { boosts.count }
    public var totalMsat: Int64 { boosts.reduce(0) { $0 &+ $1.amountMsat } }
    public var boostedByMe: Bool { boosts.contains(where: \.fromMe) }
    /// Any boost of ours on it, failed ones included (`Engine.quickBoost`
    /// boosts a message once).
    public var hasOwnBoost: Bool { boostedByMe || !failed.isEmpty }
    /// Our own boosts on it the server passed on but never settled.
    public var unsettled: [Boost] { boosts.filter(\.unsettled) }
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
    public var lastDate: Date? { lastTimestamp.map(Date.init(millisecondsSince1970:)) }
}

/// A thread as its own view shows it.
public struct ChatThread: Sendable, Equatable {
    /// Nil until the original is stored (it may come later in history).
    public var original: Message?
    /// The newest 200 thread messages, oldest first.
    public var messages: [Message]
    /// The messages replied to inside the thread, by uuid.
    public var parents: [String: Message]
    /// The boosts on the original and `messages`, by the boosted uuid.
    public var boosts: [String: BoostSummary] = [:]
    /// The paid attachments among the original and `messages`, by row id.
    public var purchases: [Int64: PurchaseState] = [:]
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

    /// The balance the server last reported, in msat; nil until it has.
    public func balanceMsat() throws -> UInt64? {
        try value(for: .balanceMsat).flatMap { UInt64($0) }
    }

    public func set(_ value: String, for setting: Setting) throws {
        try pool.write { db in try SettingRow(key: setting.rawValue, value: value).upsert(db) }
    }

    /// The photo on this account's newest direct message that says one, as
    /// the server returns it to every device: where a restore finds the
    /// account's own photo, as the official apps do. Records without sender
    /// details (payments, key exchanges) are passed over, and so are payments
    /// and boosts, which go without the photo when it would split them; an
    /// empty photo on the newest one that has the field means none. Nil unless https.
    func newestOwnPhotoURL() throws -> String? {
        let senders = try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT sender FROM message
                WHERE fromMe = 1 AND sender IS NOT NULL AND serverIndex IS NOT NULL
                  AND type NOT IN (\(MessageType.directPayment), \(MessageType.boost))
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

    /// The newest text, attachment, direct payment or call (a payment or a
    /// call only while not deleted) gives each conversation its place in
    /// the sidebar.
    private static let conversationsSQL = """
        SELECT c.*, m.content AS lastContent, m.timestamp AS lastTimestamp, m.fromMe AS lastFromMe
        FROM (\(chatsSQL)) c
        LEFT JOIN message m ON m.id = (
            SELECT id FROM message WHERE chat = c.chat AND (type IN (\(MessageType.contentSQL))
                OR (type IN (\(MessageType.directPayment), \(MessageType.call)) AND deleted = 0))
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
            WHERE chat = ? AND type IN (\(MessageType.sqlList(MessageType.shownInChats)))
                AND NOT (fromMe = 1 AND type = \(MessageType.groupKick))
            \(condition)
            ORDER BY timestamp DESC, id DESC LIMIT ?
        ) ORDER BY timestamp, id
        """
    }

    /// How many of a chat's newest messages a timeline shows.
    public static let pageSize = 200

    /// A timeline limit that reaches back to `message` (with a few older ones,
    /// so it does not sit at the very top), and never below `pageSize`. It
    /// counts every row from it on, hidden types too, so it may reach further.
    public func timelineLimit(reaching message: Message) throws -> Int {
        guard let timestamp = message.timestamp, let id = message.id else { return Self.pageSize }
        let since = try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message WHERE chat = ? AND (timestamp, id) >= (?, ?)",
                arguments: [message.chat, timestamp, id]
            ) ?? 0
        }
        return max(Self.pageSize, since + 20)
    }

    /// The first reply in a thread past `marker` from someone else: where a
    /// thread with new replies opens.
    public func firstUnreadReply(inThread uuid: String, in chat: String, after marker: Int64) throws -> Message? {
        try pool.read { db in
            try Message.fetchOne(
                db,
                sql: """
                    SELECT * FROM message m
                    WHERE m.chat = ? AND m.threadUUID = ? AND \(Self.countsAsUnreadSQL) AND m.serverIndex > ?
                        -- A boost has no row of its own to open at.
                        AND m.type != \(MessageType.boost)
                    ORDER BY m.serverIndex LIMIT 1
                    """,
                arguments: [chat, uuid, marker]
            )
        }
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

    /// Incoming text, attachments and direct payments past the read marker
    /// count as unread, and boosts only on this account's own messages
    /// (someone else's boost on someone else's message is not news to us;
    /// Tom, 2026-10-07). One row per conversation; each count is ranges on
    /// `message_unread` (one per type), plus a lookup of the boosted message
    /// for each boost in range; the mentions among them a range on
    /// `message_mentions`. A message deleted after it arrived still counts,
    /// as before payments (it was news when it came).
    /// What counts as unread, for a message `m` past the marker: someone
    /// else's text, attachment or payment, or their boost on our message.
    private static let countsAsUnreadSQL = """
        m.fromMe = 0
            AND m.type IN (\(MessageType.sqlList(MessageType.unreadTypes + [MessageType.boost])))
            -- The rule `isMoneyForMe` holds for notifications too.
            AND (m.type != \(MessageType.boost) OR EXISTS (
                SELECT 1 FROM message b WHERE b.uuid = m.replyUUID AND b.chat = m.chat AND b.fromMe = 1))
        """

    private static let readStatesSQL = """
        SELECT c.chat, COALESCE(s.muteLevel, 0) AS muteLevel, s.lastRead, (
            SELECT COUNT(*) FROM message m
            WHERE m.chat = c.chat AND \(countsAsUnreadSQL)
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

    /// Read markers moved here and not yet sent to the server.
    func pendingReads() throws -> [String: Int64] {
        try pool.read { db in
            var reads: [String: Int64] = [:]
            let sql = "SELECT chat, lastRead FROM chatState WHERE readPending != 0 AND lastRead IS NOT NULL"
            for row in try Row.fetchAll(db, sql: sql) {
                reads[row["chat"]] = row["lastRead"]
            }
            return reads
        }
    }

    /// The newest server index in one chat, which is what a read marker points at.
    func highestServerIndex(in chat: String) throws -> Int64? {
        try pool.read { db in try Self.highestServerIndex(in: chat, db) }
    }

    private static func highestServerIndex(in chat: String, _ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT MAX(serverIndex) FROM message WHERE chat = ?", arguments: [chat])
    }

    public func message(id: Int64) throws -> Message? {
        try pool.read { db in try Message.fetchOne(db, sql: "SELECT * FROM message WHERE id = ?", arguments: [id]) }
    }

    /// Our sends the server has not confirmed or refused: every payment or
    /// boost, and text that has waited past the confirmation timeout, newest
    /// first, at most 200 (`message_pending`).
    func pendingSends(textBefore cutoff: Int64) throws -> [Message] {
        try pool.read { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT * FROM message WHERE fromMe = 1 AND status = 'PENDING' AND tag IS NOT NULL
                        AND (type IN (\(MessageType.sqlList(MessageType.moneySends))) OR timestamp < ?)
                    ORDER BY id DESC LIMIT 200
                    """,
                arguments: [cutoff]
            )
        }
    }

    func chat(forTag tag: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT chat FROM message WHERE tag = ?1
                    UNION ALL SELECT chat FROM invoice WHERE tag = ?1 AND chat IS NOT NULL
                    LIMIT 1
                    """,
                arguments: [tag]
            )
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
                    WHERE chat = ? AND fromMe = 0 AND type IN (\(MessageType.sqlList(types)))
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

    /// The newest 200 payments and boosts, sent or received, in one chat or
    /// (nil) in all, newest first, re-emitted whenever they change.
    public func payments(in chat: String? = nil) -> some AsyncSequence<[Message], any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                try Message.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM message
                        WHERE type IN (\(MessageType.sqlList(MessageType.payments))) AND deleted = 0
                            \(chat == nil ? "" : "AND chat = ?")
                        ORDER BY timestamp DESC, id DESC LIMIT 200
                        """,
                    arguments: StatementArguments(chat.map { [$0] } ?? [])
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
            .trackingConstantRegion { db in
                try Message.fetchAll(db, sql: Self.messagesSQL, arguments: [chat, Self.pageSize])
            }
            .removeDuplicates()
            .values(in: pool)
    }
}

// MARK: - Replies and threads

extension Storage {
    /// A chat's main conversation, re-emitted whenever it changes: in a tribe
    /// with threads collapsed as the Mac app shows them, in a DM every
    /// message; plus the parents quoted and the collapsed threads.
    ///
    /// `limit` (at least the newest 200) reaches further back for a message
    /// older than those; see `timelineLimit(reaching:)`.
    public func timeline(in chat: String, limit: Int = pageSize) -> some AsyncSequence<Timeline, any Error> {
        // Read once: inside the observation every setting written would emit again.
        let requesterNodes = (try? requesterNodes(chat)) ?? [chat]
        // Not a constant region: read markers are read only once there are threads.
        return ValueObservation
            .tracking { db in
                let isTribe = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM tribe WHERE pubkey = ?)", arguments: [chat]
                ) ?? false
                let messages = try Message.fetchAll(
                    db, sql: isTribe ? Self.tribeTimelineSQL : Self.messagesSQL, arguments: [chat, limit]
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
                return Timeline(
                    messages: messages, parents: try Self.parents(of: messages, in: chat, db), threads: threads,
                    boosts: try Self.boosts(on: messages + threads.values.map(\.original), in: chat, db),
                    requests: try Self.requests(in: messages, requesterNodes: requesterNodes, db),
                    purchases: try Self.purchases(in: messages + threads.values.map(\.original), db)
                )
            }
            .removeDuplicates()
            .values(in: pool)
    }

    /// One thread: its original and its newest 200 messages, re-emitted
    /// whenever they change.
    public func thread(_ uuid: String, in chat: String) -> some AsyncSequence<ChatThread, any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                let messages = try Message.fetchAll(
                    db, sql: Self.threadMessagesSQL, arguments: [chat, uuid, Self.pageSize]
                )
                let original = try Self.message(uuid: uuid, in: chat, db)
                return ChatThread(
                    original: original,
                    messages: messages,
                    parents: try Self.parents(of: messages, in: chat, db),
                    boosts: try Self.boosts(on: messages + [original].compactMap { $0 }, in: chat, db),
                    purchases: try Self.purchases(in: messages + [original].compactMap { $0 }, db)
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

    /// When this account last boosted the message `uuid` in `chat`, if it
    /// has (failed boosts too: a tap that failed is still a tap).
    func lastOwnBoost(on uuid: String, in chat: String) throws -> Date? {
        try pool.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT MAX(timestamp) FROM message
                    WHERE chat = ? AND replyUUID = ? AND fromMe = 1 AND type = \(MessageType.boost)
                    """,
                arguments: [chat, uuid]
            ).map(Date.init(millisecondsSince1970:))
        }
    }

    /// A message of one chat by uuid, such as the parent of a reply, however
    /// old. Only the same chat: a reply cannot quote another conversation.
    public func message(uuid: String, in chat: String) throws -> Message? {
        try pool.read { db in try Self.message(uuid: uuid, in: chat, db) }
    }

    static func message(uuid: String, in chat: String, _ db: Database) throws -> Message? {
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

    /// The boosts on `messages`, by boosted uuid; same chat only.
    private static func boosts(on messages: [Message], in chat: String, _ db: Database) throws -> [String: BoostSummary] {
        let uuids = Set(messages.compactMap(\.uuid))
        guard !uuids.isEmpty else { return [:] }
        let boosts = try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE chat = ? AND replyUUID IN (\(databaseQuestionMarks(count: uuids.count)))
                    AND type = \(MessageType.boost) AND deleted = 0
                ORDER BY timestamp, id
                """,
            arguments: StatementArguments([chat] + Array(uuids))
        )
        var summaries: [String: BoostSummary] = [:]
        // A boost on our own message pays us: only the sats that arrived
        // count, never what its sender declared.
        let ours = Set(messages.filter(\.fromMe).compactMap(\.uuid))
        for var boost in boosts {
            guard let boosted = boost.replyUUID else { continue }
            if !boost.fromMe, ours.contains(boosted) { boost.amountMsat = boost.msat ?? 0 }
            if boost.fromMe, boost.delivery == .failed {
                summaries[boosted, default: BoostSummary()].failed.append(boost)
                continue
            }
            let sender: (alias: String?, photoURL: String?) = boost.fromMe ? (nil, nil) : boost.senderDetails
            summaries[boosted, default: BoostSummary()].boosts.append(BoostSummary.Boost(
                alias: sender.alias, photoURL: sender.photoURL, fromMe: boost.fromMe,
                amountMsat: boost.amountMsat ?? 0,
                pendingSince: boost.fromMe && boost.delivery == .pending ? boost.date : nil,
                unsettled: boost.fromMe && boost.delivery == .unsettled,
                serverIndex: boost.serverIndex
            ))
        }
        return summaries
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
        /// Send statuses by tag; each only moves a row forward (`setStatus`).
        var statuses: [(tag: String, status: String)] = []
        /// Read markers from the server. They replace ours, lower ones too
        /// (marked unread on another device), except where ours is pending.
        var reads: [String: Int64] = [:]
        var mutes: [String: Int] = [:]
        /// An outgoing row sent again: it takes the new send's uuid, tag and
        /// payment hash.
        var resend: Resend?
        typealias Resend = (id: Int64, chat: String, uuid: String?, tag: String?, paymentHash: String?, timestamp: Int64)
        var tribes: [Tribe] = []
        /// Rows of the server's payment history.
        var payments: [PaymentRecord] = []
        /// Invoices made here, or about to be paid (written before publishing).
        var invoices: [InvoiceRecord] = []
        /// Why a send failed, by tag, as the server said.
        var sendErrors: [String: String] = [:]
        /// Payments to invoices made here that the core is settling: payment
        /// hash and the msat that arrived.
        var settling: [(paymentHash: String, msat: Int64)] = []
        /// Payment hashes the server confirmed settled, and when.
        var settled: [(paymentHash: String, at: Int64)] = []
        /// Pings sent with an asynchronous payment: the ping's payment hash
        /// and the payment's.
        var pings: [(rhash: String, forHash: String)] = []
    }

    /// Returns the stored rows; messages the upsert rejected are left out.
    func apply(_ commit: Commit) throws -> [Message] {
        var purged: [String] = []
        return try apply(commit, purged: &purged)
    }

    /// As `apply`, also giving the bodies of attachments a delete emptied, so
    /// their decrypted copies can be removed from the cache.
    func apply(_ commit: Commit, purged: inout [String]) throws -> [Message] {
        var received: [Message] = []
        return try apply(commit, purged: &purged, received: &received)
    }

    /// As `apply`, also giving the sats that reached this account in this
    /// commit (`received`): direct payments to it and boosts on its own
    /// messages, stored for the first time, with real sats (never an amount
    /// only declared), not deleted and past the chat's read marker (so a
    /// restore or catch-up of what was already seen stays quiet).
    func apply(_ commit: Commit, purged: inout [String], received: inout [Message]) throws -> [Message] {
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
            // Payments and boosts stored for the first time, checked once
            // this commit's read markers are in.
            var fresh: [Message] = []
            for (message, trustSender, replaces) in commit.messages {
                let money = !message.fromMe && MessageType.payments.contains(message.type)
                let isNew = try money && !(Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM message WHERE uuid = ?)", arguments: [message.uuid]
                ) ?? false)
                guard let row = try Self.store(message, replacing: replaces, in: db) else { continue }
                stored.append(row)
                if isNew { fresh.append(row) }
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
            for record in commit.payments {
                try record.upsert(db)
            }
            for invoice in commit.invoices {
                try Self.insert(invoice, db)
            }
            for (rhash, forHash) in commit.pings {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO paymentPing (rhash, forHash) VALUES (?, ?)", arguments: [rhash, forHash]
                )
            }
            for (tag, status) in commit.statuses {
                try Self.setStatus(db, status, tag: tag, error: commit.sendErrors[tag])
                if status == Message.Delivery.delivered.rawValue,
                   let delete = try Message.fetchOne(
                       db, sql: "SELECT * FROM message WHERE tag = ? AND fromMe = 1 AND type = ?",
                       arguments: [tag, MessageType.delete]
                   ),
                   let deleted = try Self.applyDelete(delete, purged: &purged, in: db) {
                    stored.append(deleted)
                }
            }
            for (hash, msat) in commit.settling {
                try db.execute(
                    sql: "UPDATE invoice SET paidMsat = ? WHERE paymentHash = ? AND incoming = 1 AND status = 'OPEN'",
                    arguments: [msat, hash]
                )
            }
            for (hash, at) in commit.settled {
                try db.execute(
                    sql: """
                        UPDATE invoice SET paidAt = ?,
                            status = CASE WHEN IFNULL(paidMsat, 0) >= amountMsat THEN 'COMPLETE' ELSE 'UNDERPAID' END
                        WHERE paymentHash = ? AND incoming = 1 AND status = 'OPEN'
                        """,
                    arguments: [at, hash]
                )
            }
            for (chat, index) in commit.reads {
                try Self.applyServerRead(db, chat: chat, index: index)
            }
            received += try fresh.filter { try Self.isMoneyForMe($0, db) }
            for (chat, level) in commit.mutes {
                try Self.setMute(db, chat: chat, level: level)
            }
            // The rule of `Message.isRetryable`, held here too: text again once
            // failed or unconfirmed, a payment or boost only once it failed.
            if let resend = commit.resend {
                let row = try Message.fetchOne(
                    db,
                    sql: """
                        UPDATE message SET uuid = ?, tag = ?,
                            paymentHash = CASE WHEN type = \(MessageType.invoice) THEN COALESCE(?, paymentHash) ELSE ? END,
                            status = ?, timestamp = ?
                        WHERE id = ? AND chat = ? AND fromMe = 1 AND deleted = 0
                            AND type IN (\(MessageType.sqlList(MessageType.resendable + MessageType.payments)))
                            AND (status = ? OR (status = ? AND type IN (\(MessageType.sqlList(MessageType.resendable)))))
                        RETURNING *
                        """,
                    arguments: [
                        resend.uuid, resend.tag, resend.paymentHash, resend.paymentHash, Message.Delivery.pending.rawValue,
                        resend.timestamp,
                        resend.id, resend.chat,
                        Message.Delivery.failed.rawValue, Message.Delivery.pending.rawValue,
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
                     mentionsMe, replyUUID, threadUUID, mediaType, fileName, fileSize, upload, amountMsat)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    mediaType = CASE WHEN message.deleted THEN NULL ELSE COALESCE(message.mediaType, excluded.mediaType) END,
                    amountMsat = CASE WHEN excluded.msat IS NOT NULL AND message.fromMe = 0
                        THEN excluded.amountMsat ELSE COALESCE(message.amountMsat, excluded.amountMsat) END
                WHERE message.chat = excluded.chat AND message.fromMe = excluded.fromMe
                RETURNING *
                """,
            arguments: [
                message.uuid, message.serverIndex, message.type, message.chat, message.fromMe, message.sender,
                message.body, message.content, message.msat, message.timestamp, message.tag, message.paymentHash,
                message.status, message.mentionsMe, message.replyUUID, message.threadUUID,
                message.mediaType, message.fileName, message.fileSize, message.upload, message.amountMsat,
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

    /// Someone else's payment or boost that brought this account sats it has
    /// not seen yet: a direct payment, or a boost on one of its own messages
    /// (someone else's boost on someone else's message is not news to it;
    /// the unread count in `readStatesSQL` holds the same rule). `row` is
    /// someone else's payment or boost, just stored.
    private static func isMoneyForMe(_ row: Message, _ db: Database) throws -> Bool {
        guard !row.deleted, (row.msat ?? 0) > 0, let index = row.serverIndex else { return false }
        let lastRead = try Int64.fetchOne(db, sql: "SELECT lastRead FROM chatState WHERE chat = ?", arguments: [row.chat])
        guard index > lastRead ?? -1 else { return false }
        guard row.type == MessageType.boost else { return true }
        guard let boosted = row.replyUUID else { return false }
        return try message(uuid: boosted, in: row.chat, db)?.fromMe == true
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

    /// `chatState.readPending`: a marker moved here and not yet sent.
    enum ReadPending: Int {
        case none = 0
        /// Read: a server marker at or past it makes it moot.
        case read = 1
        /// Marked unread: sent as it is, whatever the server holds.
        case unread = 2
    }

    /// A server marker replaces ours unless ours is still to be sent; a
    /// pending read gives way to a server marker at or past it.
    private static func applyServerRead(_ db: Database, chat: String, index: Int64) throws {
        try db.execute(
            sql: """
                INSERT INTO chatState (chat, lastRead) VALUES (?, ?)
                ON CONFLICT(chat) DO UPDATE SET lastRead = excluded.lastRead, readPending = 0
                WHERE readPending = 0 OR (readPending = ? AND excluded.lastRead >= COALESCE(lastRead, -1))
                """,
            arguments: [chat, index, ReadPending.read.rawValue]
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

    /// Moves this device's read marker and holds it as pending until the
    /// server has it: a read only forward, an unread either way. Returns
    /// whether it moved.
    func setRead(chat: String, index: Int64, as kind: ReadPending) throws -> Bool {
        try pool.write { db in
            let before = try Int64.fetchOne(db, sql: "SELECT lastRead FROM chatState WHERE chat = ?", arguments: [chat])
            guard before != index, kind != .read || (before ?? -1) < index else { return false }
            try db.execute(
                sql: """
                    INSERT INTO chatState (chat, lastRead, readPending) VALUES (?, ?, ?)
                    ON CONFLICT(chat) DO UPDATE SET lastRead = excluded.lastRead, readPending = excluded.readPending
                    """,
                arguments: [chat, index, kind.rawValue]
            )
            return true
        }
    }

    /// The server has this marker: unless it moved again meanwhile, the
    /// server's markers replace it from now on.
    func readSent(chat: String, index: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE chatState SET readPending = 0 WHERE chat = ? AND lastRead = ?", arguments: [chat, index]
            )
        }
    }

    /// After a send in `chat`: the server moves its marker to the sent
    /// message, so everything stored there is read and nothing is left to send.
    func readBySending(in chat: String) throws {
        try pool.write { db in
            guard let newest = try Self.highestServerIndex(in: chat, db) else { return }
            try db.execute(
                sql: """
                    INSERT INTO chatState (chat, lastRead) VALUES (?, ?)
                    ON CONFLICT(chat) DO UPDATE SET
                        lastRead = MAX(COALESCE(lastRead, -1), excluded.lastRead), readPending = 0
                    """,
                arguments: [chat, newest]
            )
        }
    }

    /// The server index of the newest message in `chat` that counts as
    /// unread (`countsAsUnreadSQL`): what "Mark as unread" leaves unread.
    public func newestIncomingIndex(in chat: String) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT MAX(m.serverIndex) FROM message m WHERE m.chat = ? AND \(Self.countsAsUnreadSQL)
                    """,
                arguments: [chat]
            )
        }
    }

    func setMute(chat: String, level: MuteLevel) throws {
        try pool.write { db in try Self.setMute(db, chat: chat, level: level.rawValue) }
    }

    func setStatus(_ status: Message.Delivery, tag: String, error: String? = nil) throws {
        try pool.write { db in try Self.setStatus(db, status.rawValue, tag: tag, error: error) }
    }

    /// Only a payment or boost can be unsettled. A status only moves forward: an unconfirmed send becomes delivered,
    /// unsettled or failed, an unsettled one delivered or failed, a failed
    /// one delivered (the server had it after all), and a delivered one never
    /// changes. So a late or synthesised failure can never make a payment
    /// that went through retryable. An invoice we pay follows the same rule
    /// (unsettled leaves it pending), and keeps the server's reason for a failure.
    private static func setStatus(_ db: Database, _ status: String, tag: String, error: String? = nil) throws {
        try db.execute(
            sql: """
                UPDATE message SET status = ?1 WHERE tag = ?2
                    AND (status IS NULL OR status = 'PENDING'
                        OR (status = 'UNSETTLED' AND ?1 IN ('COMPLETE', 'FAILED'))
                        OR (status = 'FAILED' AND ?1 = 'COMPLETE'))
                    AND (?1 != 'UNSETTLED' OR type IN (\(MessageType.sqlList(MessageType.moneySends))))
                """,
            arguments: [status, tag]
        )
        try db.execute(
            sql: """
                UPDATE invoice SET status = ?1,
                    paidAt = CASE WHEN ?1 = 'COMPLETE' THEN COALESCE(paidAt, ?3) ELSE paidAt END,
                    error = CASE WHEN ?1 = 'FAILED' THEN COALESCE(?4, error) WHEN ?1 = 'COMPLETE' THEN NULL ELSE error END
                WHERE tag = ?2 AND incoming = 0
                    AND (status = 'PENDING'
                        OR (status = 'UNSETTLED' AND ?1 IN ('COMPLETE', 'FAILED'))
                        OR (status = 'FAILED' AND ?1 = 'COMPLETE'))
                """,
            arguments: [status, tag, Date().millisecondsSince1970, error]
        )
    }

    /// Writes an invoice made here, or one about to be paid. An invoice
    /// already being paid or paid is never written over: only a failed
    /// payment may be tried again. Refusing throws, so the whole commit,
    /// and with it the publish, is abandoned.
    private static func insert(_ invoice: InvoiceRecord, _ db: Database) throws {
        let written = try String.fetchOne(
            db,
            sql: """
                INSERT INTO invoice
                    (paymentHash, incoming, bolt11, amountMsat, memo, payee, createdAt, expiresAt, status, tag, chat)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(paymentHash, incoming) DO UPDATE SET
                    status = excluded.status, tag = excluded.tag, createdAt = excluded.createdAt,
                    chat = COALESCE(excluded.chat, invoice.chat), error = NULL
                WHERE invoice.incoming = 0 AND invoice.status = 'FAILED'
                RETURNING paymentHash
                """,
            arguments: [
                invoice.paymentHash, invoice.incoming, invoice.bolt11, invoice.amountMsat, invoice.memo,
                invoice.payee, invoice.createdAt, invoice.expiresAt, invoice.status.rawValue, invoice.tag, invoice.chat,
            ]
        )
        guard written != nil else { throw PeelError("that invoice is already being paid or paid") }
    }

    /// Which of these payment hashes name an invoice made here and still open.
    func openInvoices(among hashes: [String]) throws -> Set<String> {
        guard !hashes.isEmpty else { return [] }
        return try pool.read { db in
            try Set(String.fetchAll(
                db,
                sql: """
                    SELECT paymentHash FROM invoice WHERE incoming = 1 AND status = 'OPEN'
                        AND paymentHash IN (\(databaseQuestionMarks(count: hashes.count)))
                    """,
                arguments: StatementArguments(hashes)
            ))
        }
    }

    /// Whether an invoice made here is open and may have been paid since
    /// `checkedAt` (milliseconds), when the history was last fetched back to
    /// what is stored: it had not expired by then, with a margin for the
    /// clocks (one with no expiry counts as a week, CLN's default). Nil asks
    /// about any open one.
    func hasInvoicesAwaitingHistory(checkedAt: Int64?) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM invoice WHERE incoming = 1 AND status = 'OPEN'
                        AND COALESCE(expiresAt, createdAt + 604800000) + 600000 > ?)
                    """,
                arguments: [checkedAt ?? 0]
            ) ?? false
        }
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
