import Foundation

/// A GIF from Giphy as the official apps send one (`GiphyHelper`): a type 0
/// text message whose content is `giphy::` and base64 of a JSON object
/// `{"id", "url", "aspect_ratio", "text"}`. Nothing goes through the memes
/// server; the receiver loads the GIF from Giphy's CDN.
public struct Giphy: Sendable, Equatable {
    static let prefix = "giphy::"

    /// The 200 px wide variant on Giphy's CDN that the apps load
    /// (`get200WidthURL`); nil when the message names any other host.
    public let url: URL?
    /// Width over height, 1 when missing or not positive (`getAspectRatioFrom`).
    public let aspectRatio: Double
    /// The caption, "" when there is none (`getMessageFrom`).
    public let text: String

    /// Nil unless `content` is a `giphy::` message the Mac app reads:
    /// strict base64 of UTF-8 JSON (`getJSONObjectFrom`).
    public init?(content: String?) {
        guard let content, content.hasPrefix(Self.prefix),
              let data = Data(base64Encoded: String(content.dropFirst(Self.prefix.count))),
              let json = String(data: data, encoding: .utf8),
              let fields = JSON.decode(Fields.self, from: json) else { return nil }
        let ratio = fields.aspectRatio ?? 0
        aspectRatio = ratio.isFinite && ratio > 0 ? ratio : 1
        text = fields.text ?? ""
        url = fields.url.flatMap { URL(string: $0.replacingOccurrences(of: "giphy.gif", with: "200.gif")) }
            .flatMap { Self.isAllowed($0) ? $0 : nil }
    }

    /// Giphy's media hosts, as the URLs its API gives the apps name them.
    /// A message names the URL, so nothing else is ever fetched for one.
    static let hosts: Set<String> = [
        "media.giphy.com", "media0.giphy.com", "media1.giphy.com", "media2.giphy.com",
        "media3.giphy.com", "media4.giphy.com", "i.giphy.com",
    ]

    /// https on the default port to one of `hosts`, as written: no
    /// credentials, no other port, no trailing dot.
    static func isAllowed(_ url: URL) -> Bool {
        // The host as written, percent-encoding and all, matched exactly.
        guard Web.isPublic(url), url.port == nil || url.port == 443, let host = url.host(percentEncoded: true) else {
            return false
        }
        return hosts.contains(host.lowercased())
    }

    /// The most a GIF may weigh: the 200 px variants are well under it.
    static let limit = 8_000_000

    /// A redirect is followed only to Giphy's media hosts.
    static func onGiphy(_ request: URLRequest, from _: URLRequest?) -> URLRequest? {
        request.url.map(isAllowed) == true ? request : nil
    }

    private static let session = Web.session(requestTimeout: 30, resourceTimeout: 60, redirect: onGiphy)

    /// The GIF's bytes. Nil when there is nothing to fetch or the CDN said
    /// no; throws when it is worth asking again later, as `Web.photo`.
    /// Loading one tells Giphy this Mac's address, as in the official apps.
    public static func data(at url: URL) async throws -> Data? {
        guard isAllowed(url) else { return nil }
        return try await Web.retryLater { try await Web.get(url, limit: limit, what: "the GIF", session: session) }
    }

    private struct Fields: Decodable {
        let url: String?
        let aspectRatio: Double?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case url, text
            case aspectRatio = "aspect_ratio"
        }

        /// Each field on its own, so an odd one costs only itself; the apps
        /// write `aspect_ratio` as a string.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try? container.decode(String.self, forKey: .url)
            text = try? container.decode(String.self, forKey: .text)
            aspectRatio = (try? container.decode(Double.self, forKey: .aspectRatio))
                ?? (try? container.decode(String.self, forKey: .aspectRatio)).flatMap(Double.init)
        }
    }
}
