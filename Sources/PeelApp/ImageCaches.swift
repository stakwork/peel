import ImageIO
import SwiftUI
import PeelCore

/// Images, and animations frame by frame, decoded off the main thread at
/// the size they are drawn, kept while memory allows and up to a cost
/// limit. A row in a lazy list is made
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
    /// GIFs' frames, attachments' and Giphy's. Apart from `shared`, so a few
    /// large GIFs never push the still images out.
    static let animations = ImageCache(costLimit: 160 * 1024 * 1024)

    /// Images, or animations.
    private let cache = NSCache<NSString, AnyObject>()
    /// Loads running now.
    private var loads: [NSString: Task<(any Decoded)?, any Error>] = [:]
    /// Photos and GIFs whose server gave no image, not asked for again this session.
    private var missing: Set<NSString> = []
    /// GIFs' own sizes by file path (`size(of:)`).
    private var sizes: [String: CGSize] = [:]
    /// Giphy's GIFs as fetched (each at most `Giphy.limit`), for `animation(giphy:)`.
    private let giphyBytes: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private init(costLimit: Int) {
        cache.totalCostLimit = costLimit
    }

    /// Already decoded, to draw a row that scrolls back without a blank frame.
    func cached(_ file: URL?, maxPixels: Int) -> CGImage? {
        file.flatMap { object(Self.key($0, maxPixels)) }
    }

    /// The image at `file`, at most `maxPixels` on its long side, upright.
    func image(_ file: URL, maxPixels: Int) async -> CGImage? {
        await load(Self.key(file, maxPixels), priority: .userInitiated, remembersMissing: false) {
            ImageDecoding.thumbnail(file, maxPixels: maxPixels)
        }
    }

    func cached(animation file: URL?, maxPixels: Int) -> AnimationFrames? {
        file.flatMap { object(Self.key(animation: $0, maxPixels)) }
    }

    /// A GIF's own size once decoded, kept after its frames are evicted, so
    /// its row keeps its shape while they decode again.
    func size(of file: URL?) -> CGSize? {
        file.flatMap { sizes[$0.path] }
    }

    /// Every frame of the picture at `file`, as `image` decodes the first,
    /// one GIF at a time (`ImageDecoding.oneAtATime`).
    func animation(_ file: URL, maxPixels: Int) async -> AnimationFrames? {
        let frames = await load(Self.key(animation: file, maxPixels), priority: .userInitiated, remembersMissing: false) {
            await ImageDecoding.oneAtATime { ImageDecoding.animation(file, maxPixels: maxPixels) }
        }
        if let frames { sizes[file.path] = frames.size }
        return frames
    }

    func cached(giphy url: URL) -> AnimationFrames? {
        object(Self.key(giphy: url))
    }

    /// Giphy answered with no GIF: not worth asking again this session.
    func isMissing(giphy url: URL) -> Bool {
        missing.contains(Self.key(giphy: url))
    }

    /// The GIF at a Giphy `url`, fetched once (`Giphy.data`) and retried as
    /// photos are. Its bytes stay, so frames evicted are decoded again
    /// without asking Giphy (and telling it this Mac's address) again.
    func animation(giphy url: URL) async -> AnimationFrames? {
        let kept = giphyBytes.object(forKey: url.absoluteString as NSString).map { $0 as Data }
        return await load(Self.key(giphy: url), priority: .utility, remembersMissing: true) { [self] in
            let data: Data
            if let kept {
                data = kept
            } else {
                guard let fetched = try await Giphy.data(at: url) else { return nil }
                await keep(fetched, giphy: url)
                data = fetched
            }
            return await ImageDecoding.oneAtATime { ImageDecoding.animation(data, maxPixels: GiphyTile.maxPixels) }
        }
    }

    private func keep(_ data: Data, giphy url: URL) {
        giphyBytes.setObject(data as NSData, forKey: url.absoluteString as NSString, cost: data.count)
    }

    func cached(photo url: URL) -> CGImage? {
        object(Self.key(photo: url))
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

    private func object<T: AnyObject>(_ key: NSString) -> T? {
        cache.object(forKey: key) as? T
    }

    private func load<T: Decoded>(_ key: NSString, priority: TaskPriority, remembersMissing: Bool,
                                               _ make: @escaping @Sendable () async throws -> T?) async -> T? {
        if let object: T = object(key) { return object }
        guard !missing.contains(key) else { return nil }
        let load = loads[key] ?? Task.detached(priority: priority) { try await make() as (any Decoded)? }
        loads[key] = load
        let result = await load.result
        loads[key] = nil
        switch result {
        case .success(let object as T):
            cache.setObject(object, forKey: key, cost: object.cost)
            return object
        case .success:
            if remembersMissing { missing.insert(key) }
            return nil
        case .failure:
            return nil
        }
    }


    private static func key(_ file: URL, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(file.path)" as NSString }
    private static func key(animation file: URL, _ maxPixels: Int) -> NSString { "frames|\(maxPixels)|\(file.path)" as NSString }
    private static func key(giphy url: URL) -> NSString { "giphy|\(url.absoluteString)" as NSString }
    private static func key(photo url: URL) -> NSString { "photo|\(url.absoluteString)" as NSString }
}

/// What `ImageCache` keeps: an image or an animation, with its bytes as its cost.
protocol Decoded: AnyObject, Sendable {
    var cost: Int { get }
}

extension CGImage: Decoded {
    var cost: Int { bytesPerRow * height }
}

extension AnimationFrames: Decoded {}

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
            cache.setObject(entry, forKey: key, cost: poster?.cost ?? 0)
        }
        return info
    }
}
