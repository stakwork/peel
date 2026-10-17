import Foundation
import Security
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

    /// A failed read turns Face ID off only when the system reports other
    /// faces, or none; a lockout, a cancel or a face not matched keeps it.
    @Test(arguments: [
        (errSecAuthFailed, Data([1]), BiometricEnrolment.unknown, BiometricRelease.declined),     // locked out
        (errSecAuthFailed, Data([1]), BiometricEnrolment.faces(Data([1])), BiometricRelease.declined),
        (errSecAuthFailed, Data([1]), BiometricEnrolment.faces(Data([2])), BiometricRelease.unreadable),
        (errSecAuthFailed, Data([1]), BiometricEnrolment.none, BiometricRelease.unreadable),
        (errSecAuthFailed, Data(), BiometricEnrolment.faces(Data([2])), BiometricRelease.declined), // none kept
        (errSecUserCanceled, Data([1]), BiometricEnrolment.faces(Data([2])), BiometricRelease.declined),
        (errSecItemNotFound, Data([1]), BiometricEnrolment.unknown, BiometricRelease.unreadable),
    ] as [(OSStatus, Data, BiometricEnrolment, BiometricRelease)])
    func aFailedReadTurnsItOffOnlyForOtherFaces(status: OSStatus, kept: Data, now: BiometricEnrolment, outcome: BiometricRelease) {
        #expect(BiometricEnrolment.outcome(of: status, kept: kept, now: now) == outcome)
    }

    /// A key that cannot be removed until `fails` is cleared.
    private final class StuckKey: SecretItem, @unchecked Sendable {
        var fails = true
        func read() throws -> Data? { nil }
        func write(_ data: Data) throws {}
        func delete() throws { if fails { throw PeelError("Keychain delete failed") } }
    }

    private final class StuckKeeper: BiometricKeeper, @unchecked Sendable {
        var isKept: Bool { true }
        func keep(_ pin: String) throws {}
        func release(reason: String) async -> BiometricRelease { .declined }
        func discard() throws { throw PeelError("Keychain delete failed") }
    }

    /// Forget removes every key it can, and the words only once the keys
    /// are gone; Face ID's copy of the PIN never stops it.
    @Test func forgetTakesTheWordsLastAndFaceIDNeverStopsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let strut = StuckKey()
        let profile = Profile(developmentAt: folder, strutKey: strut,
                              biometrics: BiometricUnlock(secrets: words, keeper: StuckKeeper()))
        try profile.secrets.save(mnemonic: "words", pin: "")
        try profile.agentCredential.write(Data("key".utf8))
        try profile.brain.write(Data("home server".utf8))

        #expect(throws: PeelError.self) { try profile.delete() }
        #expect(profile.hasAccount)
        #expect(try profile.agentCredential.read() == nil)
        #expect(try profile.brain.read() == nil)

        strut.fails = false
        try profile.delete()
        #expect(!profile.hasAccount)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
