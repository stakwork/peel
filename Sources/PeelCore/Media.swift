import AVFoundation
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

    /// The extension of a declared type: UTType's, else "mov" for the Mac
    /// app's `video/mov`, which is no MIME type UTType knows.
    public static func fileExtension(mediaType: String?) -> String? {
        guard let mediaType else { return nil }
        if let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension { return ext }
        return mediaType.lowercased() == "video/mov" ? "mov" : nil
    }

    /// A name for an image, video or recording the server gave none:
    /// "video.mov", as the Mac app names its videos, "audio.m4a".
    static func fallbackName(mediaType: String?) -> String? {
        let kind = AttachmentKind(mediaType: mediaType)
        guard [.image, .video, .audio].contains(kind), let ext = fileExtension(mediaType: mediaType) else { return nil }
        return "\(kind.rawValue).\(ext)"
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
        guard let container = container(data) else { return false }
        return container.isoMedia || container.mimeType.hasPrefix("video/")
    }

    /// WAV, MP3 (ID3 or a frame sync), AAC (ADTS), MPEG-4 audio, Ogg, FLAC, AIFF.
    private static func isAudio(_ data: Data) -> Bool {
        guard let container = container(data) else { return false }
        return container.isoMedia || container.mimeType.hasPrefix("audio/")
    }

    /// The video or audio container `data` starts with, by its signature:
    /// its MIME type, and whether it is ISO base media (`ftyp`), which holds
    /// either.
    static func container(_ data: Data) -> (mimeType: String, isoMedia: Bool)? {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 4 else { return nil }
        func text(_ range: Range<Int>) -> String {
            head.count >= range.upperBound ? String(decoding: head[range], as: UTF8.self) : ""
        }
        switch text(4..<8) {
        case "ftyp":
            let brand = text(8..<12)
            if brand == "qt  " { return ("video/quicktime", true) }
            return (["M4A ", "M4B ", "M4P "].contains(brand) ? "audio/mp4" : "video/mp4", true)
        case "moov", "mdat", "wide", "free", "skip": return ("video/quicktime", false)
        default: break
        }
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return ("video/webm", false) }
        switch text(0..<4) {
        case "RIFF": return text(8..<12) == "WAVE" ? ("audio/wav", false) : nil
        case "FORM": return text(8..<12).hasPrefix("AIF") ? ("audio/aiff", false) : nil
        case "fLaC": return ("audio/flac", false)
        case "OggS": return ("audio/ogg", false)
        default: break
        }
        if text(0..<3) == "ID3" { return ("audio/mpeg", false) }
        // A frame sync: layer bits 00 are AAC in ADTS, the others MPEG audio.
        if head[0] == 0xFF && head[1] & 0xE0 == 0xE0 { return (head[1] & 0x06 == 0 ? "audio/aac" : "audio/mpeg", false) }
        return nil
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
        JSON.decode(AttachmentFields.self, from: body)
    }
}

/// What a downloaded video or audio file holds, read from the decrypted file
/// where it sits in the cache. Cached files have no extension, so the
/// container's MIME type is named from its first bytes; nothing is copied.
public struct MediaInfo: Sendable {
    /// Seconds; nil when the file does not say.
    public let duration: TimeInterval?
    /// A video's picture, turned as it plays, in pixels; nil for audio.
    public let size: CGSize?
    /// A video's poster frame, when asked for and one could be made.
    public let poster: CGImage?

    /// The file as AVFoundation should read it.
    public static func asset(_ file: URL) -> AVURLAsset {
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 12)
        } ?? Data()
        let options = AttachmentKind.container(head).map { [AVURLAssetOverrideMIMETypeKey: $0.mimeType] } ?? [:]
        return AVURLAsset(url: file, options: options)
    }

    /// Its duration, a video's picture size and, with `posterPixels`, its
    /// poster frame a second in (or a third of the way into a shorter one),
    /// its long side at most that; nil when AVFoundation cannot play it.
    /// One asset, read once.
    public static func load(_ file: URL, posterPixels: Int? = nil) async -> MediaInfo? {
        let asset = asset(file)
        guard let (time, playable, tracks) = try? await asset.load(.duration, .isPlayable, .tracks), playable
        else { return nil }
        let duration = time.isNumeric ? time.seconds : nil
        var size: CGSize?
        if let track = tracks.first(where: { $0.mediaType == .video }),
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let turned = natural.applying(transform)
            size = CGSize(width: abs(turned.width), height: abs(turned.height))
        }
        var poster: CGImage?
        if let posterPixels, size != nil {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: posterPixels, height: posterPixels)
            let at = CMTime(seconds: min(1, (duration ?? 0) / 3), preferredTimescale: 600)
            poster = try? await generator.image(at: at).image
        }
        return MediaInfo(duration: duration, size: size, poster: poster)
    }

    /// "0:07", "12:30", "1:02:03".
    public static func format(duration seconds: TimeInterval) -> String {
        let time = Duration.seconds(max(0, seconds.rounded(.down)))
        return time.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
