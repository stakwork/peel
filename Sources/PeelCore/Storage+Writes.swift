import Foundation
import GRDB

private struct CoreStateRow: Codable, PersistableRecord {
    static let databaseTableName = "coreState"
    var key: String
    var value: Data
}

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
        /// Send statuses by tag; each only moves a row forward (`applyStatus`).
        var statuses: [(tag: String, status: String)] = []
        /// Read markers from the server. They replace ours, lower ones too
        /// (marked unread on another device), except where ours is pending.
        var reads: [String: Int64] = [:]
        var mutes: [String: Int] = [:]
        /// An outgoing row sent again: it takes the new send's uuid, tag and
        /// payment hash, keeps when it was first sent, and with `auto` notes
        /// that a reconnect sent it (`Message.autoResentAt`).
        var resend: Resend?
        typealias Resend = (
            id: Int64, chat: String, uuid: String?, tag: String?, paymentHash: String?, timestamp: Int64, auto: Bool
        )
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
        /// Invites made here, written before their payment is published.
        var invites: [InviteRecord] = []
        /// Whether someone adding this account (type 10, first seen) marks
        /// the contact new: not in a restore, which replays old ones.
        var marksNewContacts = false
    }

    /// What one `apply` did.
    struct Applied {
        /// The rows stored; messages the upsert rejected are left out.
        var stored: [Message] = []
        /// The bodies of attachments a delete emptied, so their decrypted
        /// copies can be removed from the cache.
        var purged: [String] = []
        /// Someone else's payments and boosts with sats that this commit
        /// found arrived (`arrived`): by its history rows, or by a row already
        /// stored for a message stored now. The engine tells only those it
        /// was waiting to tell (`announceable`), never on the message alone
        /// (payments review F2).
        var confirmed: [Message] = []
        /// Ids of the sats that reached this account, stored for the first
        /// time: direct payments to it and boosts on its own messages, with
        /// real sats (never an amount only declared), not deleted and past
        /// the chat's read marker as it stood then (so a restore or catch-up
        /// of what was already seen stays quiet). Decided now, not when
        /// confirmed: by then the open chat may have been marked read.
        var announceable: [Int64] = []
        /// Someone else's payment or boost with sats stored for the first
        /// time: the history is worth asking about it.
        var newMoney = false
        /// The key exchanges of people adding this account seen for the
        /// first time (only with `marksNewContacts`).
        var addedUs: [Message] = []
    }

    @discardableResult
    func apply(_ commit: Commit) throws -> Applied {
        try pool.write { db in
            var applied = Applied()
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
            // Payments and boosts stored for the first time, checked once
            // this commit's read markers and history rows are in.
            var fresh: [Message] = []
            for (message, trustSender, replaces) in commit.messages {
                let money = !message.fromMe && MessageType.payments.contains(message.type)
                let addsUs = commit.marksNewContacts && trustSender && !message.fromMe
                    && message.type == MessageType.contactKey
                let isNew = try (money || addsUs) && !(Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM message WHERE uuid = ?)", arguments: [message.uuid]
                ) ?? false)
                guard let row = try Self.store(message, replacing: replaces, in: db) else { continue }
                applied.stored.append(row)
                if isNew, money, (row.msat ?? 0) > 0 { fresh.append(row) }
                if isNew, addsUs {
                    applied.addedUs.append(row)
                    try db.execute(
                        sql: "INSERT INTO contact (pubkey, isNew) VALUES (?, 1) ON CONFLICT(pubkey) DO UPDATE SET isNew = 1",
                        arguments: [row.chat]
                    )
                }
                if trustSender, let info = message.senderInfo {
                    try Self.upsertContact(db, pubkey: row.chat, alias: info.alias, photoURL: info.photoURL)
                    // Someone who joined with one of our invites adds us with its code.
                    if row.type == MessageType.contactKey, !row.fromMe, let code = info.code {
                        try Self.markInviteUsed(code: code, by: row.chat, db)
                    }
                }
            }
            // After every message of the batch, so a delete finds its target
            // even when both came in the same history page.
            // Our own delete only once the server has it (its echo, the
            // tribe's copy, or a delivered status below), so a delete that
            // fails to send leaves the message as everyone else still sees it.
            for (message, _, _) in commit.messages
            where message.type == MessageType.delete && !(message.fromMe && message.serverIndex == nil) {
                if let deleted = try Self.applyDelete(message, purged: &applied.purged, in: db) { applied.stored.append(deleted) }
            }
            for record in commit.payments {
                try record.upsert(db)
            }
            applied.confirmed = try Self.reconcile(commit.payments, db)
            for invoice in commit.invoices {
                try Self.insert(invoice, db)
            }
            for invite in commit.invites {
                try invite.insert(db)
            }
            for (rhash, forHash) in commit.pings {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO paymentPing (rhash, forHash) VALUES (?, ?)", arguments: [rhash, forHash]
                )
            }
            for (tag, status) in commit.statuses {
                if let delivery = Message.Delivery(rawValue: status) {
                    try Self.applyStatus(db, delivery, tag: tag, error: commit.sendErrors[tag])
                }
                if status == Message.Delivery.delivered.rawValue,
                   let delete = try Message.fetchOne(
                       db, sql: "SELECT * FROM message WHERE tag = ? AND fromMe = 1 AND type = ?",
                       arguments: [tag, MessageType.delete]
                   ),
                   let deleted = try Self.applyDelete(delete, purged: &applied.purged, in: db) {
                    applied.stored.append(deleted)
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
            applied.newMoney = !fresh.isEmpty
            applied.announceable = try fresh.filter { try Self.isMoneyForMe($0, db) }.compactMap(\.id)
            // Their history row may be stored already, fetched before the message came.
            for row in fresh {
                if let index = row.serverIndex { applied.confirmed += try Self.markArrived(index: index, db) }
            }
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
                            status = ?, timestamp = ?, firstSentAt = COALESCE(firstSentAt, timestamp),
                            autoResentAt = COALESCE(?, autoResentAt)
                        WHERE id = ? AND chat = ? AND fromMe = 1 AND deleted = 0
                            AND type IN (\(MessageType.sqlList(MessageType.resendable + MessageType.payments)))
                            AND (status = ? OR (status = ? AND type IN (\(MessageType.sqlList(MessageType.resendable)))))
                        RETURNING *
                        """,
                    arguments: [
                        resend.uuid, resend.tag, resend.paymentHash, resend.paymentHash, Message.Delivery.pending.rawValue,
                        resend.timestamp, resend.auto ? resend.timestamp : nil,
                        resend.id, resend.chat,
                        Message.Delivery.failed.rawValue, Message.Delivery.pending.rawValue,
                    ]
                )
                if let row { applied.stored.append(row) }
            }
            return applied
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
                     mentionsMe, replyUUID, threadUUID, mediaType, fileName, fileSize, upload, amountMsat, noWords)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    -- Goes with the content kept.
                    noWords = CASE WHEN message.content IS NULL AND NOT message.deleted THEN excluded.noWords
                        ELSE message.noWords END,
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
                message.hasNoWords,
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

    /// What a page of the server's history settles. Someone else's payment
    /// or boost whose incoming row it has arrived: the message the row names
    /// by index, the one the server delivered with those sats; a row with no
    /// index only a message with none, by payment hash (every delivered
    /// message has an index, so a hash a message claims never stands in for
    /// it). A money send of ours still pending,
    /// unsettled or failed whose outgoing row it has with no error went
    /// through; one still pending or unsettled whose only rows failed,
    /// failed (the server put the sats back). Our rows from a restore carry
    /// no payment hash; those go by their tag (`Engine.checkPendingSends`).
    /// Returns the payments now known to have arrived.
    static func reconcile(_ page: [PaymentRecord], _ db: Database) throws -> [Message] {
        let payments = MessageType.sqlList(MessageType.payments)
        let sends = MessageType.sqlList(MessageType.moneySends)
        var arrived: [Message] = []
        for row in page where row.incoming && !row.failed {
            if let index = row.msgIndex {
                arrived += try markArrived(index: index, db)
            } else {
                // A row with no index vouches only for a message with none.
                arrived += try Message.fetchAll(
                    db,
                    sql: """
                        UPDATE message SET arrived = 1
                        WHERE paymentHash = ? AND serverIndex IS NULL
                            AND type IN (\(payments)) AND fromMe = 0 AND msat > 0 AND arrived IS NOT 1
                        RETURNING *
                        """,
                    arguments: [row.rhash]
                )
            }
        }
        for row in page where !row.incoming {
            if row.failed {
                try db.execute(
                    sql: """
                        UPDATE message SET status = 'FAILED'
                        WHERE paymentHash = ?1 AND fromMe = 1 AND type IN (\(sends)) AND status IN ('PENDING', 'UNSETTLED')
                            AND NOT EXISTS (SELECT 1 FROM payment
                                WHERE rhash = ?1 AND incoming = 0 AND IFNULL(error, '') = '')
                        """,
                    arguments: [row.rhash]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE message SET status = 'COMPLETE'
                        WHERE paymentHash = ? AND fromMe = 1 AND type IN (\(sends))
                            AND status IN ('PENDING', 'UNSETTLED', 'FAILED')
                        """,
                    arguments: [row.rhash]
                )
            }
        }
        return arrived
    }

    /// Someone else's payment or boost with sats that the server delivered
    /// at `index`, marked arrived: an incoming history row names it.
    private static func markArrived(index: Int64, _ db: Database) throws -> [Message] {
        try Message.fetchAll(
            db,
            sql: """
                UPDATE message SET arrived = 1
                WHERE serverIndex = ?1 AND type IN (\(MessageType.sqlList(MessageType.payments)))
                    AND fromMe = 0 AND msat > 0 AND arrived IS NOT 1
                    AND EXISTS (SELECT 1 FROM payment WHERE msgIndex = ?1 AND incoming = 1 AND IFNULL(error, '') = '')
                RETURNING *
                """,
            arguments: [index]
        )
    }

    /// Someone else's payments and boosts with sats, stored by row
    /// `storedThrough`, sent at or after `since` (the oldest time a history
    /// fetch reached, so their row would be in it), that the history has no
    /// incoming row for: the message came, the sats did not (payments
    /// review F2: a payment the server redeemed but could not pay). A row
    /// that turns up later still marks it arrived (`reconcile`).
    func markNotArrived(storedThrough id: Int64, since: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE message SET arrived = 0
                    WHERE type IN (\(MessageType.sqlList(MessageType.payments))) AND timestamp >= ? AND id <= ?
                        AND fromMe = 0 AND msat > 0 AND arrived IS NULL
                        AND NOT EXISTS (SELECT 1 FROM payment p WHERE p.incoming = 1 AND IFNULL(p.error, '') = ''
                            AND (p.msgIndex = message.serverIndex
                                OR (message.serverIndex IS NULL AND p.rhash = message.paymentHash)))
                    """,
                arguments: [since, id]
            )
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
        try pool.write { db in try Self.applyStatus(db, status, tag: tag, error: error) }
    }

    /// The one rule for every send tracked by tag: a status only moves
    /// forward. An unconfirmed send becomes delivered, unsettled or failed,
    /// an unsettled one delivered or failed, a failed one delivered (the
    /// server had it after all), and a delivered one never changes. So a late
    /// or synthesised failure can never make a payment that went through
    /// retryable. These are the statuses a row may be in to move to `status`.
    private static func statuses(movingTo status: Message.Delivery) -> [Message.Delivery] {
        switch status {
        case .pending: []
        case .unsettled: [.pending]
        case .failed: [.pending, .unsettled]
        case .delivered: [.pending, .unsettled, .failed]
        }
    }

    /// An invite's status for its funding payment's: sending while it is on
    /// its way, ready once delivered, failed. An unsettled funding payment
    /// is still on its way (Q2, 2026-10-08): the invite stays sending and
    /// the server is asked about it on every connect, so it has no status
    /// of its own here.
    private static func inviteStatus(_ funding: Message.Delivery) -> InviteRecord.Status? {
        switch funding {
        case .pending: .sending
        case .delivered: .ready
        case .failed: .failed
        case .unsettled: nil
        }
    }

    /// Moves the send with `tag` by the one forward-only rule
    /// (`statuses(movingTo:)`), in whichever of the three tables tracks it:
    /// our message, the invoice we pay, or the invite the payment funds.
    /// Only a message that moves sats (`MessageType.moneySends`) can be
    /// unsettled; an invoice we pay can too (held: it is never paid again
    /// until it settles or fails), and it keeps the server's reason for a
    /// failure. An invite is never unsettled (`inviteStatus`), and once
    /// ready, cancelled or used no funding status moves it.
    private static func applyStatus(_ db: Database, _ status: Message.Delivery, tag: String, error: String?) throws {
        let from = statuses(movingTo: status)
        guard !from.isEmpty else { return }
        let fromSQL = from.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let onlyMoney = status == .unsettled ? "AND type IN (\(MessageType.sqlList(MessageType.moneySends)))" : ""
        try db.execute(
            sql: """
                UPDATE message SET status = :status
                WHERE tag = :tag AND (status IS NULL OR status IN (\(fromSQL))) \(onlyMoney)
                """,
            arguments: ["status": status.rawValue, "tag": tag]
        )
        try db.execute(
            sql: """
                UPDATE invoice SET status = :status,
                    paidAt = CASE WHEN :status = 'COMPLETE' THEN COALESCE(paidAt, :now) ELSE paidAt END,
                    error = CASE WHEN :status = 'FAILED' THEN COALESCE(:error, error)
                        WHEN :status = 'COMPLETE' THEN NULL ELSE error END
                WHERE tag = :tag AND incoming = 0 AND status IN (\(fromSQL))
                """,
            arguments: ["status": status.rawValue, "tag": tag, "now": Date().millisecondsSince1970, "error": error]
        )
        if let next = inviteStatus(status) {
            let fromInvite = from.compactMap(inviteStatus).map { "'\($0.rawValue)'" }.joined(separator: ", ")
            try db.execute(
                sql: "UPDATE invite SET status = :next WHERE tag = :tag AND status IN (\(fromInvite))",
                arguments: ["next": next.rawValue, "tag": tag]
            )
        }
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

    /// The version of `Message.hasNoWords` that `markNoWords` checks stored
    /// messages by; raise it when that rule changes.
    static let noWordsVersion = "1"

    /// Sets `noWords` on the stored messages, once per `noWordsVersion`
    /// (`Setting.noWordsScan`): rows stored before v17, or by an older rule.
    /// One pass over the table in chunks, each its own transaction, in which
    /// SQLite hands over only the rows that could have no words: calls, and
    /// text whose content, past ASCII spaces, is empty or starts beyond
    /// ASCII (any other ASCII character is a word); and those marked now.
    /// A deleted row keeps what it had: its content is gone.
    func markNoWords(chunk: Int = 500) throws {
        guard try value(for: .noWordsScan) != Self.noWordsVersion else { return }
        try inChunks(of: chunk) { db, after in
            try Row.fetchAll(
                db, sql: """
                    SELECT id, type, content, noWords FROM message
                    WHERE id > ? AND deleted = 0 AND (noWords = 1 OR type = \(MessageType.call)
                        OR (type = \(MessageType.text)
                            AND IFNULL(unicode(ltrim(content, char(9, 10, 11, 12, 13, 32))), 128) >= 128))
                    ORDER BY id LIMIT ?
                    """,
                arguments: [after, chunk]
            )
        } update: { db, row in
            let noWords = Message.hasNoWords(type: row["type"], content: row["content"])
            if noWords != row["noWords"] {
                try db.execute(sql: "UPDATE message SET noWords = ? WHERE id = ?", arguments: [noWords, row["id"] as Int64])
            }
        }
        try set(Self.noWordsVersion, for: .noWordsScan)
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

    private static func markInviteUsed(code: String, by pubkey: String, _ db: Database) throws {
        let pending = InviteRecord.pendingStatuses.map(\.rawValue)
        try db.execute(
            sql: """
                UPDATE invite SET status = ?, usedBy = ?
                WHERE code = ? AND status IN (\(databaseQuestionMarks(count: pending.count)))
                """,
            arguments: StatementArguments([InviteRecord.Status.used.rawValue, pubkey, code.lowercased()] + pending)
        )
    }

    /// Moves an invite from one of `from` to `status`; false when it was in none.
    func setInviteStatus(code: String, to status: InviteRecord.Status, from: [InviteRecord.Status]) throws -> Bool {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE invite SET status = ? WHERE code = ? AND status IN (\(databaseQuestionMarks(count: from.count)))",
                arguments: StatementArguments([status.rawValue, code] + from.map(\.rawValue))
            )
            return db.changesCount > 0
        }
    }

    /// The contact's chat was opened: no longer new. False if it was not.
    func clearNewContact(_ pubkey: String) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "UPDATE contact SET isNew = 0 WHERE pubkey = ? AND isNew = 1", arguments: [pubkey])
            return db.changesCount > 0
        }
    }

    func upsertContact(pubkey: String, alias: String?) throws {
        try pool.write { db in try Self.upsertContact(db, pubkey: pubkey, alias: alias, photoURL: nil) }
    }

    /// Removes a contact and their chat in one transaction: the core's
    /// `c/` entry, every message in the chat, the contact row, the read
    /// marker and mute level, and the time zone switch. The money tables
    /// (payments, invoices, pings, invites) stay: they are history, and
    /// what is still settling keeps its record. Returns the removed
    /// attachments, so their files can go too.
    func deleteContact(_ pubkey: String) throws -> [Message] {
        try pool.write { db in
            let attachments = try Message.fetchAll(
                db, sql: "SELECT * FROM message WHERE chat = ? AND type = ?", arguments: [pubkey, MessageType.attachment]
            )
            try CoreStateRow.deleteAll(db, keys: ["c/\(pubkey)"])
            for table in ["message", "chatState", "chatTimeZone"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE chat = ?", arguments: [pubkey])
            }
            try db.execute(sql: "DELETE FROM contact WHERE pubkey = ?", arguments: [pubkey])
            return attachments
        }
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
