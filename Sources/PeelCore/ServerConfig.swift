import Foundation

/// Where a restored account connects when nothing is known yet; the same
/// endpoint the official apps read.
public struct ServerConfig: Decodable, Sendable {
    public let defaultLSP: String
    /// Where tribes are listed, as `host[:port]`.
    public let tribeHost: String?

    /// The tribes host if it is a plain `host[:port]`, as a link's must be.
    var usableTribeHost: String? { tribeHost.flatMap { TribeLink.isPlainHost($0) ? $0 : nil } }

    enum CodingKeys: String, CodingKey {
        case defaultLSP = "default_lsp"
        case tribeHost = "tribe_host"
    }

    public static func fetch(network: String = "bitcoin") async throws -> ServerConfig {
        let url = URL(string: "https://config.config.sphinx.chat/api/config/\(network)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(ServerConfig.self, from: data)
    }
}
