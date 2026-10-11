import Foundation

/// Turns one provider's stream of server-sent events into `ModelEvent`s.
protocol StreamDecoder: Sendable {
    /// The events one server-sent event gives. Throws the provider's error.
    mutating func decode(_ event: SSEEvent) throws -> [ModelEvent]
    /// The events left when the stream ends; throws if the reply was cut off.
    mutating func finish() throws -> [ModelEvent]
}

/// An API key that prints as "[key]", so dumping or logging a provider, a
/// decoder or a loop never shows it.
struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String
    init(_ value: String) { self.value = value }
    var description: String { "[key]" }
    var debugDescription: String { "[key]" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The HTTP side both model clients share: the session, the base URL rule,
/// error statuses, and reading the streamed body.
enum ModelHTTP {
    /// No cookies, no URL cache, no redirects (a redirect would carry the key
    /// to wherever it pointed). `timeoutIntervalForRequest` is the longest
    /// silence between bytes; Anthropic pings, and a reasoning model may
    /// think for a while before its first token.
    /// The session every provider shares: one connection pool, and no
    /// session (with its delegate) left behind per provider.
    static let shared = session()

    static func session(protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    /// A base URL the key may be sent to: https, or http to this machine (a
    /// local proxy or test server). Never one with credentials in it.
    static func checked(_ baseURL: URL) throws -> URL {
        let scheme = baseURL.scheme?.lowercased()
        let host = baseURL.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: ["[", "]"]) ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard baseURL.user == nil, baseURL.password == nil, !host.isEmpty,
            scheme == "https" || (scheme == "http" && loopback)
        else {
            throw ModelError.invalidAddress
        }
        return baseURL
    }

    static func post(_ url: URL, headers: [String: String], body: JSONValue) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try StableJSON.encode(body)
        return request
    }

    /// Sends `request` and decodes its event stream. An error status becomes a
    /// `ModelError` (its body read up to 64 KB); `secret` is kept out of every
    /// message. Cancelling the reading task cancels the request.
    static func stream(
        _ request: @autoclosure () throws -> URLRequest, session: URLSession, secret: String, decoder: some StreamDecoder
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        let built = Result { try request() }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var decoder = decoder
                    let (bytes, response) = try await session.bytes(for: built.get())
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 65536 { break }
                        }
                        throw ModelError(
                            status: status, retryAfter: http?.value(forHTTPHeaderField: "retry-after"), body: body, secret: secret)
                    }
                    var lines = LineSplitter()
                    var parser = SSEParser()
                    func emit(_ items: [ModelEvent]) { for item in items { continuation.yield(item) } }
                    for try await byte in bytes {
                        guard let line = try lines.feed(byte), let event = parser.feed(line[...]) else { continue }
                        emit(try decoder.decode(event))
                    }
                    try Task.checkCancellation()
                    if let line = lines.flush(), let event = parser.feed(line[...]) { emit(try decoder.decode(event)) }
                    if let event = parser.flush() { emit(try decoder.decode(event)) }
                    emit(try decoder.finish())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ModelError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
