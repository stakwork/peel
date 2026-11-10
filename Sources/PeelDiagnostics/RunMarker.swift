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
    // Why a run that never quit ended (`PreviousRunDetail`); optional, so an older marker still reads.
    /// What it ran on: the device's boot, the OS, and its own executable (a new install changes the date).
    public var bootTime: Date?
    public var osVersion: String?
    public var binaryStamp: Date?
    /// Out of the front: since when, the footprint then, and when it was last known alive (an event
    /// recorded in the background, a push fetch, the background task ending).
    public var backgroundedAt: Date?
    public var backgroundFootprint: UInt64?
    public var lastAliveAt: Date?
    /// The memory warnings this run had, and whether its background task ran out of time.
    public var memoryWarnings: Int?
    public var backgroundTaskExpired: Bool?
}

/// The device and the build a run is on, read at launch.
public struct RunEnvironment: Sendable, Equatable {
    public var bootTime: Date?
    public var osVersion: String
    public var binaryStamp: Date?

    public init(bootTime: Date?, osVersion: String, binaryStamp: Date?) {
        self.bootTime = bootTime
        self.osVersion = osVersion
        self.binaryStamp = binaryStamp
    }

    public static func current() -> RunEnvironment {
        RunEnvironment(bootTime: bootTime(), osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                       binaryStamp: Bundle.main.executableURL.flatMap {
                           try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                       })
    }

    /// When the device last booted (`kern.boottime`).
    static func bootTime() -> Date? {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }
}

/// What a run that never quit (killed, in front or not) left in its marker, read at the next launch:
/// the likeliest cause and what it was doing. Only enums and numbers.
public struct PreviousRunDetail: Sendable, Equatable {
    public var cause: DiagnosticEvent.ExitCause
    /// Known alive out of the front for this long (from leaving it to the last sign of life).
    public var aliveInBackground: Int?
    /// From the last sign of life to this launch: the kill came somewhere in it.
    public var sinceAlive: Int?
    public var backgroundFootprint: UInt64?
    public var memoryWarnings: Int
    public var backgroundTaskExpired: Bool

    /// A boot clock read twice can differ by a little; a restart moves it by far more.
    static let bootTolerance: TimeInterval = 60

    /// nil for a run that quit, or no marker.
    public static func of(_ marker: RunMarker?, now: Date = Date(), environment: RunEnvironment) -> PreviousRunDetail? {
        guard let marker, marker.phase == .running else { return nil }
        let cause: DiagnosticEvent.ExitCause
        if let was = marker.bootTime, let boot = environment.bootTime, abs(was.timeIntervalSince(boot)) > bootTolerance {
            cause = marker.osVersion.map { $0 != environment.osVersion } == true ? .osUpdated : .restarted
        } else if let was = marker.binaryStamp, let stamp = environment.binaryStamp, was != stamp {
            cause = .reinstalled
        } else {
            cause = .system
        }
        let alive = marker.lastAliveAt
        return PreviousRunDetail(
            cause: cause,
            aliveInBackground: marker.backgroundedAt.flatMap { left in alive.map { max(Int($0.timeIntervalSince(left)), 0) } },
            sinceAlive: max(Int(now.timeIntervalSince(alive ?? marker.startedAt)), 0),
            backgroundFootprint: marker.backgroundFootprint,
            memoryWarnings: marker.memoryWarnings ?? 0,
            backgroundTaskExpired: marker.backgroundTaskExpired ?? false
        )
    }
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
                      state: RunMarker.State = .foreground, now: Date = Date(),
                      environment: RunEnvironment = .current()) -> PreviousRun {
        let data = try? Data(contentsOf: url)
        let marker = data.flatMap { try? Self.decoder().decode(RunMarker.self, from: $0) }
        let previous = Self.classify(marker, markerReadable: data == nil || marker != nil, crashReportID: crashReportID)
        var next = RunMarker(launchID: launchID, appVersion: appVersion, startedAt: now, phase: .running, lastKnownState: state)
        next.bootTime = environment.bootTime
        next.osVersion = environment.osVersion
        next.binaryStamp = environment.binaryStamp
        if state == .background { (next.backgroundedAt, next.lastAliveAt) = (now, now) }
        write(next)
        return previous
    }

    /// Into the front or out of it; out, with the footprint then.
    public func setState(_ state: RunMarker.State, footprint: UInt64? = nil, now: Date = Date()) {
        update {
            $0.lastKnownState = state
            if state == .background {
                $0.backgroundedAt = now
                $0.lastAliveAt = now
                $0.backgroundFootprint = footprint
            } else {
                $0.backgroundedAt = nil
            }
        }
    }

    /// Something happened out of the front: the run was alive then. At most once every few seconds.
    public func markAlive(now: Date = Date()) {
        update { marker in
            guard marker.lastKnownState == .background else { return }
            if let last = marker.lastAliveAt, now.timeIntervalSince(last) < 5 { return }
            marker.lastAliveAt = now
        }
    }

    public func noteMemoryWarning() {
        update { $0.memoryWarnings = ($0.memoryWarnings ?? 0) + 1 }
    }

    public func noteBackgroundTaskExpired() {
        update { $0.backgroundTaskExpired = true }
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
