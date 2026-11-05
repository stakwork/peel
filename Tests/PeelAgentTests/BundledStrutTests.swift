import Foundation
import Synchronization
import Testing
import AgentKit
@testable import PeelAgent
import PeelCore

/// The strut Peel ships: what it trusts in strut's ready line, the
/// environment it starts strut with, and, when one is staged
/// (scripts/stage-strut.sh), a real start and stop.
@MainActor
struct BundledStrutTests {
    let key = String(repeating: "ab", count: 32)
    let secretKey = String(repeating: "cd", count: 32)

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
             "STRUT_CONNECTION_FILE": "/elsewhere", "STRUT_HOST": "0.0.0.0", "PEEL_AGENT_API_KEY": "model key",
             "STRUT_SECRET_KEY": "the caller's", "ANTHROPIC_API_KEY": "shell key", "OPENAI_API_KEY": "shell key",
             "OPENROUTER_API_KEY": "shell key"],
            key: key, secretKey: secretKey, data: data, hostConfig: data.appending(path: "host-config.json"))
        #expect(environment["PATH"] == "/usr/bin" && environment["HOME"] == "/Users/x")
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil && environment["NODE_OPTIONS"] == nil
                && environment["STRUT_CONNECTION_FILE"] == nil && environment["PEEL_AGENT_API_KEY"] == nil)
        // A model key from the shell would outlive a disconnect: strut has only the store's.
        #expect(environment["ANTHROPIC_API_KEY"] == nil && environment["OPENAI_API_KEY"] == nil
                && environment["OPENROUTER_API_KEY"] == nil)
        #expect(environment["STRUT_HOST"] == "127.0.0.1" && environment["STRUT_PORT"] == "0")
        #expect(environment["STRUT_API_KEY"] == key && environment["STRUT_READY_KEY"] == "1")
        #expect(environment["STRUT_SECRET_KEY"] == secretKey)
        #expect(environment["STRUT_EXIT_ON_STDIN_EOF"] == "1")
        #expect(environment["STRUT_WORKSPACE"] == "/tmp/peel-strut/workspace")
        #expect(environment["STRUT_WORKSPACE_BACKEND"] == "ladybug")
        #expect(environment["STRUT_HOST_CONFIG"] == "/tmp/peel-strut/host-config.json")
        // An MCP server on this Mac only for a development profile's test server.
        #expect(environment["STRUT_MCP_LOCAL"] == "0")
        #expect(BundledStrut.environment([:], key: key, secretKey: secretKey, data: data, hostConfig: data.appending(path: "h"),
                                         allowsLocalMCP: true)["STRUT_MCP_LOCAL"] == "1")
        // Nothing sealed beside strut's own: the builder has no card to run a step around.
        #expect(environment["STRUT_SEALED"] == nil)
        // strut clears its environment at boot: only a stand-in model on this Mac is kept through it.
        #expect(environment["STRUT_ENV_KEEP"] == nil)
        for (base, kept) in [("http://127.0.0.1:9", true), ("http://localhost:9", true), ("https://example.com", false)] {
            let keeping = BundledStrut.environment(["ANTHROPIC_BASE_URL": base], key: key, secretKey: secretKey, data: data,
                                                   hostConfig: data.appending(path: "host-config.json"))
            #expect((keeping["STRUT_ENV_KEEP"] == "ANTHROPIC_BASE_URL") == kept, "\(base)")
        }
    }

    /// strut's secret store key: made once, owner-only, the same on every
    /// start after, so what strut encrypted stays readable.
    @Test func theSecretKeyIsMadeOnceAndKept() throws {
        let item = FileItem(file: FileManager.default.temporaryDirectory.appending(path: "peel-strut-key-\(UUID().uuidString)"))
        defer { try? item.delete() }
        let first = try BundledStrut.secretKey(in: item)
        #expect(first.count == 64 && first.allSatisfy(\.isHexDigit))
        #expect(try FileManager.default.attributesOfItem(atPath: item.file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try BundledStrut.secretKey(in: item) == first)
        try item.write(Data("short".utf8))
        #expect(try BundledStrut.secretKey(in: item) != "short")
    }

    /// A Keychain that cannot be read is not a missing key: nothing is
    /// made over it, or strut's store would be lost to a new key.
    @Test func anUnreadableKeyIsNotReplaced() {
        let item = Unreadable()
        #expect(throws: (any Error).self) { try BundledStrut.secretKey(in: item) }
        #expect(item.writes.withLock { $0 } == 0)
    }

    private final class Unreadable: SecretItem {
        let writes = Mutex(0)
        func read() throws -> Data? { throw PeelError("locked") }
        func write(_ data: Data) throws { writes.withLock { $0 += 1 } }
        func delete() throws {}
    }

    @Test func aBuildWithoutStrutHasNone() {
        #expect(BundledStrut(in: Bundle(for: Marker.self), secretKey: FileItem(file: URL(filePath: "/nonexistent"))) == nil)
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
        return (try #require(BundledStrut(in: bundle, data: data, secretKey: FileItem(file: root.appending(path: "strut-key")))), data)
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
    /// answering the graph's steps, and gone once stopped.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.path)))
    func theStagedStrutStartsAnswersAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-strut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let strut = try stagedStrut(in: root)
        defer { strut.stop(quietly: true) }

        let server = try await strut.start()
        #expect(server.base.host() == "127.0.0.1")
        _ = try await server.run(step: "graph/get-ontology", [:])
        strut.stop()
        #expect(strut.server == nil)
        await #expect(throws: (any Error).self) { _ = try await server.run(step: "graph/get-ontology", [:]) }
    }

    /// What Peel hands strut's secret store (here the connected model's
    /// key) is encrypted with the account's key: no file strut wrote holds it as it is.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.path)))
    func theStagedStrutNeverKeepsASecretAsItIs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-strut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let strut = try stagedStrut(in: root)
        defer { strut.stop(quietly: true) }
        let key = "sk-ant-" + (try BundledStrut.newKey())
        let client = AutomationsClient(server: try await strut.start())
        try await client.setModel(AgentCredential(provider: .anthropic, model: "claude-sonnet-5-5", apiKey: key))

        let workspace = root.appending(path: "data/workspace")
        #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "secrets.json").path))
        let files = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let holding = files.filter { (try? Data(contentsOf: $0))?.range(of: Data(key.utf8)) != nil }
        #expect(holding.isEmpty, "\(holding.map(\.lastPathComponent))")
    }

    /// The old database's facts are imported on the first start only, its
    /// counts kept; strut gives the orchestrator the graph tools and no
    /// agent the memory steps; at the next start the old database is
    /// removed, one copy kept beside it.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.appending(path: "build/steps/lib/graph/import-memory.js").path)))
    func theStagedStrutImportsTheOldMemoryOnceThenRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-strut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let strut = try stagedStrut(in: root)
        defer { strut.stop(quietly: true) }
        // A first start with no old database: recorded as done, nothing imported.
        _ = try await strut.start()
        #expect(FileManager.default.fileExists(atPath: strut.memoryImportRecord.path))
        strut.stop(quietly: true)
        // What a Peel from before the graph remembered ("Tom lives in Bristol."), on the
        // old database, with no import yet: strut no longer has the steps that wrote it.
        let fixture = try #require(Bundle.module.resourceURL).appending(path: "Fixtures/old-memory")
        try FileManager.default.createDirectory(at: strut.oldMemory.deletingLastPathComponent(), withIntermediateDirectories: true)
        for name in ["graph.lbug", "graph.lbug.wal"] {
            let to = strut.oldMemory.deletingLastPathComponent().appending(path: name)
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: fixture.appending(path: name), to: to)
        }
        try FileManager.default.removeItem(at: strut.memoryImportRecord)
        #expect(FileManager.default.fileExists(atPath: strut.oldMemory.path))

        let server = try await strut.start()
        let record = try AgentKit.JSONValue(parsing: String(decoding: try Data(contentsOf: strut.memoryImportRecord), as: UTF8.self))
        #expect((record["imported"]?.int ?? 0) >= 1, "\(record)")
        let found = try await server.run(step: "graph/graph-search", ["q": "Bristol", "facts": true])
        #expect(found.jsonString.contains("Tom lives in Bristol."), "\(found)")
        let flow = try await AutomationsClient(server: server).call("GET", "workflows/orchestrator/flow", nil, what: "the orchestrator")
        let tools = flow["params"]?["tools"]?.array?.compactMap(\.string) ?? []
        #expect(tools.contains("graph/assert") && !tools.contains { $0.hasPrefix("memory/") }, "\(tools)")
        // Dictation's lexicon is on the graph.
        _ = try await server.run(step: "memory/lexicon", [:])
        // Kept while strut has it open after the import.
        #expect(FileManager.default.fileExists(atPath: strut.oldMemory.path))

        // Again: the record stands, so nothing runs, and the old database goes, its copy kept.
        strut.stop(quietly: true)
        let kept = try Data(contentsOf: strut.memoryImportRecord)
        let old = try Data(contentsOf: strut.oldMemory)
        let again = try await strut.start()
        #expect(try Data(contentsOf: strut.memoryImportRecord) == kept)
        #expect(!FileManager.default.fileExists(atPath: strut.oldMemory.path))
        #expect(try Data(contentsOf: strut.oldMemoryBackup) == old)
        // Memory still answers from the graph.
        #expect(try await again.run(step: "graph/graph-search", ["q": "Bristol", "facts": true]).jsonString.contains("Tom lives in Bristol."))

        // A record from an earlier import (no version): it runs again, and the record is this one's.
        strut.stop(quietly: true)
        try Data(#"{"imported":1}"#.utf8).write(to: strut.memoryImportRecord)
        _ = try await strut.start()
        let rerun = try AgentKit.JSONValue(parsing: String(decoding: try Data(contentsOf: strut.memoryImportRecord), as: UTF8.self))
        #expect(rerun["version"]?.int == BundledStrut.memoryImportVersion, "\(rerun)")
    }

    /// The old memory database is removed only once the import of it
    /// succeeded at this version, a copy written beside it first; never
    /// when the import failed, never ran or is from an earlier version, and
    /// the one copy is never written over.
    @Test(arguments: [
        (#"{"version":\#(BundledStrut.memoryImportVersion),"imported":3}"#, true),
        (#"{"imported":3}"#, false),
        (nil, false),
    ] as [(String?, Bool)])
    func theOldMemoryGoesOnlyOnceItsImportSucceeded(record: String?, removed: Bool) async throws {
        let (strut, data) = try fake(Self.ready + "\nexec cat > /dev/null\n")
        defer { strut.stop(quietly: true) }
        try FileManager.default.createDirectory(at: strut.oldMemory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old memory".utf8).write(to: strut.oldMemory)
        let wal = strut.oldMemory.appendingPathExtension("wal")
        try Data("unwritten".utf8).write(to: wal)
        if let record { try Data(record.utf8).write(to: strut.memoryImportRecord) }
        _ = try await strut.start()
        #expect(strut.oldMemory.path.hasPrefix(data.appending(path: "workspace/memory").path))
        #expect(FileManager.default.fileExists(atPath: strut.oldMemory.path) == !removed)
        #expect(FileManager.default.fileExists(atPath: strut.oldMemoryBackup.path) == removed)
        // Its write-ahead log goes with it, copied beside the copy.
        #expect(FileManager.default.fileExists(atPath: wal.path) == !removed)
        if removed {
            #expect(try Data(contentsOf: strut.oldMemoryBackup) == Data("old memory".utf8))
            #expect(try Data(contentsOf: strut.oldMemoryBackup.appendingPathExtension("wal")) == Data("unwritten".utf8))
        }

        // Back again (a read copy pulled from a home): removed again, the first copy kept.
        guard removed else { return }
        strut.stop(quietly: true)
        try Data("later".utf8).write(to: strut.oldMemory)
        _ = try await strut.start()
        #expect(!FileManager.default.fileExists(atPath: strut.oldMemory.path))
        #expect(try Data(contentsOf: strut.oldMemoryBackup) == Data("old memory".utf8))
    }

    /// A development profile's memory is inside its own folder, never the app account's.
    @Test func aDevelopmentProfilesMemoryIsItsOwn() throws {
        let development = try Profile(name: "agent-setup-test", kind: .development)
        #expect(BundledStrut.dataFolder(for: development) == development.directory.appending(path: "strut"))
        #expect(BundledStrut.dataFolder(for: try Profile(name: "x", kind: .app)) == BundledStrut.dataFolder)
    }

    /// A Peel.app in `root` whose strut is the staged one, its data and key beside it.
    func stagedStrut(in root: URL) throws -> BundledStrut {
        try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "data"),
                                  secretKey: FileItem(file: root.appending(path: "strut-key"))))
    }

    private final class Marker {}
}
