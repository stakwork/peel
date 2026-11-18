import Foundation
import PeelCore
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The words in an attachment of the agent's DM, for a model that reads text
/// (docs/agent-on-strut.md, "Attachments"): a picture's text by Apple Vision,
/// a PDF's by PDFKit (a page with none read as a picture), a document's by
/// the system's reader, plain text as it is, and speech by the system's
/// on-device recognizer (`AudioTranscribing`). Everything is read on this
/// Mac and nothing leaves it. What it returns is someone else's words: the
/// tool frames it as data (`AttachmentReader`).
public enum AttachmentText {
    /// The most characters of one answer, so a result with its frame stays
    /// under `ChatData.maxCharacters`; the rest is read with `offset`.
    public static let chunk = 10_000
    /// The most characters kept of one file; the rest is dropped and said.
    public static let maxCharacters = 2_000_000
    /// The most blank PDF pages read as pictures.
    public static let maxScannedPages = 20
    /// The longest recording transcribed.
    public static let maxAudioSeconds: Double = 10 * 60
    /// The longest side, in pixels, a picture is read at.
    public static let maxPixels = 4096

    /// What a file is read as.
    public enum Kind: String, Sendable, Equatable {
        case image, pdf, audio, document, text, unreadable
    }

    /// Why a file gave no text, in words the model is told.
    public enum Failure: LocalizedError, Equatable {
        /// A video, an archive or any other file with no text to read.
        case unreadable
        /// This device cannot read this kind of document.
        case unsupportedDocument
        case tooLong(seconds: Int)
        /// No on-device speech model, or not allowed: `locale` is the language asked for.
        case cannotTranscribe(locale: String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable: "this kind of file cannot be read"
            case .unsupportedDocument: "this Mac cannot read this kind of document"
            case .tooLong(let seconds): "this recording is \(seconds / 60) minutes long; at most \(Int(AttachmentText.maxAudioSeconds) / 60) are transcribed"
            case .cannotTranscribe(let locale): "this Mac cannot transcribe offline for \(locale)"
            case .failed(let why): why
            }
        }
    }

    /// One part of a file's text: from `offset`, how many characters in all,
    /// and where the next part starts (nil at the end).
    public typealias Part = (text: String, total: Int, next: Int?)

    // MARK: - What a file is

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static let audioExtensions: Set<String> = ["m4a", "wav", "mp3", "aiff", "aif", "flac", "ogg", "oga", "opus", "caf", "aac"]
    static let documentExtensions: Set<String> = ["doc", "docx", "rtf", "html", "htm"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
    static let archiveExtensions: Set<String> = ["zip", "gz", "tgz", "tar", "7z", "rar", "bz2", "xz", "dmg", "pkg"]
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "ini", "log", "swift", "py", "js", "ts",
        "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "rb", "php", "sh", "sql", "css", "tex",
    ]

    /// How `file` is read, by what it is called and the sender's media type
    /// (the bytes are looked at only for a plain file with neither).
    public static func kind(file: URL, mediaType: String?) -> Kind {
        let type = mediaType?.lowercased() ?? ""
        let ext = file.pathExtension.lowercased()
        if type.contains("pdf") || ext == "pdf" { return .pdf }
        if type.hasPrefix("image/") || type.contains("gif") || imageExtensions.contains(ext) { return .image }
        if type.hasPrefix("audio/") || audioExtensions.contains(ext) { return .audio }
        if type.hasPrefix("video/") || type.contains("zip") || videoExtensions.contains(ext) || archiveExtensions.contains(ext) {
            return .unreadable
        }
        if documentExtensions.contains(ext) || type.contains("rtf") || type.contains("html") || type.contains("wordprocessingml")
            || type == "application/msword" { return .document }
        if type.hasPrefix("text/") || type.contains("json") || type.contains("xml") || textExtensions.contains(ext) { return .text }
        // Anything that decodes as UTF-8 is text.
        return looksLikeText(file) ? .text : .unreadable
    }

    private static func looksLikeText(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 8192) else { return false }
        try? handle.close()
        return !head.isEmpty && !head.contains(0) && decodeUTF8(head, cut: true) != nil
    }

    /// `data` as UTF-8; with `cut`, a last character split in two is dropped.
    static func decodeUTF8(_ data: Data, cut: Bool) -> String? {
        for drop in 0...(cut ? 3 : 0) where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return data.isEmpty ? "" : nil
    }

    // MARK: - Reading

    /// One part of `file`'s text from `offset` (a character count).
    public static func extract(
        file: URL, mediaType: String?, offset: Int = 0, transcriber: any AudioTranscribing = SystemTranscriber()
    ) async throws -> Part {
        let text = try await fullText(file: file, mediaType: mediaType, transcriber: transcriber)
        return part(of: text, from: offset)
    }

    /// All of `file`'s text, made safe for a model to read
    /// (`TextLine.block`: no marker, no hidden controls) and cut to `maxCharacters`.
    public static func fullText(
        file: URL, mediaType: String?, transcriber: any AudioTranscribing = SystemTranscriber()
    ) async throws -> String {
        let raw: String
        switch kind(file: file, mediaType: mediaType) {
        case .unreadable: throw Failure.unreadable
        case .image: raw = try await Task.detached { try recognizeText(inImageAt: file) }.value
        case .pdf: raw = try await Task.detached { try pdfText(file) }.value
        case .text: raw = try await Task.detached { try plainText(file) }.value
        case .document: raw = try await DocumentReader.text(of: file)
        case .audio: raw = try await speech(file, transcriber: transcriber)
        }
        return TextLine.block(raw, max: maxCharacters)
    }

    /// The part of `text` from character `offset`, at most `chunk` characters,
    /// ending at a line break when one is near.
    public static func part(of text: String, from offset: Int, chunk: Int = AttachmentText.chunk) -> Part {
        let total = text.count
        let start = min(max(offset, 0), total)
        let begin = text.index(text.startIndex, offsetBy: start)
        guard total - start > chunk else { return (String(text[begin...]), total, nil) }
        var end = text.index(begin, offsetBy: chunk)
        let window = text.index(end, offsetBy: -min(500, chunk / 4))
        if let newline = text[window..<end].lastIndex(of: "\n") { end = text.index(after: newline) }
        return (String(text[begin..<end]), total, text.distance(from: text.startIndex, to: end))
    }

    private static func plainText(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Four bytes of UTF-8 at most to a character.
        let limit = maxCharacters * 4
        let data = try handle.read(upToCount: limit) ?? Data()
        guard let text = decodeUTF8(data, cut: data.count == limit) else { throw Failure.unreadable }
        return text
    }

    private static func speech(_ file: URL, transcriber: any AudioTranscribing) async throws -> String {
        #if canImport(AVFoundation)
        if let seconds = try? await AVURLAsset(url: file).load(.duration).seconds, seconds.isFinite, seconds > maxAudioSeconds {
            throw Failure.tooLong(seconds: Int(seconds))
        }
        #endif
        return try await transcriber.transcribe(file, locale: .current)
    }

    // MARK: - Pictures and PDFs

    private static func recognizeText(inImageAt file: URL) throws -> String {
        #if canImport(Vision) && canImport(ImageIO)
        guard let image = ImageDecoding.thumbnail(file, maxPixels: maxPixels) else { throw Failure.failed("the picture could not be opened") }
        return try recognizeText(in: image)
        #else
        throw Failure.failed("this device cannot read text from pictures")
        #endif
    }

    #if canImport(Vision)
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    #endif

    private static func pdfText(_ file: URL) throws -> String {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: file) else { throw Failure.failed("the PDF could not be opened") }
        if document.isLocked { throw Failure.failed("the PDF is locked with a password") }
        var pages: [String] = []
        var scanned = 0, skipped = 0
        var characters = 0
        for index in 0..<document.pageCount {
            guard characters < maxCharacters, let page = document.page(at: index) else { break }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                if scanned < maxScannedPages { scanned += 1; text = scan(page) } else { skipped += 1 }
            }
            characters += text.count
            pages.append("[page \(index + 1)]\n\(text)")
        }
        if skipped > 0 { pages.append("[\(skipped) more pages with no text were not read: only \(maxScannedPages) are read as pictures]") }
        return pages.joined(separator: "\n\n")
        #else
        throw Failure.failed("this device cannot read PDFs")
        #endif
    }

    #if canImport(PDFKit)
    /// A page with no text, drawn and read as a picture; empty when it cannot be.
    private static func scan(_ page: PDFPage) -> String {
        #if canImport(Vision)
        guard let source = page.pageRef else { return "" }
        let box = source.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return "" }
        let scale = min(Double(maxPixels) / max(box.width, box.height), 3)
        let size = CGSize(width: (box.width * scale).rounded(.up), height: (box.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "" }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.concatenate(source.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(source)
        guard let image = context.makeImage() else { return "" }
        return (try? recognizeText(in: image)) ?? ""
        #else
        return ""
        #endif
    }
    #endif
}
