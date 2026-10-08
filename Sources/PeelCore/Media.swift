import Foundation
import ImageIO
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

    private static func isImage(_ data: Data) -> Bool { imageFrames(data) != nil }

    /// How many frames the data holds if ImageIO can decode it, else nil.
    static func imageFrames(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return CGImageSourceGetCount(source)
    }

    /// ISO base media (`ftyp`, as in .mov and .mp4), QuickTime atoms, Matroska/WebM.
    private static func isVideo(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 8 else { return false }
        let atom = String(decoding: head[4..<8], as: UTF8.self)
        return ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(atom) || head.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
    }

    /// WAV, MP3 (ID3 or a frame sync), MPEG-4 audio, Ogg, FLAC, AIFF.
    private static func isAudio(_ data: Data) -> Bool {
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

/// A media token, as the core makes it: `b64(host).muid.b64(buyer).b64(expiry).b64(meta).sig`,
/// URL-safe base64.
struct MediaToken: Equatable {
    let host: String
    let muid: String
    /// What a paid attachment costs, in sats: `amt` in the token's meta, as
    /// the official apps read it. Nil for a free one.
    let priceSats: UInt64?

    init?(_ token: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let host = Self.base64URLDecode(parts[0]).flatMap({ String(data: $0, encoding: .utf8) }),
              !parts[1].isEmpty else { return nil }
        self.host = host
        muid = parts[1]
        priceSats = parts.count > 4 ? Self.price(meta: parts[4]) : nil
    }

    /// `amt=<sats>` among the `&`-separated meta, base64 encoded (either alphabet).
    private static func price(meta: String) -> UInt64? {
        let decoded = base64URLDecode(meta).flatMap { String(data: $0, encoding: .utf8) }
            ?? Data(base64Encoded: meta).flatMap { String(data: $0, encoding: .utf8) }
        guard let decoded else { return nil }
        for pair in decoded.split(separator: "&") where pair.hasPrefix("amt=") {
            if let sats = UInt64(pair.dropFirst(4)), sats > 0 { return sats }
        }
        return nil
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
    /// The key as the sender keeps it for their own devices; a paid
    /// attachment's own row has only this one.
    let mediaKeyForSelf: String?

    /// The key the sender keeps: in the message, or for a paid one only for themself.
    var ownKey: String? { mediaKey?.nilIfEmpty ?? mediaKeyForSelf?.nilIfEmpty }

    static func decode(_ body: String?) -> AttachmentFields? {
        body.flatMap { try? JSONDecoder().decode(AttachmentFields.self, from: Data($0.utf8)) }
    }
}
