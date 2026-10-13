import GRDB

// Migrations: append only, never edit a shipped one (as PeelCore's).

extension SQLiteAgentStore {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // The log: each event's stable JSON, with its stamp for ordering.
            try db.create(table: "event") { t in
                t.primaryKey("event_id", .text)
                t.column("ref_id", .text).notNull().indexed()
                t.column("wall_ms", .integer).notNull()
                t.column("counter", .integer).notNull()
                t.column("device", .text).notNull()
                t.column("json", .text).notNull()
            }
            // Built from the log. A row an update reached before its add has
            // no type or name yet; reads skip it until the add arrives.
            // `id` keys the search index: a rowid that VACUUM never renumbers.
            try db.create(table: "record") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ref_id", .text).notNull().unique()
                t.column("type", .text).indexed()
                t.column("name", .text)
                t.column("body", .text)
                t.column("props", .text).notNull().defaults(to: "{}")
                t.column("created_by", .text)
                t.column("source", .text)
                t.column("created_ms", .integer)
                t.column("updated_ms", .integer)
                t.column("deleted_ms", .integer)
            }
            try db.create(table: "link") { t in
                t.primaryKey("ref_id", .text)
                t.column("type", .text).indexed()
                t.column("from_ref", .text).indexed()
                t.column("to_ref", .text).indexed()
                t.column("props", .text).notNull().defaults(to: "{}")
                t.column("created_by", .text)
                t.column("created_ms", .integer)
                t.column("deleted_ms", .integer)
            }
            // The stamp of the value each field holds (see SQLiteAgentStore).
            try db.create(table: "field_clock") { t in
                t.column("ref_id", .text).notNull()
                t.column("field", .text).notNull()
                t.column("wall_ms", .integer).notNull()
                t.column("counter", .integer).notNull()
                t.column("device", .text).notNull()
                t.column("event_id", .text).notNull()
                t.primaryKey(["ref_id", "field"])
            }
            // Search over names and bodies, kept by triggers.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE record_text USING fts5(
                    name, body, content = 'record', content_rowid = 'id', tokenize = 'unicode61 remove_diacritics 2');
                CREATE TRIGGER record_text_insert AFTER INSERT ON record BEGIN
                    INSERT INTO record_text (rowid, name, body) VALUES (new.id, new.name, new.body);
                END;
                CREATE TRIGGER record_text_delete AFTER DELETE ON record BEGIN
                    INSERT INTO record_text (record_text, rowid, name, body)
                        VALUES ('delete', old.id, old.name, old.body);
                END;
                CREATE TRIGGER record_text_update AFTER UPDATE OF name, body ON record BEGIN
                    INSERT INTO record_text (record_text, rowid, name, body)
                        VALUES ('delete', old.id, old.name, old.body);
                    INSERT INTO record_text (rowid, name, body) VALUES (new.id, new.name, new.body);
                END;
                """)
        }
        return migrator
    }
}
