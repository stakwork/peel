import Foundation
import Synchronization

/// The memes server: sign-in by signed challenge, upload, download.
struct MemesServer: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unreadableHost(String)
        case refused(String, Int)
        case unreadableReply(String)
        /// Over the limit in bytes; the size when the server named it.
        case tooLarge(Int, size: Int64? = nil)

        var description: String {
            switch self {
            case .unreadableHost(let host): "unreadable memes host \(host)"
            case .refused(let what, let status): "the memes server refused \(what) (HTTP \(status))"
            case .unreadableReply(let what): "the memes server's reply to \(what) was unreadable"
            case .tooLarge(let limit, _): "the file is larger than \(limit / 1_000_000) MB"
            }
        }

        var isUnauthorized: Bool {
            if case .refused(_, let status) = self { return status == 401 || status == 403 }
            return false
        }
    }

    /// A bearer token and when it stops working.
    struct Token: Sendable {
        let value: String
        let expires: Date

        var isFresh: Bool { expires.timeIntervalSinceNow > 60 }

        /// The JWT's `exp`; without one the token is used for this call only.
        init(_ value: String) {
            self.value = value
            let parts = value.split(separator: ".")
            let exp = parts.count > 1 ? MediaToken.base64URLDecode(String(parts[1]))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["exp"] as? Double : nil
            expires = exp.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        }
    }

    let host: String
    private let base: URL

    /// `host[:port]`: http for this machine, https for everything else.
    init(host: String) throws {
        guard let base = TribeLink.baseURL(host) else { throw Failure.unreadableHost(host) }
        self.host = host
        self.base = base
    }

    /// No cookies, no on-disk cache, and the bearer token never follows a
    /// redirect to another host or away from https.
    private static let session = Web.session(requestTimeout: 60, resourceTimeout: 600, redirect: redirect)

    /// A redirect is followed only to https (or this machine), and without
    /// the bearer token when it leaves the host it was sent to.
    private static func redirect(_ request: URLRequest, from original: URLRequest?) -> URLRequest? {
        guard let url = request.url, let host = url.host else { return nil }
        let secure = url.scheme == "https" || (url.scheme == "http" && ServerAddress.isLoopback(host: host))
        guard secure else { return nil }
        var request = request
        if host != original?.url?.host || url.port != original?.url?.port {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
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
        private let state = Mutex(State())

        init(limit: Int, what: String, progress: Progress?) {
            self.limit = limit
            self.what = what
            self.progress = progress
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
            let failure: Failure? = status != 200 ? .refused(what, status)
                : response.expectedContentLength > Int64(limit)
                    ? .tooLarge(limit, size: response.expectedContentLength) : nil
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
                    state.failure = Failure.tooLarge(limit)
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

    /// `GET /ask`: an id and a challenge to sign.
    func challenge() async throws -> (id: String, challenge: String) {
        let (data, _) = try await send(URLRequest(url: base.appendingPathComponent("ask")), what: "sign-in")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, let challenge = json["challenge"] as? String else {
            throw Failure.unreadableReply("sign-in")
        }
        return (id, challenge)
    }

    /// `POST /verify`: the signed challenge for a bearer token.
    func verify(id: String, signature: String, pubkey: String) async throws -> Token {
        // Built by hand as the Mac app does, so the signature's padding is sent as is.
        let query = "id=\(Self.queryValue(id))&sig=\(Self.queryValue(signature))&pubkey=\(Self.queryValue(pubkey))"
        guard let url = URL(string: base.appendingPathComponent("verify").absoluteString + "?" + query) else {
            throw Failure.unreadableReply("sign-in")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request, what: "the signed challenge")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw Failure.unreadableReply("the signed challenge")
        }
        return Token(token)
    }

    private static func queryValue(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+?#"))) ?? text
    }

    /// `POST /file`: the encrypted bytes; returns the muid. `POST /public`
    /// takes a public image in the clear (a profile photo), as the Mac app's
    /// `uploadPublicImage`; it is then served at `publicURL(muid)`.
    func upload(
        _ sealed: Data, as file: OutgoingFile, token: Token, route: String = "file", progress: Progress? = nil
    ) async throws -> String {
        let boundary = "peel-\(UUID().uuidString)"
        var body = Data()
        body.reserveCapacity(sealed.count + 1024)
        func part(_ headers: String, _ content: Data) {
            body.append(Data("--\(boundary)\r\n\(headers)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part("Content-Disposition: form-data; name=\"name\"", Data(file.field.utf8))
        // A file name can hold quotes and line breaks; neither may reach the part headers.
        let fileName = file.fileName.withoutControlCharacters.replacingOccurrences(of: "\"", with: "'")
        part("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(file.mediaType)", sealed)
        body += Data("--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: base.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        let transfer = Transfer(limit: 1_000_000, what: "the upload", progress: progress)
        let (data, _) = try await transfer.run(Self.session.uploadTask(with: request, from: body))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let muid = json["muid"] as? String, !muid.isEmpty,
              // It becomes part of a URL path and of the media token.
              muid.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_=".unicodeScalars.contains($0)) })
        else {
            throw Failure.unreadableReply("the upload")
        }
        return muid
    }

    /// Where an image uploaded to `/public` is served.
    func publicURL(_ muid: String) -> URL { base.appendingPathComponent("public").appendingPathComponent(muid) }

    /// `GET /file/<media token>`: the encrypted bytes and the file name the
    /// server gives, refusing anything over `limit` bytes.
    func download(
        mediaToken: String, token: Token, limit: Int, progress: Progress? = nil
    ) async throws -> (data: Data, fileName: String?) {
        guard let url = URL(string: base.absoluteString + "/file/" + mediaToken) else {
            throw Failure.unreadableReply("the download")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        let transfer = Transfer(limit: limit, what: "the download", progress: progress)
        let (data, response) = try await transfer.run(Self.session.dataTask(with: request))
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")
        return (data, disposition.flatMap(Self.fileName(fromDisposition:)))
    }

    /// The `filename=` of a Content-Disposition header, made safe to show and
    /// to save under: the last path component, no control characters, no
    /// leading dot, at most 200 characters.
    static func fileName(fromDisposition header: String) -> String? {
        guard let range = header.range(of: "filename=") else { return nil }
        let raw = header[range.upperBound...].split(separator: ";").first.map(String.init) ?? ""
        let unquoted = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
        let last = unquoted.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let clean = last.withoutControlCharacters.replacingOccurrences(of: ":", with: "")
        let name = String(clean.drop(while: { $0 == "." || $0 == " " }).prefix(200))
        return name.nilIfEmpty
    }

    /// The challenge's bytes, read as the Mac app's `nonBase64Data` reads
    /// them: cut to a multiple of four characters, either base64 alphabet.
    static func challengeBytes(_ challenge: String) -> Data? {
        let cut = String(challenge.prefix(challenge.count - challenge.count % 4))
        return Data(base64Encoded: cut.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
    }

    private func send(_ request: URLRequest, what: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableReply(what) }
        guard http.statusCode == 200 else { throw Failure.refused(what, http.statusCode) }
        return (data, http)
    }
}
