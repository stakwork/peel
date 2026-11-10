import Foundation
import MQTTNIO
import NIOCore
import NIOFoundationCompat
import NIOTransportServices
import PeelDiagnostics
import Synchronization

/// Where the account's broker lives.
public struct ServerAddress: Sendable, Equatable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var tls: Bool
    /// Whether MQTT runs over a WebSocket (`ws://`, `wss://`), as through
    /// networks that let only the web's ports out.
    public var webSocket = false
    /// The WebSocket's URL path; unused unless `webSocket`.
    public var path = Self.defaultPath

    public static let defaultPath = "/mqtt"
    /// The port `wss://` takes when none is given.
    public static let webSocketPort = 443

    init(host: String, port: Int, tls: Bool, webSocket: Bool = false, path: String = ServerAddress.defaultPath) {
        self.host = host
        self.port = port
        self.tls = tls
        self.webSocket = webSocket
        self.path = path
    }

    /// Parses "host:port" with an optional scheme. TLS is on unless the scheme is
    /// `mqtt://` or the host is this machine. `wss://host[:port][/path]` is MQTT
    /// over a secure WebSocket (port 443, path `/mqtt` unless given); `ws://` is
    /// the same in the clear and only for this machine.
    public init?(_ string: String) {
        var rest = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme: String?
        if let range = rest.range(of: "://") {
            scheme = rest[..<range.lowerBound].lowercased()
            rest = String(rest[range.upperBound...])
        }
        let isWebSocket = scheme == "ws" || scheme == "wss"
        if isWebSocket, let slash = rest.firstIndex(of: "/") {
            let urlPath = String(rest[slash...])
            guard !urlPath.contains(where: \.isWhitespace) else { return nil }
            path = urlPath
            rest = String(rest[..<slash])
        } else if rest.contains("/") {
            return nil
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, !parts[0].isEmpty else { return nil }
        if parts.count == 2 {
            guard let port = Int(parts[1]) else { return nil }
            self.port = port
        } else if scheme == "wss" {
            port = Self.webSocketPort
        } else {
            return nil
        }
        host = String(parts[0])
        webSocket = isWebSocket
        switch scheme {
        case nil: tls = !Self.isLoopback(host: host)
        case "mqtts", "ssl", "tls", "wss": tls = true
        case "mqtt", "tcp": tls = false
        case "ws":
            guard Self.isLoopback(host: host) else { return nil }
            tls = false
        default: return nil
        }
    }

    /// A server someone else named (an invite, the public config): as `init`,
    /// but plaintext only to this machine, so an `mqtt://` in an invite
    /// cannot take the login and the account's traffic off TLS. Only the
    /// CLI's `--server` may ask for plaintext elsewhere.
    static func named(_ string: String) throws -> ServerAddress {
        guard let address = ServerAddress(string) else { throw PeelError("the server address \(string) is unreadable") }
        guard address.tls || isLoopback(host: address.host) else {
            throw PeelError("\(address.host) is named without TLS; Peel connects in the clear only to this Mac")
        }
        return address
    }

    /// This machine: the only place plaintext is allowed without asking.
    public static func isLoopback(host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    /// Round-trips through `init`, so what is stored keeps its TLS setting.
    public var description: String {
        if webSocket { return "\(tls ? "wss" : "ws")://\(host):\(port)\(path)" }
        return "\(tls ? "mqtts" : "mqtt")://\(host):\(port)"
    }

    /// The route for networks that let only the web's ports out: secure
    /// WebSocket on 443, same host. Derived when connecting and never stored
    /// (so `agentAccount` still sees the address as named). Only for a TLS
    /// address off this machine, and none for one that is already a WebSocket.
    var fallback: ServerAddress? {
        guard tls, !webSocket, !Self.isLoopback(host: host) else { return nil }
        return ServerAddress(host: host, port: Self.webSocketPort, tls: true, webSocket: true)
    }

    /// The routes to try, in order. The address as named comes first, except
    /// that when the fallback was the last to work it comes first, unless
    /// `probingPrimary` asks to check whether the named one works again.
    func routes(lastWorked: ServerAddress? = nil, probingPrimary: Bool = false) -> [ServerAddress] {
        guard let fallback else { return [self] }
        if let lastWorked, lastWorked == fallback, !probingPrimary { return [fallback, self] }
        return [self, fallback]
    }
}

struct Inbound: Sendable {
    let topic: String
    let payload: Data
}

/// The clients alive: each `Transport` counts when it is made and stops counting once, when it is closed
/// or left behind after `Transport.closeTimeout`. The login is bound to one client ID, so more than one
/// alive at once means the broker takes the session over from the one before and a reader may be left
/// running on a socket that was closed (`Engine.establish` expects none).
final class LiveClients: Sendable {
    static let shared = LiveClients()
    private let alive = Mutex(0)

    var count: Int { alive.withLock { $0 } }

    /// One more client alive; the count after.
    func opened() -> Int { alive.withLock { $0 += 1; return $0 } }

    /// One client less; the count after.
    func released() -> Int { alive.withLock { $0 = max($0 - 1, 0); return $0 } }
}

/// One MQTT connection. The login is a signed timestamp, so a connection is never
/// reused: reconnecting means signing a fresh timestamp and making a new Transport.
final class Transport: Sendable {
    /// The largest WebSocket frame taken from the broker (16 MB).
    static let webSocketMaxFrameSize = 1 << 24

    private let client: MQTTClient
    /// When the broker last sent anything; see `answersPing`.
    private let lastHeard: LastHeard
    /// Whether a read failed on this connection (`answersPing` then says no).
    private let readFailed: ReadFailed
    /// Set once the connection is left behind (`close` ran out of time): its listeners deliver nothing more.
    private let abandoned: Flag
    /// Set once the client stops counting as alive (`LiveClients`).
    private let released = Flag()
    private let registry: LiveClients
    /// The one `close`, which every caller awaits.
    private let closeTask = Mutex<Task<Void, Never>?>(nil)
    /// Whether the client was left behind un-shut-down after `closeTimeout`.
    var isAbandoned: Bool { abandoned.isSet }
    /// Whether the client no longer counts as alive: closed, or abandoned.
    var isReleased: Bool { released.isSet }
    /// The clients alive now, of every transport.
    static var liveCount: Int { LiveClients.shared.count }
    /// How long this transport's `close` waits; tests shorten it.
    private let closeLimit = Mutex(Transport.closeTimeout)
    /// Tests only: how long the client's disconnect takes before it starts.
    private let testCloseDelay = Mutex<Duration?>(nil)
    #if DEBUG
    func setCloseForTesting(limit: Duration? = nil, delay: Duration? = nil) {
        if let limit { closeLimit.withLock { $0 = limit } }
        testCloseDelay.withLock { $0 = delay }
    }
    #endif
    /// Whether a read failed on this connection: it is dead whatever its socket says.
    var hasReadFailure: Bool { readFailed.isSet }
    /// Tests only (`init(publishing:)`): whether pings are answered.
    private let testAnswersPing = Mutex(true)
    func setAnswersPingForTesting(_ answers: Bool) { testAnswersPing.withLock { $0 = answers } }
    /// How long `close` waits for the client to disconnect and shut down.
    static let closeTimeout: Duration = .seconds(3)

    /// Messages from the broker, listened for from the moment the transport
    /// exists. The stream ends when the connection closes.
    let inbound: AsyncStream<Inbound>
    /// Takes the place of the client's write; set only by the tests' `init(publishing:)`.
    private let testWrite: (@Sendable (String, Data) async throws -> Void)?

    convenience init(server: ServerAddress, clientID: String, username: String, password: String, allowUntrustedCertificate: Bool) {
        self.init(
            server: server, clientID: clientID, username: username, password: password,
            allowUntrustedCertificate: allowUntrustedCertificate, testWrite: nil, registry: .shared
        )
    }

    #if DEBUG
    /// Tests only: stands in for a connected broker that answers pings and
    /// takes every connect and subscribe, with publishes going to `write`
    /// in place of it and throwing what it throws, mapped as a real
    /// write's are, so a test can cut a send short.
    convenience init(publishing write: @escaping @Sendable (String, Data) async throws -> Void, registry: LiveClients = .shared) {
        self.init(
            server: ServerAddress("mqtt://127.0.0.1:1")!, clientID: "test", username: "test", password: "test",
            allowUntrustedCertificate: false, testWrite: write, registry: registry
        )
    }
    #endif

    private init(
        server: ServerAddress, clientID: String, username: String, password: String, allowUntrustedCertificate: Bool,
        testWrite: (@Sendable (String, Data) async throws -> Void)?, registry: LiveClients
    ) {
        self.testWrite = testWrite
        self.registry = registry
        let tls: MQTTClient.TLSConfigurationType? = server.tls
            ? .ts(TSTLSConfiguration(certificateVerification: allowUntrustedCertificate ? .none : .fullVerification))
            : nil
        let client = MQTTClient(
            host: server.host,
            port: server.port,
            identifier: clientID,
            eventLoopGroupProvider: .shared(NIOTSEventLoopGroup.singleton),
            configuration: MQTTClient.Configuration(
                // The engine pings instead (`answersPing`): a failed ping of
                // the client's own never closes the connection, so a dead
                // one that still looks open is never noticed.
                disablePing: true,
                keepAliveInterval: .seconds(15),
                // How long the broker may take to acknowledge a connect or a
                // subscribe; without one a connect to a dead network hangs
                // in "connecting" for good.
                timeout: .seconds(20),
                userName: username,
                password: password,
                useSSL: server.tls,
                useWebSockets: server.webSocket,
                tlsConfiguration: tls,
                webSocketURLPath: server.webSocket ? server.path : nil,
                // A page of history or a large message is one frame, well
                // over the client's 16 KB default, which closes the
                // WebSocket as soon as one arrives.
                webSocketMaxFrameSize: Self.webSocketMaxFrameSize
            )
        )
        self.client = client
        let lastHeard = LastHeard()
        self.lastHeard = lastHeard
        let readFailed = ReadFailed()
        self.readFailed = readFailed
        let abandoned = Flag()
        self.abandoned = abandoned
        inbound = AsyncStream { continuation in
            client.addPublishListener(named: "peel") { result in
                // A client left behind (`close` ran out of time) is harmless: it delivers nothing.
                if abandoned.isSet { return }
                switch result {
                case .success(let info):
                    lastHeard.now()
                    continuation.yield(Inbound(topic: info.topicName, payload: Data(buffer: info.payload)))
                case .failure:
                    // A read that fails (a bad file descriptor, say) leaves a
                    // connection that is not closed and hears nothing: it is
                    // dead. Ending the stream has the engine close it and
                    // connect afresh (`Engine.connectionClosed`). No error
                    // text is kept.
                    if readFailed.set() { Diagnostics.recordReadFailure() }
                    continuation.finish()
                }
            }
            client.addCloseListener(named: "peel") { _ in
                if abandoned.isSet { return }
                continuation.finish()
            }
        }
        Diagnostics.recordTransportLifecycle(stage: .opened, live: registry.opened())
    }

    func connect() async throws {
        if testWrite != nil { return }
        try await client.connect(cleanSession: true)
    }

    func subscribe(_ topics: [String]) async throws {
        if testWrite != nil { return }
        try await whileConnected {
            _ = try await client.subscribe(to: topics.map { MQTTSubscribeInfo(topicFilter: $0, qos: .atMostOnce) })
        }
    }

    func publish(_ topic: String, _ payload: Data) async throws {
        try await whileConnected {
            if let testWrite { return try await testWrite(topic, payload) }
            try await client.publish(to: topic, payload: ByteBuffer(data: payload), qos: .atMostOnce)
        }
    }

    /// Whether the broker answers a ping within `timeout`, or sent anything
    /// else meanwhile (on a slow link the answer can queue behind a page of
    /// history). A connection that does neither is dead whatever its socket
    /// says (a network that went, a path that changed), and is the caller's
    /// to close.
    func answersPing(within timeout: Duration) async -> Bool {
        if testWrite != nil { return testAnswersPing.withLock { $0 } }
        let (answers, answered) = AsyncStream.makeStream(of: Bool.self)
        if readFailed.isSet { return false }
        let (client, lastHeard, readFailed, asked) = (client, lastHeard, readFailed, ContinuousClock.now)
        // The client's ping ignores cancellation; it ends at the client's
        // ACK timeout, or when the connection is closed.
        Task { answered.yield((try? await client.ping()) != nil) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            answered.yield(lastHeard.since(asked))
        }
        defer {
            timer.cancel()
            answered.finish()
        }
        for await alive in answers { return alive && !readFailed.isSet }
        return false
    }

    /// `notConnected` when the connection had already gone, so nothing was
    /// written (a send may then be marked failed). A write the closing
    /// connection cut short may have left, so it keeps its own error.
    private func whileConnected(_ send: () async throws -> Void) async throws {
        do {
            try await send()
        } catch MQTTError.noConnection {
            throw Engine.Failure.notConnected
        }
    }

    /// Disconnects and shuts the client down, but waits no longer than
    /// `closeTimeout`: on a socket gone bad they can hang, and the caller
    /// must not hang with them. A client that did not finish in time is
    /// abandoned: it stops counting as alive and its listeners go quiet, so
    /// it can neither deliver messages nor end `inbound`. The close runs
    /// once; every caller waits for it.
    func close() async {
        let task = closeTask.withLock { state -> Task<Void, Never> in
            if let state { return state }
            let created = Task { await self.performClose() }
            state = created
            return created
        }
        await task.value
    }

    private func performClose() async {
        let client = client
        let delay = testCloseDelay.withLock { $0 }
        let limit = closeLimit.withLock { $0 }
        if testWrite != nil, delay == nil {
            // A test transport's client never connected: waiting on it would
            // take its connect timeout. Close cleanly now, and still shut the
            // client down (mqtt-nio requires it before deinit).
            Task { try? await client.shutdown() }
            if released.set() {
                Diagnostics.recordTransportLifecycle(stage: .closed, live: registry.released())
            }
            return
        }
        let (done, finished) = AsyncStream.makeStream(of: Bool.self)
        Task {
            if let delay { try? await Task.sleep(for: delay) }
            try? await client.disconnect()
            try? await client.shutdown()
            finished.yield(true)
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            finished.yield(false)
        }
        var shutDown = false
        for await result in done {
            shutDown = result
            break
        }
        timer.cancel()
        finished.finish()
        if !shutDown { abandoned.set() }
        if released.set() {
            Diagnostics.recordTransportLifecycle(stage: shutDown ? .closed : .abandoned, live: registry.released())
        }
    }
}

/// A flag that is set once.
private final class Flag: Sendable {
    private let flag = Mutex(false)

    var isSet: Bool { flag.withLock { $0 } }

    /// Sets it; true only the first time.
    @discardableResult
    func set() -> Bool { flag.withLock { let first = !$0; $0 = true; return first } }
}

/// When a connection last heard from the broker.
private final class LastHeard: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    func now() { instant.withLock { $0 = .now } }

    func since(_ start: ContinuousClock.Instant) -> Bool { instant.withLock { $0 > start } }
}

/// Whether a read failed on a connection.
private final class ReadFailed: Sendable {
    private let flag = Mutex(false)

    var isSet: Bool { flag.withLock { $0 } }

    /// Sets it; true only the first time.
    func set() -> Bool { flag.withLock { let first = !$0; $0 = true; return first } }
}
