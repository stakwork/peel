import Foundation
import Testing
@testable import PeelDiagnostics

struct TraceEventTests {
    @Test func newFieldsRoundTripThroughTheRing() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "peel-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var network = DiagnosticEvent(kind: .network, timestamp: Date(timeIntervalSince1970: 5))
        network.networkStatus = .satisfied
        network.networkInterface = .cellular
        network.isExpensive = true
        network.isConstrained = false
        var exits = DiagnosticEvent(kind: .appExits, timestamp: Date(timeIntervalSince1970: 6))
        exits.exitCounts = ["bgMemoryPressure": 3, "fgNormal": 1]
        var lock = DiagnosticEvent(kind: .lock, timestamp: Date(timeIntervalSince1970: 7))
        lock.lockReason = .idleTimeout
        lock.idleSeconds = 90_000
        lock.timeoutHours = 24
        let ring = DiagnosticsRing(file: file)
        for event in [network, exits, lock] { ring.append(event) }
        #expect(DiagnosticsRing(file: file).read() == [network, exits, lock])
    }

    @Test func oldRingLinesStillDecode() throws {
        let old = Data(#"{"kind":"launch","timestamp":100,"count":1,"lastAction":"launch"}"#.utf8 + [0x0A])
        let events = DiagnosticsRing.decode(old)
        #expect(events.count == 1)
        #expect(events[0].kind == .launch)
        #expect(events[0].launchedInFront == nil)
        #expect(events[0].exitCounts == nil)
    }

    @Test func linesNameEveryNewFieldWithoutFreeText() {
        var event = DiagnosticEvent(kind: .launch, timestamp: Date(timeIntervalSince1970: 0))
        event.launchedInFront = false
        event.uptimeSeconds = 42
        #expect(event.line.contains("background-launch"))
        #expect(event.line.contains("uptime=42s"))
        var phase = DiagnosticEvent(kind: .scenePhase)
        phase.scenePhase = .background
        phase.sinceSeconds = 12
        #expect(phase.line.contains("phase=background since=12s"))
        var push = DiagnosticEvent(kind: .pushFetch)
        push.pushStage = .expired
        push.elapsedSeconds = 29.9
        #expect(push.line.contains("push=expired"))
        #expect(push.line.contains("elapsed=29.9s"))
        var exits = DiagnosticEvent(kind: .appExits)
        exits.exitCounts = [AppExit.bgWatchdog.rawValue: 2]
        #expect(exits.line.contains("bgWatchdog=2"))
        var crash = DiagnosticEvent(kind: .metricDiagnostic)
        crash.metricKind = .crash
        crash.signal = 9
        #expect(crash.line.contains("metric=crash signal=9"))
    }

    @Test func reportRendersNewEventsAndThePreviousRun() {
        var lock = DiagnosticEvent(kind: .lock)
        lock.lockReason = .coldLaunch
        let report = DiagnosticsReport(previousRun: .killedBackground, hasReport: false, appVersion: nil,
                                       footprintBytes: nil, events: [lock])
        let text = report.rendered()
        #expect(text.contains("Previous run: killedBackground"))
        #expect(text.contains("lock=coldLaunch"))
    }

    @Test func everyKindIsUnique() {
        #expect(Set(DiagnosticEvent.Kind.allCases.map(\.rawValue)).count == DiagnosticEvent.Kind.allCases.count)
    }
}
