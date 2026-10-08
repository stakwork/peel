import Foundation
import GRDB

extension Storage {
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
    static let chatsSQL = """
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
    static let messagesSQL = messagesSQL(also: "")

    static func messagesSQL(also condition: String) -> String {
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
    static let countsAsUnreadSQL = """
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

    static func highestServerIndex(in chat: String, _ db: Database) throws -> Int64? {
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
