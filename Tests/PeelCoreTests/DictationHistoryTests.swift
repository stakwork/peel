import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Dictation History's table (`dictation`, v28): kept newest first, older
/// than the keep time dropped as each new one is kept, cleared on request.
struct DictationHistoryTests {
    let profile = TempProfile()

    private func record(_ text: String?, at date: Date, outcome: DictationRecord.Outcome = .typed) -> DictationRecord {
        DictationRecord(id: UUID(), startedAt: date, duration: 2, text: text, appID: "com.apple.Notes", appName: "Notes",
                        outcome: outcome, note: nil)
    }

    @Test func keptNewestFirstAndOldOnesDropped() async throws {
        let storage = try profile.storage()
        let day: TimeInterval = 24 * 60 * 60
        let now = Date()
        try await storage.addDictation(record("long ago", at: now - 40 * day), keep: 365 * day)
        try await storage.addDictation(record("yesterday", at: now - day), keep: 365 * day)
        // Keeping one with a 30-day keep time drops the 40-day-old one.
        try await storage.addDictation(record("just now", at: now), keep: 30 * day)
        let kept = try #require(try await first(storage.dictations(limit: 10)))
        #expect(kept.map(\.text) == ["just now", "yesterday"])
        #expect(kept.first?.appName == "Notes")
        #expect(abs(kept[0].date.timeIntervalSince(now)) < 0.01)
    }

    @Test func oldOnesDropWithoutANewOne() async throws {
        // History off, or nothing dictated for a while: looking at it still drops the old.
        let storage = try profile.storage()
        let day: TimeInterval = 24 * 60 * 60
        try await storage.addDictation(record("old", at: Date() - 31 * day), keep: 365 * day)
        try await storage.addDictation(record("recent", at: Date() - day), keep: 365 * day)
        try await storage.dropDictations(olderThan: 30 * day)
        #expect(try await first(storage.dictations(limit: 10))?.map(\.text) == ["recent"])
    }

    @Test func clearHistoryEmptiesIt() async throws {
        let storage = try profile.storage()
        let now = Date()
        try await storage.addDictation(record(nil, at: now, outcome: .blocked), keep: 3600)
        try await storage.addDictation(record("keep me", at: now - 60), keep: 3600)
        #expect(try await first(storage.dictations(limit: 10))?.map(\.text) == [nil, "keep me"])
        try await storage.clearDictations()
        #expect(try await first(storage.dictations(limit: 10))?.isEmpty == true)
    }
}
