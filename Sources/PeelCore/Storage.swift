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

struct SettingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"
    var key: String
    var value: String
}

// MARK: - Settings and core state

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

    /// Internal: the app and the CLI change settings through `Engine`.
    func set(_ value: String, for setting: Setting) throws {
        try pool.write { db in try SettingRow(key: setting.rawValue, value: value).upsert(db) }
    }
}
