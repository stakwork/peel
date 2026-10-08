import CryptoKit
import Foundation

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
        let digest = SHA256.hash(data: Data("\(muid)\n\(key)".utf8)).hex
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
    private func trim(to limit: Int) {
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
