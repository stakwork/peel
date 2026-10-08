import Foundation
import GRDB

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
