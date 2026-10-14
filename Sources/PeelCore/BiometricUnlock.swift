import Foundation
import LocalAuthentication
import Security

/// Face ID (or Touch ID) in place of typing the PIN, opt-in on this device.
///
/// Turned on with the PIN, it keeps that PIN in a Keychain item that only a
/// biometric match of the faces enrolled at that moment opens
/// (`.biometryCurrentSet`), on this device only and only while it has a
/// passcode. Face ID then hands back exactly what typing would: the words
/// stay sealed under the PIN (`PINBox`), and the PIN still opens them. A
/// face added or removed, or the passcode turned off, makes the item
/// unreadable; a PIN changed since makes it wrong. Either way it is
/// removed and the PIN is asked for (`releasePIN`, `refused`).
public struct BiometricUnlock: Sendable {
    let secrets: any SecretStore
    let keeper: any BiometricKeeper

    init(secrets: any SecretStore, keeper: any BiometricKeeper) {
        self.secrets = secrets
        self.keeper = keeper
    }

    /// Whether Face ID is turned on here (read without asking for a face).
    public var isOn: Bool { keeper.isKept }

    /// Turns it on with the PIN typed now, once the PIN opens the words; a
    /// wrong PIN throws `SecretStoreFailure.wrongPIN` and keeps nothing.
    /// Slow, as every PIN check is: call it off the main thread.
    public func turnOn(pin: String) throws {
        try PIN.validate(pin)
        _ = try secrets.loadMnemonic(pin: pin)
        try keeper.keep(pin)
    }

    public func turnOff() throws {
        try keeper.discard()
    }

    /// The PIN, after a face; nil when there is none kept, the person
    /// cancelled or did not match, or the item can no longer be read (the
    /// faces changed), which turns it off. Unchecked: the caller uses it as
    /// a typed PIN and hands any refusal to `refused`.
    public func releasePIN(reason: String) async -> String? {
        guard keeper.isKept else { return nil }
        switch await keeper.release(reason: reason) {
        case .pin(let pin) where (try? PIN.validate(pin)) != nil:
            return pin
        case .pin, .unreadable:
            try? keeper.discard()
            return nil
        case .declined:
            return nil
        }
    }

    /// A released PIN was refused: when as the wrong PIN (changed since), it
    /// is removed, so the next unlock asks for the PIN. Returns whether it was.
    @discardableResult
    public func refused(_ error: any Error) -> Bool {
        guard (error as? SecretStoreFailure) == .wrongPIN else { return false }
        try? keeper.discard()
        return true
    }

    /// The PIN changed: Face ID keeps the new one if it was on. If that
    /// fails it is turned off, never left holding the old PIN.
    func pinChanged(to pin: String) {
        guard keeper.isKept else { return }
        do { try keeper.keep(pin) } catch { try? keeper.discard() }
    }

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

/// The enrolled faces as the system reports them now.
enum BiometricEnrolment: Equatable, Sendable {
    /// Their fingerprint (`domainState.biometry.stateHash`), not a secret.
    case faces(Data)
    /// None enrolled any more.
    case none
    /// Not known just now: locked out after failed tries, or busy.
    case unknown

    /// What a read that did not give the PIN means, from its status, the
    /// faces' fingerprint kept with the item, and the faces now. Only a
    /// change of faces the system reports (or none left) turns Face ID off;
    /// a lockout, a cancel or a face not matched falls back to the PIN and
    /// keeps it on.
    static func outcome(of status: OSStatus, kept: Data?, now: BiometricEnrolment) -> BiometricRelease {
        switch status {
        case errSecItemNotFound, errSecDecode:
            return .unreadable
        case errSecAuthFailed:
            switch now {
            case .none:
                return .unreadable
            case .faces(let faces):
                guard let kept, !kept.isEmpty else { return .declined }
                return kept == faces ? .declined : .unreadable
            case .unknown:
                return .declined
            }
        default:
            // errSecUserCanceled, errSecInteractionNotAllowed and the rest.
            return .declined
        }
    }
}

/// What a biometric read gave.
enum BiometricRelease: Sendable, Equatable {
    case pin(String)
    /// Cancelled, no match, or biometrics not available just now.
    case declined
    /// Gone or unreadable for good (the enrolled faces changed).
    case unreadable
}

/// Where Face ID keeps the PIN: the Keychain on a device, a fake in tests.
protocol BiometricKeeper: Sendable {
    /// Whether a PIN is kept, found without asking for a face.
    var isKept: Bool { get }
    /// Keeps `pin`, replacing what was kept.
    func keep(_ pin: String) throws
    func release(reason: String) async -> BiometricRelease
    /// Removes it; nothing kept is not an error.
    func discard() throws
}

/// The PIN in the data-protection Keychain behind `.biometryCurrentSet`,
/// `WhenPasscodeSetThisDeviceOnly`, never synchronised. The enrolled faces'
/// fingerprint at that moment is kept in the item's generic attribute, so a
/// failed read can be told apart (`BiometricEnrolment.outcome`).
struct KeychainBiometricKeeper: BiometricKeeper {
    let account: String
    private static let service = "dev.peel.biometric"

    /// The enrolled faces as the system reports them now.
    private static var enrolment: BiometricEnrolment {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return context.domainState.biometry.stateHash.map(BiometricEnrolment.faces) ?? .unknown
        }
        // Locked out after failed tries says nothing about the faces.
        return error?.code == LAError.Code.biometryNotEnrolled.rawValue ? .none : .unknown
    }

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

    func keep(_ pin: String) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error
        ) else {
            throw PeelError("could not set up Face ID: \(error?.takeRetainedValue().localizedDescription ?? "no access control")")
        }
        try discard()
        let attributes = query.merging([
            kSecValueData as String: Data(pin.utf8),
            kSecAttrLabel as String: "Peel Face ID \(account)",
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
            kSecAttrGeneric as String: { if case .faces(let faces) = Self.enrolment { faces } else { Data() } }(),
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw PeelError("could not turn on Face ID (\(status))") }
    }

    func release(reason: String) async -> BiometricRelease {
        let query = query
        // The read waits for the face, so it runs off the caller's thread.
        return await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            context.localizedFallbackTitle = "Enter PIN"
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query.merging([
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
            ]) { $1 } as CFDictionary, &item)
            guard status == errSecSuccess else {
                return BiometricEnrolment.outcome(of: status, kept: keptEnrolment(query), now: Self.enrolment)
            }
            guard let data = item as? Data, let pin = String(data: data, encoding: .utf8) else { return .unreadable }
            return .pin(pin)
        }.value
    }

    /// The faces' fingerprint kept with the item, read without asking for a face.
    private func keptEnrolment(_ query: [String: Any]) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ]) { $1 } as CFDictionary, &attributes)
        guard status == errSecSuccess, let found = attributes as? [String: Any] else { return nil }
        return found[kSecAttrGeneric as String] as? Data
    }

    func discard() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeelError("could not turn off Face ID (\(status))")
        }
    }
}
