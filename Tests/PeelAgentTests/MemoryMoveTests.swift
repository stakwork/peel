import CryptoKit
import Foundation
import Testing
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// Moving memory between this Mac's strut and a home server (`MemoryMove`)
/// against stub struts: what is sent where, strut's refusals in words, the
/// counts checked, and the export file never left behind or read from
/// outside strut's folder.
struct MemoryMoveTests {
    /// Stands in for a snapshot: the move checks only its size and hash.
    static let snapshot = Data("a memory snapshot".utf8)
    static let counts = #"{"Entity":3,"Fact":5,"Episode":2,"MENTIONS":4,"Ontology":40}"#

    static func reply(_ output: String) -> String { #"{"status":"success","output":\#(output),"events":[]}"# }

    static func export(path: String? = nil, data: Bool = false, counts: String = counts) -> String {
        let hash = SHA256.hash(data: snapshot).hex
        let place = path.map { #""path":"\#($0)","# } ?? ""
        let inline = data ? #""data":"\#(snapshot.base64EncodedString())","# : ""
        return reply(#"{\#(place)\#(inline)"sha256":"\#(hash)","bytes":\#(snapshot.count),"counts":\#(counts)}"#)
    }

    /// This Mac's strut's folder with an export in it, as strut leaves one.
    static func folderWithExport() throws -> (TempProfile, URL) {
        let folder = TempProfile()
        let file = folder.url.appending(path: "workspace/memory/snapshots/memory-1.tar.gz")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try snapshot.write(to: file)
        return (folder, file)
    }

    static func local(_ stub: HTTPStub) throws -> MemoryServer {
        let url = try #require(URL(string: "http://127.0.0.1:\(stub.port)"))
        return try #require(MemoryServer(base: url, key: "local-key"))
    }

    static func body(_ request: String?) -> String { request?.components(separatedBy: "\r\n\r\n").last ?? "" }

    /// Sent with `replace`, so a home server that already has memory (a
    /// reconnect after switching back) takes this Mac's in its place, its
    /// own kept as a backup there: no failure, and said as replaced.
    @Test(arguments: [false, true])
    func copiesThisMacsMemoryToTheHomeServer(replacing: Bool) async throws {
        let (folder, file) = try Self.folderWithExport()
        let local = try await HTTPStub { _ in Self.export(path: file.path) }
        let arrived = Self.counts.replacingOccurrences(of: "40", with: "44")
        let backup = replacing ? #","backup":"memory-20261014T200000Z-a1b2c3.tar.gz""# : ""
        let home = try await HTTPStub { _ in Self.reply(#"{"counts":\#(arrived),"replaced":\#(replacing)\#(backup)}"#) }
        defer { local.stop(); home.stop() }

        let copy = try await MemoryMove.toHomeServer(from: try Self.local(local), folder: folder.url,
                                                     to: try BrainTests.server("http://127.0.0.1:\(home.port)"))
        guard case .copied(let moved, let replaced) = copy else { Issue.record("not copied: \(copy)"); return }
        #expect(moved.facts == 5 && replaced == replacing)
        #expect(local.requests.first?.hasPrefix("POST /steps/memory/export/run ") == true)
        let sent = try #require(home.requests.first)
        #expect(sent.hasPrefix("POST /steps/memory/import/run ") && sent.contains("Authorization: Bearer \(BrainTests.key)"))
        #expect(Self.body(sent).hasSuffix(#""data":"\#(Self.snapshot.base64EncodedString())","replace":true}}"#))
        // The plaintext snapshot is gone from this Mac once sent.
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// This Mac's memory empty: nothing is sent, and its export is still deleted.
    @Test func nothingToCopyFromThisMac() async throws {
        let (folder, file) = try Self.folderWithExport()
        let local = try await HTTPStub { _ in Self.export(path: file.path, counts: #"{"Entity":0,"Fact":0,"Episode":0,"Ontology":40}"#) }
        let home = try await HTTPStub { _ in Self.reply("{}") }
        defer { local.stop(); home.stop() }

        let copy = try await MemoryMove.toHomeServer(from: try Self.local(local), folder: folder.url,
                                                     to: try BrainTests.server("http://127.0.0.1:\(home.port)"))
        #expect(copy == .nothingToCopy && home.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// strut's refusals come back as a successful step whose output is
    /// `{error}`; each stops the move with its words.
    @Test(arguments: [
        (#"{"error":"backup_failed: disk full; nothing was imported and the memory is as it was"}"#,
         "The home server could not save a backup of its own memory first, so nothing was copied"),
        // A strut there from before `replace`, which ignores it.
        (#"{"error":"not_empty: memory already holds 1 entities, 2 facts and 1 episodes"}"#,
         "The home server's strut is too old to replace its memory"),
        (#"{"error":"bad_snapshot: the content hash does not match"}"#,
         "The memory snapshot was damaged or not one strut made"),
        (#"{"counts":{"Entity":3,"Fact":4,"Episode":2,"MENTIONS":4}}"#,
         "The memory that arrived does not match what was sent (4 of 5 facts)."),
    ])
    func aRefusedOrShortImportToTheHomeServer(importReply: String, words: String) async throws {
        let (folder, file) = try Self.folderWithExport()
        let local = try await HTTPStub { _ in Self.export(path: file.path) }
        let home = try await HTTPStub { _ in Self.reply(importReply) }
        defer { local.stop(); home.stop() }
        await #expect {
            try await MemoryMove.toHomeServer(from: try Self.local(local), folder: folder.url,
                                              to: try BrainTests.server("http://127.0.0.1:\(home.port)"))
        } throws: { "\($0)".hasPrefix(words) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The home server going away between the export and the import.
    @Test func theHomeServerUnreachableMidway() async throws {
        let (folder, file) = try Self.folderWithExport()
        let local = try await HTTPStub { _ in Self.export(path: file.path) }
        let gone = try await HTTPStub { _ in "" }
        gone.stop()
        defer { local.stop() }
        await #expect {
            try await MemoryMove.toHomeServer(from: try Self.local(local), folder: folder.url,
                                              to: try BrainTests.server("http://127.0.0.1:\(gone.port)"))
        } throws: { "\($0)".hasPrefix("The brain is offline.") }
        #expect(local.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// An export path outside strut's folder is neither read nor deleted,
    /// and nothing is sent.
    @Test func aSnapshotOutsideStrutsFolder() async throws {
        let (folder, _) = try Self.folderWithExport()
        let (elsewhere, outside) = try Self.folderWithExport()
        let local = try await HTTPStub { _ in Self.export(path: outside.path) }
        let home = try await HTTPStub { _ in Self.reply("{}") }
        defer { local.stop(); home.stop() }
        await #expect {
            try await MemoryMove.toHomeServer(from: try Self.local(local), folder: folder.url,
                                              to: try BrainTests.server("http://127.0.0.1:\(home.port)"))
        } throws: { "\($0)".hasPrefix("This Mac's strut put its memory snapshot somewhere Peel does not read.") }
        #expect(FileManager.default.fileExists(atPath: outside.path) && home.requests.isEmpty)
        _ = elsewhere
    }

    /// Only a snapshot file strut's export writes, in strut's own folder:
    /// never through `..`, a link, a folder whose name merely starts the
    /// same ("Strut2"), a folder, or a file of another name.
    @Test func whatSnapshotFileIsReadAndDeleted() throws {
        let (folder, file) = try Self.folderWithExport()
        let fm = FileManager.default
        let snapshots = file.deletingLastPathComponent()
        let base = folder.url.path
        #expect(MemoryMove.snapshotFile(file.path, in: folder.url)?.lastPathComponent == file.lastPathComponent)

        let sibling = URL(filePath: base + "2/workspace/memory/snapshots/memory-1.tar.gz")
        try fm.createDirectory(at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.snapshot.write(to: sibling)
        defer { try? fm.removeItem(atPath: base + "2") }
        let away = TempProfile()
        try fm.createDirectory(at: away.url.appending(path: "snapshots"), withIntermediateDirectories: true)
        try Self.snapshot.write(to: away.url.appending(path: "snapshots/memory-9.tar.gz"))
        try fm.createSymbolicLink(at: folder.url.appending(path: "link"), withDestinationURL: away.url)
        try fm.createSymbolicLink(at: snapshots.appending(path: "memory-2.tar.gz"),
                                  withDestinationURL: away.url.appending(path: "snapshots/memory-9.tar.gz"))
        try fm.createDirectory(at: snapshots.appending(path: "memory-3.tar.gz"), withIntermediateDirectories: true)
        try Self.snapshot.write(to: snapshots.appending(path: "graph.lbug"))

        for refused in [
            sibling.path,                                                  // "Strut2"
            base + "/workspace/memory/snapshots/../snapshots/memory-1.tar.gz",
            base + "/link/snapshots/memory-9.tar.gz",                      // through a link out
            snapshots.appending(path: "memory-2.tar.gz").path,             // a link itself
            snapshots.appending(path: "memory-3.tar.gz").path,             // a folder
            snapshots.appending(path: "graph.lbug").path,                  // not an export
            "workspace/memory/snapshots/memory-1.tar.gz",                  // relative
        ] {
            #expect(MemoryMove.snapshotFile(refused, in: folder.url) == nil, "\(refused)")
        }
    }

    // MARK: Bringing the home server's memory back in place of this Mac's

    /// strut's memory folder holding this Mac's graph and its log.
    static func memoryFolder() throws -> (TempProfile, URL) {
        let data = TempProfile()
        let folder = data.url.appending(path: "workspace/memory")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("this Mac's graph".utf8).write(to: folder.appending(path: "graph.lbug"))
        try Data("this Mac's log".utf8).write(to: folder.appending(path: "graph.lbug.wal"))
        return (data, folder)
    }

    static func contents(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    /// A strut started on the folder: a fresh graph, as strut opens one.
    @MainActor static func start(_ folder: URL, _ server: MemoryServer) -> () async throws -> MemoryServer {
        {
            try Data("empty".utf8).write(to: folder.appending(path: "graph.lbug"))
            return server
        }
    }

    @MainActor @Test func bringsTheHomeServersMemoryInPlaceOfThisMacs() async throws {
        let (data, folder) = try Self.memoryFolder()
        let home = try await HTTPStub { _ in Self.export(data: true) }
        let local = try await HTTPStub { _ in Self.reply(#"{"counts":\#(Self.counts)}"#) }
        defer { local.stop(); home.stop() }
        var stops = 0

        let brought = try await MemoryMove.replacingThisMac(
            with: try BrainTests.server("http://127.0.0.1:\(home.port)"), folder: folder,
            stop: { stops += 1 }, start: Self.start(folder, try Self.local(local))
        )
        #expect(brought?.moved.facts == 5 && stops == 1)
        #expect(Self.body(home.requests.first).contains(#""inline":true"#))
        #expect(Self.body(local.requests.first).contains(#""data":"\#(Self.snapshot.base64EncodedString())""#))
        // This Mac's graph and log, renamed whole into the owner-only backups folder.
        let backups = folder.appending(path: "backups")
        let kept = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        #expect(kept.count == 2 && kept[0].hasPrefix("graph-") && kept[0].hasSuffix(".lbug") && kept[1] == kept[0] + ".wal")
        #expect(Self.contents(backups.appending(path: kept[0])) == "this Mac's graph")
        #expect(Self.contents(backups.appending(path: kept[1])) == "this Mac's log")
        #expect(try FileManager.default.attributesOfItem(atPath: backups.path)[.posixPermissions] as? Int == 0o700)
        #expect(Self.contents(folder.appending(path: "graph.lbug")) == "empty")
        _ = data
    }

    /// The home server's memory read before anything here is touched: one
    /// holding nothing, or a strut there with no inline export yet (it
    /// sends a path on its own machine), leaves this Mac's graph as it was
    /// and strut never stopped.
    @MainActor @Test(arguments: [true, false])
    func nothingBroughtLeavesThisMacAlone(empty: Bool) async throws {
        let (data, folder) = try Self.memoryFolder()
        let home = try await HTTPStub { _ in
            empty ? Self.export(data: true, counts: #"{"Entity":0,"Fact":0,"Episode":0,"Ontology":40}"#)
                : Self.export(path: "/data/memory/snapshots/memory-1.tar.gz")
        }
        defer { home.stop() }
        var stops = 0
        let bring = {
            try await MemoryMove.replacingThisMac(
                with: try BrainTests.server("http://127.0.0.1:\(home.port)"), folder: folder,
                stop: { stops += 1 }, start: { throw PeelError("unreached") }
            )
        }
        if empty {
            #expect(try await bring() == nil)
        } else {
            await #expect { try await bring() } throws: { "\($0)".hasPrefix("The home server's strut cannot send its memory yet.") }
        }
        #expect(stops == 0 && Self.contents(folder.appending(path: "graph.lbug")) == "this Mac's graph")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "backups").path))
        _ = data
    }

    /// Failing once this Mac's graph is set aside (the import refused, or
    /// strut not starting) stops strut and puts the graph back as it was,
    /// over the one strut made; putting it back again does nothing.
    @MainActor @Test(arguments: [true, false])
    func aFailedBringBackPutsThisMacsMemoryBack(starts: Bool) async throws {
        let (data, folder) = try Self.memoryFolder()
        let home = try await HTTPStub { _ in Self.export(data: true) }
        let local = try await HTTPStub { _ in Self.reply(#"{"error":"import_failed: disk full; the memory is left empty"}"#) }
        defer { local.stop(); home.stop() }
        var stops = 0
        var held: MemoryBackup?
        let start = Self.start(folder, try Self.local(local))

        await #expect {
            try await MemoryMove.replacingThisMac(
                with: try BrainTests.server("http://127.0.0.1:\(home.port)"), folder: folder,
                stop: { stops += 1 },
                start: { if starts { return try await start() } else { throw PeelError("Peel's strut exited with status 1.") } },
                holding: { if let backup = $0 { held = backup } }
            )
        } throws: { "\($0)".hasSuffix("This Mac's memory is as it was.") }
        #expect(stops == 2)
        #expect(Self.contents(folder.appending(path: "graph.lbug")) == "this Mac's graph")
        #expect(Self.contents(folder.appending(path: "graph.lbug.wal")) == "this Mac's log")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "backups").path).isEmpty)
        try #require(held).restore()
        #expect(Self.contents(folder.appending(path: "graph.lbug")) == "this Mac's graph")
        _ = data
    }

    /// A graph file that is a link is never moved, and nothing is started.
    @MainActor @Test func aLinkedGraphIsLeftAlone() async throws {
        let (data, folder) = try Self.memoryFolder()
        let away = TempProfile()
        try FileManager.default.createDirectory(at: away.url, withIntermediateDirectories: true)
        try Data("elsewhere".utf8).write(to: away.url.appending(path: "x"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "graph.lbug.shadow"),
                                                   withDestinationURL: away.url.appending(path: "x"))
        let home = try await HTTPStub { _ in Self.export(data: true) }
        defer { home.stop() }
        var started = false
        await #expect {
            try await MemoryMove.replacingThisMac(
                with: try BrainTests.server("http://127.0.0.1:\(home.port)"), folder: folder, stop: {},
                start: { started = true; throw PeelError("unreached") }
            )
        } throws: { "\($0)".hasPrefix("This Mac's memory files are not as Peel left them") }
        #expect(!started && Self.contents(folder.appending(path: "graph.lbug")) == "this Mac's graph")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "backups").path))
        _ = data
    }

    /// The newest three sets stay; nothing but sets is removed.
    @Test func keepsTheNewestThreeBackups() throws {
        let data = TempProfile()
        let backups = MemoryBackup.backups(in: data.url)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamps = ["20260101T000000Z", "20260201T000000Z", "20260301T000000Z", "20260401T000000Z", "20260501T000000Z"]
        for stamp in stamps {
            try Data().write(to: backups.appending(path: "graph-\(stamp).lbug"))
            try Data().write(to: backups.appending(path: "graph-\(stamp).lbug.wal"))
        }
        try Data().write(to: backups.appending(path: "notes.txt"))
        try MemoryBackup.prune(in: data.url)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path))
        #expect(left == Set(stamps.suffix(3).flatMap { ["graph-\($0).lbug", "graph-\($0).lbug.wal"] } + ["notes.txt"]))
    }

    @Test(arguments: [
        ("not_empty", false, "This Mac already has memory, so nothing was brought back. Peel never overwrites it."),
        ("bad_snapshot", true, "The memory snapshot was damaged or not one strut made, so nothing was loaded."),
        ("newer_format", true, "This Mac's memory comes from a newer strut than the home server's. Update the home server and try again."),
        ("newer_format", false, "The home server's memory comes from a newer strut than Peel's. Update Peel and try again."),
        ("too_large", true, "The memory is over 100 MB, more than strut takes in one piece."),
        ("invalid_input", false, "strut did not take the memory as Peel sent it. Update Peel and strut, then try again."),
        ("not_found", false, "strut could not find the memory snapshot it was given."),
        ("import_failed", true, "The home server could not load the memory."),
    ])
    func refusalsInWords(code: String, onHomeServer: Bool, words: String) {
        #expect(MemoryMove.words(code: code, onHomeServer: onHomeServer) == words)
    }

    @Test func otherRefusalsKeepTheirWords() {
        #expect(MemoryMove.words(code: "unknown_code", onHomeServer: true) == nil)
    }
}
