import AgentKit
import CryptoKit
import Foundation
import PeelCore

/// Moving the agent's memory between this Mac's strut and a home server
/// (`docs/peel-brain.md`, "Move, not sync"): strut's `memory/export` on one,
/// `memory/import` on the other, which loads into an empty graph (or, on a
/// home server, in place of its graph, which strut there backs up first),
/// then the rows counted on both. Nothing is deleted from where it came from.
/// The snapshot goes only to the two struts named, and is never logged.
public enum MemoryMove {
    /// Where a move is.
    public enum Step: Sendable, Equatable {
        case reading
        case sending
    }

    /// What arrived: rows per table, as the receiving strut counted them.
    public struct Moved: Sendable, Equatable {
        public let counts: [String: Int]

        public var facts: Int { counts["Fact"] ?? 0 }
        /// Whether it holds anything `memory/import` counts as memory.
        public var holdsMemory: Bool { ["Entity", "Fact", "Episode"].contains { (counts[$0] ?? 0) > 0 } }
    }

    /// The most `memory/import` takes as `data`, and an inline export gives.
    static let dataLimit = 100 * 1024 * 1024

    /// How a copy to the home server ended.
    public enum ToHomeServer: Sendable, Equatable {
        /// Copied; `replaced`: in place of memory the home server had, which
        /// strut kept first as a backup there.
        case copied(Moved, replaced: Bool)
        /// This Mac's memory was empty: nothing sent, and the home server's
        /// used as it is.
        case nothingToCopy
    }

    /// This Mac's memory to the home server, in place of any there (memory
    /// follows you: `docs/peel-brain.md`, "Reconnecting"): exported by
    /// `local` into its own folder (`folder`; `snapshotFile` says what Peel
    /// reads there), read, sent as `data` with `replace`, and the export's
    /// file deleted whatever happens.
    public static func toHomeServer(
        from local: MemoryServer, folder: URL, to home: MemoryServer,
        progress: @Sendable (Step) async -> Void = { _ in }
    ) async throws -> ToHomeServer {
        await progress(.reading)
        let export = try await worded(on: local) { try await local.run("export", [:], snapshot: true) }
        guard let path = export["path"]?.string else { throw PeelError("This Mac's strut wrote no memory snapshot.") }
        // Never read, or deleted, but a snapshot file in strut's own folder.
        guard let file = snapshotFile(path, in: folder) else {
            throw PeelError("This Mac's strut put its memory snapshot somewhere Peel does not read.")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard Moved(counts: counts(export["counts"])).holdsMemory else { return .nothingToCopy }
        guard let bytes = size(export["bytes"]), bytes <= dataLimit else {
            throw PeelError("This Mac's memory is over 100 MB, more than a home server takes in one piece.")
        }
        let encoded = try {
            let snapshot = try Data(contentsOf: file, options: .mappedIfSafe)
            try check(snapshot, against: export)
            return snapshot.base64EncodedData()
        }()
        await progress(.sending)
        let imported = try await worded(on: home) { try await home.importSnapshot(base64: encoded, replace: true) }
        return .copied(try matched(export, imported), replaced: imported["replaced"] == .bool(true))
    }

    /// The home server's memory in place of this Mac's: while a home server
    /// is in use its memory is the truth, and this Mac's copy only went
    /// stale. The home server's is read first, exported inline (no file kept
    /// there; over 100 MB strut refuses) and checked; if it holds nothing,
    /// nil and this Mac's is left alone. Otherwise Peel's strut, with its
    /// graph in `folder`, is stopped (`stop`), this Mac's graph set aside
    /// (`MemoryBackup`), the strut started on an empty one (`start`) and the
    /// snapshot loaded into it. The set aside is told to `holding` until it
    /// is settled, so a move cut short (Peel quitting) can still put it back.
    /// On any failure the strut is stopped and this Mac's graph put back as
    /// it was; on success the newest `MemoryBackup.kept` sets are kept.
    @MainActor
    public static func replacingThisMac(
        with home: MemoryServer, folder: URL,
        stop: () -> Void, start: () async throws -> MemoryServer,
        holding: (MemoryBackup?) -> Void = { _ in },
        progress: @Sendable (Step) async -> Void = { _ in }
    ) async throws -> (moved: Moved, backup: MemoryBackup)? {
        await progress(.reading)
        guard let (export, encoded) = try await snapshot(of: home) else { return nil }
        // Stopped before anything is touched (the account closed while strut started).
        try Task.checkCancellation()
        stop()
        let backup = try MemoryBackup.setAside(in: folder)
        holding(backup)
        defer { holding(nil) }
        do {
            let local = try await start()
            try Task.checkCancellation()
            await progress(.sending)
            let moved = try await load(encoded, export, into: local)
            // Stopped while the last reply came: put back, never kept.
            try Task.checkCancellation()
            // Old copies beyond the newest few; the one just made is among them.
            try? MemoryBackup.prune(in: folder)
            return (moved, backup)
        } catch {
            stop()
            let why = PeelError.problem(error)
            do {
                try backup.restore()
            } catch {
                throw PeelError("\(why) Peel could not put this Mac's own memory back; it is kept in \(MemoryBackup.backups(in: folder).path).")
            }
            throw PeelError(backup.isEmpty ? why : "\(why) This Mac's memory is as it was.")
        }
    }

    /// The home server's memory, exported inline and checked; nil when it
    /// holds nothing.
    private static func snapshot(of home: MemoryServer) async throws -> (export: AgentKit.JSONValue, encoded: Data)? {
        let reply = try await worded(on: home) { try await home.run("export", ["inline": true], snapshot: true) }
        guard case .object(var fields) = reply, case .string(let text)? = fields.removeValue(forKey: "data") else {
            throw PeelError("The home server's strut cannot send its memory yet. Update strut there and try again.")
        }
        let export = AgentKit.JSONValue.object(fields)
        guard Moved(counts: counts(export["counts"])).holdsMemory else { return nil }
        let encoded = Data(text.utf8)
        // The decoded snapshot is only for the check, and freed before the import.
        try {
            guard let snapshot = Data(base64Encoded: encoded) else { throw PeelError("The home server sent memory Peel cannot read.") }
            try check(snapshot, against: export)
        }()
        return (export, encoded)
    }

    /// `encoded` loaded into `local`, the rows that arrived checked against `export`.
    private static func load(_ encoded: Data, _ export: AgentKit.JSONValue, into local: MemoryServer) async throws -> Moved {
        try matched(export, try await worded(on: local) { try await local.importSnapshot(base64: encoded) })
    }

    /// The snapshot is the one the export described: its size and hash.
    static func check(_ snapshot: Data, against export: AgentKit.JSONValue) throws {
        let hash = SHA256.hash(data: snapshot).hex
        guard export["sha256"]?.string == hash, size(export["bytes"]) == snapshot.count else {
            throw PeelError("The memory snapshot changed on its way, so nothing was loaded.")
        }
    }

    /// The rows that arrived against the rows that left, table by table;
    /// the ontology is left out, since a newer strut seeds its own terms.
    static func matched(_ export: AgentKit.JSONValue, _ imported: AgentKit.JSONValue) throws -> Moved {
        let sent = counts(export["counts"])
        let arrived = counts(imported["counts"])
        guard !sent.isEmpty, sent.allSatisfy({ $0.key == "Ontology" || arrived[$0.key] == $0.value }) else {
            let facts = "\(arrived["Fact"] ?? 0) of \(sent["Fact"] ?? 0) facts"
            throw PeelError("The memory that arrived does not match what was sent (\(facts)). Where it came from is unchanged.")
        }
        return Moved(counts: arrived)
    }

    private static func counts(_ value: AgentKit.JSONValue?) -> [String: Int] {
        guard case .object(let fields)? = value else { return [:] }
        return fields.compactMapValues(size)
    }

    private static func size(_ value: AgentKit.JSONValue?) -> Int? {
        value?.int.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// The export `path` names, if it is what `memory/export` writes: an
    /// absolute path with no `.` or `..` in it, to a regular file (not a
    /// link) named `memory-….tar.gz` in a `snapshots` folder, inside
    /// `folder` once every link above it is resolved. Read and deleted only there.
    static func snapshotFile(_ path: String, in folder: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
              let name = parts.last, name.hasPrefix("memory-"), name.hasSuffix(".tar.gz"),
              parts.dropLast().last == "snapshots" else { return nil }
        let resolved = URL(filePath: path).deletingLastPathComponent().resolvingSymlinksInPath().appending(path: String(name))
        let root = folder.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
              let kind = try? FileManager.default.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType,
              kind == .typeRegular else { return nil }
        return resolved
    }

    /// Runs one step on `server`, with strut's refusals said for a person.
    private static func worded<T>(on server: MemoryServer, _ step: () async throws -> T) async throws -> T {
        do {
            return try await step()
        } catch let refusal as MemoryServer.Refusal {
            guard let words = words(code: refusal.code, onHomeServer: server.isHomeServer) else { throw refusal }
            throw PeelError(words)
        }
    }

    /// strut's refusal `code` from the strut on the home server or this Mac,
    /// in plain words; nil for anything else, which keeps its own words.
    static func words(code: String, onHomeServer: Bool) -> String? {
        let here = onHomeServer ? "The home server" : "This Mac"
        switch code {
        case "not_empty":
            // On the home server only from a strut without `replace` (strut#176).
            return onHomeServer
                ? "The home server's strut is too old to replace its memory, so nothing was copied. Update strut there and try again."
                : "This Mac already has memory, so nothing was brought back. Peel never overwrites it."
        case "backup_failed":
            return "\(here) could not save a backup of its own memory first, so nothing was copied and its memory is as it was."
        case "bad_snapshot":
            return "The memory snapshot was damaged or not one strut made, so nothing was loaded."
        case "newer_format":
            return onHomeServer
                ? "This Mac's memory comes from a newer strut than the home server's. Update the home server and try again."
                : "The home server's memory comes from a newer strut than Peel's. Update Peel and try again."
        case "too_large":
            return "The memory is over 100 MB, more than strut takes in one piece."
        case "invalid_input":
            return "strut did not take the memory as Peel sent it. Update Peel and strut, then try again."
        case "not_found":
            return "strut could not find the memory snapshot it was given."
        case "import_failed":
            return "\(here) could not load the memory."
        default:
            return nil
        }
    }
}
