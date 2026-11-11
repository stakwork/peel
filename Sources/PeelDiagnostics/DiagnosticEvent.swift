import Foundation

/// One entry in the event ring. Enums and numbers, with ONE string field:
/// `errorDetail`/`messageKind`, which only `Diagnostics.redact` output may
/// fill (hex and base64-like runs, invoices, URL paths and emails replaced,
/// whitespace collapsed, 200 characters at most). Keep every other field an
/// enum or a number (docs/diagnostics.md).
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
        // Why messages may not arrive on a connection that answers pings: the cursor each catch-up asks from,
        // each page of history and each live message as numbers, the clients alive, the subscriptions made,
        // and the self-check that asks the server whether anything came that was never delivered live.
        case catchUpCursor, historyPage, liveMessage, transportLifecycle, subscribed, selfCheck
        // The core refusing a call (where, which message kind, redacted text) and the engine reloading its state from storage.
        case coreFailure, coreRecovery
        // Why the system ended the last run (a restart, a new install, or the system itself) and what it was
        // doing out of the front; and the background task running out of time.
        case previousRunDetail, backgroundExpired
    }

    /// Where the engine saw the core fail.
    public enum CoreFailureSite: String, Codable, Sendable, CaseIterable {
        case receive, commit, cameOnline, checkPending, resumeHistory, catchUp
    }

    /// Why the engine reloaded its core state (`Engine.recoverCore`).
    public enum CoreRecoveryReason: String, Codable, Sendable, CaseIterable {
        case pageFailed, repeated, reinit, cameOnline, syncBound, catchUp
        /// stdout or stderr could not be written, which fails every core call (`StandardStreams`).
        case brokenStreams
    }

    /// How deep a recovery went: the state read again from storage, or everything the engine initialises.
    public enum CoreRecoveryStage: String, Codable, Sendable, CaseIterable {
        case reloadState, reinit
        /// stdout and stderr pointed at /dev/null.
        case streams
    }

    /// A transport's life: made, closed, left behind after `Transport.closeTimeout`, and (`establish`) the
    /// clients alive as a connect begins (`leak` when any is).
    public enum LifecycleStage: String, Codable, Sendable, CaseIterable {
        case opened, closed, abandoned, establish, leak
    }

    /// What a self-check found: nothing new from the server's history, or messages never delivered live.
    public enum SelfCheckOutcome: String, Codable, Sendable, CaseIterable {
        case ok, missed
    }

    /// What ran a self-check: the first after a catch-up, or the periodic one.
    public enum SelfCheckTrigger: String, Codable, Sendable, CaseIterable {
        case afterCaughtUp, periodic
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
        case foregroundRebuild, cameOnlineTimeout, selfCheckMissed, coreFailure
    }

    /// Where a catch-up is: asked for, ended at the last page, cut short by a cancel, or given up on.
    public enum CatchUpStage: String, Codable, Sendable, CaseIterable {
        case start, finish, cancel, abandon
    }

    /// Why a catch-up was asked for, or given up on.
    public enum CatchUpReason: String, Codable, Sendable, CaseIterable {
        case foreground, push, watchdog, cameOnline, stuckFlag, readFailure, syncBound, appLeftForeground, error, cancelled, selfCheck
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

    /// The likeliest reason a run that never quit ended (`PreviousRunDetail`): the device restarted (or
    /// was updated), the app was installed again (an update, Xcode), or none of those: the system ended
    /// it (memory, most often, for a suspended app).
    public enum ExitCause: String, Codable, Sendable, CaseIterable {
        case restarted, osUpdated, reinstalled, system
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
        /// "When Peel opens": back from the background. Face ID's check (within the timeout). And a launch
        /// that opened with the kept PIN, asking for nothing (not a lock, noted with them).
        case everyOpen, biometricCheck, rememberedPIN
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
    /// `catchUpCursor`: the index the catch-up asks from and the next it will ask for (`catchUpReason` says why).
    /// `selfCheck`: the cursor the check asked from.
    public var cursorFrom: Int?
    public var cursorNext: Int?
    /// `historyPage`: the indices on the page, the highest, how many stored a new row and how many did not
    /// (already stored, or records that keep no row).
    public var pageCount: Int?
    public var pageMaxIndex: Int?
    public var pageNew: Int?
    public var pageDup: Int?
    /// `liveMessage`: the server index, whether it is ours, its type number and whether it stored a new row;
    /// the type and `liveFromMe` are nil when it stored no row. Never its content.
    public var liveIndex: Int?
    public var liveFromMe: Bool?
    public var liveType: Int?
    public var liveNew: Bool?
    /// `transportLifecycle`: the stage and the clients alive after it.
    public var lifecycleStage: LifecycleStage?
    public var liveTransports: Int?
    /// `subscribed`: how many topics were subscribed on the connection, and whether the broker took them.
    public var subscribedTopics: Int?
    public var subscribedOk: Bool?
    /// `selfCheck`: what it found, what ran it, how many messages came that were never delivered live, and
    /// the highest server index stored here.
    public var selfCheckOutcome: SelfCheckOutcome?
    public var selfCheckTrigger: SelfCheckTrigger?
    public var selfCheckMissed: Int?
    public var highestIndex: Int?
    /// `error`, `coreFailure`: the failure's text after `Diagnostics.redact`, never raw.
    public var errorDetail: String?
    /// `coreFailure`: where, and the kind of message being handled (a word such as `batch`, redacted).
    public var failureSite: CoreFailureSite?
    public var messageKind: String?
    /// `coreRecovery`: why and how deep.
    public var recoveryReason: CoreRecoveryReason?
    public var recoveryStage: CoreRecoveryStage?
    /// `previousRunDetail`: why, how long it was known alive out of the front, how long from then to this
    /// launch, its memory warnings and whether its background task ran out (its footprint on leaving the
    /// front is `footprintBytes`).
    public var exitCause: ExitCause?
    public var aliveInBackgroundSeconds: Int?
    public var sinceAliveSeconds: Int?
    public var memoryWarnings: Int?
    public var backgroundTaskExpired: Bool?

    public init(
        kind: Kind, timestamp: Date = Date(), count: Int = 1, errorKind: ErrorKind? = nil,
        lastAction: Action? = nil, footprintBytes: UInt64? = nil, availableBytes: UInt64? = nil,
        pressureLevel: PressureLevel? = nil, previousRun: PreviousRunKind? = nil,
        exitReason: ExitReason? = nil, exitStatus: Int32? = nil, errorDetail: String? = nil
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
        self.errorDetail = errorDetail
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
