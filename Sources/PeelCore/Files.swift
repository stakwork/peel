#if os(macOS)
import CoreServices
#endif
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures decoded at the size they are used, upright: attachments, photos,
/// thumbnails. One set of ImageIO options for all of them.
public enum ImageDecoding {
    /// The first image of `source`, at most `maxPixels` on its long side.
    public static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// The picture in a file, read without keeping the full-size image.
    public static func thumbnail(_ file: URL, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { thumbnail($0, maxPixels: maxPixels) }
    }
}

/// Bytes over a size limit: a file picked to send or attach, or a download
/// cut off. `size` is the whole size, when the server named it.
struct TooLarge: Error, CustomStringConvertible {
    let limit: Int
    var size: Int64?

    var description: String {
        "the file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))"
    }
}

/// A profile photo as the Mac app uploads one: JPEG at quality 0.5.
enum ProfilePhoto {
    static let maxPixels = 1024

    /// The picture at `file`, at most `maxPixels` on its long side, upright.
    static func jpeg(from file: URL, limit: Int) throws -> Data {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw TooLarge(limit: limit) }
        guard let image = ImageDecoding.thumbnail(file, maxPixels: maxPixels) else {
            throw PeelError("\(file.lastPathComponent) is not a picture")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PeelError("could not make a JPEG")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PeelError("could not make a JPEG") }
        return data as Data
    }
}

/// Files Peel writes for the person: an attachment saved where they chose,
/// or into Downloads. Each is a copy of the decrypted file, marked as
/// downloaded from the internet (quarantined, with Peel as the agent), so
/// Gatekeeper checks it before it is opened. Peel itself never opens one.
public enum UserFiles {
    /// Copies `file` into `directory` under a cleaned `name`, as "name (1).ext"
    /// and so on when that is taken. Returns where it went.
    public static func save(_ file: URL, named name: String, in directory: URL) throws -> URL {
        let clean = cleanName(name)
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        for attempt in 0..<1000 {
            let candidate = attempt == 0 ? clean : "\(base) (\(attempt))" + (ext.isEmpty ? "" : ".\(ext)")
            let target = directory.appendingPathComponent(candidate, isDirectory: false)
            do {
                try FileManager.default.copyItem(at: file, to: target)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
            try quarantine(target)
            return target
        }
        throw PeelError("there are too many files called \(clean) already")
    }

    /// `save` into the person's Downloads folder, off the caller's actor.
    public static func saveToDownloads(_ file: URL, named name: String) async throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw PeelError("there is no Downloads folder")
        }
        return try await Task.detached { try save(file, named: name, in: downloads) }.value
    }

    /// Copies `file` to `target`, replacing what is there (the person chose
    /// it in a save panel, which asked first).
    public static func copy(_ file: URL, to target: URL, replacing: Bool) throws {
        if replacing, FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: file, to: target)
        try quarantine(target)
    }

    /// A name that stays one file name: no folders, no hidden file, no
    /// control characters (bidirectional overrides among them), and at most
    /// `maxNameBytes` (the file system takes 255) with its extension kept,
    /// so shortening never turns "….pdf" into another type.
    static func cleanName(_ name: String) -> String {
        var clean = name.withoutControlCharacters
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        // Spaces and dots both, so " .zshrc" cannot become a hidden ".zshrc".
        while let first = clean.first, first == "." || first.isWhitespace { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        guard clean.utf8.count > maxNameBytes else { return clean.isEmpty ? "file" : clean }
        let ext = (clean as NSString).pathExtension
        let suffix = (1...16).contains(ext.utf8.count) && clean.hasSuffix("." + ext) ? "." + ext : ""
        var stem = "", bytes = suffix.utf8.count
        for character in clean.dropLast(suffix.count) {
            bytes += character.utf8.count
            guard bytes <= maxNameBytes else { break }
            stem.append(character)
        }
        // One huge character (a letter under a pile of accents) leaves no stem.
        return (stem.isEmpty ? "file" : stem) + suffix
    }

    static let maxNameBytes = 200

    /// Marks a file as downloaded by Peel. A file that cannot be marked is
    /// removed rather than left unmarked.
    private static func quarantine(_ file: URL) throws {
        #if os(macOS)
        var url = file
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Peel",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        do {
            try url.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        #endif
    }
}
