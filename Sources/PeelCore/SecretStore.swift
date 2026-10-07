import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Where an account's twelve words live, locked with the account's PIN.
public protocol SecretStore: Sendable {
    var hasMnemonic: Bool { get }
    /// Whether this store asks for a PIN at all.
    var requiresPIN: Bool { get }
    func loadMnemonic(pin: String) throws -> String
    func save(mnemonic: String, pin: String) throws
    func changePIN(from oldPIN: String, to newPIN: String) throws
    func deleteMnemonic() throws
}

public enum SecretStoreFailure: Error, Equatable, CustomStringConvertible {
    case noAccount
    case accountExists
    case wrongPIN

    public var description: String {
        switch self {
        case .noAccount: "no account stored"
        case .accountExists: "an account is already stored here"
        case .wrongPIN: "wrong PIN"
        }
    }
}

/// The six-digit PIN that unlocks an account on this device. ASCII digits only,
/// so a PIN typed one way can always be typed again.
public enum PIN {
    public static let length = 6

    public static func validate(_ pin: String) throws {
        guard pin.utf8.count == length, pin.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            throw PeelError("the PIN must be \(length) digits")
        }
    }
}

/// The data-protection Keychain, holding the words encrypted with the PIN.
///
/// The item belongs to the app's Keychain access group, so only an app signed
/// by the same team with that group can see it, and it is
/// `WhenUnlockedThisDeviceOnly`: wrapped by a key tied to this Mac, never
/// synced to iCloud, never restored from a backup onto another Mac. The PIN
/// then has to be guessed to use what is read. Six digits are a small space,
/// so the derivation is slow on purpose, but it buys minutes against a GPU,
/// not days: the Keychain is the real wall.
///
/// Needs a bundle signed with a provisioning profile that grants the access
/// group (`scripts/sign-app.sh`); anything else gets `errSecMissingEntitlement`.
/// Words kept by earlier builds in the file-based login Keychain move here on
/// the first unlock.
public struct KeychainSecretStore: SecretStore {
    private static let service = "dev.peel"
    public let account: String

    public init(account: String) {
        self.account = account
    }

    private enum Keychain {
        /// Where the words live.
        case dataProtection
        /// The file-based login keychain earlier builds used; read only to move
        /// the words out of it.
        case login
    }

    private func query(_ keychain: Keychain) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: keychain == .dataProtection,
        ]
    }

    public var hasMnemonic: Bool {
        exists(.dataProtection) || exists(.login)
    }

    public var requiresPIN: Bool { true }

    public func loadMnemonic(pin: String) throws -> String {
        let current = try read(.dataProtection)
        let legacy = try read(.login)
        guard let sealed = current ?? legacy else { throw SecretStoreFailure.noAccount }
        let words = try PINBox.open(sealed, pin: pin)
        if let legacy {
            try moveToDataProtection(legacy, alreadyThere: current)
        }
        return words
    }

    public func save(mnemonic: String, pin: String) throws {
        try PIN.validate(pin)
        guard !exists(.login) else { throw SecretStoreFailure.accountExists }
        try add(PINBox.seal(mnemonic, pin: pin))
    }

    public func changePIN(from oldPIN: String, to newPIN: String) throws {
        try PIN.validate(newPIN)
        let mnemonic = try loadMnemonic(pin: oldPIN)
        let update = [kSecValueData as String: try PINBox.seal(mnemonic, pin: newPIN)]
        let status = SecItemUpdate(query(.dataProtection) as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw PeelError("Keychain update failed: \(Self.message(status))") }
    }

    /// Removes the words from both keychains.
    public func deleteMnemonic() throws {
        for keychain in [Keychain.dataProtection, .login] {
            let status = SecItemDelete(query(keychain) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PeelError("Keychain delete failed: \(Self.message(status))")
            }
        }
    }

    /// Copies the sealed words from the login keychain, reads the copy back,
    /// and only when it matches removes the original. Any failure leaves the
    /// original where it was. A copy already in place (an earlier move whose
    /// delete failed) is checked the same way; one that differs is left alone,
    /// and so is the original.
    private func moveToDataProtection(_ sealed: Data, alreadyThere current: Data?) throws {
        if current == nil {
            do {
                try add(sealed)
            } catch {
                throw PeelError("could not move the account into the data-protection Keychain (\(error)); it is still in the login Keychain")
            }
            guard try read(.dataProtection) == sealed else {
                _ = SecItemDelete(query(.dataProtection) as CFDictionary)
                throw PeelError("the account's copy in the data-protection Keychain did not match; it is still in the login Keychain")
            }
        } else if current != sealed {
            return
        }
        let status = SecItemDelete(query(.login) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeelError("the account moved to the data-protection Keychain, but the old copy in the login Keychain could not be removed: \(Self.message(status))")
        }
    }

    private func add(_ sealed: Data) throws {
        let attributes = query(.dataProtection).merging([
            kSecValueData as String: sealed,
            kSecAttrLabel as String: "Peel account \(account)",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status != errSecDuplicateItem else { throw SecretStoreFailure.accountExists }
        guard status == errSecSuccess else { throw PeelError("Keychain write failed: \(Self.message(status))") }
    }

    private func exists(_ keychain: Keychain) -> Bool {
        SecItemCopyMatching(query(keychain) as CFDictionary, nil) == errSecSuccess
    }

    /// The sealed words, or nil when there is no item.
    private func read(_ keychain: Keychain) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query(keychain).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item
        )
        switch status {
        case errSecSuccess:
            guard let sealed = item as? Data else { throw PeelError("the Keychain item for \(account) is unreadable") }
            return sealed
        case errSecItemNotFound:
            return nil
        default:
            throw PeelError("Keychain read failed: \(Self.message(status))")
        }
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }
}

/// The words sealed under a key derived from the PIN:
/// `version(1) | salt(16) | iterations(4, big-endian) | AES-GCM nonce+ciphertext+tag`.
enum PINBox {
    private static let version: UInt8 = 1
    // About 0.4 s on an M-series Mac. Fixed for this version; a blob claiming
    // another count is refused rather than obeyed.
    private static let iterations: UInt32 = 2_500_000
    private static let headerLength = 1 + 16 + 4

    static func seal(_ mnemonic: String, pin: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = try derive(pin: pin, salt: salt)
        guard let box = try AES.GCM.seal(Data(mnemonic.utf8), using: key).combined else {
            throw PeelError("could not seal the account")
        }
        var out = Data([version])
        out.append(salt)
        out.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian) { Array($0) })
        out.append(box)
        return out
    }

    static func open(_ sealed: Data, pin: String) throws -> String {
        let bytes = Data(sealed)
        guard bytes.count > headerLength, bytes[0] == version,
              bytes.withUnsafeBytes({ UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 17, as: UInt32.self)) }) == iterations
        else {
            throw PeelError("the stored account has an unknown format")
        }
        let key = try derive(pin: pin, salt: bytes[1..<17])
        do {
            let box = try AES.GCM.SealedBox(combined: bytes[headerLength...])
            let plain = try AES.GCM.open(box, using: key)
            guard let words = String(data: plain, encoding: .utf8) else { throw SecretStoreFailure.wrongPIN }
            return words
        } catch {
            // A wrong PIN derives a wrong key, which fails authentication.
            throw SecretStoreFailure.wrongPIN
        }
    }

    private static func derive(pin: String, salt: Data) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPointer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pin, pin.utf8.count,
                saltPointer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                &key, key.count
            )
        }
        guard status == kCCSuccess else { throw PeelError("key derivation failed") }
        return SymmetricKey(data: key)
    }
}

/// A plain file with owner-only permissions and no PIN. Only for throwaway
/// accounts used by the command-line harness, which has to run unattended.
public struct FileSecretStore: SecretStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public var hasMnemonic: Bool { FileManager.default.fileExists(atPath: file.path) }

    public var requiresPIN: Bool { false }

    public func loadMnemonic(pin: String) throws -> String {
        guard let words = try? String(contentsOf: file, encoding: .utf8) else { throw SecretStoreFailure.noAccount }
        return words
    }

    public func save(mnemonic: String, pin: String) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw errno == EEXIST ? SecretStoreFailure.accountExists : PeelError("could not create \(file.path)")
        }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(mnemonic.utf8))
    }

    public func changePIN(from oldPIN: String, to newPIN: String) throws {}

    public func deleteMnemonic() throws {
        if hasMnemonic {
            try FileManager.default.removeItem(at: file)
        }
    }
}
