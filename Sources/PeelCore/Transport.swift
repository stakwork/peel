import Foundation
import MQTTNIO
import NIOCore
import NIOFoundationCompat
import NIOTransportServices

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

    /// This machine: the only place plaintext is allowed without asking.
    static func isLoopback(host: String) -> Bool {
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
                keepAliveInterval: .seconds(15),
                userName: username,
                password: password,
                useSSL: server.tls,
                tlsConfiguration: tls
            )
        )
        self.client = client
        inbound = AsyncStream { continuation in
            client.addPublishListener(named: "peel") { result in
                if case .success(let info) = result {
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
        _ = try await client.subscribe(to: topics.map { MQTTSubscribeInfo(topicFilter: $0, qos: .atMostOnce) })
    }

    func publish(_ topic: String, _ payload: Data) async throws {
        try await client.publish(to: topic, payload: ByteBuffer(data: payload), qos: .atMostOnce)
    }

    func close() async {
        try? await client.disconnect()
        try? await client.shutdown()
    }
}
