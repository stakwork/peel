import Foundation
import Testing
@testable import PeelDiagnostics

struct ClearEventsTests {
    @Test func clearingLeavesPreviousRunAndEmptiesTheList() {
        let file = FileManager.default.temporaryDirectory.appending(path: "peel-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let ring = DiagnosticsRing(file: file)
        ring.append(.init(kind: .error, errorKind: .file))
        ring.clear()
        #expect(ring.read().isEmpty)
        #expect(DiagnosticsRing(file: file).read().isEmpty)
        let report = DiagnosticsReport(previousRun: .killedBackground, hasReport: false, appVersion: nil,
                                       footprintBytes: nil, events: ring.read())
        #expect(report.rendered().contains("Previous run: killedBackground"))
    }

    @Test func renderedLimitKeepsTheNewestAndTimestampsAreISO() {
        let events = (0..<100).map { DiagnosticEvent(kind: .scenePhase, timestamp: Date(timeIntervalSince1970: Double($0) * 1000), count: $0 + 1) }
        let report = DiagnosticsReport(previousRun: .clean, hasReport: false, appVersion: nil, footprintBytes: nil, events: events)
        let lines = { (text: String) in text.split(separator: "\n").filter { $0.contains("scenePhase") }.count }
        #expect(lines(report.rendered()) == 60)
        #expect(lines(report.rendered(limit: 500)) == 100)
        #expect(lines(report.rendered(limit: 5)) == 5)
        #expect(report.rendered(limit: 1).contains("1970-01-"))
    }

    @Test func clearingBeforeStartIsSafe() {
        Diagnostics.clearEvents()
    }
}
