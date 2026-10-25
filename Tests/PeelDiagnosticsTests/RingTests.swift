import Foundation
import Testing
@testable import PeelDiagnostics

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "peel-diag-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct RingTests {
    @Test func roundTripsEvents() {
        let dir = tempDirectory()
        let file = dir.appending(path: "ring")
        let ring = DiagnosticsRing(file: file)
        let a = DiagnosticEvent(kind: .error, timestamp: Date(timeIntervalSince1970: 100), errorKind: .network, lastAction: .tribeJoin)
        let b = DiagnosticEvent(kind: .memorySample, timestamp: Date(timeIntervalSince1970: 200), footprintBytes: 123_456_789, availableBytes: 42)
        ring.append(a)
        ring.append(b)
        #expect(ring.read() == [a, b])
        // A new process reads the same from the file.
        #expect(DiagnosticsRing(file: file).read() == [a, b])
    }

    @Test func coalescesIdenticalConsecutiveEvents() {
        let ring = DiagnosticsRing(file: tempDirectory().appending(path: "ring"))
        ring.append(.init(kind: .error, timestamp: Date(timeIntervalSince1970: 1), errorKind: .server, lastAction: .send))
        ring.append(.init(kind: .error, timestamp: Date(timeIntervalSince1970: 2), errorKind: .server, lastAction: .send))
        ring.append(.init(kind: .error, timestamp: Date(timeIntervalSince1970: 3), errorKind: .database, lastAction: .send))
        ring.append(.init(kind: .error, timestamp: Date(timeIntervalSince1970: 4), errorKind: .server, lastAction: .send))
        let events = ring.read()
        #expect(events.map(\.count) == [2, 1, 1])
        #expect(events[0].timestamp == Date(timeIntervalSince1970: 2))
        #expect(DiagnosticsRing(file: tempDirectory().appending(path: "x")).read().isEmpty)
    }

    @Test func rotationKeepsTheNewest() {
        let file = tempDirectory().appending(path: "ring")
        let ring = DiagnosticsRing(file: file, maxBytes: 4096, maxEvents: 2000)
        for index in 0..<200 {
            ring.append(.init(kind: .memorySample, timestamp: Date(timeIntervalSince1970: Double(index)), footprintBytes: UInt64(index + 1) * 1000))
        }
        let events = ring.read()
        #expect(events.last?.footprintBytes == 200_000)
        #expect(events.count < 200)
        #expect(events.count > 10)
        let size = (try? Data(contentsOf: file).count) ?? Int.max
        #expect(size <= 4096)
        // Newest kept, in order.
        let sizes = events.compactMap(\.footprintBytes)
        #expect(sizes == sizes.sorted())
        #expect(DiagnosticsRing(file: file).read() == events)
    }

    @Test func eventCountCapRotates() {
        let ring = DiagnosticsRing(file: tempDirectory().appending(path: "ring"), maxBytes: 10_000_000, maxEvents: 10)
        for index in 0..<25 { ring.append(.init(kind: .memorySample, footprintBytes: UInt64(index + 1))) }
        let events = ring.read()
        #expect(events.count <= 10)
        #expect(events.last?.footprintBytes == 25)
    }

    @Test func toleratesACorruptOrTruncatedTail() throws {
        let file = tempDirectory().appending(path: "ring")
        let ring = DiagnosticsRing(file: file)
        let a = DiagnosticEvent(kind: .error, timestamp: Date(timeIntervalSince1970: 1), errorKind: .file)
        ring.append(a)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"kind\":\"err".utf8))
        try handle.close()
        let reopened = DiagnosticsRing(file: file)
        #expect(reopened.read() == [a])
        let b = DiagnosticEvent(kind: .error, timestamp: Date(timeIntervalSince1970: 2), errorKind: .core)
        reopened.append(b)
        #expect(DiagnosticsRing(file: file).read() == [a, b])
    }

    @Test func encodedEventHasOnlyExpectedKeys() throws {
        let event = DiagnosticEvent(kind: .error, errorKind: .network, lastAction: .send, footprintBytes: 1, availableBytes: 2,
                                    pressureLevel: .critical, previousRun: .crashed, exitReason: .exit, exitStatus: 3)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        let allowed: Set<String> = ["kind", "timestamp", "count", "errorKind", "lastAction", "footprintBytes", "availableBytes",
                                    "pressureLevel", "previousRun", "exitReason", "exitStatus"]
        #expect(Set(object.keys) == allowed)
        // Strings only where an enum's name is.
        for (key, value) in object where value is String {
            #expect(["kind", "errorKind", "lastAction", "pressureLevel", "previousRun", "exitReason"].contains(key))
        }
    }

    @Test func concurrentAppendsAreAllKept() async {
        let file = tempDirectory().appending(path: "ring")
        let ring = DiagnosticsRing(file: file)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { ring.append(.init(kind: .memorySample, footprintBytes: UInt64(index + 1))) }
            }
        }
        #expect(ring.read().count == 100)
        #expect(Set(ring.read().compactMap(\.footprintBytes)).count == 100)
        #expect(DiagnosticsRing(file: file).read().count == 100)
    }
}

struct MarkerTests {
    private func store() -> (RunMarkerStore, URL) {
        let file = tempDirectory().appending(path: "marker.json")
        return (RunMarkerStore(file: file), file)
    }

    @Test func firstLaunchIsClean() {
        let (store, _) = store()
        #expect(store.begin(appVersion: "1", crashReportID: nil) == .clean)
    }

    @Test func cleanExit() {
        let (first, file) = store()
        first.begin(appVersion: "1", crashReportID: nil)
        first.markClean()
        #expect(RunMarkerStore(file: file).begin(appVersion: "1", crashReportID: nil) == .clean)
    }

    @Test func killedInFront() {
        let (first, file) = store()
        first.begin(appVersion: "1", crashReportID: nil)
        #expect(RunMarkerStore(file: file).begin(appVersion: "1", crashReportID: nil) == .killedForeground)
    }

    @Test func killedInBackgroundIsExpected() {
        let (first, file) = store()
        first.begin(appVersion: "1", crashReportID: nil)
        first.setState(.background)
        let previous = RunMarkerStore(file: file).begin(appVersion: "1", crashReportID: nil)
        #expect(previous == .killedBackground)
        #expect(!previous.isProblem)
    }

    @Test func comingBackToTheFrontIsRemembered() {
        let (first, file) = store()
        first.begin(appVersion: "1", crashReportID: nil)
        first.setState(.background)
        first.setState(.foreground)
        #expect(RunMarkerStore(file: file).begin(appVersion: "1", crashReportID: nil) == .killedForeground)
    }

    @Test func aReportMakesItCrashed() {
        let (first, file) = store()
        first.begin(appVersion: "1", crashReportID: nil)
        first.setState(.background)
        let previous = RunMarkerStore(file: file).begin(appVersion: "1", crashReportID: "abc")
        #expect(previous == .crashed(reportID: "abc"))
        #expect(previous.isProblem)
    }

    @Test func anUnreadableMarkerIsUnknown() throws {
        let (store, file) = store()
        try Data("not json".utf8).write(to: file)
        #expect(store.begin(appVersion: "1", crashReportID: nil) == .unknown)
        // And the new run's marker replaced it.
        #expect(store.read()?.phase == .running)
    }
}

struct SmallPartsTests {
    @Test func memorySamplesSkipSmallChanges() {
        #expect(MemoryPolicy.shouldRecord(last: nil, new: 100))
        #expect(!MemoryPolicy.shouldRecord(last: 1000, new: 1030))
        #expect(MemoryPolicy.shouldRecord(last: 1000, new: 1050))
        #expect(MemoryPolicy.shouldRecord(last: 1000, new: 900))
        #expect(MemoryPolicy.shouldRecord(last: 1000, new: 1001, pressure: true))
    }

    @Test func stderrTailIsBoundedAndStartsOnALine() {
        let tail = StderrTail(limit: 20)
        tail.append(Data("first line\nsecond line\n".utf8))
        tail.append(Data("third\n".utf8))
        #expect(tail.text == "second line\nthird\n")
        let short = StderrTail(limit: 100)
        short.append(Data("only this".utf8))
        #expect(short.text == "only this")
    }

    @Test func diagnosticsFunctionsDoNothingBeforeInstall() {
        Diagnostics.note(errorKind: .other)
        Diagnostics.setAction(.send)
        #expect(Diagnostics.previousRun() == .clean)
    }

    @Test func runtimeRecordsAndReadsBack() async throws {
        let root = tempDirectory()
        let runtime = DiagnosticsRuntime(root: root, appVersion: "9", crash: nil)
        runtime.setAction(.tribeJoin)
        runtime.note(.network)
        runtime.recordStrutExit(reason: .uncaughtSignal, status: 9, tail: "boom at /Users/alice/x\nsecret 12,500 sats")
        let kinds = runtime.ring.read().map(\.kind)
        #expect(kinds == [.launch, .previousRun, .error, .strutExit])
        #expect(runtime.ring.read()[2].lastAction == .tribeJoin)
        let tail = try #require(runtime.store.strutTail())
        #expect(!tail.contains("alice"))
        #expect(!tail.contains("12,500"))
        #expect(tail.utf8.count <= 2048)
        #expect(try runtime.latestRedacted(allow: [], knownNames: []) == nil)
    }

    @Test func storeKeepsRawAndRedactedApartAndDeletesBoth() throws {
        let store = DiagnosticsStore(root: tempDirectory())
        store.prepare()
        let record = Fixtures.record
        try store.saveRaw(record)
        #expect(store.rawIDs() == [record.id])
        let redacted = Redactor().redact(record)
        try store.saveRedacted(redacted)
        #expect(store.loadRedacted(record.id) == redacted)
        let stored = try String(contentsOf: store.redacted.appending(path: "\(record.id).json"), encoding: .utf8)
        #expect(!stored.contains("alice"))
        store.deleteAll()
        #expect(store.rawIDs().isEmpty)
        #expect(store.loadRedacted(record.id) == nil)
    }
}
