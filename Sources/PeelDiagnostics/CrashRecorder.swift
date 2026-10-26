import Foundation
#if canImport(CrashReporter)
import CrashReporter
#endif

/// Starts crash recording, once, at the earliest point of a launch (before
/// the app's model exists). Only the crash reporter is Apple-only; the run
/// marker, the ring and the sampler run anywhere.
public enum CrashRecorder {
    private static let started = Locked(false)
    #if canImport(CrashReporter)
    // The one reporter: PLCrashReporter keeps its handlers for the life of the process.
    private nonisolated(unsafe) static var reporter: PLCrashReporter?
    #endif
    #if os(macOS) && canImport(Dispatch)
    private nonisolated(unsafe) static var pressure: [DispatchSourceMemoryPressure] = []
    #endif

    /// Where Diagnostics lives: Application Support, in Peel's folder on the
    /// Mac (shared with other apps' otherwise), in the app's own container on iOS.
    public static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return support.appending(path: "Peel/Diagnostics", directoryHint: .isDirectory)
        #else
        return support.appending(path: "Diagnostics", directoryHint: .isDirectory)
        #endif
    }

    public static func install(root: URL = defaultRoot()) {
        guard started.withLock({ let was = $0; $0 = true; return !was }) else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let store = DiagnosticsStore(root: root)
        store.prepare()
        // A report left by the last run is taken before this one's ring entries exist.
        var crash: String?
        #if canImport(CrashReporter)
        let ring = DiagnosticsRing(file: store.ringFile)
        // With a debugger attached the reporter would swallow its signals, so it stays off:
        // run a crash test without one (docs/diagnostics.md).
        let config = PLCrashReporterConfig(signalHandlerType: signalHandler, symbolicationStrategy: symbolication)
        if let candidate = PLCrashReporter(configuration: config) {
            crash = PendingReport.collect(from: candidate, into: store, events: ring.read())
            if !MemoryProbe.debuggerAttached() {
                do { try candidate.enableAndReturnError() } catch { Diagnostics.mirror("crash reporter not enabled") }
                reporter = candidate
            }
        }
        #endif
        Diagnostics.start(DiagnosticsRuntime(root: root, appVersion: version, crash: crash))
        startPressureSource()
        Diagnostics.setForeground(true)
    }

    #if canImport(CrashReporter)
    /// Frames named at crash time in debug builds, which keep their symbols;
    /// none in release, whose binaries are stripped and whose crash handler
    /// should do no more than it must.
    private static var symbolication: PLCrashReporterSymbolicationStrategy {
        #if DEBUG
        return .all
        #else
        return []
        #endif
    }

    /// Mach for release (it sees what BSD signals miss); BSD in debug builds, where Xcode's own handlers are about.
    private static var signalHandler: PLCrashReporterSignalHandlerType {
        #if DEBUG
        return .BSD
        #else
        return .mach
        #endif
    }
    #endif

    private static func startPressureSource() {
        #if os(macOS)
        // One source per level, so the handlers capture nothing.
        for (mask, level) in [(DispatchSource.MemoryPressureEvent.warning, DiagnosticEvent.PressureLevel.warning),
                              (.critical, .critical)] {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: mask, queue: .global(qos: .utility))
            source.setEventHandler { Diagnostics.current?.sample(pressure: level) }
            source.resume()
            pressure.append(source)
        }
        #endif
    }
}
