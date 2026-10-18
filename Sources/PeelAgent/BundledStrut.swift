import Foundation
import PeelCore

/// The strut Peel ships in `Contents/Strut` (scripts/stage-strut.sh): its
/// desktop package and the Node that runs it, started once per launch and
/// stopped when Peel quits. Its key is made here for this launch and kept
/// only in memory; its address is the port the OS gives it, read from its
/// ready line. It exits by itself when Peel goes away, however that
/// happens: its stdin is a pipe only Peel holds (`STRUT_EXIT_ON_STDIN_EOF`).
/// Its secret store (the automation token) is encrypted with a key the
/// account keeps (`Profile.strutKey`), made on its first start.
/// Its workspace and the memory graph are in the folder it is given (the app
/// account's under Application Support), and go with the account (`erase`).
/// Its workspace (workflows, steps, automations) is one Ladybug file,
/// `workspace/graph/graph.lbug`, which strut fills from the old files once.
@MainActor
public final class BundledStrut {
    /// The running strut's address and key; nil until it is ready and
    /// once it has stopped.
    public private(set) var server: MemoryServer?
    /// Called when `server` changes, ready or stopped.
    public var onChange: (() -> Void)?

    private let folder: URL
    private let data: URL
    private let secretKey: any SecretItem
    private var process: Process?
    private var stdin: Pipe?
    private var starting: Task<MemoryServer, any Error>?

    /// How long strut may take to say it is ready.
    static let readyTimeout: Duration = .seconds(30)

    /// The strut in `bundle`, if it has one, its secrets encrypted with the key kept in `secretKey`.
    public convenience init?(in bundle: Bundle = .main, data: URL = BundledStrut.dataFolder, secretKey: any SecretItem) {
        self.init(folder: bundle.bundleURL.appending(path: "Contents/Strut"), data: data, secretKey: secretKey)
    }

    /// The strut package in `folder` (its `desktop.js` and `native/node`),
    /// if there is one: for `peel agent`, which is not inside Peel.app, the
    /// one `stage-strut.sh` staged (`staged`).
    public init?(folder: URL, data: URL, secretKey: any SecretItem) {
        guard FileManager.default.isExecutableFile(atPath: folder.appending(path: "native/node").path),
              FileManager.default.fileExists(atPath: folder.appending(path: "desktop.js").path) else { return nil }
        self.folder = folder
        self.data = data
        self.secretKey = secretKey
    }

    /// Where its workspace and the memory graph live: beside the profiles, in Peel's folder.
    public nonisolated static let dataFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Peel/Strut")

    /// The data folder `profile`'s agent uses: the app account's in Peel's
    /// folder, a development profile's inside its own, so a test account
    /// never writes to the real memory.
    public nonisolated static func dataFolder(for profile: Profile) -> URL {
        switch profile.kind {
        case .app: dataFolder
        case .development: profile.directory.appending(path: "strut")
        }
    }

    /// Where strut keeps the memory graph for `data`: `graph.lbug` in its
    /// workspace's `memory` folder (`STRUT_WORKSPACE`, strut's data folder;
    /// Peel never sets `STRUT_MEMORY_DB`).
    public nonisolated static func memoryFolder(data: URL) -> URL {
        data.appending(path: "workspace/memory")
    }

    /// The strut `scripts/stage-strut.sh` staged once for this Mac, which
    /// every checkout's `bundle-app.sh` copies into `Contents/Strut`.
    public nonisolated static let staged = ProcessInfo.processInfo.environment["PEEL_STRUT_STAGE"].map { URL(filePath: $0) }
        .map { $0.appending(path: "strut") }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/dev.peel.build/strut/strut")

    /// Stops it and removes its workspace and memory graph: what the agent
    /// remembered and the automations it ran, so a later account starts empty.
    public func erase() throws {
        stop(quietly: true)
        try Self.erase(data: data)
    }

    /// Removes a workspace and memory graph, whether or not this build ships
    /// a strut to run them.
    public nonisolated static func erase(data: URL = dataFolder) throws {
        if FileManager.default.fileExists(atPath: data.path) { try FileManager.default.removeItem(at: data) }
    }

    /// Starts it, unless it is running or starting: its server once ready.
    public func start() async throws -> MemoryServer {
        if let server { return server }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { if starting == task { starting = nil } }
        return try await task.value
    }

    /// Stops it: its stdin closed and SIGTERM, then SIGKILL if it is still
    /// there after two seconds. Waits, so Peel's quit outlives it. `quietly`
    /// (quitting, erasing): no `onChange`.
    public func stop(quietly: Bool = false) {
        guard let process else { return }
        self.process = nil
        try? stdin?.fileHandleForWriting.close()
        stdin = nil
        // Gone before it returns, so nothing writes its graph once its files are moved (`MemoryBackup`).
        endProcess(process.processIdentifier, isRunning: { process.isRunning })
        if server != nil {
            server = nil
            if !quietly { onChange?() }
        }
    }

    private func launch() async throws -> MemoryServer {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        let key = try AutomationServer.newKey()
        let secrets = try Self.secretKey(in: secretKey)
        // Peel's part of the orchestrator strut seeds at boot (`Orchestrator`), written each launch.
        let hostConfig = data.appending(path: "host-config.json")
        try Orchestrator.hostConfig().write(to: hostConfig, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostConfig.path)
        let process = Process()
        process.executableURL = folder.appending(path: "native/node")
        process.arguments = [folder.appending(path: "desktop.js").path]
        process.currentDirectoryURL = folder
        process.environment = Self.environment(ProcessInfo.processInfo.environment, key: key, secretKey: secrets, data: data,
                                               hostConfig: hostConfig)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Its log may hold what the agent was asked: read and dropped.
        process.standardError = FileHandle.nullDevice

        // Read to the end, so strut never stalls on a full pipe; the first ready line is the one.
        let (ready, announce) = AsyncStream<MemoryServer>.makeStream()
        let reader = LineReader()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return announce.finish()
            }
            for line in reader.lines(adding: chunk) {
                if let server = Self.readyServer(line, key: key) { announce.yield(server) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.ended(ended) }
        }
        try process.run()
        self.process = process
        stdin = input

        let server = try await first(of: ready, within: Self.readyTimeout)
        guard let server, self.process === process else {
            // Its output can end a moment before it is reaped.
            for _ in 0..<40 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            let why = process.isRunning ? "did not answer in \(Int(Self.readyTimeout.components.seconds)) seconds"
                : "exited with status \(process.terminationStatus)"
            if self.process === process { stop(quietly: true) }
            throw PeelError("Peel's strut \(why).")
        }
        self.server = server
        onChange?()
        return server
    }

    private func ended(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        stdin = nil
        guard server != nil else { return }
        server = nil
        onChange?()
    }

    /// The server a ready line names, `{"event":"ready","port":…,"host":"127.0.0.1","key":…}`,
    /// only on this Mac and only with the key Peel gave it.
    nonisolated static func readyServer(_ line: String, key: String) -> MemoryServer? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              json["event"] as? String == "ready", json["host"] as? String == "127.0.0.1",
              let port = json["port"] as? Int, (1...65_535).contains(port),
              json["key"] as? String == key,
              let url = URL(string: "http://127.0.0.1:\(port)") else { return nil }
        return MemoryServer(base: url, key: key)
    }

    /// The key kept in `item`, or a new random one kept there.
    nonisolated static func secretKey(in item: any SecretItem) throws -> String {
        if let kept = try item.read(), let key = String(data: kept, encoding: .utf8), key.count == 64 { return key }
        let key = try AutomationServer.newKey()
        try item.write(Data(key.utf8))
        return key
    }

    /// Peel's own environment without anything that would change how Node,
    /// strut or its OpenSSL runs (`DYLD_*`, `NODE_*`, `STRUT_*`, `OPENSSL_*`,
    /// `SSL_CERT_*`) or that is Peel's own (`PEEL_*`, the CLI's model key
    /// among them), without a model provider's key (strut takes the connected
    /// model's from its secret store, `AutomationsClient.setModel`, so one
    /// disconnected is gone), and then strut's: this Mac only, a port the OS picks,
    /// Peel's keys and folders, exit with Peel. Its OpenSSL (Ladybug's) reads no
    /// configuration and loads no engine or provider: it was built for
    /// Homebrew's folders, which another user may own. `hostConfig`: the
    /// file of Peel's delta for the workflows strut ships (`STRUT_HOST_CONFIG`).
    nonisolated static func environment(
        _ inherited: [String: String], key: String, secretKey: String, data: URL, hostConfig: URL
    ) -> [String: String] {
        var environment = inherited.filter { name, _ in
            // A company's extra certificates, which Node otherwise lacks behind a proxy that inspects TLS.
            name == "NODE_EXTRA_CA_CERTS"
                || !["DYLD_", "NODE_", "STRUT_", "OPENSSL_", "SSL_CERT_", "PEEL_"].contains { name.hasPrefix($0) }
                && !AutomationsClient.keySecrets.contains(name)
        }
        environment.merge([
            "STRUT_HOST": "127.0.0.1",
            "STRUT_PORT": "0",
            "STRUT_API_KEY": key,
            "STRUT_READY_KEY": "1",
            "STRUT_SECRET_KEY": secretKey,
            "STRUT_WORKSPACE_BACKEND": "ladybug",
            "STRUT_WORKSPACE": data.appending(path: "workspace").path,
            "STRUT_CACHE_DIR": data.appending(path: "cache").path,
            "STRUT_HOST_CONFIG": hostConfig.path,
            "STRUT_EXIT_ON_STDIN_EOF": "1",
            "OPENSSL_CONF": "/dev/null",
            "OPENSSL_MODULES": "/var/empty",
            "OPENSSL_ENGINES": "/var/empty",
        ]) { _, new in new }
        return environment
    }
}

/// The first thing `stream` yields within `timeout`; nil if it ends or the time runs out first.
func first<T: Sendable>(of stream: AsyncStream<T>, within timeout: Duration) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await stream.first { _ in true } }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Ends process `pid`: SIGTERM, then SIGKILL if it is still there after two
/// seconds; returns once it is gone, or a second after the SIGKILL.
func endProcess(_ pid: pid_t, isRunning: () -> Bool) {
    guard isRunning() else { return }
    kill(pid, SIGTERM)
    let deadline = Date.now.addingTimeInterval(2)
    while isRunning(), Date.now < deadline { usleep(50_000) }
    if isRunning() { kill(pid, SIGKILL) }
    let killed = Date.now.addingTimeInterval(1)
    while isRunning(), Date.now < killed { usleep(10_000) }
}

/// Lines from chunks of a pipe's output, read on Foundation's own queue
/// (`readabilityHandler`), not the concurrency pool, which busy work can
/// starve while strut (or the bridge) waits on a full pipe.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func lines(adding chunk: Data) -> [String] {
        lock.withLock {
            pending.append(chunk)
            var lines: [String] = []
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                pending.removeSubrange(...end)
            }
            return lines
        }
    }
}
