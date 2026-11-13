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

    // MARK: The failure's text, redacted

    @Test func linesNameTheCoreFailuresAndRecoveries() {
        var failure = DiagnosticEvent(kind: .coreFailure, timestamp: Date(timeIntervalSince1970: 0))
        failure.failureSite = .receive
        failure.messageKind = "batch"
        failure.errorDetail = "core refused the page"
        #expect(failure.line.contains("coreFailure site=receive msg=batch detail=\"core refused the page\""))
        var recovery = DiagnosticEvent(kind: .coreRecovery, timestamp: Date(timeIntervalSince1970: 0))
        recovery.recoveryReason = .pageFailed
        recovery.recoveryStage = .reloadState
        #expect(recovery.line.contains("coreRecovery recovery=pageFailed stage=reloadState"))
        let error = DiagnosticEvent(kind: .error, errorKind: .core, errorDetail: "x")
        #expect(error.line.contains("error=core"))
        #expect(error.line.contains("detail=\"x\""))
        #expect(!DiagnosticEvent(kind: .error, errorKind: .core).line.contains("detail="))
    }

    @Test func theDetailRoundTripsThroughTheRingAndOldLinesDecodeWithout() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "peel-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var failure = DiagnosticEvent(kind: .coreFailure, timestamp: Date(timeIntervalSince1970: 5))
        failure.failureSite = .cameOnline
        failure.errorDetail = "boom"
        let ring = DiagnosticsRing(file: file)
        ring.append(failure)
        #expect(DiagnosticsRing(file: file).read() == [failure])
        let old = Data(#"{"kind":"error","timestamp":100,"count":1,"errorKind":"core"}"#.utf8 + [0x0A])
        let events = DiagnosticsRing.decode(old)
        #expect(events.count == 1)
        #expect(events[0].errorDetail == nil)
    }

    @Test func redactingRemovesKeysInvoicesUrlsAndEmails() {
        let key = String(repeating: "ab", count: 33)
        let hash = String(repeating: "0f", count: 32)
        let invoice = "lnbc" + String(repeating: "q", count: 40)
        let url = "https://" + "example.com/path/to?token=1"
        let email = "someone" + "@" + "example.org"
        let text = "bad key \(key) hash \(hash) pay \(invoice) at \(url) mail \(email)"
        let redacted = Diagnostics.redact(text)
        #expect(!redacted.contains(key))
        #expect(!redacted.contains(hash))
        #expect(!redacted.contains(invoice))
        #expect(!redacted.contains("path/to"))
        #expect(!redacted.contains("token=1"))
        #expect(!redacted.contains(email))
        #expect(redacted.contains("https://example.com"))
        #expect(redacted.contains("<redacted>"))
        #expect(redacted.hasPrefix("bad key"))
    }

    @Test func redactingRemovesLongTokensAndKeepsShortWords() {
        let token = String(repeating: "Zx9", count: 12)
        let redacted = Diagnostics.redact("batch: could not read \(token) (server index 7)")
        #expect(!redacted.contains(token))
        #expect(redacted.contains("could not read"))
        #expect(redacted.contains("server index 7"))
    }

    @Test func redactingCollapsesWhitespaceAndCapsTheLength() {
        #expect(Diagnostics.redact("a \n\n  b\t c") == "a b c")
        let long = String(repeating: "word ", count: 200)
        #expect(Diagnostics.redact(long).count == Diagnostics.detailLimit)
        #expect(Diagnostics.detailLimit == 200)
    }

    @Test func everyKindIsUnique() {
        #expect(Set(DiagnosticEvent.Kind.allCases.map(\.rawValue)).count == DiagnosticEvent.Kind.allCases.count)
    }

    @Test func callAudioRoundTripsAndHasNoFreeText() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "peel-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var event = DiagnosticEvent(kind: .callAudio, timestamp: Date(timeIntervalSince1970: 9))
        event.callAudioStage = .micState
        event.micTrigger = .foreground
        event.micEnabled = true
        event.micPublicationMuted = false
        event.wantsMic = true
        event.audioCategory = .playAndRecord
        let ring = DiagnosticsRing(file: file)
        ring.append(event)
        #expect(DiagnosticsRing(file: file).read() == [event])
        #expect(event.line.contains("callAudio"))
        #expect(event.line.contains("stage=micState"))
        #expect(event.line.contains("trigger=foreground"))
        #expect(event.line.contains("micEnabled=true"))
        #expect(event.line.contains("micMuted=false"))
        #expect(event.line.contains("wantsMic=true"))
    }
}
