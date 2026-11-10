import Foundation
import PeelUI
#if canImport(MetricKit)
import MetricKit

/// MetricKit's record of how the app ended and what hung or crashed, kept in
/// the diagnostics ring as kinds and numbers only (docs/diagnostics.md): no
/// call stack, termination reason or any other string is read. The system
/// delivers payloads about earlier runs, daily or on launch; the past ones
/// still held are read at start (a payload seen again repeats its lines).
final class MetricKitRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitRecorder()

    func start() {
        MXMetricManager.shared.add(self)
        didReceive(MXMetricManager.shared.pastPayloads)
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let fg = exits.foregroundExitData
            let bg = exits.backgroundExitData
            Diagnostics.recordAppExits([
                .fgNormal: fg.cumulativeNormalAppExitCount,
                .fgAbnormal: fg.cumulativeAbnormalExitCount,
                .fgMemoryResourceLimit: fg.cumulativeMemoryResourceLimitExitCount,
                .fgWatchdog: fg.cumulativeAppWatchdogExitCount,
                .fgBadAccess: fg.cumulativeBadAccessExitCount,
                .fgIllegalInstruction: fg.cumulativeIllegalInstructionExitCount,
                .bgNormal: bg.cumulativeNormalAppExitCount,
                .bgAbnormal: bg.cumulativeAbnormalExitCount,
                .bgMemoryResourceLimit: bg.cumulativeMemoryResourceLimitExitCount,
                .bgMemoryPressure: bg.cumulativeMemoryPressureExitCount,
                .bgWatchdog: bg.cumulativeAppWatchdogExitCount,
                .bgCPUResourceLimit: bg.cumulativeCPUResourceLimitExitCount,
                .bgBadAccess: bg.cumulativeBadAccessExitCount,
                .bgIllegalInstruction: bg.cumulativeIllegalInstructionExitCount,
                .bgSuspendedWithLockedFile: bg.cumulativeSuspendedWithLockedFileExitCount,
                .bgBackgroundTaskAssertionTimeout: bg.cumulativeBackgroundTaskAssertionTimeoutExitCount,
            ])
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                Diagnostics.recordMetricDiagnostic(.crash, signal: crash.signal?.intValue,
                                                   exceptionType: crash.exceptionType?.intValue,
                                                   exceptionCode: crash.exceptionCode?.intValue)
            }
            for hang in payload.hangDiagnostics ?? [] {
                Diagnostics.recordMetricDiagnostic(.hang, hangSeconds: hang.hangDuration.converted(to: .seconds).value)
            }
            for _ in payload.cpuExceptionDiagnostics ?? [] { Diagnostics.recordMetricDiagnostic(.cpuException) }
            for _ in payload.diskWriteExceptionDiagnostics ?? [] { Diagnostics.recordMetricDiagnostic(.diskWriteException) }
        }
    }
}
#else
/// No MetricKit on this platform: nothing to start.
final class MetricKitRecorder: Sendable {
    static let shared = MetricKitRecorder()
    func start() {}
}
#endif
