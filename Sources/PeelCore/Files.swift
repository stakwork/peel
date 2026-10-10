#if os(macOS)
import CoreServices
#endif
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures decoded at the size they are used, upright: attachments, photos,
/// thumbnails. One set of ImageIO options for all of them.
public enum ImageDecoding {
    /// The first image of `source`, at most `maxPixels` on its long side;
    /// nil when it is not a picture or `isTooLarge`.
    public static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        guard !isTooLarge(source) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixels))
    }

    /// The picture in a file, read without keeping the full-size image.
    public static func thumbnail(_ file: URL, maxPixels: Int) -> CGImage? {
        source(file).flatMap { thumbnail($0, maxPixels: maxPixels) }
    }

    /// The most source pixels decoded for a still in a format ImageIO
    /// scales while it decodes (JPEG, HEIC): a 200 MP phone photo or a
    /// long panorama costs about what its smaller decode does.
    public static let scaledFormatPixels = 500_000_000

    /// Whether the picture says it holds more source pixels than are
    /// decoded for its format: `scaledFormatPixels` for JPEG and HEIC,
    /// `animationPixels` for the rest (PNG, GIF, TIFF, BMP and others, which
    /// ImageIO reads in full whatever size they are drawn at, so a few
    /// compressed megabytes could claim a picture it then decodes at full
    /// size). A picture that does not say is not held to either.
    public static func isTooLarge(_ source: CGImageSource) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int else { return false }
        return isTooLarge(width: width, height: height, type: CGImageSourceGetType(source).flatMap { UTType($0 as String) })
    }

    /// The rule `isTooLarge` applies to what a picture's header says.
    static func isTooLarge(width: Int, height: Int, type: UTType?) -> Bool {
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        let scaled = type.map { $0.conforms(to: .jpeg) || $0.conforms(to: .heic) || $0.conforms(to: .heif) } ?? false
        return overflow || area > (scaled ? scaledFormatPixels : animationPixels)
    }

    public static func isTooLarge(_ file: URL) -> Bool {
        source(file).map(isTooLarge) ?? false
    }

    private static func source(_ file: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func options(_ maxPixels: Int) -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
    }

    /// More frames than this play as the first frame alone.
    static let maxFrames = 400
    /// The most one animation's decoded frames hold: past it they are decoded smaller.
    public static let animationBudget = 48 * 1024 * 1024
    /// The most source pixels (width × height × frames) decoded for one
    /// animation. ImageIO reads every frame at its full size whatever size
    /// it is drawn at, so this caps the work, as the budget caps the memory.
    /// A still image (`thumbnail`) in such a format is held to the same.
    public static let animationPixels = 100_000_000

    /// `source`'s frames at most `maxPixels` on their long side (smaller
    /// when they would not fit `budget` bytes), upright; nil when its first
    /// frame does not decode. Only its first frame, as a still, when it has
    /// more than `maxFrames` frames, more than `pixels` source pixels in
    /// all, or a first frame of unknown size.
    public static func animation(
        _ source: CGImageSource, maxPixels: Int, budget: Int = animationBudget, pixels: Int = animationPixels
    ) -> AnimationFrames? {
        let count = CGImageSourceGetCount(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            return thumbnail(source, maxPixels: maxPixels).map {
                AnimationFrames(frames: [$0], delays: [0], size: CGSize(width: $0.width, height: $0.height))
            }
        }
        // Upright, as the frames are drawn.
        let turned = ((properties?[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let (area, overflow) = (width * height).multipliedReportingOverflow(by: count)
        guard count > 1, count <= maxFrames, !overflow, area <= pixels else {
            return thumbnail(source, maxPixels: maxPixels).map { AnimationFrames(frames: [$0], delays: [0], size: size) }
        }
        var side = maxPixels
        let long = Double(min(max(width, height), maxPixels))
        let frameBytes = long * long * Double(min(width, height)) / Double(max(width, height)) * 4
        let total = frameBytes * Double(count)
        if total > Double(budget) {
            side = max(16, Int(long * (Double(budget) / total).squareRoot()))
        }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options(side)) else { break }
            frames.append(frame)
            delays.append(delay(source, at: index))
        }
        return frames.isEmpty ? nil : AnimationFrames(frames: frames, delays: delays, size: size)
    }

    private static let animationQueue = DispatchQueue(label: "peel.animation-decoding", qos: .utility)

    /// `decode` on a queue of its own, one at a time, so a run of GIFs
    /// never takes over the threads everything else shares.
    public static func oneAtATime(_ decode: @escaping @Sendable () -> AnimationFrames?) async -> AnimationFrames? {
        await withCheckedContinuation { continuation in
            animationQueue.async { continuation.resume(returning: decode()) }
        }
    }

    public static func animation(_ file: URL, maxPixels: Int) -> AnimationFrames? {
        CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { animation($0, maxPixels: maxPixels) }
    }

    public static func animation(
        _ data: Data, maxPixels: Int, budget: Int = animationBudget, pixels: Int = animationPixels
    ) -> AnimationFrames? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { animation($0, maxPixels: maxPixels, budget: budget, pixels: pixels) }
    }

    /// How long frame `index` shows: as browsers do, under 11 ms means 100 ms.
    static func delay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let formats: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in formats {
            guard let format = properties?[dictionary] as? [CFString: Any] else { continue }
            let seconds = (format[unclamped] as? Double) ?? (format[clamped] as? Double) ?? 0
            return seconds.isFinite && seconds >= 0.011 ? seconds : 0.1
        }
        return 0.1
    }
}

/// An animated picture (a GIF, an animated PNG or WebP) decoded at the size
/// it is drawn: its frames and how long each shows. One frame for a still
/// picture, or for one with too many frames to keep.
public final class AnimationFrames: Sendable {
    public let frames: [CGImage]
    /// Seconds each frame shows.
    public let delays: [Double]
    /// The picture's own size in pixels, upright, before any decoding
    /// smaller: what a tile is shaped and sized by.
    public let size: CGSize

    init(frames: [CGImage], delays: [Double], size: CGSize) {
        self.frames = frames
        self.delays = delays
        self.size = size
    }

    public var isAnimated: Bool { frames.count > 1 }

    /// The decoded bytes it holds, for a cache's cost.
    public var cost: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
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
        guard !ImageDecoding.isTooLarge(file) else { throw PeelError("\(file.lastPathComponent) is too large") }
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
