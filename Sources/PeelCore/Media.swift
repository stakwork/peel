import CommonCrypto
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// What an attachment is, as the official apps tell from its `mediaType`.
public enum AttachmentKind: String, Sendable, Equatable {
    case image, video, audio, pdf
    /// A paid text message (`sphinx/text`).
    case text
    case file

    /// The Mac app's `getMediaType`: an empty type is an image.
    public init(mediaType: String?) {
        let type = mediaType?.lowercased() ?? ""
        if type.isEmpty || type.contains("image") || type.contains("gif") {
            self = .image
        } else if type.contains("video") {
            self = .video
        } else if type.contains("audio") {
            self = .audio
        } else if type.contains("sphinx/text") {
            self = .text
        } else if type.contains("pdf") {
            self = .pdf
        } else {
            self = .file
        }
    }

    /// What `data` really is, given what the sender said: the declared kind
    /// when the bytes look like it, otherwise a plain file, which nothing
    /// renders. Images must decode; video, audio and PDFs must carry their
    /// container's signature; paid text must be UTF-8.
    public static func verified(_ data: Data, declared: AttachmentKind) -> AttachmentKind {
        let matches: Bool
        switch declared {
        case .image: matches = Self.isImage(data)
        case .video: matches = Self.isVideo(data)
        case .audio: matches = Self.isAudio(data)
        case .pdf: matches = data.starts(with: Array("%PDF-".utf8))
        case .text: matches = String(data: data, encoding: .utf8) != nil
        case .file: matches = true
        }
        return matches ? declared : .file
    }

    static func isImage(_ data: Data) -> Bool { imageFrames(data) != nil }

    /// How many frames the data holds if ImageIO can decode it, else nil.
    static func imageFrames(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return CGImageSourceGetCount(source)
    }

    /// ISO base media (`ftyp`, as in .mov and .mp4), QuickTime atoms, Matroska/WebM.
    static func isVideo(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 8 else { return false }
        let atom = String(decoding: head[4..<8], as: UTF8.self)
        return ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(atom) || head.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
    }

    /// WAV, MP3 (ID3 or a frame sync), MPEG-4 audio, Ogg, FLAC, AIFF.
    static func isAudio(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 4 else { return false }
        let ascii = String(decoding: head, as: UTF8.self)
        if ascii.hasPrefix("RIFF") && head.count >= 12 { return String(decoding: head[8..<12], as: UTF8.self) == "WAVE" }
        if ascii.hasPrefix("FORM") && head.count >= 12 { return String(decoding: head[8..<12], as: UTF8.self).hasPrefix("AIF") }
        if ascii.hasPrefix("ID3") || ascii.hasPrefix("OggS") || ascii.hasPrefix("fLaC") { return true }
        if head[0] == 0xFF && head[1] & 0xE0 == 0xE0 { return true }
        return head.count >= 8 && String(decoding: head[4..<8], as: UTF8.self) == "ftyp"
    }
}

/// How a file goes up to the memes server, as the Mac app's
/// `AttachmentObject.getFileAndMime` names it: its file name and MIME type,
/// which also becomes the message's `mediaType`.
struct OutgoingFile: Equatable {
    let fileName: String
    let mediaType: String

    /// Still images go up as `image.jpg` whatever their format (the bytes are
    /// unchanged), animated ones as `image.gif`, videos as `video.mov`; PDFs
    /// and other files keep their name, with the MIME type of their extension.
    init(name: String, data: Data) {
        let ext = (name as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ext != "pdf", let frames = AttachmentKind.imageFrames(data) {
            let animated = frames > 1
            self.init(fileName: animated ? "image.gif" : "image.jpg", mediaType: animated ? "image/gif" : "image/jpg")
        } else if ["mov", "mp4", "m4v", "3gp"].contains(ext) {
            // The Mac app's `URL.isVideo`; other videos go as plain files.
            self.init(fileName: "video.mov", mediaType: "video/mov")
        } else {
            self.init(fileName: name, mediaType: type?.preferredMIMEType ?? "application/octet-stream")
        }
    }

    init(fileName: String, mediaType: String) {
        self.fileName = fileName
        self.mediaType = mediaType
    }

    /// The upload's `name` field, as `AttachmentObject.getNameParam`: only
    /// the Mac app's own photos, videos and recordings get their own.
    var field: String {
        switch mediaType {
        case "image/jpg", "image/gif": "image"
        case "video/mov": "video"
        case "audio/wav": "audio"
        case "sphinx/text": "text"
        default: "file"
        }
    }
}

/// The official apps' attachment encryption: RNCryptor v3 with a password.
/// The password is the media key, 64 hex characters.
enum MediaCrypto {
    enum Failure: Error, CustomStringConvertible {
        case malformed
        case wrongKey
        case cipher(Int32)

        var description: String {
            switch self {
            case .malformed: "the attachment is not in the expected encrypted format"
            case .wrongKey: "the attachment could not be decrypted with its key"
            case .cipher(let status): "the attachment cipher failed (\(status))"
            }
        }
    }

    private static let rounds: UInt32 = 10_000
    private static let headerSize = 2 + 8 + 8 + 16
    private static let macSize = 32

    /// 32 random letters and digits, hex-encoded, as the Mac app's `Nonce(length: 32).hexString`.
    static func newKey() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", alphabet.randomElement(using: &generator)!) }.joined()
    }

    static func encrypt(_ plain: Data, key: String) throws -> Data {
        let encryptionSalt = randomBytes(8), macSalt = randomBytes(8), iv = randomBytes(16)
        var sealed = Data(capacity: headerSize + plain.count + kCCBlockSizeAES128 + macSize)
        sealed.append(contentsOf: [3, 1])
        sealed.append(encryptionSalt)
        sealed.append(macSalt)
        sealed.append(iv)
        sealed.append(try aes(CCOperation(kCCEncrypt), plain, key: derive(key, salt: encryptionSalt), iv: iv))
        sealed.append(Data(HMAC<SHA256>.authenticationCode(for: sealed, using: derive(key, salt: macSalt))))
        return sealed
    }

    static func decrypt(_ sealed: Data, key: String) throws -> Data {
        // Indexes below count from zero; only a slice needs rebasing.
        let bytes = sealed.startIndex == 0 ? sealed : Data(sealed)
        guard bytes.count >= headerSize + 16 + macSize, bytes[0] == 3, bytes[1] == 1 else { throw Failure.malformed }
        let encryptionSalt = bytes[2..<10], macSalt = bytes[10..<18], iv = bytes[18..<34]
        let message = bytes[..<(bytes.count - macSize)]
        let mac = bytes[(bytes.count - macSize)...]
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: derive(key, salt: macSalt))
        else { throw Failure.wrongKey }
        return try aes(CCOperation(kCCDecrypt), bytes[headerSize..<(bytes.count - macSize)],
                       key: derive(key, salt: encryptionSalt), iv: iv)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// PBKDF2-HMAC-SHA1 over the password's UTF-8 bytes, 32 bytes out.
    private static func derive(_ password: String, salt: Data) -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds, &derived, derived.count
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 cannot fail with these parameters")
        return SymmetricKey(data: derived)
    }

    /// AES-256-CBC with PKCS#7 padding.
    private static func aes(_ operation: CCOperation, _ input: Data, key: SymmetricKey, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                input.withUnsafeBytes { inputBuffer in
                    output.withUnsafeMutableBytes { outputBuffer in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, keyBuffer.count, ivBuffer.baseAddress,
                            inputBuffer.baseAddress, inputBuffer.count,
                            outputBuffer.baseAddress, outputBuffer.count, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCDecrypt) ? Failure.wrongKey : Failure.cipher(status)
        }
        output.count = written
        return output
    }
}

/// A media token, as the core makes it: `b64(host).muid.b64(buyer).b64(expiry).b64(meta).sig`,
/// URL-safe base64.
struct MediaToken: Equatable {
    let host: String
    let muid: String

    init?(_ token: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let host = Self.base64URLDecode(parts[0]).flatMap({ String(data: $0, encoding: .utf8) }),
              !parts[1].isEmpty else { return nil }
        self.host = host
        muid = parts[1]
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}

/// The memes server: sign-in by signed challenge, upload, download.
struct MemesServer: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unreadableHost(String)
        case refused(String, Int)
        case unreadableReply(String)
        case tooLarge(Int)

        var description: String {
            switch self {
            case .unreadableHost(let host): "unreadable memes host \(host)"
            case .refused(let what, let status): "the memes server refused \(what) (HTTP \(status))"
            case .unreadableReply(let what): "the memes server's reply to \(what) was unreadable"
            case .tooLarge(let limit): "the file is larger than \(limit / 1_000_000) MB"
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
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
    }()

    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            MemesServer.redirect(request, from: task.originalRequest)
        }
    }

    /// A redirect is followed only to https (or this machine), and without
    /// the bearer token when it leaves the host it was sent to.
    static func redirect(_ request: URLRequest, from original: URLRequest?) -> URLRequest? {
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
    /// off past its limit, progress reported as it goes.
    private final class Transfer: NSObject, URLSessionDataDelegate, Sendable {
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
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            MemesServer.redirect(request, from: task.originalRequest)
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
                : response.expectedContentLength > Int64(limit) ? .tooLarge(limit) : nil
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

    /// `POST /file`: the encrypted bytes; returns the muid.
    func upload(_ sealed: Data, as file: OutgoingFile, token: Token, progress: Progress? = nil) async throws -> String {
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
        var request = URLRequest(url: base.appendingPathComponent("file"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        let transfer = Transfer(limit: 1_000_000, what: "the upload", progress: progress)
        let (data, _) = try await transfer.run(Self.session.uploadTask(with: request, from: body))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let muid = json["muid"] as? String, !muid.isEmpty else {
            throw Failure.unreadableReply("the upload")
        }
        return muid
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

/// Decrypted attachments on disk, one file per muid, trimmed oldest first.
/// The encrypted uploads waiting for the memes server sit beside them.
struct MediaStore: Sendable {
    let cache: URL
    let outbox: URL

    init(profile directory: URL) {
        cache = directory.appendingPathComponent("media/cache", isDirectory: true)
        outbox = directory.appendingPathComponent("media/outbox", isDirectory: true)
    }

    /// Named by a hash of the muid and the key, so no muid can name a path
    /// and a message that reuses someone else's muid with another key never
    /// gets their file without decrypting it itself.
    func cached(muid: String, key: String) -> URL {
        let digest = SHA256.hash(data: Data("\(muid)\n\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent(digest)
    }

    func outgoing(_ id: Int64) -> URL {
        outbox.appendingPathComponent(String(id))
    }

    /// The cached file, touched so trimming keeps it longest.
    func lookup(muid: String, key: String) -> URL? {
        let url = cached(muid: muid, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    func store(_ data: Data, muid: String, key: String, limit: Int) throws -> URL {
        let url = cached(muid: muid, key: key)
        try write(data, to: url)
        trim(to: limit)
        return url
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
    }

    /// Removes the least recently used files until the cache fits.
    func trim(to limit: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: keys)
        else { return }
        let entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// A downloaded attachment: the decrypted file in the profile's cache.
public struct DownloadedAttachment: Sendable {
    public let file: URL
    /// What the bytes turned out to be; `.file` when they did not match the declared type.
    public let kind: AttachmentKind
    public let fileName: String?
    public let size: Int
    /// True when it came from the cache without a download.
    public let cached: Bool
}

/// What a message's JSON says about its attachment.
struct AttachmentFields: Decodable {
    let mediaToken: String?
    let mediaKey: String?
    let mediaType: String?

    static func decode(_ body: String?) -> AttachmentFields? {
        body.flatMap { try? JSONDecoder().decode(AttachmentFields.self, from: Data($0.utf8)) }
    }
}
