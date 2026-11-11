import Foundation
import LocalAuthentication
import Security

/// Face ID (or Touch ID) as a check on entering Peel, opt-in on this device.
///
/// It stands in for nothing: the PIN Peel opens with is the one it keeps
/// while the PIN timeout has not run out (`RememberedPIN`), and past it the
/// PIN is typed. On, Face ID is asked for before Peel opens with that kept
/// PIN, at launch and after a minute away. The twelve words and a PIN change
/// always take the typed PIN.
///
/// Whether it is on is a flag in the Keychain, on this device only. Earlier
/// builds kept the PIN itself behind a face (`legacy`): such an item turns
/// the flag on and is removed, unread.
public struct BiometricUnlock: Sendable {
    let flag: any SecretItem
    let checker: any BiometricChecker
    let legacy: (any BiometricKeeper)?

    init(flag: any SecretItem, checker: any BiometricChecker, legacy: (any BiometricKeeper)? = nil) {
        self.flag = flag
        self.checker = checker
        self.legacy = legacy
    }

    /// Whether Face ID is turned on here (read without asking for a face).
    public var isOn: Bool {
        if let legacy, legacy.isKept {
            try? flag.write(Self.on)
            try? legacy.discard()
            return true
        }
        return (try? flag.read()) != nil
    }

    /// Turns it on once a face matches now; false, and nothing turned on, when
    /// none did (cancelled, no match, no biometrics).
    public func turnOn(reason: String) async -> Bool {
        guard await checker.check(reason: reason) else { return false }
        do { try flag.write(Self.on) } catch { return false }
        return true
    }

    public func turnOff() throws {
        try flag.delete()
        try legacy?.discard()
    }

    /// Asks for a face: whether one matched.
    public func check(reason: String) async -> Bool {
        await checker.check(reason: reason)
    }

    private static let on = Data("1".utf8)

    /// What this device unlocks with ("Face ID", "Touch ID", "Optic ID"),
    /// or nil when it has no biometrics enrolled.
    public static var available: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }
}

/// Asks for a face: the system on a device, a fake in tests.
protocol BiometricChecker: Sendable {
    func check(reason: String) async -> Bool
}

/// `LAContext`'s biometric policy; its fallback button reads "Enter PIN" and
/// ends the check unmatched, leaving the keypad.
struct SystemBiometricChecker: BiometricChecker {
    func check(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter PIN"
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}

/// The PIN item earlier builds kept behind a face: only found and removed now.
protocol BiometricKeeper: Sendable {
    /// Whether one is kept, found without asking for a face.
    var isKept: Bool { get }
    /// Removes it; nothing kept is not an error.
    func discard() throws
}

/// Earlier builds' item: the PIN in the data-protection Keychain behind
/// `.biometryCurrentSet`. Never read again, only found and removed.
struct KeychainBiometricKeeper: BiometricKeeper {
    let account: String
    private static let service = "dev.peel.biometric"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    var isKept: Bool {
        // Found but not read: no face is asked for.
        let context = LAContext()
        context.interactionNotAllowed = true
        let status = SecItemCopyMatching(
            query.merging([kSecUseAuthenticationContext as String: context]) { $1 } as CFDictionary, nil
        )
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func discard() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeelError("could not turn off Face ID (\(status))")
        }
    }
}
