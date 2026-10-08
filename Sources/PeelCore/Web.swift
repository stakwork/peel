import Foundation

/// Requests to the web outside the memes server: sender and contact photos,
/// the tribes registry, the public config. Never `URLSession.shared`, whose
/// on-disk cache would keep a record of every photo and tribe looked up and
/// whose redirects go anywhere, plain http and this network included.
public enum Web {
    /// Where a redirect may go: the request to follow, or nil to stop.
    typealias RedirectPolicy = @Sendable (_ request: URLRequest, _ original: URLRequest?) -> URLRequest?

    /// No cookies and no URL cache; every redirect passes `redirect`.
    static func session(requestTimeout: TimeInterval, resourceTimeout: TimeInterval, redirect: @escaping RedirectPolicy) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: Redirects(redirect), delegateQueue: nil)
    }

    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        private let policy: RedirectPolicy
        init(_ policy: @escaping RedirectPolicy) { self.policy = policy }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            policy(request, task.originalRequest)
        }
    }

    /// A redirect is followed only to a public https host, so a server cannot
    /// bounce Peel onto this network.
    static func publicOnly(_ request: URLRequest, from _: URLRequest?) -> URLRequest? {
        request.url.flatMap(isPublic) == true ? request : nil
    }

    private static let session = session(requestTimeout: 30, resourceTimeout: 60, redirect: publicOnly)

    /// `GET url`: its body if the answer is 200 and at most `limit` bytes.
    /// Only a public https host, or this machine over http (the local test
    /// stack). Throws `MemesServer.Failure.refused` with the status otherwise.
    static func get(_ url: URL, limit: Int, what: String) async throws -> Data {
        let loopback = url.scheme == "http" && url.host.map(ServerAddress.isLoopback) == true
        guard loopback || isPublic(url) else { throw PeelError("\(url.host ?? "the host") is not on the internet") }
        return try await MemesServer.Transfer(limit: limit, what: what, progress: nil).run(session.dataTask(with: url)).0
    }

    /// The bytes of a photo someone else chose: only a public https URL, at
    /// most 2 MB (an app's upload is a 1024 px JPEG). Nil when there is
    /// nothing to fetch or the server said no; throws when it is worth asking
    /// again later (no answer, or the server busy or failing).
    public static func photo(at url: URL) async throws -> Data? {
        guard isPublic(url) else { return nil }
        do {
            return try await get(url, limit: 2_000_000, what: "the photo")
        } catch MemesServer.Failure.refused(_, let status) where status == 429 || status >= 500 {
            throw URLError(.badServerResponse)
        } catch is MemesServer.Failure {
            return nil
        }
    }

    /// An https URL on a named host out on the internet: no credentials, no
    /// IP address (no photo or registry is served from one, and every
    /// private range is one), and not a name only this network resolves.
    /// Judged by the name as written; a public name that resolves to a
    /// private address is not caught here.
    static func isPublic(_ url: URL) -> Bool {
        guard url.absoluteString.httpsOnly != nil, url.user == nil, url.password == nil,
              var host = url.host?.lowercased() else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        // Letters, digits, dots, dashes and colons only: no NUL or other byte a resolver may cut at.
        guard TribeLink.isPlainHost(host.trimmingCharacters(in: ["[", "]"])) else { return false }
        // The resolver reads `127.1` and `2130706433` as addresses, and so does `inet_aton`.
        var v4 = in_addr(), v6 = in6_addr()
        let bare = host.trimmingCharacters(in: ["[", "]"])
        guard inet_aton(bare, &v4) == 0, inet_pton(AF_INET6, bare, &v6) != 1, host.contains(".") else { return false }
        return !localSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let localSuffixes = ["localhost", "local", "internal", "lan", "home.arpa"]
}
