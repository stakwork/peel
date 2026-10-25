import Darwin
import Foundation
import Testing
@testable import PeelAgent
@testable import PeelCore

/// The agent's bridge Peel ships: what it trusts in runner's output, the
/// environment it starts runner with, and, when one is staged
/// (scripts/stage-bridge.sh), a real start, stop and restart.
@MainActor
struct BundledBridgeTests {
    let agent = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    let lsp = "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
    let account = AgentAccount(
        seed: String(repeating: "ab", count: 32), pubkey: "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
        network: "bitcoin", owner: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", device: "mac-1",
        broker: "127.0.0.1:1"
    )
    let strut = MemoryServer(base: URL(string: "http://127.0.0.1:4100")!, key: String(repeating: "cd", count: 32))!

    @Test func onlyRocketsLaunchLineOnPeelsPortSaysRunnerListens() {
        let line = "2026-10-17T10:48:12.318Z WARN  [rocket::launch] Rocket has launched from http://127.0.0.1:61008"
        #expect(line.hasSuffix(BundledBridge.launchLine(port: 61008)))
        for (line, port) in [
            (line, 61009),
            (line, 6100),
            ("2026-10-17T10:48:12.318Z WARN  [rocket::launch] Rocket has launched from http://0.0.0.0:61008", 61008),
            ("2026-10-17T10:48:12.318Z WARN  [rocket::launch] Rocket has launched from http://127.0.0.1:610080", 61008),
            ("2026-10-17T10:48:12.318Z INFO  [sphinx_runner] Rocket has launched from http://127.0.0.1:61008", 61008),
        ] {
            #expect(!line.hasSuffix(BundledBridge.launchLine(port: port)), "\(line)")
        }
    }

    @Test func onlyTheAgentsOwnContactInfoIsTaken() {
        let info = "\(agent)_\(lsp)_1099511627777"
        func reply(_ info: String) -> Data { Data(#"{"contact_info":"\#(info)","alias":"Agent","balance_msat":9000}"#.utf8) }
        #expect(BundledBridge.contactInfo(in: reply(info), agent: agent) == info)
        #expect(BundledBridge.balanceMsat(in: reply(info)) == 9000)
        #expect(BundledBridge.balanceMsat(in: Data(#"{"contact_info":"x","balance_msat":null}"#.utf8)) == nil)
        for bad in [
            reply("\(lsp)_\(lsp)_1099511627777"),           // someone else's account
            reply("\(agent)_\(lsp)"),                        // no scid
            reply("\(agent)_\(lsp)_12a"),
            reply("\(agent)_\(lsp)_1 and more"),
            reply("\(agent)_\(String(lsp.dropLast()))_1"),
            reply("\(agent)_\(lsp)_1_2"),
            Data(#"{"alias":"Agent"}"#.utf8),
            Data("registered, contact info: \(info)".utf8),
        ] {
            #expect(BundledBridge.contactInfo(in: bad, agent: agent) == nil, "\(String(decoding: bad, as: UTF8.self))")
        }
    }

    @Test func runnerGetsItsSettingsAndNothingOfPeels() {
        let data = URL(filePath: "/tmp/peel-bridge")
        let environment = BundledBridge.environment(
            ["PATH": "/usr/bin", "HOME": "/Users/x", "TMPDIR": "/tmp/x/", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
             "ROCKET_ADDRESS": "0.0.0.0", "ROCKET_CONFIG": "/elsewhere/Rocket.toml", "BRIDGE_PUBLIC_URL": "http://evil",
             "BRIDGE_SESSION": "other", "RUNNER_ADMIN_TOKEN": "the caller's", "PEEL_AGENT_API_KEY": "model key",
             "ANTHROPIC_API_KEY": "shell key"],
            account: account, strut: strut, port: 61008, admin: "admin token", token: "bridge token", alias: "Peel",
            data: data
        )
        #expect(environment == [
            "TMPDIR": "/tmp/x/",
            "BROKER_URL": "127.0.0.1:1",
            "DB_PATH": "/tmp/peel-bridge/db",
            "ROCKET_ADDRESS": "127.0.0.1",
            "ROCKET_PORT": "61008",
            "RUNNER_ADMIN_TOKEN": "admin token",
            "BRIDGE_TOKEN": "bridge token",
            "BRIDGE_STRUT_URL": "http://127.0.0.1:4100",
            "BRIDGE_STRUT_KEY": strut.key,
            "BRIDGE_DEVICE": "mac-1",
            "BRIDGE_WORKFLOW": "orchestrator",
            "RUNNER_ALIAS": "Peel",
            "RUNNER_EXIT_ON_STDIN_EOF": "1",
            "ROCKET_CONFIG": "/tmp/peel-bridge/Rocket.toml",
        ])
        #expect(!environment.values.contains(account.seed))
        // Paired with Hive, runner names the owner to strut as their orgs know them; a caller's never counts.
        let paired = BundledBridge.environment(["BRIDGE_ACTOR": "someone else"], account: account, strut: strut, port: 61008,
                                               admin: "admin token", token: "bridge token", alias: "Peel", data: data, actor: "tom-cm1")
        #expect(paired["BRIDGE_ACTOR"] == "tom-cm1")
        #expect(BundledBridge.environment(["BRIDGE_ACTOR": "someone else"], account: account, strut: strut, port: 61008, admin: "a",
                                          token: "t", alias: "Peel", data: data)["BRIDGE_ACTOR"] == nil)
    }

    @Test func itsServerNeverPrintsTheToken() throws {
        let server = BundledBridge.Server(base: URL(string: "http://127.0.0.1:61008")!, token: "bridge token")
        var dumped = ""
        dump(server, to: &dumped)
        dump(try #require(BundledBridge(executable: URL(filePath: "/bin/sh"), data: URL(filePath: "/tmp"))), to: &dumped)
        for text in [String(describing: server), String(reflecting: server), dumped] {
            #expect(!text.contains("bridge token"))
        }
    }

    @Test func aPickedPortIsOnThisMacAndFree() throws {
        let port = try BundledBridge.freePort()
        #expect((1024...65_535).contains(port))
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(port).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
    }

    @Test func noRunnerNoBridge() {
        #expect(BundledBridge(executable: URL(filePath: "/nonexistent/sphinx-runner"), data: URL(filePath: "/tmp")) == nil)
    }

    /// The staged runner, started as the app starts it, with no broker to
    /// reach: it listens, takes the agent's seed (with an invite) and owner, and its bridge
    /// answers with Peel's token. Its store is owner-only. Started again on
    /// the same store, the seed already set is no failure.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: BundledBridge.staged.path)))
    func theStagedRunnerTakesTheAgentAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appending(path: "bridge")
        let bridge = try #require(BundledBridge(executable: BundledBridge.staged, data: data))
        var changes = 0
        bridge.onChange = { changes += 1 }

        let server = try await bridge.start(account, strut: strut, invite: String(repeating: "0a", count: 32))
        #expect(bridge.server == server && changes == 1)
        #expect(server.base.host == "127.0.0.1")
        let (status, body) = try await Web.requestStrut(
            "GET", server.base.appending(path: "bridge/health"), bearer: server.token, limit: 4096, what: "health"
        )
        #expect(status == 200 && String(decoding: body, as: UTF8.self).contains("inbox_depth"))
        let (refused, _) = try await Web.requestStrut(
            "GET", server.base.appending(path: "bridge/health"), bearer: "not the token", limit: 4096, what: "health"
        )
        #expect(refused == 401)
        #expect(try FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? Int == 0o700)
        #expect(try await bridge.start(account, strut: strut) == server)

        bridge.stop()
        #expect(bridge.server == nil && changes == 2)
        let again = try await bridge.start(account, strut: strut, invite: String(repeating: "0a", count: 32))
        #expect(again.base != server.base || again.token != server.token)
        bridge.stop(quietly: true)

        try BundledBridge.erase(data: data)
        #expect(!FileManager.default.fileExists(atPath: data.path))
    }

    /// Peel dies however it dies: its end of runner's stdin closes, and
    /// runner, started with Peel's settings, exits by itself.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: BundledBridge.staged.path)))
    func theStagedRunnerExitsWhenPeelsPipeCloses() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "peel-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = BundledBridge.staged
        process.environment = BundledBridge.environment(
            [:], account: account, strut: strut, port: try BundledBridge.freePort(), admin: "admin token",
            token: String(repeating: "t", count: 32), alias: "Agent", data: data
        )
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(for: .milliseconds(500))
        #expect(process.isRunning)
        try input.fileHandleForWriting.close()
        for _ in 0..<40 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!process.isRunning)
        if process.isRunning { process.terminate() }
    }

    /// A Peel that crashed left its runner on the store, an orphan of
    /// launchd holding it open: the next start stops it and runs, where the
    /// new runner otherwise exits as it starts (the store already open).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: BundledBridge.staged.path)))
    func aStartStopsTheRunnerACrashLeftOnItsStore() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "peel-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        // Started from a shell that exits at once, so launchd is its parent, as after Peel's crash.
        var environment = BundledBridge.environment(
            [:], account: account, strut: strut, port: try BundledBridge.freePort(), admin: "admin token",
            token: String(repeating: "t", count: 32), alias: "Agent", data: data
        )
        environment["RUNNER_EXIT_ON_STDIN_EOF"] = nil
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "\"$0\" < /dev/null > /dev/null 2>&1 & echo $!", BundledBridge.staged.path]
        shell.environment = environment
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        let leftover = try #require(pid_t(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: data.appending(path: "db.redb").path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(leftover, 0) == 0)

        let bridge = try #require(BundledBridge(executable: BundledBridge.staged, data: data))
        var failure: (any Error)?
        do { _ = try await bridge.start(account, strut: strut) } catch { failure = error }
        // Killed here only if still there: once stopped, its pid may be another process's.
        let survived = kill(leftover, 0) == 0
        if survived { kill(leftover, SIGKILL) }
        bridge.stop(quietly: true)
        if let failure { throw failure }
        #expect(!survived)
    }
}
