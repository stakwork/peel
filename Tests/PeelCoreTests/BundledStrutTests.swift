import Foundation
import Testing
@testable import PeelAgent

/// The strut Peel ships: what it trusts in strut's ready line, the
/// environment it starts strut with, and, when one is staged
/// (scripts/stage-strut.sh), a real start and stop.
@MainActor
struct BundledStrutTests {
    let key = String(repeating: "ab", count: 32)

    @Test func onlyAReadyLineOnThisMacWithPeelsKeyIsTrusted() throws {
        let server = try #require(BundledStrut.readyServer(#"{"event":"ready","port":53111,"host":"127.0.0.1","key":"\#(key)"}"#, key: key))
        #expect(server.base.absoluteString == "http://127.0.0.1:53111" && server.key == key)
        for line in [
            #"{"event":"ready","port":53111,"host":"127.0.0.1","key":"other"}"#,
            #"{"event":"ready","port":53111,"host":"0.0.0.0","key":"\#(key)"}"#,
            #"{"event":"ready","port":0,"host":"127.0.0.1","key":"\#(key)"}"#,
            #"{"event":"started","port":53111,"host":"127.0.0.1","key":"\#(key)"}"#,
            "strut server: http://127.0.0.1:53111",
        ] {
            #expect(BundledStrut.readyServer(line, key: key) == nil, "\(line)")
        }
    }

    @Test func strutGetsPeelsSettingsAndNoneOfTheCallers() {
        let data = URL(filePath: "/tmp/peel-strut")
        let environment = BundledStrut.environment(
            ["PATH": "/usr/bin", "HOME": "/Users/x", "DYLD_INSERT_LIBRARIES": "/evil.dylib", "NODE_OPTIONS": "--inspect",
             "STRUT_CONNECTION_FILE": "/elsewhere", "STRUT_HOST": "0.0.0.0"],
            key: key, data: data)
        #expect(environment["PATH"] == "/usr/bin" && environment["HOME"] == "/Users/x")
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil && environment["NODE_OPTIONS"] == nil
                && environment["STRUT_CONNECTION_FILE"] == nil)
        #expect(environment["STRUT_HOST"] == "127.0.0.1" && environment["STRUT_PORT"] == "0")
        #expect(environment["STRUT_API_KEY"] == key && environment["STRUT_READY_KEY"] == "1")
        #expect(environment["STRUT_EXIT_ON_STDIN_EOF"] == "1")
        #expect(environment["STRUT_WORKSPACE"] == "/tmp/peel-strut/workspace")
    }

    @Test func aBuildWithoutStrutHasNone() {
        #expect(BundledStrut(in: Bundle(for: Marker.self)) == nil)
    }

    /// A Peel.app whose strut is `script` in place of Node, and its data folder.
    func fake(_ script: String) throws -> (BundledStrut, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-fake-strut-\(UUID().uuidString)")
        let strut = root.appending(path: "Peel.app/Contents/Strut")
        try FileManager.default.createDirectory(at: strut.appending(path: "native"), withIntermediateDirectories: true)
        try Data().write(to: strut.appending(path: "desktop.js"))
        let node = strut.appending(path: "native/node")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let bundle = try #require(Bundle(url: root.appending(path: "Peel.app")))
        let data = root.appending(path: "data")
        return (try #require(BundledStrut(in: bundle, data: data)), data)
    }

    static let ready = #"printf '{"event":"ready","port":4321,"host":"127.0.0.1","key":"%s"}\n' "$STRUT_API_KEY""#

    @Test func startsOnceSaysWhenReadyAndStops() async throws {
        let (strut, data) = try fake(Self.ready + "\nexec cat > /dev/null\n")
        defer { strut.stop(quietly: true) }
        var changes = 0
        strut.onChange = { changes += 1 }
        async let first = strut.start()
        async let second = strut.start()
        let (a, b) = try await (first, second)
        #expect(a == b && a.base.port == 4321 && strut.server == a && changes == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? Int == 0o700)
        strut.stop()
        #expect(strut.server == nil && changes == 2)
    }

    @Test func aStrutThatStopsByItselfIsDropped() async throws {
        // Runs until the test leaves a file beside its workspace, then exits.
        let (strut, data) = try fake(Self.ready + "\nuntil [ -e \"$(dirname \"$STRUT_WORKSPACE\")/stop\" ]; do sleep 0.05; done\n")
        defer { strut.stop(quietly: true) }
        var stopped = false
        strut.onChange = { if strut.server == nil { stopped = true } }
        _ = try await strut.start()
        try Data().write(to: data.appending(path: "stop"))
        for _ in 0..<100 where !stopped { try await Task.sleep(for: .milliseconds(100)) }
        #expect(stopped && strut.server == nil)
    }

    @Test func aStrutThatNeverGetsReadySaysWhy() async throws {
        let (strut, _) = try fake("exit 7\n")
        await #expect(throws: (any Error).self) { _ = try await strut.start() }
        do { _ = try await strut.start() } catch { #expect("\(error)".contains("exited with status 7")) }
    }

    @Test func eraseStopsItAndRemovesItsData() async throws {
        let (strut, data) = try fake(Self.ready + "\nexec cat > /dev/null\n")
        defer { strut.stop(quietly: true) }
        _ = try await strut.start()
        try Data("memory".utf8).write(to: data.appending(path: "graph.lbug"))
        try strut.erase()
        #expect(strut.server == nil && !FileManager.default.fileExists(atPath: data.path))
    }

    /// The staged strut, run as the app runs it: ready with Peel's key,
    /// answering the memory steps, and gone once stopped.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrutTests.staged.path)))
    func theStagedStrutStartsAnswersAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-strut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Peel.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: app.appending(path: "Contents/Strut"), withDestinationURL: Self.staged)
        let bundle = try #require(Bundle(url: app))
        let strut = try #require(BundledStrut(in: bundle, data: root.appending(path: "data")))
        defer { strut.stop(quietly: true) }

        let server = try await strut.start()
        #expect(server.base.host() == "127.0.0.1")
        _ = try await server.run("ontology", [:])
        strut.stop()
        #expect(strut.server == nil)
        await #expect(throws: (any Error).self) { _ = try await server.run("ontology", [:]) }
    }

    /// Where scripts/stage-strut.sh leaves it, for every checkout.
    nonisolated static let staged = ProcessInfo.processInfo.environment["PEEL_STRUT_STAGE"].map { URL(filePath: $0) }
        .map { $0.appending(path: "strut") }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/dev.peel.build/strut/strut")

    private final class Marker {}
}
