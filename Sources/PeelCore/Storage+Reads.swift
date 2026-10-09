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
                  AND chat NOT IN (\(Self.tribeChats))
                ORDER BY serverIndex DESC LIMIT 50
                """)
        }
        let photo = senders.lazy.compactMap { JSON.decode(SenderInfo.self, from: $0)?.photoURL }.first
        return photo?.httpsOnly
    }

    /// The aliases the tribes echoed back on this account's own messages, by tribe.
    func echoedOwnAliases() throws -> [String: Set<String>] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT chat, json_extract(sender, '$.alias') AS alias FROM message
                WHERE fromMe = 1 AND chat IN (\(Self.tribeChats)) AND json_valid(sender)
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
        try inChunks(of: chunk) { db, after in
            try Row.fetchAll(
                db, sql: """
                    SELECT id, chat, content, mentionsMe FROM message
                    WHERE id > ? AND fromMe = 0 AND deleted = 0 AND content IS NOT NULL
                      AND type IN (\(MessageType.contentSQL)) AND chat IN (\(Self.tribeChats)) \(only)
                    ORDER BY id LIMIT ?
                    """,
                arguments: [after] + StatementArguments(Array(chats ?? [])) + [chunk]
            )
        } update: { db, row in
            let mentioned = PeelCore.mentions(row["content"], aliases: aliasesByChat[row["chat"]] ?? plain)
            if mentioned != row["mentionsMe"] {
                try db.execute(
                    sql: "UPDATE message SET mentionsMe = ? WHERE id = ?",
                    arguments: [mentioned, row["id"] as Int64]
                )
            }
        }
    }

    /// Goes over message rows by id, a chunk at a time, each chunk its own
    /// transaction so other writes go on alongside: `fetch` reads the rows
    /// after an id (at most `chunk`, ordered by id), `update` writes one.
    func inChunks(
        of chunk: Int, _ fetch: (Database, Int64) throws -> [Row], update: (Database, Row) throws -> Void
    ) throws {
        var after: Int64 = 0
        while true {
            let last: Int64? = try pool.write { db in
                let rows = try fetch(db, after)
                for row in rows { try update(db, row) }
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

    /// Every stored tribe, joined or left: the subquery for "is this chat a tribe".
    static let tribeChats = "SELECT pubkey FROM tribe"

    /// Every conversation: ready contacts and joined tribes. A tribe is a core
    /// contact with no contact key, so it is never a ready contact.
    static let chatsSQL = """
        SELECT pubkey AS chat, alias, photoURL, 0 AS isTribe, isNew FROM contact WHERE ready = 1
        UNION ALL
        SELECT pubkey, name, photoURL, 1, 0 FROM tribe WHERE left = 0
        """

    /// The newest text, attachment, direct payment or call (a payment or a
    /// call only while not deleted; none with no words) gives each
    /// conversation its place in the sidebar.
    private static let conversationsSQL = """
        SELECT c.*, m.content AS lastContent, m.timestamp AS lastTimestamp, m.fromMe AS lastFromMe
        FROM (\(chatsSQL)) c
        LEFT JOIN message m ON m.id = (
            SELECT id FROM message WHERE chat = c.chat AND noWords = 0 AND (type IN (\(MessageType.contentSQL))
                OR (type IN (\(MessageType.directPayment), \(MessageType.call)) AND deleted = 0))
            ORDER BY timestamp DESC, id DESC LIMIT 1
        )
        ORDER BY lastTimestamp IS NULL, lastTimestamp DESC, alias
        """

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

    /// What counts as unread, for a message `m` past the marker: someone
    /// else's message of `MessageType.unreadTypes` (text, attachments,
    /// payments, requests and calls) with words (`Message.hasNoWords`, read
    /// from `message_unread`), or their boost on our message (someone else's
    /// boost on someone else's message is not news to us; Tom, 2026-10-07).
    static let countsAsUnreadSQL = """
        m.fromMe = 0 AND m.noWords = 0
            AND m.type IN (\(MessageType.sqlList(MessageType.unreadTypes + [MessageType.boost])))
            -- The rule `isMoneyForMe` holds for notifications too.
            AND (m.type != \(MessageType.boost) OR EXISTS (
                SELECT 1 FROM message b WHERE b.uuid = m.replyUUID AND b.chat = m.chat AND b.fromMe = 1))
        """

    /// The unread and mention counts past each chat's read marker
    /// (`countsAsUnreadSQL`). One row per conversation; each count is ranges
    /// on `message_unread` (one per type), plus a lookup of the boosted
    /// message for each boost in range; the mentions a range on
    /// `message_mentions`. A message deleted after it arrived still counts,
    /// as before payments (it was news when it came).
    private static let readStatesSQL = """
        SELECT c.chat, COALESCE(s.muteLevel, 0) AS muteLevel, s.lastRead, c.isNew, (
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

    /// A send tracked by tag that the server has not confirmed or refused.
    struct PendingSend: Hashable {
        var tag: String
        /// When it was sent or written, in milliseconds since 1970.
        var createdAt: Int64
        /// It pays: a payment, boost or purchase, an invoice we pay or an
        /// invite's funding payment, so one the server never recorded failed
        /// (`Message.unrecordedPaymentTimeout`).
        var movesMoney: Bool
    }

    /// Every send the server has not confirmed or refused, from the three
    /// tables that track one by tag: our payments, boosts and purchases, and
    /// text that has waited past `cutoff` (newest first, at most 200,
    /// `message_pending`); invoices we pay (newest first, at most 200); and
    /// invites whose funding payment is still sending.
    func pendingSendTags(textBefore cutoff: Int64) throws -> [PendingSend] {
        let moneySends = MessageType.sqlList(MessageType.moneySends)
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM (
                        SELECT tag, COALESCE(timestamp, 0) AS createdAt, type IN (\(moneySends)) AS movesMoney
                        FROM message WHERE fromMe = 1 AND status = 'PENDING' AND tag IS NOT NULL
                            AND (type IN (\(moneySends)) OR timestamp < ?)
                        ORDER BY id DESC LIMIT 200)
                    UNION ALL SELECT * FROM (
                        SELECT tag, createdAt, 1 FROM invoice WHERE incoming = 0 AND status = 'PENDING' AND tag IS NOT NULL
                        ORDER BY createdAt DESC LIMIT 200)
                    UNION ALL SELECT tag, createdAt, 1 FROM invite WHERE status = ? AND tag IS NOT NULL
                    """,
                arguments: [cutoff, InviteRecord.Status.sending.rawValue]
            ).map { PendingSend(tag: $0["tag"], createdAt: $0["createdAt"], movesMoney: $0["movesMoney"]) }
        }
    }

    /// Whether sats with this chat are still on their way: a payment, boost
    /// or purchase of ours, or an invoice of theirs we are paying, that the
    /// server has neither confirmed nor refused.
    func hasPendingPayment(in chat: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM message WHERE chat = ?1 AND fromMe = 1 AND status = ?2
                        AND type IN (\(MessageType.sqlList(MessageType.moneySends))))
                    OR EXISTS (SELECT 1 FROM invoice WHERE chat = ?1 AND incoming = 0 AND status = ?2)
                    """,
                arguments: [chat, Message.Delivery.pending.rawValue]
            ) ?? false
        }
    }

    /// The server indexes of a chat's messages of these types.
    func serverIndexes(in chat: String, types: [Int]) throws -> [UInt64] {
        try pool.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT serverIndex FROM message WHERE chat = ? AND serverIndex IS NOT NULL
                        AND type IN (\(MessageType.sqlList(types)))
                    """,
                arguments: [chat]
            ).compactMap { UInt64(exactly: $0) }
        }
    }

    /// When the chat began: its oldest message (the key exchange, for a
    /// contact added here or by someone), in milliseconds since 1970.
    public func firstMessageTime(in chat: String) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(timestamp) FROM message WHERE chat = ?", arguments: [chat])
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

    /// Every tribe this account knows, joined or left, by pubkey,
    /// re-emitted whenever one changes.
    public func tribesByPubkey() -> some AsyncSequence<[String: Tribe], any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                Dictionary(try Tribe.fetchAll(db).map { ($0.pubkey, $0) }, uniquingKeysWith: { $1 })
            }
            .removeDuplicates()
            .values(in: pool)
    }

    /// The message a tribe's owner pinned, however old, re-emitted whenever
    /// the pin or the message changes; nil when nothing is pinned or the
    /// message is not stored here.
    public func pinnedMessage(in tribe: String) -> some AsyncSequence<Message?, any Error> {
        // Not a constant region: the message is read only once there is a pin.
        ValueObservation
            .tracking { db -> Message? in
                guard let pin = try String.fetchOne(db, sql: "SELECT pin FROM tribe WHERE pubkey = ?", arguments: [tribe])
                else { return nil }
                return try Self.message(uuid: pin, in: tribe, db)
            }
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

    /// Every invite made here, newest first, re-emitted whenever one changes.
    public func invites() -> some AsyncSequence<[InviteRecord], any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                try InviteRecord.fetchAll(db, sql: "SELECT * FROM invite ORDER BY createdAt DESC")
            }
            .removeDuplicates()
            .values(in: pool)
    }

    public func listPendingInvites() throws -> [InviteRecord] {
        try pool.read(Self.pendingInvites)
    }

    private static func pendingInvites(_ db: Database) throws -> [InviteRecord] {
        let pending = InviteRecord.pendingStatuses.map(\.rawValue)
        return try InviteRecord.fetchAll(
            db, sql: "SELECT * FROM invite WHERE status IN (\(databaseQuestionMarks(count: pending.count))) ORDER BY createdAt DESC",
            arguments: StatementArguments(pending)
        )
    }

    public func invite(code: String) throws -> InviteRecord? {
        try pool.read { db in try InviteRecord.fetchOne(db, key: code) }
    }

    /// Every conversation, newest first, re-emitted whenever one changes.
    public func conversations() -> some AsyncSequence<[Conversation], any Error> {
        ValueObservation
            .trackingConstantRegion { db in try Conversation.fetchAll(db, sql: Self.conversationsSQL) }
            .removeDuplicates()
            .values(in: pool)
    }
}
