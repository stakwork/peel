import Foundation
import Synchronization

/// Requests to the web outside the memes server: sender and contact photos,
/// the tribes registry, the public config; and the size-limited `Transfer`
/// the memes and call servers use too. Never `URLSession.shared`, whose
/// on-disk cache would keep a record of every photo and tribe looked up and
/// whose redirects go anywhere, plain http and this network included.
public enum Web {
    /// Why a request through `Transfer` failed, in words that name no
    /// server; the memes and call servers map it to their own.
    enum Failure: Error, CustomStringConvertible {
        case refused(String, Int)
        case unreadableReply(String)

        var description: String {
            switch self {
            case .refused(let what, let status): "the server refused \(what) (HTTP \(status))"
            case .unreadableReply(let what): "the server's reply to \(what) was unreadable"
            }
        }
    }

    /// Where a redirect may go: the request to follow, or nil to stop.
    typealias RedirectPolicy = @Sendable (_ request: URLRequest, _ original: URLRequest?) -> URLRequest?

    /// No cookies and no URL cache; every redirect passes `redirect`.
    /// `direct`: no proxy either, for a request that must stay on this Mac.
    static func session(
        requestTimeout: TimeInterval, resourceTimeout: TimeInterval, direct: Bool = false, redirect: @escaping RedirectPolicy
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if direct { configuration.connectionProxyDictionary = [:] }
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
    /// For strut (`isStrut`): no redirect is followed, anywhere. A strut over
    /// https (a Stadeum workspace's) goes through the system's proxy; plain
    /// http to this Mac never does, so its key is never handed to a proxy in
    /// the clear.
    private static let directSession = session(requestTimeout: 30, resourceTimeout: 60, direct: true) { _, _ in nil }
    private static let proxiedSession = session(requestTimeout: 30, resourceTimeout: 60) { _, _ in nil }
    /// The same for a call to Peel's own strut that takes its time
    /// (dictation's model download and transcription, `StrutSpeech`).
    private static let slowDirectSession = session(requestTimeout: 300, resourceTimeout: 1800, direct: true) { _, _ in nil }

    private static func strutSession(for url: URL, slow: Bool = false) -> URLSession {
        if url.scheme == "https" { return proxiedSession }
        return slow ? slowDirectSession : directSession
    }

    /// Bytes moved so far and in all, reported at most every 5% or 250 ms
    /// (and always at the end).
    typealias Progress = @Sendable (_ bytes: Int64, _ total: Int64) -> Void

    /// One upload or download: the reply collected chunk by chunk and cut
    /// off past its limit, progress reported as it goes. Redirects are left
    /// to the session's own policy.
    final class Transfer: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var data = Data()
            var response: HTTPURLResponse?
            var failure: (any Error)?
            var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
            var reported: (fraction: Double, at: ContinuousClock.Instant)?
        }

        private let limit: Int
        private let what: String
        private let progress: Progress?
        /// The statuses whose body is the answer; any other is a refusal.
        private let accepted: Set<Int>
        private let state = Mutex(State())

        init(limit: Int, what: String, progress: Progress?, accepting accepted: Set<Int> = [200]) {
            self.limit = limit
            self.what = what
            self.progress = progress
            self.accepted = accepted
        }

        func run(_ task: URLSessionTask) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                task.delegate = self
                task.resume()
            }
        }

        private func report(_ bytes: Int64, of total: Int64) {
            guard let progress, total > 0 else { return }
            let fraction = Double(bytes) / Double(total)
            let now = ContinuousClock.now
            let due = state.withLock { state in
                if let last = state.reported, bytes < total, fraction - last.fraction < 0.05,
                   now - last.at < .milliseconds(250) { return false }
                state.reported = (fraction, now)
                return true
            }
            if due { progress(bytes, total) }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64, totalBytesExpectedToSend: Int64
        ) {
            report(totalBytesSent, of: totalBytesExpectedToSend)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let failure: (any Error)? = !accepted.contains(status) ? Failure.refused(what, status)
                : response.expectedContentLength > Int64(limit)
                    ? TooLarge(limit: limit, size: response.expectedContentLength) : nil
            state.withLock { state in
                state.response = response as? HTTPURLResponse
                state.failure = failure
                if failure == nil { state.data.reserveCapacity(max(0, Int(response.expectedContentLength))) }
                state.reported = nil
            }
            completionHandler(failure == nil ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let received = state.withLock { state -> Int? in
                guard state.failure == nil else { return nil }
                guard state.data.count + data.count <= limit else {
                    state.failure = TooLarge(limit: limit)
                    return nil
                }
                state.data.append(data)
                return state.data.count
            }
            guard let received else { return dataTask.cancel() }
            // An upload's progress is what it sent, not its short reply.
            guard !(dataTask is URLSessionUploadTask) else { return }
            report(Int64(received), of: dataTask.countOfBytesExpectedToReceive)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let finished = state.withLock { state in
                defer { state.continuation = nil; state.data = Data() }
                let result: Result<(Data, HTTPURLResponse), any Error> = if let failure = state.failure ?? error {
                    .failure(failure)
                } else if let response = state.response {
                    .success((state.data, response))
                } else {
                    .failure(Failure.unreadableReply(what))
                }
                return (state.continuation, result)
            }
            finished.0?.resume(with: finished.1)
        }
    }

    /// `GET url`: its body if the answer is 200 and at most `limit` bytes.
    /// Only where `isAllowed`. Throws `Failure.refused` with the status
    /// otherwise, and `TooLarge` over the limit. A caller with stricter
    /// redirects passes its own `session`.
    static func get(_ url: URL, limit: Int, what: String, session: URLSession = session) async throws -> Data {
        guard isAllowed(url) else { throw PeelError("\(url.host ?? "the host") is not on the internet") }
        return try await Transfer(limit: limit, what: what, progress: nil).run(session.dataTask(with: url)).0
    }

    /// `POST url` with a JSON body to strut (`isStrut`; its one caller is
    /// Peel's own on this Mac, `MemoryServer`): its reply if the answer is
    /// 200 and at most `limit` bytes. Anywhere else is refused before anything is sent,
    /// and a redirect is never followed (nor a proxy used for plain http).
    /// `bearer` is the server's key: anything on this Mac can reach a
    /// loopback port, so the key is what makes it Peel's.
    public static func postToStrut(
        _ url: URL, json body: Data, bearer: String? = nil, limit: Int, what: String
    ) async throws -> Data {
        let request = try strutRequest("POST", url, json: body, bearer: bearer)
        return try await Transfer(limit: limit, what: what, progress: nil)
            .run(strutSession(for: url).dataTask(with: request)).0
    }

    /// One request to strut, as `postToStrut` makes it, with its status: any
    /// reply comes back with its body, so a refusal's or a failure's own words
    /// reach the caller; only a request that got no usable reply
    /// (none, too large, unreadable) throws. `timeout` cuts a request short
    /// (a check that should not wait half a minute for a box that is off).
    /// `headers`: any other credential, as Peel's bridge takes its admin token.
    /// `slow`: on the slow session, as `postToStrut`'s, for what takes minutes
    /// (dictation's model download, a long recording).
    public static func requestStrut(
        _ method: String, _ url: URL, json body: Data? = nil, bearer: String? = nil, headers: [String: String] = [:],
        limit: Int, what: String, timeout: TimeInterval? = nil, slow: Bool = false
    ) async throws -> (status: Int, data: Data) {
        var request = try strutRequest(method, url, json: body, bearer: bearer)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let timeout { request.timeoutInterval = timeout }
        let (data, response) = try await Transfer(limit: limit, what: what, progress: nil, accepting: Set(100..<600))
            .run(strutSession(for: url, slow: slow).dataTask(with: request))
        return (response.statusCode, data)
    }

    private static func strutRequest(_ method: String, _ url: URL, json body: Data?, bearer: String?) throws -> URLRequest {
        guard isStrut(url) else { throw PeelError("\(url.host ?? "the host") is not a strut Peel may use") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Where a strut may be: plain http to this Mac (Peel's own), or https
    /// anywhere (a Stadeum workspace's). Never with a user or password in it.
    public static func isStrut(_ url: URL?) -> Bool {
        guard let url, url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme {
        case "https": return true
        case "http": return isThisMac(url)
        default: return false
        }
    }

    /// A public https host, or this machine over http (the local test stack).
    static func isAllowed(_ url: URL) -> Bool {
        isThisMac(url) || isPublic(url)
    }

    /// Plain http to this machine: the local test stack.
    public static func isThisMac(_ url: URL?) -> Bool {
        url?.scheme == "http" && url?.host.map(ServerAddress.isLoopback) == true
    }

    /// The bytes of a photo someone else chose: only a public https URL, at
    /// most 2 MB (an app's upload is a 1024 px JPEG). Nil when there is
    /// nothing to fetch or the server said no; throws when it is worth asking
    /// again later (no answer, or the server busy or failing).
    public static func photo(at url: URL) async throws -> Data? {
        guard isPublic(url) else { return nil }
        return try await retryLater { try await get(url, limit: 2_000_000, what: "the photo") }
    }

    /// `fetch`'s bytes; nil when the server said no or sent too much;
    /// throws when it is worth asking again later (no answer, or the server
    /// busy or failing).
    static func retryLater(_ fetch: () async throws -> Data) async throws -> Data? {
        do {
            return try await fetch()
        } catch Failure.refused(_, let status) where status == 429 || status >= 500 {
            throw URLError(.badServerResponse)
        } catch is Failure, is TooLarge {
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
