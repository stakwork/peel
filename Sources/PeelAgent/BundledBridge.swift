import Darwin
import Foundation
import PeelCore

/// The agent's bridge Peel ships in `Contents/Bridge` (scripts/stage-bridge.sh):
/// sphinx/runner, which holds the agent's own Sphinx account and pipes its
/// owner's DM to strut (docs/agent-on-strut.md, section 4). Started beside
/// Peel's strut, which it reaches on loopback with strut's key, and stopped
/// with it; gone by itself if Peel dies, since its stdin is a pipe only Peel
/// holds (`RUNNER_EXIT_ON_STDIN_EOF`). Its admin token and the token strut
/// uses with it are made here for each launch and kept only in memory. Its
/// port is picked here, since runner names its own address to strut from
/// it, and trusted only once runner says it has it (Rocket's launch line on
/// its own output). Only then are the agent's seed (`AgentAccount`, derived
/// from the account's; never the words), with an invite from this account
/// for its first register, and its owner, this account, set over its admin
/// routes. Its store, the agent's account and its inbox, is in the folder it
/// is given, owner-only, and goes with the account (`erase`).
@MainActor
public final class BundledBridge: CustomReflectable {
    /// Nothing of it, its tokens least of all, however it is dumped.
    public nonisolated var customMirror: Mirror { Mirror(self, children: []) }

    /// Where strut reaches the running bridge, and the token it takes there
    /// (`BRIDGE_TOKEN`); never printed.
    public struct Server: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let base: URL
        let token: String
        public var description: String { base.absoluteString }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["base": base], displayStyle: .struct) }
        /// strut's callback for a run's end (the token in its query, as the
        /// bridge gives its own runs): an automation's report goes to the DM.
        public var runEnds: URL {
            var parts = URLComponents(url: base.appending(path: "bridge/run-end"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "token", value: token)]
            return parts.url!
        }
    }

    /// The running bridge; nil until it is ready and once it has stopped.
    public private(set) var server: Server?
    /// Called when `server` changes.
    public var onChange: (() -> Void)?

    private let executable: URL
    private let data: URL
    private var process: Process?
    private var stdin: Pipe?
    /// The running runner's admin token and the agent it holds.
    private var admin: (token: String, agent: String)?
    private var starting: Task<Server, any Error>?

    /// How long runner may take to listen, and then to start the bridge once it has the seed.
    static let readyTimeout: Duration = .seconds(15)
    /// The workflow each of the owner's messages runs (PR 5 seeds it in strut).
    nonisolated static let workflow = "orchestrator"
    /// What the invite for the agent's first register holds: enough for its
    /// paid answer to this account's key exchange (3 sats and a 1-sat ping),
    /// which the server forwards before it credits the exchange's own sats.
    public nonisolated static let inviteMsat: UInt64 = 10_000

    /// The bridge in `bundle`, if it has one, its store in `data`.
    public convenience init?(in bundle: Bundle = .main, data: URL) {
        self.init(executable: bundle.bundleURL.appending(path: "Contents/Bridge/sphinx-runner"), data: data)
    }

    /// The runner at `executable`, if there is one: for the journeys, the one
    /// `stage-bridge.sh` staged (`staged`).
    public init?(executable: URL, data: URL) {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        self.executable = executable
        self.data = data
    }

    /// Where the agent's account and inbox live: beside the profiles, in Peel's folder.
    public nonisolated static let dataFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Peel/Bridge")

    /// The data folder `profile`'s bridge uses: the app account's in Peel's
    /// folder, a development profile's inside its own.
    public nonisolated static func dataFolder(for profile: Profile) -> URL {
        switch profile.kind {
        case .app: dataFolder
        case .development: profile.directory.appending(path: "bridge")
        }
    }

    /// The runner `scripts/stage-bridge.sh` staged once for this Mac, which
    /// every checkout's build copies into `Contents/Bridge`.
    public nonisolated static let staged = (ProcessInfo.processInfo.environment["PEEL_BRIDGE_STAGE"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/dev.peel.build/bridge"))
        .appending(path: "sphinx-runner")

    /// Removes a bridge's store, the agent's account on this Mac (the words
    /// still recover it) and its inbox, whether or not this build ships a bridge.
    public nonisolated static func erase(data: URL = dataFolder) throws {
        if FileManager.default.fileExists(atPath: data.path) { try FileManager.default.removeItem(at: data) }
    }

    /// Starts it for `account` beside `strut` (Peel's own, on this Mac),
    /// unless it is running or starting: its server once the bridge runs.
    /// `invite`, a code from an invite this account made, goes with the seed
    /// for the account's first register (runner ignores it after that, and a
    /// seed already set takes none). `alias` is the name the agent's messages carry.
    public func start(_ account: AgentAccount, strut: MemoryServer, invite: String? = nil, alias: String = "Agent") async throws -> Server {
        if let server { return server }
        if let starting { return try await starting.value }
        let task = Task { try await launch(account, strut: strut, invite: invite, alias: alias) }
        starting = task
        defer { if starting == task { starting = nil } }
        return try await task.value
    }

    /// What the agent pays to answer its owner's key exchange: the core's
    /// `PRICE_TO_MEET` (3 sats) and a 1-sat ping.
    nonisolated static let answerMsat: UInt64 = 4_000

    /// What setting up the agent's account costs this account, at most: the
    /// invite, then the key exchange and its ping (`Engine.keyExchangeMsat`),
    /// of which the agent pays 3 sats back. Shown before the person starts it.
    public nonisolated static var setUpMsat: UInt64 { inviteMsat + Engine.keyExchangeMsat + Engine.pingMsat(toTribe: false) }

    /// Setting up was not started: the agent is not a contact yet, and only
    /// the person's own "Set up" may pay for it (`setUp`'s `pair`).
    public struct NotSetUp: Error {}

    /// The agent's account on `engine`'s, from its seed (`agentAccount`),
    /// running here beside `strut`; the account it registered checked to be
    /// the agent's, whatever store runner had. Unless it is already a contact
    /// (an account set up before, on this Mac or another from the same words,
    /// is used again: one agent 1, never a second), it is added, named
    /// `alias`, only when `pair` (the person's "Set up", which showed what it
    /// costs, `setUpMsat`; otherwise `NotSetUp`): it registers with
    /// an invite from the account (`inviteMsat`), so it has sats to answer the
    /// key exchange. One invite per store, its code kept there and used again
    /// until the agent has registered, so it is always the one runner holds.
    /// Then its sats are asked back: they return if the agent did not need it
    /// (an account registered before, from the same words), and once redeemed
    /// the server says nothing and it is set aside (`forgetInvite`). The key
    /// exchange goes only when the agent can pay to answer it, and setting up
    /// ends when it has. Waits up to two minutes for the account to be online.
    public func setUp(on engine: Engine, beside strut: MemoryServer, alias: String, pair: Bool) async throws -> AgentAccount {
        let account = try await engine.agentAccount()
        let contact = { try await engine.contacts().first { $0.pubkey == account.pubkey } }
        if try await contact() != nil {
            try await launched(account, strut: strut, invite: nil, alias: alias)
            _ = try await agentContactInfo()
            guard try await contact()?.contactKey != nil else {
                throw PeelError("Your assistant has not answered your key exchange yet. Try again in a minute.")
            }
            return account
        }
        guard pair else { throw NotSetUp() }
        let invite = try await agentInvite(on: engine, alias: alias)
        try await launched(account, strut: strut, invite: invite, alias: alias)
        let (info, balance) = try await registered()
        // The server holds nothing more for it either way: the code is runner's no longer.
        try? FileManager.default.removeItem(at: Self.inviteFile(in: data))
        await Task.detached {
            do {
                try await engine.cancelInvite(code: invite, wait: .seconds(10))
            } catch Engine.Failure.inviteNotRefunded {
                try? await engine.forgetInvite(code: invite)
            } catch {}
        }.value
        guard balance >= Self.answerMsat else {
            throw PeelError("Your assistant has no sats to answer your key exchange: its account was made before, without this invite.")
        }
        // The person's "Set up" showed this cost: no second confirmation.
        _ = try await Self.online { try await engine.addContact(code: info, alias: alias, confirmedMsat: Engine.keyExchangeMsat) }
        let deadline = ContinuousClock.now + .seconds(30)
        while try await contact()?.contactKey == nil {
            guard ContinuousClock.now < deadline else { throw PeelError("Your assistant has not answered your key exchange yet. Try again in a minute.") }
            try await Task.sleep(for: .milliseconds(500))
        }
        return account
    }

    /// Started, unless the set-up was cancelled before or while it started
    /// (the account locked, the brain moved): then stopped again.
    private func launched(_ account: AgentAccount, strut: MemoryServer, invite: String?, alias: String) async throws {
        try Task.checkCancellation()
        _ = try await start(account, strut: strut, invite: invite, alias: alias)
        if Task.isCancelled {
            stop(quietly: true)
            throw CancellationError()
        }
    }

    /// The code of this store's invite for the agent: the one made before if
    /// the server still holds or is taking its sats, else a new one, kept in
    /// the store before anything else. Made apart from the set-up's task, so
    /// a cancel never leaves an invite without its code.
    private func agentInvite(on engine: Engine, alias: String) async throws -> String {
        let file = Self.inviteFile(in: data)
        if let kept = try? String(contentsOf: file, encoding: .utf8),
           let status = try engine.storage.invite(code: kept)?.status, [.sending, .ready].contains(status) {
            guard status == .ready else { throw PeelError("The server has not confirmed your agent's invite yet. Try again in a minute.") }
            return kept
        }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let made = try await Task.detached {
            try await Self.online {
                try await engine.makeInvite(
                    amountMsat: Self.inviteMsat, nickname: alias, confirmedMsat: Self.inviteMsat, wait: .seconds(60)
                )
            }
        }.value
        try Data(made.code.utf8).write(to: file, options: .atomic)
        guard made.status == .ready else { throw PeelError("The server has not confirmed your agent's invite yet. Try again in a minute.") }
        return made.code
    }

    nonisolated private static func inviteFile(in data: URL) -> URL { data.appending(path: "invite") }

    /// `work`, again every two seconds while the account is offline, for two minutes.
    nonisolated private static func online<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(120)
        while true {
            do { return try await work() } catch Engine.Failure.notConnected where ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The agent's contact info (`pubkey_lsp_scid`) once runner has
    /// registered its account (`GET /contact_info`, 503 until then), waiting
    /// up to `timeout`; only the agent's own is taken.
    func agentContactInfo(within timeout: Duration = .seconds(30)) async throws -> String {
        try await registered(within: timeout, balance: false).info
    }

    /// The agent's contact info once registered, and with `balance` its
    /// balance once the server has said it (0 when not asked for).
    private func registered(within timeout: Duration = .seconds(30), balance: Bool = true) async throws -> (info: String, balanceMsat: UInt64) {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let server, let admin else { throw PeelError("Peel's bridge stopped before the agent's account registered.") }
            if let (status, body) = try? await Web.requestStrut(
                "GET", server.base.appending(path: "contact_info"), headers: ["x-admin-token": admin.token], limit: 4096,
                what: "the agent's contact info", timeout: 5
            ), status == 200 {
                guard let info = Self.contactInfo(in: body, agent: admin.agent) else {
                    throw PeelError("Peel's bridge holds an account that is not your agent's.")
                }
                if !balance { return (info, 0) }
                if let msat = Self.balanceMsat(in: body) { return (info, msat) }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PeelError("The agent's account did not register in \(Int(timeout.components.seconds)) seconds.")
    }

    /// Stops it: its stdin closed, SIGTERM, then SIGKILL if it is still there
    /// after two seconds. Waits, so Peel's quit outlives it. `quietly`
    /// (quitting, erasing): no `onChange`.
    public func stop(quietly: Bool = false) {
        starting?.cancel()
        guard let process else { return }
        try? stdin?.fileHandleForWriting.close()
        endProcess(process.processIdentifier, isRunning: { process.isRunning })
        clear(quietly: quietly)
    }

    /// Nothing running: what a stop or runner's own end leaves.
    private func clear(quietly: Bool) {
        process = nil
        stdin = nil
        admin = nil
        guard server != nil else { return }
        server = nil
        if !quietly { onChange?() }
    }

    private func launch(_ account: AgentAccount, strut: MemoryServer, invite: String?, alias: String) async throws -> Server {
        guard !strut.isHomeServer else { throw PeelError("Peel's bridge runs only beside Peel's own strut.") }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        // It holds the agent's seed, which the words recover: never in a backup.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = data
        try folder.setResourceValues(excluded)
        let port = try Self.freePort()
        let admin = try BundledStrut.newKey()
        let token = try BundledStrut.newKey()
        let process = Process()
        process.executableURL = executable
        // Not the data folder: runner reads `./runner/.env` from where it starts.
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.environment = Self.environment(
            ProcessInfo.processInfo.environment, account: account, strut: strut, port: port, admin: admin, token: token,
            alias: alias, data: data
        )
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Runner logs to its output; nothing comes here.
        process.standardError = FileHandle.nullDevice

        // Read to the end, so runner never stalls on a full pipe; the launch line is looked for until it comes.
        let (listening, announce) = AsyncStream<Void>.makeStream()
        let reader = LineReader()
        let launched = Self.launchLine(port: port)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return announce.finish()
            }
            if reader.lines(adding: chunk).contains(where: { $0.hasSuffix(launched) }) {
                announce.yield()
                announce.finish()
            }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.ended(ended) }
        }
        try process.run()
        self.process = process
        stdin = input

        do {
            guard try await first(of: listening, within: Self.readyTimeout) != nil, process.isRunning,
                  self.process === process else {
                throw PeelError("Peel's bridge \(process.isRunning ? "did not listen in \(Int(Self.readyTimeout.components.seconds)) seconds" : "stopped as it started").")
            }
            let base = URL(string: "http://127.0.0.1:\(port)")!
            var seed = ["network": account.network, "seed": account.seed]
            if let invite { seed["invite"] = invite }
            try await Self.admin(base, "seed", seed, token: admin, allowing: [409])
            try await Self.admin(base, "add_sender", ["pubkey": account.owner], token: admin)
            try await Self.waitForBridge(base, token: token, while: { process.isRunning })
            guard self.process === process else { throw CancellationError() }
            self.admin = (admin, account.pubkey)
            let server = Server(base: base, token: token)
            self.server = server
            onChange?()
            return server
        } catch {
            if self.process === process { stop(quietly: true) }
            throw error
        }
    }

    private func ended(_ ended: Process) {
        guard ended === process else { return }
        clear(quietly: false)
    }

    /// One admin call, `POST /<route>` with the admin token: refused unless
    /// it answers 200 (or a status in `allowing`: the seed already set).
    private static func admin(_ base: URL, _ route: String, _ body: [String: String], token: String, allowing: Set<Int> = []) async throws {
        let (status, _) = try await Web.requestStrut(
            "POST", base.appending(path: route), json: JSONSerialization.data(withJSONObject: body),
            headers: ["x-admin-token": token], limit: 4096, what: "the bridge's \(route)", timeout: 10
        )
        guard status == 200 || allowing.contains(status) else {
            throw PeelError("Peel's bridge refused \(route == "seed" ? "the agent's account" : "its owner") (HTTP \(status)).")
        }
    }

    /// Until the bridge itself answers (`GET /bridge/health`, which says 503
    /// until runner has the seed and starts it), while runner runs.
    private static func waitForBridge(_ base: URL, token: String, while running: () -> Bool) async throws {
        let deadline = ContinuousClock.now + readyTimeout
        while ContinuousClock.now < deadline, running() {
            if let (status, _) = try? await Web.requestStrut(
                "GET", base.appending(path: "bridge/health"), bearer: token, limit: 4096, what: "the bridge's health", timeout: 5
            ), status == 200 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PeelError("Peel's bridge \(running() ? "did not start in \(Int(readyTimeout.components.seconds)) seconds" : "stopped as it started").")
    }

    /// Runner's settings (its README), and nothing of Peel's own environment
    /// but where temporary files go: no `DYLD_*`, no keys, no `ROCKET_*` or
    /// `BRIDGE_*` from whoever started Peel. This Mac only, the port picked
    /// here, the workflow PR 5 seeds, the agent's session left at runner's default.
    nonisolated static func environment(
        _ inherited: [String: String], account: AgentAccount, strut: MemoryServer, port: Int, admin: String, token: String,
        alias: String, data: URL
    ) -> [String: String] {
        var environment = inherited.filter { $0.key == "TMPDIR" }
        environment.merge([
            "BROKER_URL": account.broker,
            "DB_PATH": data.appending(path: "db").path,
            "ROCKET_ADDRESS": "127.0.0.1",
            "ROCKET_PORT": "\(port)",
            "RUNNER_ADMIN_TOKEN": admin,
            "BRIDGE_TOKEN": token,
            "BRIDGE_STRUT_URL": strut.base.absoluteString,
            "BRIDGE_STRUT_KEY": strut.key,
            "BRIDGE_DEVICE": account.device,
            "BRIDGE_WORKFLOW": workflow,
            "RUNNER_ALIAS": alias,
            "RUNNER_EXIT_ON_STDIN_EOF": "1",
            // Rocket looks for Rocket.toml up from where it starts: none is read.
            "ROCKET_CONFIG": data.appending(path: "Rocket.toml").path,
        ]) { _, new in new }
        return environment
    }

    /// The end of Rocket's launch line, which says runner holds `port` on this
    /// Mac: `… WARN  [rocket::launch] Rocket has launched from http://127.0.0.1:<port>`.
    nonisolated static func launchLine(port: Int) -> String {
        "[rocket::launch] Rocket has launched from http://127.0.0.1:\(port)"
    }

    /// The balance in runner's `/contact_info` reply, once the server has said it.
    nonisolated static func balanceMsat(in reply: Data) -> UInt64? {
        ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["balance_msat"] as? UInt64
    }

    /// The contact info in runner's `/contact_info` reply
    /// (`{"contact_info": "<pubkey>_<lsp>_<scid>", "alias": …}`), only if it is `agent`'s.
    nonisolated static func contactInfo(in reply: Data, agent: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let info = json["contact_info"] as? String else { return nil }
        let parts = info.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == agent, parts[1].count == 66, parts[1].allSatisfy(\.isHexDigit),
              !parts[2].isEmpty, parts[2].allSatisfy(\.isASCII), UInt64(parts[2]) != nil else { return nil }
        return info
    }

    /// A port on 127.0.0.1 nothing holds now, for runner to take.
    nonisolated static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw PeelError("could not find a port for Peel's bridge") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw PeelError("could not find a port for Peel's bridge") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
