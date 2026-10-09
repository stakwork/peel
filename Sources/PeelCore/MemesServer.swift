import Foundation

/// The memes server: sign-in by signed challenge, upload, download.
struct MemesServer: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unreadableHost(String)
        case refused(String, Int)
        case unreadableReply(String)

        var description: String {
            switch self {
            case .unreadableHost(let host): "unreadable memes host \(host)"
            case .refused(let what, let status): "the memes server refused \(what) (HTTP \(status))"
            case .unreadableReply(let what): "the memes server's reply to \(what) was unreadable"
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
            struct Claims: Decodable { let exp: Double? }
            self.value = value
            let exp = JWT.payload(Claims.self, of: value)?.exp
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

    /// Bytes moved so far and in all, as `Web.Transfer` reports them.
    typealias Progress = Web.Progress

    /// A redirect is followed only to https (or this machine, from a memes
    /// server on this machine), and without the bearer token when it leaves
    /// the host it was sent to.
    static func redirect(_ request: URLRequest, from original: URLRequest?) -> URLRequest? {
        guard let url = request.url, let host = url.host else { return nil }
        guard url.scheme == "https" || (Web.isThisMac(url) && Web.isThisMac(original?.url)) else { return nil }
        var request = request
        if host != original?.url?.host || url.port != original?.url?.port {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
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
        let transfer = Web.Transfer(limit: 1_000_000, what: "the upload", progress: progress)
        let (data, _) = try await Self.run(transfer, Self.session.uploadTask(with: request, from: body))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let muid = json["muid"] as? String, MediaToken.isSafeMUID(muid)
        else {
            throw Failure.unreadableReply("the upload")
        }
        return muid
    }

    /// Where an image uploaded to `/public` is served.
    func publicURL(_ muid: String) -> URL { base.appendingPathComponent("public").appendingPathComponent(muid) }

    /// `GET /templates`: the server's payment templates, as the Mac app's
    /// `getPaymentTemplates` asks for them.
    func templates(token: Token) async throws -> [PaymentTemplate] {
        var request = URLRequest(url: base.appendingPathComponent("templates"))
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await Self.run(Web.Transfer(limit: 1_000_000, what: "the templates", progress: nil), Self.session.dataTask(with: request))
        guard let list = PaymentTemplate.list(from: data) else { throw Failure.unreadableReply("the templates") }
        return list
    }

    /// `GET /template/<muid>`: a template's picture, in the clear, refusing
    /// anything over `limit` bytes.
    func template(_ muid: String, token: Token, limit: Int) async throws -> Data {
        guard MediaToken.isSafeMUID(muid) else { throw Failure.unreadableReply("the template") }
        var request = URLRequest(url: base.appendingPathComponent("template").appendingPathComponent(muid))
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await Self.run(Web.Transfer(limit: limit, what: "the template", progress: nil), Self.session.dataTask(with: request))
        return data
    }

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
        let transfer = Web.Transfer(limit: limit, what: "the download", progress: progress)
        let (data, response) = try await Self.run(transfer, Self.session.dataTask(with: request))
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

    /// A transfer, its failures in the memes server's words.
    private static func run(_ transfer: Web.Transfer, _ task: URLSessionTask) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transfer.run(task)
        } catch Web.Failure.refused(let what, let status) {
            throw Failure.refused(what, status)
        } catch Web.Failure.unreadableReply(let what) {
            throw Failure.unreadableReply(what)
        }
    }

    private func send(_ request: URLRequest, what: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableReply(what) }
        guard http.statusCode == 200 else { throw Failure.refused(what, http.statusCode) }
        return (data, http)
    }
}
