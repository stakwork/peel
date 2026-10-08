import ImageIO
import SwiftUI
import PeelCore

/// Images decoded off the main thread at the size they are drawn, kept
/// while memory allows and up to a cost limit. A row in a lazy list is made
/// and dropped as it scrolls, so a load belongs to the cache, not the row:
/// rows asking for the same image meanwhile share it, and one dropped
/// mid-load does not cut it off. (Each `AsyncImage` once fetched on its
/// own, and a row dropped mid-fetch was left on its initial for good.)
@MainActor
final class ImageCache {
    /// Attachments, and files waiting in a composer.
    static let shared = ImageCache(costLimit: 200 * 1024 * 1024)
    /// People's photos and tribes' icons, at avatar size. Apart from
    /// `shared`, so a full-size image in the viewer never pushes them out.
    static let photos = ImageCache(costLimit: 64 * 1024 * 1024)

    private let cache = NSCache<NSString, CGImage>()
    /// Loads running now.
    private var loads: [NSString: Task<CGImage?, any Error>] = [:]
    /// Photos whose server gave no image, not asked for again this session.
    private var missing: Set<NSString> = []

    private init(costLimit: Int) {
        cache.totalCostLimit = costLimit
    }

    /// Already decoded, to draw a row that scrolls back without a blank frame.
    func cached(_ file: URL?, maxPixels: Int) -> CGImage? {
        file.flatMap { cache.object(forKey: Self.key($0, maxPixels)) }
    }

    /// The image at `file`, at most `maxPixels` on its long side, upright.
    func image(_ file: URL, maxPixels: Int) async -> CGImage? {
        await load(Self.key(file, maxPixels), priority: .userInitiated, remembersMissing: false) {
            ImageDecoding.thumbnail(file, maxPixels: maxPixels)
        }
    }

    func cached(photo url: URL) -> CGImage? {
        cache.object(forKey: Self.key(photo: url))
    }

    /// The photo at an https `url`, fetched once. A fetch that throws (no
    /// answer, or the server busy or failing) is tried again next time; one
    /// that gets no image is not.
    func image(photo url: URL) async -> CGImage? {
        await load(Self.key(photo: url), priority: .utility, remembersMissing: true) {
            guard let data = try await Web.photo(at: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            // Decoded here, at avatar size (the short side still covers a
            // 36pt avatar at 2x for photos up to 3:1, as it is filled), so
            // drawing neither decodes on the main thread nor keeps the full photo.
            return ImageDecoding.thumbnail(source, maxPixels: 256)
        }
    }

    private func load(_ key: NSString, priority: TaskPriority, remembersMissing: Bool,
                      _ make: @escaping @Sendable () async throws -> CGImage?) async -> CGImage? {
        if let image = cache.object(forKey: key) { return image }
        guard !missing.contains(key) else { return nil }
        let load = loads[key] ?? Task.detached(priority: priority, operation: make)
        loads[key] = load
        let result = await load.result
        loads[key] = nil
        switch result {
        case .success(let image?):
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        case .success(nil):
            if remembersMissing { missing.insert(key) }
            return nil
        case .failure:
            return nil
        }
    }

    private static func key(_ file: URL, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(file.path)" as NSString }
    private static func key(photo url: URL) -> NSString { "photo|\(url.absoluteString)" as NSString }
}

/// Each video's and recording's `MediaInfo` (with a video's poster), read
/// once per file and shared by rows made and dropped while scrolling.
@MainActor
final class MediaInfoCache {
    static let shared = MediaInfoCache()

    private final class Entry {
        let read: Task<MediaInfo?, Never>
        var info: MediaInfo??
        init(_ read: Task<MediaInfo?, Never>) { self.read = read }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 200
        // Posters count by their bytes once read.
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static let posterPixels = Int(ImageTile.maxSide * 2)

    /// Already read, to lay a row out at once when it scrolls back.
    func cached(_ file: URL?) -> MediaInfo?? {
        file.flatMap { cache.object(forKey: $0.path as NSString)?.info }
    }

    /// Nil when AVFoundation cannot play the file.
    func info(_ file: URL, kind: AttachmentKind) async -> MediaInfo? {
        let key = file.path as NSString
        let entry = cache.object(forKey: key) ?? {
            let pixels = kind == .video ? Self.posterPixels : nil
            let entry = Entry(Task.detached(priority: .userInitiated) { await MediaInfo.load(file, posterPixels: pixels) })
            cache.setObject(entry, forKey: key)
            return entry
        }()
        let info = await entry.read.value
        if entry.info == nil {
            entry.info = .some(info)
            let poster = info?.poster
            cache.setObject(entry, forKey: key, cost: poster.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        return info
    }
}
