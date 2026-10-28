import Foundation
import PeelCore

/// Face ID in place of typing the PIN (`BiometricUnlock`): the iPhone's lock
/// screen, the twelve words and You's switch. Face ID releases the PIN
/// itself, so everything after it is the typed PIN's path. Whether it is on
/// follows the account on the iPhone (`biometric_enabled`), but only as a
/// wish: another device's "on" is offered here (`biometricsOffered`), never
/// enrolled without the PIN; its "off" turns it off here.
extension AppModel {
    /// "Face ID" when this device can unlock with a face (or "Touch ID"),
    /// and the account has a PIN to stand in for; nil otherwise.
    public var biometryName: String? {
        guard profile?.biometrics != nil else { return nil }
        return BiometricUnlock.available
    }

    /// Whether Face ID is on for this account here. A Keychain lookup that
    /// asks for no face; read it when a screen appears, not in a body.
    public func biometricsOn() async -> Bool {
        guard let biometrics = profile?.biometrics else { return false }
        return await Task.detached { biometrics.isOn }.value
    }

    /// Turns Face ID on once `pin` opens the words; a wrong PIN throws
    /// `SecretStoreFailure.wrongPIN` and turns nothing on.
    public func turnOnBiometrics(pin: String) async throws {
        guard let biometrics = profile?.biometrics else { throw PeelError("Face ID needs a PIN.") }
        try await Task.detached { try biometrics.turnOn(pin: pin) }.value
        biometricsOffered = false
        // The person's choice, after the PIN step: it follows the account (iOS
        // only; `Engine.setBiometricEnabled` does nothing elsewhere). A sync
        // never comes through here: it never turns Face ID on (decision 10).
        try? await engine?.setBiometricEnabled(true)
    }

    public func turnOffBiometrics() async throws {
        guard let biometrics = profile?.biometrics else { return }
        try await Task.detached { try biometrics.turnOff() }.value
        try? await engine?.setBiometricEnabled(false)
    }

    /// Unlocks with a face, as the PIN would. Returns false when no PIN was
    /// released (cancelled, no match, Face ID off or invalidated), so the
    /// lock screen asks for the PIN. A released PIN the words refuse (it
    /// changed since) turns Face ID off.
    public func unlockWithBiometrics() async throws -> Bool {
        try await withReleasedPIN(reason: "Unlock Peel") { try await unlock(pin: $0) } != nil
    }

    /// The twelve words after a face; nil when no PIN was released, so the
    /// screen asks for the PIN.
    public func revealWordsWithBiometrics() async throws -> [String]? {
        try await withReleasedPIN(reason: "Show your twelve words") { try await revealWords(pin: $0) }
    }

    /// `body` with the PIN a face releases, as the typed PIN would be used;
    /// nil when none was released or the words refused it (Face ID is then off).
    private func withReleasedPIN<T>(reason: String, _ body: (String) async throws -> T) async throws -> T? {
        guard let pin = await profile?.biometrics?.releasePIN(reason: reason) else { return nil }
        do {
            return try await body(pin)
        } catch {
            if profile?.biometrics?.refused(error) == true { return nil }
            throw error
        }
    }
}
