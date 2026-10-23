import Foundation
import GRDB

/// One dictation, as the Mac's Dictation History lists it (`dictation`,
/// v28; docs/dictation.md, "History"): what was said, where
/// it was said, and where the text went. Kept in the account's own database,
/// so it goes with the account, and only while history is on.
public struct DictationRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictation"

    /// Where the text went.
    public enum Outcome: String, Codable, Sendable {
        /// Typed into the field that had focus.
        case typed
        /// Left on the clipboard: no field, the focus moved, or no Accessibility.
        case copied
        /// A password field or secure entry: nothing typed or kept, no text here.
        case blocked
        /// No text: the strut failed, or nothing was heard.
        case failed
    }

    /// `DictationSession.id`.
    public var id: UUID
    /// When the key went down, milliseconds since 1970.
    public var startedAt: Int64
    /// The recording's length, in seconds.
    public var duration: Double
    /// What was typed or copied; nil when blocked or failed.
    public var text: String?
    /// The app dictated into: its bundle id and name, never its window title.
    public var appID: String?
    public var appName: String?
    public var outcome: Outcome
    /// Why, in Peel's words, when it was not typed ("No field had focus").
    public var note: String?

    public init(
        id: UUID, startedAt: Date, duration: TimeInterval, text: String?, appID: String?, appName: String?,
        outcome: Outcome, note: String?
    ) {
        self.id = id
        self.startedAt = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
        self.duration = duration
        self.text = text
        self.appID = appID
        self.appName = appName
        self.outcome = outcome
        self.note = note
    }

    public var date: Date { Date(timeIntervalSince1970: Double(startedAt) / 1000) }
}

extension Storage {
    /// Keeps `record`, and drops what is older than `keep`.
    public func addDictation(_ record: DictationRecord, keep: TimeInterval) async throws {
        try await pool.write { db in
            try record.insert(db)
            try Self.dropDictations(db, olderThan: keep)
        }
    }

    /// Drops what is older than `keep`, as each new one is kept and when
    /// History is looked at: nothing stays past its keep time unseen.
    public func dropDictations(olderThan keep: TimeInterval) async throws {
        try await pool.write { db in try Self.dropDictations(db, olderThan: keep) }
    }

    private static func dropDictations(_ db: Database, olderThan keep: TimeInterval) throws {
        let cutoff = Int64(((Date().timeIntervalSince1970 - keep) * 1000).rounded())
        try db.execute(sql: "DELETE FROM dictation WHERE startedAt < ?", arguments: [cutoff])
    }

    /// The newest `limit` dictations, newest first, again whenever they change.
    public func dictations(limit: Int) -> some AsyncSequence<[DictationRecord], any Error> {
        ValueObservation
            .trackingConstantRegion { db in
                try DictationRecord.order(Column("startedAt").desc).limit(limit).fetchAll(db)
            }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Clear History: every dictation gone, its text overwritten in the
    /// file rather than left in freed pages, and the log folded in.
    public func clearDictations() async throws {
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            defer { try? db.execute(sql: "PRAGMA secure_delete = OFF") }
            try db.inTransaction {
                _ = try DictationRecord.deleteAll(db)
                return .commit
            }
            try db.checkpoint(.truncate)
        }
    }
}
