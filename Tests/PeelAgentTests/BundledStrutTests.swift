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
             "STRUT_SECRET_KEY": "the caller's"],
            key: key, secretKey: secretKey, data: data)
        #expect(environment["PATH"] == "/usr/bin" && environment["HOME"] == "/Users/x")
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil && environment["NODE_OPTIONS"] == nil
                && environment["STRUT_CONNECTION_FILE"] == nil && environment["PEEL_AGENT_API_KEY"] == nil)
        #expect(environment["STRUT_HOST"] == "127.0.0.1" && environment["STRUT_PORT"] == "0")
        #expect(environment["STRUT_API_KEY"] == key && environment["STRUT_READY_KEY"] == "1")
        #expect(environment["STRUT_SECRET_KEY"] == secretKey)
        #expect(environment["STRUT_EXIT_ON_STDIN_EOF"] == "1")
        #expect(environment["STRUT_WORKSPACE"] == "/tmp/peel-strut/workspace")
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
    /// answering the memory steps, and gone once stopped.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.path)))
    func theStagedStrutStartsAnswersAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-strut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let strut = try stagedStrut(in: root)
        defer { strut.stop(quietly: true) }

        let server = try await strut.start()
        #expect(server.base.host() == "127.0.0.1")
        _ = try await server.run("ontology", [:])
        strut.stop()
        #expect(strut.server == nil)
        await #expect(throws: (any Error).self) { _ = try await server.run("ontology", [:]) }
    }

    /// An automation through the staged strut, as the app runs one: the
    /// token in strut's encrypted store (never in a workflow, Peel's step
    /// or in plain text on disk), Peel's step reading it and sending it.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.path)))
    func theStagedStrutFiresAnAutomationWithTheTokenFromItsSecretStore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-strut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let strut = try stagedStrut(in: root)
        defer { strut.stop(quietly: true) }
        let seen = Mutex<[AutomationRequest]>([])
        let peel = try await AutomationServer.start(port: 0, token: try AutomationServer.newKey()) { request in
            seen.withLock { $0.append(request) }
            return AutomationReply(status: .delivered, text: "Done")
        }
        defer { Task { await peel.stop() } }

        let client = AutomationsClient(server: try await strut.start())
        try await client.install(port: peel.port, token: peel.token, model: nil)
        let automation = try await client.create(
            name: "Daily", prompt: "Summarise",
            trigger: ["type": "schedule", "every": "day", "at": ["09:00"], "tz": "Europe/London"])
        let first = try await fire(automation, on: client)
        #expect(first.status == "success", "\(first.error ?? "")")
        #expect(seen.withLock { $0 } == [AutomationRequest(name: "Daily", prompt: "Summarise")])

        // Started again with the same key, nothing installed: the stored token still decrypts.
        strut.stop()
        let again = AutomationsClient(server: try await strut.start())
        let second = try await fire(automation, on: again, after: first.id)
        #expect(second.status == "success", "\(second.error ?? "")")
        #expect(seen.withLock { $0.count } == 2)

        // Any workflow may run Peel's step, but where it goes is only what Peel stored:
        // a port or URL in its config is ignored, and without Peel's secrets nothing is sent.
        let elsewhere: AgentKit.JSONValue = ["peel_url": "http://example.invalid", "port": 1, "name": "Elsewhere", "prompt": "x"]
        #expect(try await runStep(elsewhere, on: again.server) == "success")
        #expect(seen.withLock { $0.last?.name } == "Elsewhere" && seen.withLock { $0.count } == 3)
        let (deleted, _) = try await Web.requestThisMac(
            "DELETE", again.server.base.appending(path: "secrets/PEEL_AUTOMATION_PORT"), bearer: again.server.key,
            limit: 100_000, what: "the secret")
        #expect(deleted == 200)
        #expect(try await runStep(elsewhere, on: again.server) == "error")
        #expect(seen.withLock { $0.count } == 3)

        // Nothing strut wrote holds the token as it is.
        let workspace = root.appending(path: "data/workspace")
        #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "secrets.json").path))
        #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "steps/custom/peel/run-automation.ts").path))
        let files = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let holding = files.filter { (try? Data(contentsOf: $0))?.range(of: Data(peel.token.utf8)) != nil }
        #expect(holding.isEmpty, "\(holding.map(\.lastPathComponent))")
    }

    /// Peel's step run on its own with `config`, as any workflow could: the run's status.
    func runStep(_ config: AgentKit.JSONValue, on server: MemoryServer) async throws -> String? {
        let (_, data) = try await Web.requestThisMac(
            "POST", server.base.appending(path: "steps/peel/run-automation/run"),
            json: Data(AgentKit.JSONValue.object(["config": config]).jsonString.utf8), bearer: server.key,
            limit: 1_000_000, what: "the step")
        return try AgentKit.JSONValue(parsing: String(decoding: data, as: UTF8.self))["status"]?.string
    }

    /// Runs it now and waits for that run to end: its record.
    func fire(_ automation: Automation, on client: AutomationsClient, after earlier: String? = nil) async throws -> AutomationRunRecord {
        try await client.runNow(automation)
        for _ in 0..<100 {
            if let run = try await client.runs(of: automation).first, run.id != earlier, run.status != "running" { return run }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PeelError("the run did not end")
    }

    /// A Peel.app in `root` whose strut is the staged one, its data and key beside it.
    func stagedStrut(in root: URL) throws -> BundledStrut {
        try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "data"),
                                  secretKey: FileItem(file: root.appending(path: "strut-key"))))
    }

    private final class Marker {}
}
