import Foundation

/// A Talk session saved to disk after a call ends.
public struct TalkSavedSession: Identifiable, Codable, Sendable {
    public let id: String          // random UUID, stable across reads
    public let homeId: String      // TalkHome.id (workspace slug or "@development")
    public let homeName: String    // TalkHome.name, human-readable
    public let date: Date          // when the call ended
    public let lines: [TalkLine]

    /// The first line's text as a preview; nil when the transcript is empty.
    public var preview: String? { lines.first?.text }
}

/// Reads and writes saved Talk sessions to
/// `<Application Support>/talk_history/<homeId>_<ISO8601>.json`.
public enum TalkHistoryStore {

    // MARK: - Directory

    static func directory() -> URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("talk_history", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    // MARK: - Writing

    /// Saves `transcript` for `homeId` to a timestamped JSON file.
    /// Called from a background task; never throws.
    public static func save(transcript: TalkTranscript, homeId: String, homeName: String) {
        guard let dir = directory(), !transcript.lines.isEmpty else { return }
        let date = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Sanitise homeId: replace characters that are not safe in a filename.
        let safeId = homeId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let timestamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(safeId)_\(timestamp).json"
        let session = TalkSavedSession(
            id: UUID().uuidString,
            homeId: homeId,
            homeName: homeName,
            date: date,
            lines: transcript.lines
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Reading

    /// All saved sessions for `homeId`, newest first.
    public static func sessions(for homeId: String) -> [TalkSavedSession] {
        guard let dir = directory() else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        } catch {
            return []
        }
        let safeId = homeId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.lastPathComponent.hasPrefix("\(safeId)_") && $0.pathExtension == "json" }
            .compactMap { url -> TalkSavedSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TalkSavedSession.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }
}
