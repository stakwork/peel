import Foundation
import Testing
@testable import PeelCore

/// Face ID is a check on entering Peel and holds nothing: on only after a
/// face matched, off at once, and an earlier build's PIN item turns it on and
/// is removed unread.
struct BiometricUnlockTests {
    /// A Keychain item in memory.
    private final class Item: SecretItem, @unchecked Sendable {
        var data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    /// The system's face check, scripted.
    private final class Checker: BiometricChecker, @unchecked Sendable {
        var matches = true
        var asked = 0
        func check(reason: String) async -> Bool {
            asked += 1
            return matches
        }
    }

    /// Earlier builds' PIN item.
    private final class Legacy: BiometricKeeper, @unchecked Sendable {
        var isKept = false
        func discard() throws { isKept = false }
    }

    private let flag = Item()
    private let checker = Checker()
    private let legacy = Legacy()
    private var unlock: BiometricUnlock { BiometricUnlock(flag: flag, checker: checker, legacy: legacy) }

    @Test func turnsOnOnlyAfterAFaceMatches() async {
        checker.matches = false
        #expect(await !unlock.turnOn(reason: "Turn on"))
        #expect(!unlock.isOn)
        checker.matches = true
        #expect(await unlock.turnOn(reason: "Turn on"))
        #expect(unlock.isOn)
    }

    @Test func turningOffNeedsNoFace() async throws {
        _ = await unlock.turnOn(reason: "Turn on")
        let asked = checker.asked
        try unlock.turnOff()
        #expect(!unlock.isOn)
        #expect(checker.asked == asked)
    }

    @Test func theCheckIsTheFace() async {
        checker.matches = false
        #expect(await !unlock.check(reason: "Unlock"))
        checker.matches = true
        #expect(await unlock.check(reason: "Unlock"))
    }

    @Test func anEarlierBuildsPINItemTurnsItOnAndGoes() throws {
        legacy.isKept = true
        #expect(unlock.isOn)
        #expect(!legacy.isKept)
        #expect(unlock.isOn)
        try unlock.turnOff()
        #expect(!unlock.isOn)
    }
}
