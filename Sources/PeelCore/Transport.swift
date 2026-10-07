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

    /// Parses "host:port" with an optional scheme. Port 8883 means TLS, the same
    /// rule the core's own client uses.
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
        tls = port == 8883 || ["mqtts", "tls", "ssl", "https"].contains(scheme ?? "")
    }

    public var description: String { "\(host):\(port)" }
}

struct Inbound: Sendable {
    let topic: String
    let payload: Data
}

/// One MQTT connection. The login is a signed timestamp, so a connection is never
/// reused: reconnecting means signing a fresh timestamp and making a new Transport.
final class Transport: Sendable {
    private let client: MQTTClient

    init(server: ServerAddress, clientID: String, username: String, password: String, allowUntrustedCertificate: Bool) {
        let tls: MQTTClient.TLSConfigurationType? = server.tls
            ? .ts(TSTLSConfiguration(certificateVerification: allowUntrustedCertificate ? .none : .fullVerification))
            : nil
        client = MQTTClient(
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
    }

    /// Messages from the broker. The stream ends when the connection closes.
    /// Call before `connect` so nothing is missed.
    func inbound() -> AsyncStream<Inbound> {
        AsyncStream { continuation in
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
