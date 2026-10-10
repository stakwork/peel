import Foundation
import MQTTNIO
import NIOCore
import NIOFoundationCompat
import NIOTransportServices
import Synchronization

/// Where the account's broker lives.
public struct ServerAddress: Sendable, Equatable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var tls: Bool

    /// Parses "host:port" with an optional scheme. TLS is on unless the scheme is
    /// `mqtt://` or the host is this machine.
    public init?(_ string: String) {
        var rest = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme: String?
        if let range = rest.range(of: "://") {
            scheme = rest[..<range.lowerBound].lowercased()
            rest = String(rest[range.upperBound...])
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = Int(parts[1]) else {
            return nil
        }
        host = String(parts[0])
        self.port = port
        switch scheme {
        case nil: tls = !Self.isLoopback(host: host)
        case "mqtts", "ssl", "tls": tls = true
        case "mqtt", "tcp": tls = false
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
    public var description: String { "\(tls ? "mqtts" : "mqtt")://\(host):\(port)" }
}

struct Inbound: Sendable {
    let topic: String
    let payload: Data
}

/// One MQTT connection. The login is a signed timestamp, so a connection is never
/// reused: reconnecting means signing a fresh timestamp and making a new Transport.
final class Transport: Sendable {
    private let client: MQTTClient
    /// When the broker last sent anything; see `answersPing`.
    private let lastHeard: LastHeard

    /// Messages from the broker, listened for from the moment the transport
    /// exists. The stream ends when the connection closes.
    let inbound: AsyncStream<Inbound>

    init(server: ServerAddress, clientID: String, username: String, password: String, allowUntrustedCertificate: Bool) {
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
                tlsConfiguration: tls
            )
        )
        self.client = client
        let lastHeard = LastHeard()
        self.lastHeard = lastHeard
        inbound = AsyncStream { continuation in
            client.addPublishListener(named: "peel") { result in
                if case .success(let info) = result {
                    lastHeard.now()
                    continuation.yield(Inbound(topic: info.topicName, payload: Data(buffer: info.payload)))
                }
            }
            client.addCloseListener(named: "peel") { _ in
                continuation.finish()
            }
        }
    }

    func connect() async throws {
        try await client.connect(cleanSession: true)
    }

    func subscribe(_ topics: [String]) async throws {
        try await whileConnected {
            _ = try await client.subscribe(to: topics.map { MQTTSubscribeInfo(topicFilter: $0, qos: .atMostOnce) })
        }
    }

    func publish(_ topic: String, _ payload: Data) async throws {
        try await whileConnected {
            try await client.publish(to: topic, payload: ByteBuffer(data: payload), qos: .atMostOnce)
        }
    }

    /// Whether the broker answers a ping within `timeout`, or sent anything
    /// else meanwhile (on a slow link the answer can queue behind a page of
    /// history). A connection that does neither is dead whatever its socket
    /// says (a network that went, a path that changed), and is the caller's
    /// to close.
    func answersPing(within timeout: Duration) async -> Bool {
        let (answers, answered) = AsyncStream.makeStream(of: Bool.self)
        let (client, lastHeard, asked) = (client, lastHeard, ContinuousClock.now)
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
        for await alive in answers { return alive }
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

    func close() async {
        try? await client.disconnect()
        try? await client.shutdown()
    }
}

/// When a connection last heard from the broker.
private final class LastHeard: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    func now() { instant.withLock { $0 = .now } }

    func since(_ start: ContinuousClock.Instant) -> Bool { instant.withLock { $0 > start } }
}
