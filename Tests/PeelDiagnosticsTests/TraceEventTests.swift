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

    @Test func linesNameTheConnectionRecords() {
        var ping = DiagnosticEvent(kind: .foregroundPing)
        ping.pingAnswered = false
        ping.milliseconds = 5000
        #expect(ping.line.contains("foregroundPing ping=failed took=5000ms"))
        var caught = DiagnosticEvent(kind: .caughtUp)
        caught.milliseconds = 1200
        #expect(caught.line.contains("took=1200ms"))
        #expect(DiagnosticEvent(kind: .stallReconnect).line.contains("stallReconnect"))
    }

    @Test func linesNameTheForegroundDecisionsAndDrops() {
        var decision = DiagnosticEvent(kind: .foregroundDecision)
        decision.foregroundAction = .rebuild
        decision.foregroundCause = .away
        decision.awaySeconds = 95
        #expect(decision.line.contains("foregroundDecision decision=rebuild cause=away away=95s"))
        var forced = DiagnosticEvent(kind: .forcedReconnect)
        forced.reconnectReason = .pingTimeout
        #expect(forced.line.contains("forcedReconnect reason=pingTimeout"))
        var ping = DiagnosticEvent(kind: .pingResult)
        ping.pingAnswered = false
        ping.milliseconds = 5000
        ping.pingTimedOut = true
        #expect(ping.line.contains("pingResult ping=failed timedOut took=5000ms"))
        var background = DiagnosticEvent(kind: .background)
        background.inFlightCatchUp = true
        #expect(background.line.contains("background inFlight=true"))
        var path = DiagnosticEvent(kind: .pathChangeFlagged)
        path.awaySeconds = 12
        #expect(path.line.contains("pathChangeFlagged away=12s"))
    }

    @Test func linesNameTheDeliveryRecords() {
        var cursor = DiagnosticEvent(kind: .catchUpCursor)
        cursor.cursorFrom = 7
        cursor.cursorNext = 7
        cursor.catchUpReason = .selfCheck
        #expect(cursor.line.contains("catchUpCursor reason=selfCheck from=7 next=7"))
        var page = DiagnosticEvent(kind: .historyPage)
        page.pageCount = 3
        page.pageMaxIndex = 9
        page.pageNew = 1
        page.pageDup = 2
        #expect(page.line.contains("historyPage count=3 maxIndex=9 new=1 dup=2"))
        var live = DiagnosticEvent(kind: .liveMessage)
        live.liveIndex = 12
        live.liveFromMe = false
        live.liveType = 0
        live.liveNew = true
        #expect(live.line.contains("liveMessage index=12 fromMe=false type=0 new=true"))
        var lifecycle = DiagnosticEvent(kind: .transportLifecycle)
        lifecycle.lifecycleStage = .abandoned
        lifecycle.liveTransports = 1
        #expect(lifecycle.line.contains("transportLifecycle stage=abandoned live=1"))
        var subscribed = DiagnosticEvent(kind: .subscribed)
        subscribed.subscribedTopics = 4
        subscribed.subscribedOk = true
        #expect(subscribed.line.contains("subscribed topics=4 subscribed=ok"))
        var missed = DiagnosticEvent(kind: .selfCheck)
        missed.selfCheckTrigger = .periodic
        missed.selfCheckOutcome = .missed
        missed.cursorFrom = 7
        missed.selfCheckMissed = 2
        missed.highestIndex = 9
        #expect(missed.line.contains("selfCheck from=7 trigger=periodic outcome=missed missed=2 highest=9"))
        #expect(DiagnosticEvent(kind: .selfCheck).line.contains("selfCheck"))
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
