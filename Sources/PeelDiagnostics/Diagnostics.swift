import CryptoKit
import Foundation
#if canImport(os)
import os
#endif

/// What `Diagnostics.snapshot()` returns: no free text, only enums and numbers.
public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public var previousRun: DiagnosticEvent.PreviousRunKind
    public var hasReport: Bool
    public var appVersion: String?
    public var footprintBytes: UInt64?
    public var events: [DiagnosticEvent]
}

/// One launch's diagnostics: the ring, the run marker and the store, on a
/// folder given by the caller. `Diagnostics` is the app's one instance.
final class DiagnosticsRuntime: Sendable {
    let store: DiagnosticsStore
    let ring: DiagnosticsRing
    let marker: RunMarkerStore
    let previous: PreviousRun
    private let action = Locked(DiagnosticEvent.Action.launch)
    private let last = Locked<UInt64?>(nil)
    private let lastPhaseChange = Locked<Date?>(nil)
    private let sampling = Locked<Task<Void, Never>?>(nil)

    /// `crash` is the id of the report found at launch, if any (the record is already in the store).
    init(root: URL, appVersion: String, crash: String?, state: RunMarker.State = .foreground) {
        store = DiagnosticsStore(root: root)
        store.prepare()
        ring = DiagnosticsRing(file: store.ringFile)
        marker = RunMarkerStore(file: store.markerFile)
        let environment = RunEnvironment.current()
        let detail = PreviousRunDetail.of(marker.read(), environment: environment)
        previous = marker.begin(appVersion: appVersion, crashReportID: crash, state: state, environment: environment)
        var launch = DiagnosticEvent(kind: .launch, lastAction: .launch)
        launch.launchedInFront = state == .foreground
        launch.uptimeSeconds = Int(ProcessInfo.processInfo.systemUptime)
        ring.append(launch)
        Diagnostics.mirror("launch front=\(state == .foreground) uptime=\(Int(ProcessInfo.processInfo.systemUptime))s previous=\(previous.kind.rawValue)")
        ring.append(.init(kind: .previousRun, previousRun: previous.kind))
        // A kill (no crash report): why, most likely, and what the run was doing out of the front.
        if let detail, previous.kind != .crashed {
            var event = DiagnosticEvent(kind: .previousRunDetail, footprintBytes: detail.backgroundFootprint)
            event.exitCause = detail.cause
            event.aliveInBackgroundSeconds = detail.aliveInBackground
            event.sinceAliveSeconds = detail.sinceAlive
            event.memoryWarnings = detail.memoryWarnings
            event.backgroundTaskExpired = detail.backgroundTaskExpired
            ring.append(event)
            Diagnostics.mirror(event.line)
        }
    }

    func setAction(_ value: DiagnosticEvent.Action) { action.withLock { $0 = value } }

    func note(_ kind: DiagnosticEvent.ErrorKind, detail: String? = nil) {
        let current = action.withLock { $0 }
        let event = DiagnosticEvent(kind: .error, errorKind: kind, lastAction: current, errorDetail: detail)
        ring.append(event)
        Diagnostics.mirror("error \(kind.rawValue) during \(current.rawValue)" + (detail.map { " detail=\"\($0)\"" } ?? ""))
    }

    func sample(pressure: DiagnosticEvent.PressureLevel? = nil) {
        guard let footprint = MemoryProbe.footprint() else { return }
        let record = last.withLock { last -> Bool in
            guard MemoryPolicy.shouldRecord(last: last, new: footprint, pressure: pressure != nil) else { return false }
            last = footprint
            return true
        }
        guard record else { return }
        let current = action.withLock { $0 }
        ring.append(.init(kind: pressure == nil ? .memorySample : .memoryPressure, lastAction: current,
                          footprintBytes: footprint, availableBytes: MemoryProbe.available(), pressureLevel: pressure))
        if let pressure { Diagnostics.mirror("memory pressure \(pressure.rawValue)") }
    }

    /// Appends `event` (with the current action if it has none) and mirrors it, enum names and numbers only.
    /// Out of the front, it is also a sign the run was alive then (`RunMarker.lastAliveAt`).
    func record(_ event: DiagnosticEvent) {
        ring.append(event)
        Diagnostics.mirror(event.line)
        marker.markAlive()
    }

    func recordScenePhase(_ phase: DiagnosticEvent.ScenePhase) {
        let now = Date()
        let since = lastPhaseChange.withLock { last -> Int? in
            defer { last = now }
            return last.map { Int(now.timeIntervalSince($0).rounded()) }
        }
        var event = DiagnosticEvent(kind: .scenePhase, timestamp: now)
        event.scenePhase = phase
        event.sinceSeconds = since
        record(event)
    }

    /// The footprint at the moment of leaving the front, however close it is to the last sample.
    func recordBackgroundMemory() {
        guard let footprint = MemoryProbe.footprint() else { return }
        record(.init(kind: .memoryBackground, footprintBytes: footprint, availableBytes: MemoryProbe.available()))
    }

    /// Foreground samples every 60 seconds; the background none.
    func setForeground(_ foreground: Bool) {
        if !foreground { recordBackgroundMemory() }
        marker.setState(foreground ? .foreground : .background, footprint: foreground ? nil : MemoryProbe.footprint())
        sampling.withLock { task in
            task?.cancel()
            task = nil
            guard foreground else { return }
            task = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    func recordStrutExit(reason: DiagnosticEvent.ExitReason, status: Int32, tail: String) {
        ring.append(.init(kind: .strutExit, lastAction: action.withLock { $0 }, exitReason: reason, exitStatus: status))
        store.writeStrutTail(String(Redactor().redactText(tail).suffix(DiagnosticsStore.strutTailLimit)))
        Diagnostics.mirror("strut exit \(reason.rawValue) \(status)")
    }

    func latestRedacted(allow: [String], knownNames: [String]) throws -> RedactedRecord? {
        guard let id = store.rawIDs().first, var record = store.loadRaw(id) else { return nil }
        record.strutStderrTail = record.strutStderrTail ?? store.strutTail()
        let redacted = Redactor(allow: allow, knownNames: knownNames).redact(record)
        try store.saveRedacted(redacted)
        return redacted
    }

    func snapshot() -> DiagnosticsReport {
        DiagnosticsReport(previousRun: previous.kind, hasReport: !store.rawIDs().isEmpty,
                          appVersion: marker.read()?.appVersion, footprintBytes: MemoryProbe.footprint(),
                          events: ring.read())
    }
}

/// MetricKit's app exit categories (`MXAppExitMetric`), foreground (`fg`) and background (`bg`).
public enum AppExit: String, Sendable, CaseIterable {
    case fgNormal, fgAbnormal, fgMemoryResourceLimit, fgWatchdog, fgBadAccess, fgIllegalInstruction
    case bgNormal, bgAbnormal, bgMemoryResourceLimit, bgMemoryPressure, bgWatchdog, bgCPUResourceLimit
    case bgBadAccess, bgIllegalInstruction, bgSuspendedWithLockedFile, bgBackgroundTaskAssertionTimeout
}

/// On-device crash and memory diagnostics (docs/diagnostics.md). Nothing is
/// uploaded; the redacted record is read by the person, or by their agent
/// when they ask it. Every function is safe to call before
/// `CrashRecorder.install()` and does nothing then.
public enum Diagnostics {
    private static let runtime = Locked<DiagnosticsRuntime?>(nil)

    static func start(_ value: DiagnosticsRuntime) { runtime.withLock { $0 = value } }
    static var current: DiagnosticsRuntime? { runtime.withLock { $0 } }

    /// The live mirror: enum names only, never a message.
    static func mirror(_ line: String) {
        #if canImport(os)
        Logger(subsystem: "com.sphinx.peel", category: "diagnostics").info("\(line, privacy: .public)")
        #endif
    }

    /// The scene phase the phone entered (the app's `onChange(of: scenePhase)` calls this).
    public static func recordScenePhase(_ phase: DiagnosticEvent.ScenePhase) { current?.recordScenePhase(phase) }

    /// The lock screen was shown: at a cold launch, or by the idle timeout (`idleSeconds`, `timeoutHours`).
    public static func recordLock(_ reason: DiagnosticEvent.LockReason, idleSeconds: Int? = nil, timeoutHours: Int? = nil) {
        var event = DiagnosticEvent(kind: .lock)
        event.lockReason = reason
        event.idleSeconds = idleSeconds
        event.timeoutHours = timeoutHours
        current?.record(event)
    }

    /// A raw change of the system's network path.
    public static func recordNetwork(status: DiagnosticEvent.NetworkStatus, interface: DiagnosticEvent.NetworkInterface,
                                     isExpensive: Bool, isConstrained: Bool) {
        var event = DiagnosticEvent(kind: .network)
        event.networkStatus = status
        event.networkInterface = interface
        event.isExpensive = isExpensive
        event.isConstrained = isConstrained
        current?.record(event)
    }

    /// The push fetch's background task: `begin` with the time the system allows (infinity or
    /// unknown is none), `end` and `expired` with the seconds since `begin`.
    public static func recordPushFetch(_ stage: DiagnosticEvent.PushFetchStage, secondsLeft: Double? = nil, elapsed: Double? = nil) {
        var event = DiagnosticEvent(kind: .pushFetch)
        event.pushStage = stage
        if let secondsLeft, secondsLeft.isFinite { event.backgroundSecondsLeft = Int(min(secondsLeft, 86_400)) }
        event.elapsedSeconds = elapsed.map { ($0 * 10).rounded() / 10 }
        current?.record(event)
    }

    /// The ping made when the app came to the front: whether the connection answered, and how long it took.
    public static func recordForegroundPing(answered: Bool, milliseconds: Int) {
        var event = DiagnosticEvent(kind: .foregroundPing)
        event.pingAnswered = answered
        event.milliseconds = max(milliseconds, 0)
        current?.record(event)
    }

    /// What the engine decided on coming to the front, and why.
    public static func recordForegroundDecision(action: DiagnosticEvent.ForegroundAction, reason: DiagnosticEvent.ForegroundCause,
                                                awaySeconds: Int) {
        var event = DiagnosticEvent(kind: .foregroundDecision)
        event.foregroundAction = action
        event.foregroundCause = reason
        event.awaySeconds = max(awaySeconds, 0)
        current?.record(event)
    }

    /// A connection dropped on purpose, so it connects again.
    public static func recordForcedReconnect(reason: DiagnosticEvent.ReconnectReason) {
        var event = DiagnosticEvent(kind: .forcedReconnect)
        event.reconnectReason = reason
        current?.record(event)
    }

    /// One ping of the connection: whether it answered, how long it took, and whether it ran out of time.
    public static func recordPingResult(ok: Bool, milliseconds: Int, timedOut: Bool) {
        var event = DiagnosticEvent(kind: .pingResult)
        event.pingAnswered = ok
        event.milliseconds = max(milliseconds, 0)
        event.pingTimedOut = timedOut
        current?.record(event)
    }

    /// The app left the front, with a catch-up in flight or not.
    public static func recordBackground(inFlightCatchUp: Bool) {
        var event = DiagnosticEvent(kind: .background)
        event.inFlightCatchUp = inFlightCatchUp
        current?.record(event)
    }

    /// The network path changed (status or interfaces) since the app left the front; `awaySeconds` is nil in front.
    public static func recordPathChangeFlagged(awaySeconds: Int?) {
        var event = DiagnosticEvent(kind: .pathChangeFlagged)
        event.awaySeconds = awaySeconds.map { max($0, 0) }
        current?.record(event)
    }

    /// History was caught up on a connection: the milliseconds since it came up.
    public static func recordCaughtUp(milliseconds: Int) {
        var event = DiagnosticEvent(kind: .caughtUp)
        event.milliseconds = max(milliseconds, 0)
        current?.record(event)
    }

    /// A history fetch stalled and the connection was dropped so it reconnects.
    public static func recordStallReconnect() { current?.record(DiagnosticEvent(kind: .stallReconnect)) }

    /// A step of a catch-up: its stage, why, and the milliseconds since it started when known.
    public static func recordCatchUp(_ stage: DiagnosticEvent.CatchUpStage, reason: DiagnosticEvent.CatchUpReason, milliseconds: Int? = nil) {
        var event = DiagnosticEvent(kind: .catchUp)
        event.catchUpStage = stage
        event.catchUpReason = reason
        event.milliseconds = milliseconds.map { max($0, 0) }
        current?.record(event)
    }

    /// A catch-up asks the server for history from `from`; `next` is the index its run will ask for.
    public static func recordCatchUpCursor(from: UInt64, next: UInt64, reason: DiagnosticEvent.CatchUpReason) {
        var event = DiagnosticEvent(kind: .catchUpCursor)
        event.cursorFrom = Int(clamping: from)
        event.cursorNext = Int(clamping: next)
        event.catchUpReason = reason
        current?.record(event)
    }

    /// A page of history was handled: its indices, the highest, and how many stored a new row.
    public static func recordHistoryPage(count: Int, maxIndex: Int?, new: Int) {
        var event = DiagnosticEvent(kind: .historyPage)
        event.pageCount = count
        event.pageMaxIndex = maxIndex.map { max($0, 0) }
        event.pageNew = new
        event.pageDup = max(count - new, 0)
        current?.record(event)
    }

    /// A message came live, as numbers: never its content.
    public static func recordLiveMessage(index: Int, fromMe: Bool?, type: Int?, new: Bool) {
        var event = DiagnosticEvent(kind: .liveMessage)
        event.liveIndex = max(index, 0)
        event.liveFromMe = fromMe
        event.liveType = type
        event.liveNew = new
        current?.record(event)
    }

    /// What became of a tribe, or a message from one (`tribeTrace`); `tag` is `tribeTag(_:)` of its key.
    public static func recordTribeTrace(
        _ stage: DiagnosticEvent.TribeTraceStage, tag: Int, miss: DiagnosticEvent.TribeMiss? = nil,
        status: Int? = nil, messageType: Int? = nil, restoring: Bool? = nil, fromMe: Bool? = nil
    ) {
        var event = DiagnosticEvent(kind: .tribeTrace)
        event.tribeFromMe = fromMe
        event.tribeTag = tag
        event.tribeStage = stage
        event.tribeMiss = miss
        event.tribeStatus = status
        event.tribeMessageType = messageType
        event.tribeRestoring = restoring
        current?.record(event)
    }

    /// A stored tribe's membership (`tribeState`).
    public static func recordTribeState(tag: Int, left: Bool, status: Int) {
        var event = DiagnosticEvent(kind: .tribeState)
        event.tribeTag = tag
        event.tribeLeft = left
        event.tribeStatus = status
        current?.record(event)
    }

    /// A call's audio (`callAudio`): enums and flags only.
    public static func recordCallAudio(
        _ stage: DiagnosticEvent.CallAudioStage, ok: Bool? = nil, category: DiagnosticEvent.AudioCategory? = nil,
        micTrigger: DiagnosticEvent.MicTrigger? = nil, micEnabled: Bool? = nil, micPublicationMuted: Bool? = nil,
        wantsMic: Bool? = nil, routeReason: Int? = nil, scenePhase: DiagnosticEvent.ScenePhase? = nil
    ) {
        var event = DiagnosticEvent(kind: .callAudio)
        event.callAudioStage = stage
        event.callAudioOk = ok
        event.audioCategory = category
        event.micTrigger = micTrigger
        event.micEnabled = micEnabled
        event.micPublicationMuted = micPublicationMuted
        event.wantsMic = wantsMic
        event.routeReason = routeReason
        event.scenePhase = scenePhase
        current?.record(event)
    }

    /// The tag a tribe goes by in the diagnostics: the first 24 bits of the SHA-256 of its key.
    public static func tribeTag(_ pubkey: String) -> Int {
        SHA256.hash(data: Data(pubkey.utf8)).prefix(3).reduce(0) { $0 << 8 | Int($1) }
    }

    /// A transport was made, closed or abandoned, or a connect began: the clients alive then.
    public static func recordTransportLifecycle(stage: DiagnosticEvent.LifecycleStage, live: Int) {
        var event = DiagnosticEvent(kind: .transportLifecycle)
        event.lifecycleStage = stage
        event.liveTransports = max(live, 0)
        current?.record(event)
    }

    /// Topics were subscribed on a new connection, and whether the broker took them.
    public static func recordSubscribed(topics: Int, ok: Bool) {
        var event = DiagnosticEvent(kind: .subscribed)
        event.subscribedTopics = topics
        event.subscribedOk = ok
        current?.record(event)
    }

    /// The self-check's finding: `missed` messages came from history that were never delivered live (zero is ok).
    public static func recordSelfCheck(trigger: DiagnosticEvent.SelfCheckTrigger, from: UInt64, missed: Int, highest: Int?) {
        var event = DiagnosticEvent(kind: .selfCheck)
        event.selfCheckTrigger = trigger
        event.selfCheckOutcome = missed > 0 ? .missed : .ok
        event.cursorFrom = Int(clamping: from)
        event.selfCheckMissed = max(missed, 0)
        event.highestIndex = highest.map { max($0, 0) }
        current?.record(event)
    }

    /// A read failed on the connection's socket (no error text kept); the connection is dropped.
    public static func recordReadFailure() { current?.record(DiagnosticEvent(kind: .readFailure)) }

    /// MetricKit's exit counts, by `AppExit` (zero counts left out).
    public static func recordAppExits(_ counts: [AppExit: Int]) {
        let named = counts.filter { $0.value > 0 }
        guard !named.isEmpty else { return }
        var event = DiagnosticEvent(kind: .appExits)
        event.exitCounts = Dictionary(uniqueKeysWithValues: named.map { ($0.key.rawValue, $0.value) })
        current?.record(event)
    }

    /// One MetricKit diagnostic, as its kind and numbers.
    public static func recordMetricDiagnostic(_ kind: DiagnosticEvent.MetricDiagnosticKind, signal: Int? = nil,
                                              exceptionType: Int? = nil, exceptionCode: Int? = nil, hangSeconds: Double? = nil) {
        var event = DiagnosticEvent(kind: .metricDiagnostic)
        event.metricKind = kind
        event.signal = signal
        event.exceptionType = exceptionType
        event.exceptionCode = exceptionCode
        event.hangSeconds = hangSeconds.map { ($0 * 10).rounded() / 10 }
        current?.record(event)
    }

    /// An error the person was told about, as its kind only.
    public static func note(errorKind: DiagnosticEvent.ErrorKind) { current?.note(errorKind) }

    /// The same with the failure's text, redacted here (`redact`) whatever the caller passes.
    public static func note(errorKind: DiagnosticEvent.ErrorKind, detail: String?) {
        current?.note(errorKind, detail: detail.map(redact))
    }

    /// The core refused a call: where, the kind of message being handled, and the redacted text.
    public static func recordCoreFailure(site: DiagnosticEvent.CoreFailureSite, kind: String?, detail: String) {
        var event = DiagnosticEvent(kind: .coreFailure)
        event.failureSite = site
        event.messageKind = kind.map { String(redact($0).prefix(40)) }
        event.errorDetail = redact(detail)
        current?.record(event)
    }

    /// The engine reloaded its state from storage (`Engine.recoverCore`).
    public static func recordCoreRecovery(reason: DiagnosticEvent.CoreRecoveryReason, stage: DiagnosticEvent.CoreRecoveryStage) {
        var event = DiagnosticEvent(kind: .coreRecovery)
        event.recoveryReason = reason
        event.recoveryStage = stage
        current?.record(event)
    }

    /// Longest text a detail keeps.
    public static let detailLimit = 200

    /// Makes a failure's text safe to keep: emails, URL paths and queries, invoices, hex runs of 16+
    /// (keys, hashes, tags), base64/base58/bech32-like tokens of 24+ characters are replaced by
    /// `<redacted>`, whitespace is collapsed and the text capped at `detailLimit` characters.
    public static func redact(_ text: String) -> String {
        let rules: [(pattern: String, template: String)] = [
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<redacted>"),
            (#"([A-Za-z][A-Za-z0-9+.\-]*://[^\s/?#]+)[/?#]\S*"#, "$1<redacted>"),
            (#"\b(?:lnbcrt|lntbs|lnbc|lntb)[0-9a-z]{10,}"#, "<redacted>"),
            (#"\b[0-9a-fA-F]{16,}\b"#, "<redacted>"),
            (#"[A-Za-z0-9+/=_\-]{24,}"#, "<redacted>"),
        ]
        var out = text
        for rule in rules {
            let options: String.CompareOptions = rule.pattern.contains("lnbc") ? [.regularExpression, .caseInsensitive] : .regularExpression
            out = out.replacingOccurrences(of: rule.pattern, with: rule.template, options: options)
        }
        out = out.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(out.prefix(detailLimit))
    }

    /// What the person just asked for, attached to the events that follow.
    public static func setAction(_ action: DiagnosticEvent.Action) { current?.setAction(action) }

    public static func setForeground(_ foreground: Bool) { current?.setForeground(foreground) }

    /// Normal termination: the next launch will not call this run killed.
    public static func markCleanExit() { current?.marker.markClean() }

    /// iOS's memory warning (the app's notification handler calls this; the
    /// Mac's pressure source is started by `install`).
    public static func memoryWarning() {
        current?.marker.noteMemoryWarning()
        current?.sample(pressure: .warning)
    }

    /// The app is out of the front and still running (its background work ended, say): noted in the run
    /// marker, so a kill after it is known to have come later.
    public static func markAlive() { current?.marker.markAlive() }

    /// The system is about to suspend the app before its background task ended (the iPhone's expiry
    /// handler calls this).
    public static func backgroundTaskExpired() {
        current?.marker.noteBackgroundTaskExpired()
        current?.record(DiagnosticEvent(kind: .backgroundExpired))
    }

    public static func recordStrutExit(reason: DiagnosticEvent.ExitReason, status: Int32, stderrTail: String) {
        current?.recordStrutExit(reason: reason, status: status, tail: stderrTail)
    }

    public static func previousRun() -> PreviousRun { current?.previous ?? .clean }

    public static func recentEvents(limit: Int = 100) -> [DiagnosticEvent] {
        Array((current?.ring.read() ?? []).suffix(max(limit, 0)))
    }

    public static func snapshot() -> DiagnosticsReport {
        current?.snapshot() ?? DiagnosticsReport(previousRun: .clean, hasReport: false, appVersion: nil,
                                                 footprintBytes: nil, events: [])
    }

    /// The newest crash record, redacted (and the redacted copy kept). The
    /// only way a report leaves the raw folder. `allow` is the tribe's name
    /// and key that may stay; `knownNames` the contacts', built now, never kept.
    public static func latestRedactedReport(allow: [String] = [], knownNames: [String] = []) async throws -> RedactedRecord? {
        guard let current else { return nil }
        return try await Task.detached { try current.latestRedacted(allow: allow, knownNames: knownNames) }.value
    }

    #if DEBUG
    /// Crashes the app on purpose, to see a record made. It MUST run with no
    /// debugger attached (launch from Finder or the Home Screen, not Run in
    /// Xcode): the crash reporter stays off under a debugger, and the
    /// debugger would take the signal.
    public static func forceTestCrash() -> Never {
        raise(SIGABRT)
        fatalError("test crash")
    }
    #endif

    /// Empties the event ring only: crash records and the run marker stay.
    public static func clearEvents() { current?.ring.clear() }

    /// Removes every record, raw and redacted.
    public static func deleteRecords() { current?.store.deleteAll() }
}
