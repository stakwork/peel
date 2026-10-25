import Foundation

/// The Diagnostics folder: `raw/` (private: the reports as found), `redacted/`
/// (only what `Redactor` made) and the strut's stderr tail. Takes its folder as
/// a parameter. Nothing here is public: the raw record never leaves the module.
struct DiagnosticsStore: Sendable {
    let root: URL
    var raw: URL { root.appending(path: "raw", directoryHint: .isDirectory) }
    var redacted: URL { root.appending(path: "redacted", directoryHint: .isDirectory) }
    var ringFile: URL { root.appending(path: "events.ring") }
    var markerFile: URL { root.appending(path: "run-marker.json") }
    var strutTailFile: URL { root.appending(path: "strut-stderr-tail.txt") }

    /// Creates the folders: owner-only, left out of backups and, on iOS,
    /// readable once the phone has been unlocked after a restart.
    func prepare() {
        let manager = FileManager.default
        for folder in [root, raw, redacted] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            #if os(iOS)
            try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                       ofItemAtPath: folder.path)
            #endif
        }
        #if canImport(Darwin)
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        #endif
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Ids are ours (a UUID), but a name read from disk is still checked.
    private func file(_ id: String, in folder: URL, _ ext: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return folder.appending(path: "\(id).\(ext)")
    }

    func saveRaw(_ record: CrashRecord, report: Data? = nil) throws {
        guard let url = file(record.id, in: raw, "json") else { return }
        try encoder().encode(record).write(to: url, options: .atomic)
        if let report, let copy = file(record.id, in: raw, "plcrash") { try report.write(to: copy, options: .atomic) }
    }

    /// Ids of the raw records, newest first.
    func rawIDs() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: raw, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .map { ($0.deletingPathExtension().lastPathComponent,
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func loadRaw(_ id: String) -> CrashRecord? {
        guard let url = file(id, in: raw, "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(CrashRecord.self, from: data)
    }

    func saveRedacted(_ record: RedactedRecord) throws {
        guard let url = file(record.id, in: redacted, "json") else { return }
        try encoder().encode(record).write(to: url, options: .atomic)
    }

    func loadRedacted(_ id: String) -> RedactedRecord? {
        guard let url = file(id, in: redacted, "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(RedactedRecord.self, from: data)
    }

    /// Removes the raw and redacted copies of every record, and the strut's tail.
    func deleteAll() {
        let manager = FileManager.default
        for folder in [raw, redacted] {
            for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? manager.removeItem(at: url)
            }
        }
        try? manager.removeItem(at: strutTailFile)
    }

    static let strutTailLimit = 2048

    /// The strut's last words, already redacted, at most 2 KiB, overwritten each time.
    func writeStrutTail(_ text: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(text.utf8).prefix(Self.strutTailLimit)
        try? Data(bytes).write(to: strutTailFile, options: .atomic)
    }

    func strutTail() -> String? {
        (try? Data(contentsOf: strutTailFile)).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// The last bytes a child process wrote to stderr: bounded, always taking
/// more, so the child never blocks on a full pipe.
public final class StderrTail: Sendable {
    private struct State { var bytes = Data(); var truncated = false }
    private let limit: Int
    private let state = Locked(State())

    public init(limit: Int = 2048) { self.limit = limit }

    public func append(_ chunk: Data) {
        state.withLock { state in
            state.bytes.append(chunk)
            if state.bytes.count > limit {
                state.bytes = Data(state.bytes.suffix(limit))
                state.truncated = true
            }
        }
    }

    /// The tail as text. When older output was cut away, the first line is
    /// dropped too: it begins mid-way, and half a secret is not redacted well.
    public var text: String {
        let (bytes, truncated) = state.withLock { ($0.bytes, $0.truncated) }
        var text = String(decoding: bytes, as: UTF8.self)
        if truncated {
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) } else { text = "" }
        }
        return text
    }
}

/// When a memory sample is worth a ring entry: the first, or one that moved
/// by 5% or more since the last written; pressure always.
enum MemoryPolicy {
    static func shouldRecord(last: UInt64?, new: UInt64, pressure: Bool = false) -> Bool {
        if pressure { return true }
        guard let last, last > 0 else { return true }
        let change = new > last ? new - last : last - new
        return Double(change) / Double(last) >= 0.05
    }
}
