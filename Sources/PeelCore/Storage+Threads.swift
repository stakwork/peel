import Foundation
import GRDB

extension Storage {
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
