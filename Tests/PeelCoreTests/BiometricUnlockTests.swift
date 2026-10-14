import Foundation
import Testing
@testable import PeelCore

/// Face ID stands in for the PIN and never for less: it keeps only a PIN
/// that opens the words, follows a PIN change, and gives way to the PIN
/// once what it holds is wrong or unreadable.
struct BiometricUnlockTests {
    /// Words behind a PIN, compared plainly (`PINBox` has its own tests).
    private final class Words: SecretStore, @unchecked Sendable {
        var pin = "123456"
        var hasMnemonic: Bool { true }
        var requiresPIN: Bool { true }
        func loadMnemonic(pin: String) throws -> String {
            guard pin == self.pin else { throw SecretStoreFailure.wrongPIN }
            return "words"
        }
        func save(mnemonic: String, pin: String) throws {}
        func changePIN(from oldPIN: String, to newPIN: String) throws {
            _ = try loadMnemonic(pin: oldPIN)
            pin = newPIN
        }
        func deleteMnemonic() throws {}
    }

    /// The Keychain item, with what a face read gives scripted.
    private final class Keeper: BiometricKeeper, @unchecked Sendable {
        var kept: String?
        var read: BiometricRelease?
        var failsToKeep = false
        var isKept: Bool { kept != nil }
        func keep(_ pin: String) throws {
            if failsToKeep { throw PeelError("Keychain write failed") }
            kept = pin
        }
        func release(reason: String) async -> BiometricRelease { read ?? kept.map(BiometricRelease.pin) ?? .unreadable }
        func discard() throws { kept = nil }
    }

    private let words = Words()
    private let keeper = Keeper()
    private var unlock: BiometricUnlock { BiometricUnlock(secrets: words, keeper: keeper) }

    @Test func turnsOnOnlyWithThePINThatOpensTheWords() async throws {
        #expect(throws: SecretStoreFailure.wrongPIN) { try unlock.turnOn(pin: "654321") }
        #expect(throws: PeelError.self) { try unlock.turnOn(pin: "12345") }
        #expect(!unlock.isOn)
        try unlock.turnOn(pin: "123456")
        #expect(unlock.isOn)
        #expect(await unlock.releasePIN(reason: "Unlock") == "123456")
    }

    @Test func aCancelledFaceKeepsItOnAndAnUnreadableItemTurnsItOff() async throws {
        try unlock.turnOn(pin: "123456")
        keeper.read = .declined
        #expect(await unlock.releasePIN(reason: "Unlock") == nil)
        #expect(unlock.isOn)
        keeper.read = .unreadable
        #expect(await unlock.releasePIN(reason: "Unlock") == nil)
        #expect(!unlock.isOn)
    }

    @Test func aReleasedPINTheWordsRefuseTurnsItOff() async throws {
        try unlock.turnOn(pin: "123456")
        words.pin = "111111"
        let released = try #require(await unlock.releasePIN(reason: "Unlock"))
        #expect(throws: SecretStoreFailure.wrongPIN) { try words.loadMnemonic(pin: released) }
        #expect(!unlock.refused(PeelError("offline")))
        #expect(unlock.isOn)
        #expect(unlock.refused(SecretStoreFailure.wrongPIN))
        #expect(!unlock.isOn)
    }

    @Test func aPINChangeIsFollowedAndNeverLeavesTheOldOne() throws {
        unlock.pinChanged(to: "222222")
        #expect(keeper.kept == nil)
        try unlock.turnOn(pin: "123456")
        unlock.pinChanged(to: "222222")
        #expect(keeper.kept == "222222")
        keeper.failsToKeep = true
        unlock.pinChanged(to: "333333")
        #expect(keeper.kept == nil)
    }

    @Test func somethingNotAPINIsNeverHandedBack() async throws {
        try unlock.turnOn(pin: "123456")
        keeper.read = .pin("12345a")
        #expect(await unlock.releasePIN(reason: "Unlock") == nil)
        #expect(!unlock.isOn)
    }
}
