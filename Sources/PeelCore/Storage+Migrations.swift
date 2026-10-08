import GRDB

// Migrations. Real accounts have already run every shipped one, so:
//
// - Append only. Add a new `vN` at the end; never edit, reorder, rename or
//   remove a shipped migration.
// - Literals only. A migration must not read live Swift constants
//   (`MessageType`, `Tribe.Status`, status strings): if one changes, old and
//   new databases would end up with different indexes or backfills. Write the
//   value and name the constant in a comment.
// - One test per data backfill, plus the whole chain in `MigrationTests`.

extension Storage {
    static var migrator: DatabaseMigrator {
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
                t.add(column: "status", .integer).notNull().defaults(to: 0) // Tribe.Status.active
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
        migrator.registerMigration("v11") { db in
            // Payments and boosts: the msat each stands for. Rows stored
            // before take what reached this account, else what was declared.
            try db.alter(table: "message") { t in
                t.add(column: "amountMsat", .integer)
            }
            // 29 is MessageType.boost; 5, 29 is MessageType.payments.
            try db.execute(sql: """
                UPDATE message SET amountMsat = COALESCE(msat, CASE
                    WHEN json_valid(body) AND json_type(body, '$.amount') = 'integer'
                        AND (fromMe = 1 OR (type = 29 AND chat IN (SELECT pubkey FROM tribe)))
                    THEN json_extract(body, '$.amount') END)
                WHERE type IN (5, 29);
                CREATE INDEX message_payment ON message (timestamp)
                    WHERE type IN (5, 29);
                CREATE INDEX message_pending ON message (id)
                    WHERE fromMe = 1 AND status = 'PENDING' AND tag IS NOT NULL;
                """)
        }
        migrator.registerMigration("v12") { db in
            // A read marker moved here and not yet sent (`ReadPending`).
            try db.alter(table: "chatState") { t in
                t.add(column: "readPending", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v13") { db in
            // The server's payment history, as `fetch_payments` pages it in.
            try db.create(table: "payment") { t in
                t.column("rhash", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("amountMsat", .integer).notNull()
                t.column("incoming", .boolean).notNull()
                t.column("msgIndex", .integer)
                t.column("remote", .boolean).notNull().defaults(to: false)
                t.column("error", .text)
                t.primaryKey(["rhash", "incoming", "ts"])
            }
            try db.create(index: "payment_ts", on: "payment", columns: ["ts"])
            // Invoices this account made (to receive, or to request in a
            // chat) and paid; an outgoing one is tracked by its send's tag.
            try db.create(table: "invoice") { t in
                t.column("paymentHash", .text).notNull()
                t.column("incoming", .boolean).notNull()
                t.column("bolt11", .text).notNull()
                t.column("amountMsat", .integer).notNull()
                t.column("memo", .text).notNull().defaults(to: "")
                t.column("payee", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("expiresAt", .integer)
                t.column("status", .text).notNull()
                t.column("paidAt", .integer)
                t.column("paidMsat", .integer)
                t.column("tag", .text)
                t.column("chat", .text)
                t.column("error", .text)
                t.primaryKey(["paymentHash", "incoming"])
            }
            // The 1-sat ping that goes with a payment sent the asynchronous
            // way (`asyncpay`), by its payment hash: part of that payment's
            // cost, not a payment of its own.
            try db.create(table: "paymentPing") { t in
                t.primaryKey("rhash", .text)
                t.column("forHash", .text).notNull()
            }
            // 5, 29, 7, 9, 3 is MessageType.moneySends + [invoicePayment];
            // 7, 8, 9 is purchase, purchaseAccept, purchaseDeny.
            try db.execute(sql: """
                CREATE INDEX invoice_tag ON invoice (tag) WHERE tag IS NOT NULL;
                CREATE INDEX payment_msgIndex ON payment (msgIndex) WHERE msgIndex IS NOT NULL;
                CREATE INDEX message_money ON message (timestamp)
                    WHERE type IN (5, 29, 7, 9, 3);
                CREATE INDEX message_purchase ON message (chat)
                    WHERE type IN (7, 8, 9);
                CREATE INDEX message_paymentHash ON message (paymentHash) WHERE paymentHash IS NOT NULL;
                """)
        }
        migrator.registerMigration("v14") { db in
            // Time zones: the `tz` a message's sender put in its `metadata`,
            // as sent (readers parse it), worked out from the body, so stored
            // history has it and a delete (which empties the body) clears it.
            // `metadata` is whatever the sender wrote, so the guards run in
            // order and a malformed value gives NULL rather than an error.
            try db.execute(sql: """
                ALTER TABLE message ADD COLUMN senderTZ TEXT GENERATED ALWAYS AS (CASE
                    WHEN body IS NULL OR body NOT LIKE '%metadata%' OR NOT json_valid(body) THEN NULL
                    WHEN json_type(body, '$.metadata') IS NOT 'text' THEN NULL
                    WHEN NOT json_valid(json_extract(body, '$.metadata')) THEN NULL
                    WHEN json_type(json_extract(body, '$.metadata'), '$.tz') IS NOT 'text' THEN NULL
                    WHEN length(json_extract(json_extract(body, '$.metadata'), '$.tz')) BETWEEN 1 AND 64
                    THEN json_extract(json_extract(body, '$.metadata'), '$.tz') END) VIRTUAL;
                CREATE INDEX message_senderTZ ON message (chat, timestamp) WHERE senderTZ IS NOT NULL AND fromMe = 0;
                """)
            // Whether this account shares its own in each chat, in the shape
            // of the official apps' preferences item `timezone`.
            try db.create(table: "chatTimeZone") { t in
                t.primaryKey("chat", .text)
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("identifier", .text)
                t.column("updatedAt", .integer).notNull()
            }
        }
        migrator.registerMigration("v15") { db in
            // A tribe's web app and second brain (`app_url`, `second_brain_url`).
            try db.alter(table: "tribe") { t in
                t.add(column: "appURL", .text)
                t.add(column: "secondBrainURL", .text)
            }
        }
        migrator.registerMigration("v16") { db in
            // Invites made here with sats: the core keeps no record of them
            // and the server only the code. `tag` is the funding payment's,
            // which the server confirms; status as `InviteRecord.Status`.
            try db.create(table: "invite") { t in
                t.primaryKey("code", .text)
                t.column("link", .text).notNull()
                t.column("amountMsat", .integer).notNull()
                t.column("nickname", .text)
                t.column("message", .text)
                t.column("tag", .text)
                t.column("status", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("usedBy", .text)
            }
            try db.execute(sql: "CREATE INDEX invite_tag ON invite (tag) WHERE tag IS NOT NULL")
            // Someone who added this account, until their chat is opened here.
            try db.alter(table: "contact") { t in
                t.add(column: "isNew", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v17") { db in
            // A text or call with no words (`Message.hasNoWords`), which the
            // list hides, so counts and previews leave it out too. Set when
            // stored; `Storage.markNoWords` fills it in for rows stored before.
            // `message_unread` takes the column, so unread counts read it
            // from the index rather than from each row.
            try db.execute(sql: """
                ALTER TABLE message ADD COLUMN noWords BOOLEAN NOT NULL DEFAULT 0;
                DROP INDEX message_unread;
                CREATE INDEX message_unread ON message (chat, fromMe, type, serverIndex, noWords);
                """)
        }
        return migrator
    }
}
