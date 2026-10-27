import Foundation

/// How the run before this one ended.
public enum PreviousRun: Sendable, Equatable {
    /// Quit normally, or there was no run before.
    case clean
    /// A crash report was left; its id is the record's.
    case crashed(reportID: String)
    /// Gone without quitting or a report while in front: killed.
    case killedForeground
    /// The same while in the background: the system's doing (jetsam), expected.
    case killedBackground
    /// A marker that could not be read.
    case unknown

    public var kind: DiagnosticEvent.PreviousRunKind {
        switch self {
        case .clean: .clean
        case .crashed: .crashed
        case .killedForeground: .killedForeground
        case .killedBackground: .killedBackground
        case .unknown: .unknown
        }
    }

    /// Worth telling the person: a crash, or a kill while they were using Peel.
    public var isProblem: Bool {
        switch self {
        case .crashed, .killedForeground: true
        default: false
        }
    }
}

/// The marker file: `running` from launch, `clean` once the app terminates
/// normally. PLCrashReporter has no such marker, so Peel writes its own.
public struct RunMarker: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case running, clean }
    public enum State: String, Codable, Sendable { case foreground, background }

    public var launchID: String
    public var appVersion: String
    public var startedAt: Date
    public var phase: Phase
    public var lastKnownState: State
}

public final class RunMarkerStore: Sendable {
    private let url: URL
    private let current: Locked<RunMarker?>

    public init(file: URL) {
        url = file
        current = Locked(nil)
    }

    /// The previous run's end, from the marker left by it and the crash
    /// report it may have left. Written before the new marker replaces it.
    public static func classify(_ marker: RunMarker?, markerReadable: Bool = true, crashReportID: String?) -> PreviousRun {
        if let crashReportID { return .crashed(reportID: crashReportID) }
        guard markerReadable else { return .unknown }
        guard let marker else { return .clean }
        switch marker.phase {
        case .clean: return .clean
        case .running: return marker.lastKnownState == .foreground ? .killedForeground : .killedBackground
        }
    }

    /// Classifies the last run and starts this one's marker.
    @discardableResult
    public func begin(launchID: String = UUID().uuidString, appVersion: String, crashReportID: String?,
                      state: RunMarker.State = .foreground, now: Date = Date()) -> PreviousRun {
        let data = try? Data(contentsOf: url)
        let marker = data.flatMap { try? Self.decoder().decode(RunMarker.self, from: $0) }
        let previous = Self.classify(marker, markerReadable: data == nil || marker != nil, crashReportID: crashReportID)
        write(RunMarker(launchID: launchID, appVersion: appVersion, startedAt: now, phase: .running, lastKnownState: state))
        return previous
    }

    public func setState(_ state: RunMarker.State) {
        update { $0.lastKnownState = state }
    }

    /// Normal termination.
    public func markClean() {
        update { $0.phase = .clean }
    }

    public func read() -> RunMarker? {
        (try? Data(contentsOf: url)).flatMap { try? Self.decoder().decode(RunMarker.self, from: $0) }
    }

    private func update(_ change: (inout RunMarker) -> Void) {
        current.withLock { marker in
            guard var next = marker else { return }
            change(&next)
            guard next != marker else { return }
            marker = next
            save(next)
        }
    }

    private func write(_ marker: RunMarker) {
        current.withLock { $0 = marker }
        save(marker)
    }

    private func save(_ marker: RunMarker) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder().encode(marker) { try? data.write(to: url, options: .atomic) }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
