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
    private let sampling = Locked<Task<Void, Never>?>(nil)

    /// `crash` is the id of the report found at launch, if any (the record is already in the store).
    init(root: URL, appVersion: String, crash: String?) {
        store = DiagnosticsStore(root: root)
        store.prepare()
        ring = DiagnosticsRing(file: store.ringFile)
        marker = RunMarkerStore(file: store.markerFile)
        previous = marker.begin(appVersion: appVersion, crashReportID: crash)
        ring.append(.init(kind: .launch, lastAction: .launch))
        ring.append(.init(kind: .previousRun, previousRun: previous.kind))
    }

    func setAction(_ value: DiagnosticEvent.Action) { action.withLock { $0 = value } }

    func note(_ kind: DiagnosticEvent.ErrorKind) {
        let current = action.withLock { $0 }
        ring.append(.init(kind: .error, errorKind: kind, lastAction: current))
        Diagnostics.mirror("error \(kind.rawValue) during \(current.rawValue)")
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

    /// Foreground samples every 60 seconds; the background none.
    func setForeground(_ foreground: Bool) {
        marker.setState(foreground ? .foreground : .background)
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

/// On-device crash and memory diagnostics (docs/diagnostics.md). A record
/// only: nothing leaves the device. Every function is safe to call before
/// `CrashRecorder.install()` and does nothing then.
public enum Diagnostics {
    private static let runtime = Locked<DiagnosticsRuntime?>(nil)

    static func start(_ value: DiagnosticsRuntime) { runtime.withLock { $0 = value } }
    static var current: DiagnosticsRuntime? { runtime.withLock { $0 } }

    /// The live mirror: enum names only, never a message.
    static func mirror(_ line: String) {
        #if canImport(os)
        Logger(subsystem: "dev.peel.mac", category: "diagnostics").info("\(line, privacy: .public)")
        #endif
    }

    /// An error the person was told about, as its kind only.
    public static func note(errorKind: DiagnosticEvent.ErrorKind) { current?.note(errorKind) }

    /// What the person just asked for, attached to the events that follow.
    public static func setAction(_ action: DiagnosticEvent.Action) { current?.setAction(action) }

    public static func setForeground(_ foreground: Bool) { current?.setForeground(foreground) }

    /// Normal termination: the next launch will not call this run killed.
    public static func markCleanExit() { current?.marker.markClean() }

    /// iOS's memory warning (the app's notification handler calls this; the
    /// Mac's pressure source is started by `install`).
    public static func memoryWarning() { current?.sample(pressure: .warning) }

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

    /// Removes every record, raw and redacted.
    public static func deleteRecords() { current?.store.deleteAll() }
}
