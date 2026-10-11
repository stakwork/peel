import Foundation
import GRDB
import Synchronization

/// `AgentStore` in SQLite through GRDB. The `event` table is the log,
/// append-only; `record` and `link` are built by applying it and can be
/// rebuilt from it (`rebuild`).
///
/// Last write wins per field: `field_clock` keeps, for each ref_id and
/// field (`name`, `body`, `deleted_ms`, `props.<key>`, …), the stamp and
/// event_id of the value now in the table. An event's value replaces it
/// only if its (stamp, event_id) is greater, so the tables end the same
/// whatever order the events arrive in.
public final class SQLiteAgentStore: AgentStore {
    public let device: String
    let db: any DatabaseWriter
    private let clock: Mutex<HLC>
    private let now: @Sendable () -> Int64

    /// The store in the SQLite file at `path`.
    public convenience init(path: String, device: String) throws {
        try self.init(db: DatabasePool(path: path), device: device)
    }

    /// A store in memory, gone when released.
    public static func inMemory(
        device: String, now: @escaping @Sendable () -> Int64 = wallClock
    ) throws -> SQLiteAgentStore {
        try SQLiteAgentStore(db: DatabaseQueue(), device: device, now: now)
    }

    init(db: any DatabaseWriter, device: String, now: @escaping @Sendable () -> Int64 = wallClock) throws {
        self.db = db
        self.device = device
        self.now = now
        try Self.migrator.migrate(db)
        // The clock starts past every stamp in the log, so a wall clock set
        // back while closed still stamps later events after earlier ones.
        var start = HLC(wallMs: 0, device: device)
        if let latest = try db.read({ try Self.events($0, sql: "ORDER BY wall_ms DESC, counter DESC LIMIT 1") }).first {
            start.receive(latest.ts, now: now())
        }
        clock = Mutex(start)
    }

    public static let wallClock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    public func stamp() -> HLC {
        let now = now()
        return clock.withLock { $0.tick(now: now) }
    }

    @discardableResult
    public func write(_ event: Event) throws -> Bool {
        guard event.v <= Event.version else { throw AgentStoreError.unsupportedVersion(event.v) }
        guard !event.eventId.isEmpty, !event.refId.isEmpty, event.device == event.ts.device else {
            throw AgentStoreError.malformedEvent
        }
        if event.ts.device != device {
            let now = now()
            clock.withLock { $0.receive(event.ts, now: now) }
        }
        let json = try StableJSON.string(event)
        return try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO event (event_id, ref_id, wall_ms, counter, device, json)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [event.eventId, event.refId, event.ts.wallMs, event.ts.counter, event.ts.device, json])
            guard db.changesCount > 0 else { return false }
            try Self.apply(event, db)
            return true
        }
    }

    /// Every event in the log, oldest stamp first.
    public func events() throws -> [Event] {
        try db.read { try Self.events($0) }
    }

    /// Builds `record` and `link` again from the event log.
    public func rebuild() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM record; DELETE FROM link; DELETE FROM field_clock")
            for event in try Self.events(db) {
                try Self.apply(event, db)
            }
        }
    }

    private static func events(_ db: Database, sql: String = "ORDER BY wall_ms, counter, device, event_id") throws
        -> [Event] {
        try String.fetchAll(db, sql: "SELECT json FROM event " + sql).map { try Event.decode(Data($0.utf8)) }
    }
}

// MARK: - Applying an event

extension SQLiteAgentStore {
    private enum Table: String {
        case record, link

        /// Fields an event may set: the column each is kept in, and what it holds.
        var columns: [String: (name: String, kind: Kind)] {
            switch self {
            case .record: ["type": ("type", .text), "name": ("name", .text), "body": ("body", .optionalText),
                           "source": ("source", .optionalText), "created_by": ("created_by", .text),
                           "deleted_ms": ("deleted_ms", .optionalTime)]
            case .link: ["type": ("type", .text), "from": ("from_ref", .text), "to": ("to_ref", .text),
                         "created_by": ("created_by", .text), "deleted_ms": ("deleted_ms", .optionalTime)]
            }
        }
    }

    private enum Kind {
        case text, optionalText, optionalTime

        /// `value` as this column stores it; nil if it does not fit.
        func databaseValue(_ value: JSONValue) -> DatabaseValue? {
            switch (self, value) {
            case (.text, .string(let text)), (.optionalText, .string(let text)): text.databaseValue
            case (.optionalText, .null), (.optionalTime, .null): .null
            case (.optionalTime, .number(let ms)): Int64(exactly: ms)?.databaseValue
            default: nil
            }
        }
    }

    static func apply(_ event: Event, _ db: Database) throws {
        let table: Table = event.op == .link || event.op == .unlink ? .link : .record
        let wall = event.ts.wallMs
        try db.execute(sql: "INSERT OR IGNORE INTO \(table.rawValue) (ref_id) VALUES (?)", arguments: [event.refId])
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM \(table.rawValue) WHERE ref_id = ?", arguments: [event.refId]
        ) else { return }

        var changes: [String: DatabaseValue] = [:]
        if event.op == .add || event.op == .link {
            let created: Int64? = row["created_ms"]
            changes["created_ms"] = min(created ?? wall, wall).databaseValue
        }
        if table == .record {
            let updated: Int64? = row["updated_ms"]
            changes["updated_ms"] = max(updated ?? wall, wall).databaseValue
        }
        var props = Self.props(row["props"])
        var propsChanged = false
        for (field, value) in assignments(event) {
            if field.hasPrefix("props.") {
                guard try wins(event, field, db) else { continue }
                props[String(field.dropFirst("props.".count))] = value == .null ? nil : value
                propsChanged = true
            } else if let column = table.columns[field], let stored = column.kind.databaseValue(value),
                      try wins(event, field, db) {
                changes[column.name] = stored
            }
        }
        if propsChanged { changes["props"] = try StableJSON.string(props).databaseValue }

        let columns = changes.keys.sorted()
        guard !columns.isEmpty else { return }
        try db.execute(
            sql: "UPDATE \(table.rawValue) SET " + columns.map { "\($0) = ?" }.joined(separator: ", ")
                + " WHERE ref_id = ?",
            arguments: StatementArguments(columns.map { changes[$0]! } + [event.refId.databaseValue])
        )
    }

    /// The field values `event` sets: each top-level field, and each props
    /// key as `props.<key>`. `apply` leaves out an unknown field and one of
    /// the wrong JSON type (a number for a name, null for a type).
    private static func assignments(_ event: Event) -> [(String, JSONValue)] {
        switch event.op {
        case .forget, .unlink:
            return [("deleted_ms", .number(Double(event.ts.wallMs)))]
        case .add, .update, .link:
            return event.fields.flatMap { field, value -> [(String, JSONValue)] in
                guard field == "props" else { return [(field, value)] }
                guard case .object(let props) = value else { return [] }
                return props.map { ("props.\($0.key)", $0.value) }
            }
        }
    }

    /// Whether `event`'s value for `field` is newer than the one stored; if
    /// so, its stamp becomes the field's.
    private static func wins(_ event: Event, _ field: String, _ db: Database) throws -> Bool {
        if let row = try Row.fetchOne(
            db, sql: "SELECT wall_ms, counter, device, event_id FROM field_clock WHERE ref_id = ? AND field = ?",
            arguments: [event.refId, field]
        ) {
            let stored = HLC(wallMs: row["wall_ms"], counter: row["counter"], device: row["device"])
            let storedId: String = row["event_id"]
            guard (stored, storedId) < (event.ts, event.eventId) else { return false }
        }
        try db.execute(sql: """
            INSERT OR REPLACE INTO field_clock (ref_id, field, wall_ms, counter, device, event_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [event.refId, field, event.ts.wallMs, event.ts.counter, event.ts.device, event.eventId])
        return true
    }

    /// A props column read back; empty when missing or not an object.
    static func props(_ text: String?) -> [String: JSONValue] {
        guard let text, case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return [:] }
        return object
    }
}
