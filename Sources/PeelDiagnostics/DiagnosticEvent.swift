import Foundation

/// One entry in the event ring. Only enums and numbers: there is no String
/// field, so nothing a person wrote, no error message, path, name or key can
/// be stored here, however a caller is written. That is the privacy
/// guarantee for the ring (docs/diagnostics.md); keep it when adding a field.
public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case error, memorySample, memoryPressure, launch, previousRun, strutExit
        // Why the PIN is asked so often (docs/diagnostics.md, "Tracing the PIN prompts").
        case scenePhase, memoryBackground, lock, network, pushFetch, appExits, metricDiagnostic
        // Why messages may not arrive on a connected bolt: the ping on coming to the front, how long
        // coming online took to catch up, and a stalled history that forced a reconnect.
        case foregroundPing, caughtUp, stallReconnect
        // The catch-up's lifecycle (start, finish, cancel, abandon, and why) and a read that failed on the socket.
        case catchUp, readFailure
        // What the engine decided on coming to the front and why, each connection it dropped on purpose,
        // every ping's result, leaving the front, and a path change noted while away.
        case foregroundDecision, forcedReconnect, pingResult, background, pathChangeFlagged
    }

    /// What the engine did with its connection on coming to the front.
    public enum ForegroundAction: String, Codable, Sendable, CaseIterable {
        case trust, verify, rebuild, reconnect
    }

    /// Why (`ForegroundAction`): what made the old connection untrustworthy, or none.
    public enum ForegroundCause: String, Codable, Sendable, CaseIterable {
        case away, pathChange, unverified, readFailure, notCaughtUp, offline, verifyTimeout, pingFailed, none
    }

    /// Why a connection was dropped on purpose to connect again.
    public enum ReconnectReason: String, Codable, Sendable, CaseIterable {
        case pingFailed, pingTimeout, stall, syncBound, readFailure, pathChange, catchUpError
        case foregroundRebuild, cameOnlineTimeout
    }

    /// Where a catch-up is: asked for, ended at the last page, cut short by a cancel, or given up on.
    public enum CatchUpStage: String, Codable, Sendable, CaseIterable {
        case start, finish, cancel, abandon
    }

    /// Why a catch-up was asked for, or given up on.
    public enum CatchUpReason: String, Codable, Sendable, CaseIterable {
        case foreground, push, watchdog, cameOnline, stuckFlag, readFailure, syncBound, appLeftForeground, error, cancelled
    }

    /// The kinds of failure Peel shows a notice for, as `PeelError.readable`
    /// tells them apart; the words themselves are never kept.
    public enum ErrorKind: String, Codable, Sendable, CaseIterable {
        case database, network, connection, server, secureConnection, file, cancelled
        case core, decoding, engine, call, refused, other
    }

    /// What the person had just asked Peel to do.
    public enum Action: String, Codable, Sendable, CaseIterable {
        case tribeJoin, send, sync, launch, other
    }

    public enum PressureLevel: String, Codable, Sendable, CaseIterable {
        case warning, critical
    }

    public enum ExitReason: String, Codable, Sendable, CaseIterable {
        case exit, uncaughtSignal
    }

    /// How the previous run ended (`PreviousRun`, without a report's id).
    public enum PreviousRunKind: String, Codable, Sendable, CaseIterable {
        case clean, crashed, killedForeground, killedBackground, unknown
    }

    public enum ScenePhase: String, Codable, Sendable, CaseIterable {
        case active, inactive, background
    }

    public enum LockReason: String, Codable, Sendable, CaseIterable {
        case coldLaunch, idleTimeout
    }

    public enum NetworkStatus: String, Codable, Sendable, CaseIterable {
        case satisfied, unsatisfied, requiresConnection
    }

    public enum NetworkInterface: String, Codable, Sendable, CaseIterable {
        case wifi, cellular, wiredEthernet, other, none
    }

    public enum PushFetchStage: String, Codable, Sendable, CaseIterable {
        case begin, end, expired
    }

    /// What MetricKit's diagnostic payload reported (its numbers only, never its call stacks or strings).
    public enum MetricDiagnosticKind: String, Codable, Sendable, CaseIterable {
        case crash, hang, cpuException, diskWriteException
    }

    public var kind: Kind
    public var timestamp: Date
    public var count: Int
    public var errorKind: ErrorKind?
    public var lastAction: Action?
    public var footprintBytes: UInt64?
    public var availableBytes: UInt64?
    public var pressureLevel: PressureLevel?
    public var previousRun: PreviousRunKind?
    public var exitReason: ExitReason?
    public var exitStatus: Int32?
    // Every field below is optional: ring files written before them still decode.
    /// `launch`: started in front (not by the system in the background), and the device's uptime then.
    public var launchedInFront: Bool?
    public var uptimeSeconds: Int?
    /// `scenePhase`: the phase entered and the seconds since the last change.
    public var scenePhase: ScenePhase?
    public var sinceSeconds: Int?
    /// `lock`: why the lock screen was shown, the idle seconds and the timeout in hours.
    public var lockReason: LockReason?
    public var idleSeconds: Int?
    public var timeoutHours: Int?
    /// `network`: the path as the system reported it.
    public var networkStatus: NetworkStatus?
    public var networkInterface: NetworkInterface?
    public var isExpensive: Bool?
    public var isConstrained: Bool?
    /// `pushFetch`: the stage, the background time the system allows (begin, whole seconds) and
    /// the seconds since begin (end, expired).
    public var pushStage: PushFetchStage?
    public var backgroundSecondsLeft: Int?
    public var elapsedSeconds: Double?
    /// `appExits`: MetricKit's exit counts, keyed by `AppExit` names (enum names only).
    public var exitCounts: [String: Int]?
    /// `metricDiagnostic`: the kind and its numbers.
    public var metricKind: MetricDiagnosticKind?
    public var signal: Int?
    public var exceptionType: Int?
    public var exceptionCode: Int?
    public var hangSeconds: Double?
    /// `foregroundPing`: whether the connection answered. `foregroundPing` and `caughtUp`: the milliseconds it took.
    public var pingAnswered: Bool?
    public var milliseconds: Int?
    /// `catchUp`: the stage and why; `milliseconds` is the time since it started, when known.
    public var catchUpStage: CatchUpStage?
    public var catchUpReason: CatchUpReason?
    /// `foregroundDecision`: the action, its cause and the seconds away. `pathChangeFlagged`: the seconds away, when known.
    public var foregroundAction: ForegroundAction?
    public var foregroundCause: ForegroundCause?
    public var awaySeconds: Int?
    /// `forcedReconnect`: why the connection was dropped.
    public var reconnectReason: ReconnectReason?
    /// `pingResult`: the ping got no answer in time (`pingAnswered` and `milliseconds` say the rest).
    public var pingTimedOut: Bool?
    /// `background`: a catch-up was in flight as the app left the front.
    public var inFlightCatchUp: Bool?

    public init(
        kind: Kind, timestamp: Date = Date(), count: Int = 1, errorKind: ErrorKind? = nil,
        lastAction: Action? = nil, footprintBytes: UInt64? = nil, availableBytes: UInt64? = nil,
        pressureLevel: PressureLevel? = nil, previousRun: PreviousRunKind? = nil,
        exitReason: ExitReason? = nil, exitStatus: Int32? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.count = count
        self.errorKind = errorKind
        self.lastAction = lastAction
        self.footprintBytes = footprintBytes
        self.availableBytes = availableBytes
        self.pressureLevel = pressureLevel
        self.previousRun = previousRun
        self.exitReason = exitReason
        self.exitStatus = exitStatus
    }

    /// Whether `other` is the same event again (everything but when, and
    /// how often), so the ring counts it instead of writing it twice.
    func repeats(_ other: DiagnosticEvent) -> Bool {
        var copy = other
        copy.timestamp = timestamp
        copy.count = count
        return copy == self
    }
}
