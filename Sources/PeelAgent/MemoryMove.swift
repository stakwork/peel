import AgentKit
import CryptoKit
import Foundation
import PeelCore

/// Moving the agent's memory between this Mac's strut and a home server
/// (`docs/peel-brain.md`, "Move, not sync"): strut's `memory/export` on one,
/// `memory/import` on the other, which loads only into an empty graph, then
/// the rows counted on both. Nothing is deleted from where it came from.
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

    /// This Mac's memory to an empty home server: exported by `local` into
    /// its own folder (`folder`; `snapshotFile` says what Peel reads there),
    /// read, sent as `data`, and the export's file deleted whatever happens.
    public static func toHomeServer(
        from local: MemoryServer, folder: URL, to home: MemoryServer,
        progress: @Sendable (Step) async -> Void = { _ in }
    ) async throws -> Moved {
        await progress(.reading)
        let export = try await worded(on: local) { try await local.run("export", [:], snapshot: true) }
        guard let path = export["path"]?.string else { throw PeelError("This Mac's strut wrote no memory snapshot.") }
        // Never read, or deleted, but a snapshot file in strut's own folder.
        guard let file = snapshotFile(path, in: folder) else {
            throw PeelError("This Mac's strut put its memory snapshot somewhere Peel does not read.")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let bytes = size(export["bytes"]), bytes <= dataLimit else {
            throw PeelError("This Mac's memory is over 100 MB, more than a home server takes in one piece.")
        }
        let encoded = try {
            let snapshot = try Data(contentsOf: file, options: .mappedIfSafe)
            try check(snapshot, against: export)
            return snapshot.base64EncodedData()
        }()
        await progress(.sending)
        let imported = try await worded(on: home) { try await home.importSnapshot(base64: encoded) }
        return try matched(export, imported)
    }

    /// The home server's memory to this Mac's empty one: exported by `home`
    /// inline (no file kept there; over 100 MB strut refuses), checked, and
    /// loaded into `local` as `data`.
    public static func fromHomeServer(
        _ home: MemoryServer, into local: MemoryServer,
        progress: @Sendable (Step) async -> Void = { _ in }
    ) async throws -> Moved {
        await progress(.reading)
        let reply = try await worded(on: home) { try await home.run("export", ["inline": true], snapshot: true) }
        guard case .object(var fields) = reply, case .string(let text)? = fields.removeValue(forKey: "data") else {
            throw PeelError("The home server's strut cannot send its memory yet. Update strut there and try again.")
        }
        let export = AgentKit.JSONValue.object(fields)
        let encoded = Data(text.utf8)
        // The decoded snapshot is only for the check, and freed before the import.
        try {
            guard let snapshot = Data(base64Encoded: encoded) else { throw PeelError("The home server sent memory Peel cannot read.") }
            try check(snapshot, against: export)
        }()
        await progress(.sending)
        let imported = try await worded(on: local) { try await local.importSnapshot(base64: encoded) }
        return try matched(export, imported)
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
            return onHomeServer
                ? "The home server already has memory, so nothing was moved. Peel never overwrites it."
                : "This Mac already has memory, so nothing was brought back. Peel never overwrites it."
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
            return "\(here) could not load the memory, and its memory is left empty."
        default:
            return nil
        }
    }
}
