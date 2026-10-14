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

    @Test func movesThisMacsMemoryToTheHomeServer() async throws {
        let (folder, file) = try Self.folderWithExport()
        let local = try await HTTPStub { _ in Self.export(path: file.path) }
        let home = try await HTTPStub { _ in Self.reply(#"{"counts":\#(Self.counts.replacingOccurrences(of: "40", with: "44"))}"#) }
        defer { local.stop(); home.stop() }

        let moved = try await MemoryMove.toHomeServer(from: try Self.local(local), folder: folder.url,
                                                      to: try BrainTests.server("http://127.0.0.1:\(home.port)"))
        #expect(moved.facts == 5)
        #expect(local.requests.first?.hasPrefix("POST /steps/memory/export/run ") == true)
        let sent = try #require(home.requests.first)
        #expect(sent.hasPrefix("POST /steps/memory/import/run ") && sent.contains("Authorization: Bearer \(BrainTests.key)"))
        #expect(Self.body(sent).contains(#""data":"\#(Self.snapshot.base64EncodedString())""#))
        // The plaintext snapshot is gone from this Mac once sent.
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func bringsTheHomeServersMemoryBack() async throws {
        let home = try await HTTPStub { _ in Self.export(data: true) }
        let local = try await HTTPStub { _ in Self.reply(#"{"counts":\#(Self.counts)}"#) }
        defer { local.stop(); home.stop() }

        let moved = try await MemoryMove.fromHomeServer(try BrainTests.server("http://127.0.0.1:\(home.port)"),
                                                        into: try Self.local(local))
        #expect(moved.facts == 5)
        #expect(Self.body(home.requests.first).contains(#""inline":true"#))
        #expect(Self.body(local.requests.first).contains(#""data":"\#(Self.snapshot.base64EncodedString())""#))
    }

    /// A home server whose strut has no inline export yet sends a path on
    /// its own machine: nothing is loaded here.
    @Test func aHomeServerThatSendsNoData() async throws {
        let home = try await HTTPStub { _ in Self.export(path: "/data/memory/snapshots/memory-1.tar.gz") }
        let local = try await HTTPStub { _ in Self.reply("{}") }
        defer { local.stop(); home.stop() }
        await #expect {
            try await MemoryMove.fromHomeServer(try BrainTests.server("http://127.0.0.1:\(home.port)"),
                                                into: try Self.local(local))
        } throws: { "\($0)".hasPrefix("The home server's strut cannot send its memory yet.") }
        #expect(local.requests.isEmpty)
    }

    /// strut's refusals come back as a successful step whose output is
    /// `{error}`; each stops the move with its words.
    @Test(arguments: [
        (#"{"error":"not_empty: memory already holds 1 entities, 2 facts and 1 episodes"}"#,
         "The home server already has memory, so nothing was moved."),
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

    @Test(arguments: [
        ("not_empty", false, "This Mac already has memory, so nothing was brought back. Peel never overwrites it."),
        ("bad_snapshot", true, "The memory snapshot was damaged or not one strut made, so nothing was loaded."),
        ("newer_format", true, "This Mac's memory comes from a newer strut than the home server's. Update the home server and try again."),
        ("newer_format", false, "The home server's memory comes from a newer strut than Peel's. Update Peel and try again."),
        ("too_large", true, "The memory is over 100 MB, more than strut takes in one piece."),
        ("invalid_input", false, "strut did not take the memory as Peel sent it. Update Peel and strut, then try again."),
        ("not_found", false, "strut could not find the memory snapshot it was given."),
        ("import_failed", true, "The home server could not load the memory, and its memory is left empty."),
    ])
    func refusalsInWords(code: String, onHomeServer: Bool, words: String) {
        #expect(MemoryMove.words(code: code, onHomeServer: onHomeServer) == words)
    }

    @Test func otherRefusalsKeepTheirWords() {
        #expect(MemoryMove.words(code: "unknown_code", onHomeServer: true) == nil)
    }
}
