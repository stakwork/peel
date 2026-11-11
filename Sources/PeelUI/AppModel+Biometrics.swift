import Foundation
import PeelCore

/// Face ID as a check on entering Peel (`BiometricUnlock`): within the PIN
/// timeout, a face opens Peel with the PIN this iPhone keeps
/// (`RememberedPIN`), at launch and after a minute away; past it, the PIN is
/// typed. Never for the twelve words or a PIN change. Whether it is on
/// follows the account on the iPhone (`biometric_enabled`), but only as a
/// wish: another device's "on" is offered here (`biometricsOffered`), never
/// turned on without a face; its "off" turns it off here.
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

    /// Turns Face ID on once a face matches; false when none did.
    public func turnOnBiometrics() async -> Bool {
        guard let biometrics = profile?.biometrics, let name = biometryName else { return false }
        guard await biometrics.turnOn(reason: "Turn on \(name) for Peel") else { return false }
        biometricsOffered = false
        // The person's choice: it follows the account (iOS only;
        // `Engine.setBiometricEnabled` does nothing elsewhere). A sync never
        // comes through here: it never turns Face ID on (decision 10).
        try? await engine?.setBiometricEnabled(true)
        return true
    }

    public func turnOffBiometrics() async throws {
        guard let biometrics = profile?.biometrics else { return }
        try await Task.detached { try biometrics.turnOff() }.value
        try? await engine?.setBiometricEnabled(false)
    }

    /// Face ID's check on the lock screen (`lockOffersBiometrics`): a face
    /// opens Peel, with the kept PIN if the account is not open yet. False when
    /// no face matched, or the kept PIN is gone or wrong: the PIN is typed then.
    public func unlockWithBiometrics() async throws -> Bool {
        guard lockOffersBiometrics, let profile, let biometrics = profile.biometrics else { return false }
        guard await biometrics.check(reason: "Unlock Peel") else { return false }
        if engine == nil {
            guard let pin = profile.rememberedPIN?.pin() else {
                lockOffersBiometrics = false
                return false
            }
            do {
                try await open(profile, pin: pin)
            } catch let failure as SecretStoreFailure where failure == .wrongPIN {
                profile.rememberedPIN?.forget()
                lockOffersBiometrics = false
                return false
            }
        }
        enterApp()
        return true
    }
}
