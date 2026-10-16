import Darwin
import Foundation
import PeelCore

/// This Mac's memory graph set aside so the home server's can be brought
/// back in its place (`docs/peel-brain.md`, "Move, not sync"): while a home
/// server is in use its memory is the truth and this Mac's only goes stale,
/// and strut's `memory/import` loads only into an empty graph. The graph's
/// files (`graph.lbug` and every `graph.lbug.…` beside it, its write-ahead
/// log among them) are renamed, never copied or deleted, into `backups` in
/// the same owner-only folder as `graph-<time>.lbug…`, and renamed back if
/// bringing the memory back fails. The newest `kept` sets stay.
/// Only regular files are moved, never through a link, and never onto a
/// file already there.
public struct MemoryBackup: Sendable, Equatable {
    /// strut's memory folder (`BundledStrut.memoryFolder`).
    public let folder: URL
    /// The graph's files set aside, by their names in `folder`; none when
    /// this Mac had no memory.
    public let names: [String]
    /// The time in their names in `backups`.
    let stamp: String

    /// How many sets `prune` keeps.
    public static let kept = 3

    /// Whether anything was set aside.
    public var isEmpty: Bool { names.isEmpty }

    /// Where the sets are kept.
    public static func backups(in folder: URL) -> URL { folder.appending(path: "backups") }

    /// The name `name` has in `backups`: `graph.lbug.wal` as `graph-<stamp>.lbug.wal`.
    func keptName(_ name: String) -> String { "graph-\(stamp)" + name.dropFirst("graph".count) }

    /// Moves this Mac's graph files in `folder` into `backups`, with strut
    /// stopped: a set with none when there are none. Either every file is
    /// moved or, having put back what was, it throws.
    public static func setAside(in folder: URL, at date: Date = .now) throws -> MemoryBackup {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.omitted).timeSeparator(.omitted).timeZoneSeparator(.omitted))
        guard kind(folder) != nil else { return MemoryBackup(folder: folder, names: [], stamp: stamp) }
        guard kind(folder) == .typeDirectory else { throw unexpected }
        let names = try graphFiles(in: folder)
        let backup = MemoryBackup(folder: folder, names: names, stamp: stamp)
        guard !names.isEmpty else { return backup }
        let backups = try ownerOnlyFolder(backups(in: folder))
        var moved: [String] = []
        do {
            for name in names {
                try rename(folder.appending(path: name), to: backups.appending(path: backup.keptName(name)))
                moved.append(name)
            }
        } catch {
            for name in moved { try? rename(backups.appending(path: backup.keptName(name)), to: folder.appending(path: name)) }
            throw error
        }
        return backup
    }

    /// Puts the set back as it was, in place of the graph strut made since
    /// (with strut stopped): that one is removed. Nothing is done once it is
    /// back, so a second call is harmless.
    public func restore() throws {
        let backups = Self.backups(in: folder)
        guard names.allSatisfy({ Self.kind(backups.appending(path: keptName($0))) == .typeRegular }) else {
            // Already back, or never set aside.
            guard names.allSatisfy({ Self.kind(folder.appending(path: $0)) == .typeRegular }) else { throw Self.unexpected }
            return
        }
        for name in try Self.graphFiles(in: folder) { try FileManager.default.removeItem(at: folder.appending(path: name)) }
        for name in names { try Self.rename(backups.appending(path: keptName(name)), to: folder.appending(path: name)) }
    }

    /// Removes all but the newest `keeping` sets in `backups`; only regular
    /// files named as `setAside` names them.
    public static func prune(in folder: URL, keeping: Int = kept) throws {
        let backups = backups(in: folder)
        guard kind(backups) == .typeDirectory else { return }
        let sets = Dictionary(grouping: try FileManager.default.contentsOfDirectory(atPath: backups.path).compactMap { name in
            stamp(of: name).map { (stamp: $0, name: name) }
        }, by: \.stamp)
        for stamp in sets.keys.sorted(by: >).dropFirst(keeping) {
            for file in sets[stamp] ?? [] where kind(backups.appending(path: file.name)) == .typeRegular {
                try FileManager.default.removeItem(at: backups.appending(path: file.name))
            }
        }
    }

    /// The stamp in a kept name, `graph-<stamp>.lbug…`.
    static func stamp(of name: String) -> String? {
        guard name.hasPrefix("graph-"), let end = name.range(of: ".lbug") else { return nil }
        let rest = name[end.upperBound...]
        guard rest.isEmpty || rest.hasPrefix(".") else { return nil }
        let stamp = name[name.index(name.startIndex, offsetBy: "graph-".count)..<end.lowerBound]
        return stamp.isEmpty || stamp.contains(".") ? nil : String(stamp)
    }

    /// `graph.lbug` and the `graph.lbug.…` beside it in `folder`, each a
    /// regular file (not a link).
    static func graphFiles(in folder: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0 == "graph.lbug" || $0.hasPrefix("graph.lbug.") }.sorted()
        guard names.allSatisfy({ kind(folder.appending(path: $0)) == .typeRegular }) else { throw unexpected }
        return names
    }

    /// `folder`, made owner-only if it is not there; a link or a file there is refused.
    static func ownerOnlyFolder(_ folder: URL) throws -> URL {
        if kind(folder) == nil {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard kind(folder) == .typeDirectory else { throw unexpected }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder
    }

    /// A rename on this disk that never replaces what is at `to`.
    static func rename(_ from: URL, to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            throw PeelError("Peel could not set this Mac's memory aside (\(String(cString: strerror(errno)))).")
        }
    }

    /// What is at `url` itself, a link not followed; nil when nothing is.
    static func kind(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    static let unexpected = PeelError("This Mac's memory files are not as Peel left them, so nothing was changed.")
}
