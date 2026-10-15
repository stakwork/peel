import CommonCrypto
import CryptoKit
import Foundation
import os
import Security
import Synchronization

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
    public let account: String
    /// Where the words live.
    private let item: KeychainItem
    /// The file-based login keychain earlier builds used; read only to move
    /// the words out of it.
    private let legacy: KeychainItem

    public init(account: String) {
        self.account = account
        item = KeychainItem(service: "dev.peel", account: account)
        legacy = KeychainItem(service: "dev.peel", account: account, dataProtection: false)
    }

    public var hasMnemonic: Bool {
        item.exists || legacy.exists
    }

    public var requiresPIN: Bool { true }

    /// Opens the words with the PIN. Words still in the login Keychain are
    /// moved to the data-protection Keychain once the PIN has opened them.
    public func loadMnemonic(pin: String) throws -> String {
        if let sealed = try item.read() {
            return try PINBox.open(sealed, pin: pin)
        }
        guard let old = try legacy.read() else { throw SecretStoreFailure.noAccount }
        let words = try PINBox.open(old, pin: pin)
        try moveToDataProtection(old)
        return words
    }

    public func save(mnemonic: String, pin: String) throws {
        try PIN.validate(pin)
        guard !hasMnemonic else { throw SecretStoreFailure.accountExists }
        try add(PINBox.seal(mnemonic, pin: pin))
    }

    public func changePIN(from oldPIN: String, to newPIN: String) throws {
        try PIN.validate(newPIN)
        let mnemonic = try loadMnemonic(pin: oldPIN)
        try item.update(PINBox.seal(mnemonic, pin: newPIN))
    }

    /// Removes the words from both keychains.
    public func deleteMnemonic() throws {
        try item.delete()
        try legacy.delete()
    }

    /// Copies the sealed words from the login Keychain, reads the copy back,
    /// and only when it matches removes the original. A failure before that
    /// leaves the original where it was and no copy. If only the removal
    /// fails the words are safe in both; the next unlock uses the copy.
    private func moveToDataProtection(_ sealed: Data) throws {
        do {
            try add(sealed)
        } catch {
            throw PeelError("could not move the account into the data-protection Keychain (\(error)); it is still in the login Keychain")
        }
        guard (try? item.read()) == sealed else {
            try? item.delete()
            throw PeelError("the account's copy in the data-protection Keychain did not read back the same; it is still in the login Keychain")
        }
        do {
            try legacy.delete()
        } catch {
            throw PeelError("the account moved to the data-protection Keychain, but its old copy in the login Keychain could not be removed: \(error)")
        }
    }

    private func add(_ sealed: Data) throws {
        guard try item.add(sealed, label: "Peel account \(account)") else { throw SecretStoreFailure.accountExists }
    }
}

/// One secret this device keeps, read and replaced whole: an agent's API key.
public protocol SecretItem: Sendable {
    /// The secret, or nil when none is kept.
    func read() throws -> Data?
    /// Keeps `data`, replacing what was there.
    func write(_ data: Data) throws
    /// Removes it; nothing kept is not an error.
    func delete() throws
}

/// The Keychain could not be read because this Mac is locked
/// (`errSecInteractionNotAllowed`): the secret may well be there, so this is
/// never taken for none kept.
public struct KeychainLocked: LocalizedError, Equatable, CustomStringConvertible {
    public var description: String { "the Keychain cannot be read while this Mac is locked" }
    public var errorDescription: String? { description }
}

/// A generic password in the data-protection Keychain: in the app's access
/// group, this device only (wrapped by a key tied to this Mac, never synced
/// to iCloud or restored from a backup onto another Mac), and readable
/// only while the Mac is unlocked unless the item says otherwise
/// (`accessible`).
/// Needs a bundle signed with a provisioning profile that grants the access
/// group (`scripts/sign-app.sh`); anything else gets `errSecMissingEntitlement`.
public struct KeychainItem: SecretItem {
    public let service: String
    public let account: String
    /// The data-protection Keychain; false only to read and remove what
    /// earlier builds left in the file-based login keychain.
    let dataProtection: Bool
    /// When it can be read: `WhenUnlockedThisDeviceOnly`, or
    /// `AfterFirstUnlockThisDeviceOnly` for what Peel needs while the Mac is
    /// locked (the agent's key, for a scheduled run).
    /// An item kept under another class moves to this one when next read or
    /// written.
    let accessible: String

    /// Internal, so nothing outside PeelCore can name the words' item.
    init(service: String, account: String, dataProtection: Bool = true,
         accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) {
        self.service = service
        self.account = account
        self.dataProtection = dataProtection
        self.accessible = accessible as String
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
    }

    var exists: Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The secret, or nil when none is kept; `KeychainLocked` while the Mac
    /// is locked and the item's class does not allow a read then. One kept
    /// under another class than `accessible` is moved to it.
    public func read() throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query.merging([kSecReturnData as String: true, kSecReturnAttributes as String: true]) { $1 } as CFDictionary, &item)
        guard try Self.found(status, dataProtection: dataProtection) else { return nil }
        guard let attributes = item as? [String: Any], let data = attributes[kSecValueData as String] as? Data else {
            throw PeelError("the Keychain item for \(account) is unreadable")
        }
        if dataProtection, attributes[kSecAttrAccessible as String] as? String != accessible {
            // Tried again on the next read if it fails: the secret is read either way.
            let moved = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
            if moved != errSecSuccess { Self.logOnce(moved, moving: service) }
        }
        return data
    }

    private static let log = Logger(subsystem: "dev.peel.mac", category: "keychain")
    private static let logged = Mutex<Set<String>>([])

    /// A move to another class that failed, once per item and launch: a
    /// move that never succeeds shows in the field. Names the service and
    /// the status only.
    private static func logOnce(_ status: OSStatus, moving service: String) {
        guard logged.withLock({ $0.insert(service).inserted }) else { return }
        log.error("could not move Keychain item \(service, privacy: .public) to its class: \(status, privacy: .public)")
    }

    /// A read's status: whether the item was found; a locked Mac is
    /// `KeychainLocked`, never none kept, and anything else an error. Only
    /// the data-protection Keychain's: the login keychain's says the same
    /// of a prompt it may not show.
    static func found(_ status: OSStatus, dataProtection: Bool = true) throws -> Bool {
        switch status {
        case errSecSuccess: true
        case errSecItemNotFound: false
        case errSecInteractionNotAllowed where dataProtection: throw KeychainLocked()
        default: throw PeelError("Keychain read failed: \(message(status))")
        }
    }

    public func write(_ data: Data) throws {
        if try !add(data, label: "Peel \(service) \(account)") { try update(data) }
    }

    /// Adds the item; false if one is already there.
    func add(_ data: Data, label: String) throws -> Bool {
        let attributes = query.merging([
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: false,
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status != errSecDuplicateItem else { return false }
        guard status == errSecSuccess else { throw PeelError("Keychain write failed: \(Self.message(status))") }
        return true
    }

    /// Replaces the secret, and moves it to `accessible` if it was kept under another class.
    func update(_ data: Data) throws {
        var changes: [String: Any] = [kSecValueData as String: data]
        if dataProtection { changes[kSecAttrAccessible as String] = accessible }
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw PeelError("Keychain update failed: \(Self.message(status))") }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeelError("Keychain delete failed: \(Self.message(status))")
        }
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }
}

/// A secret in a plain file with owner-only permissions, for development
/// profiles, which keep their words in a file too (`FileSecretStore`).
public struct FileItem: SecretItem {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PeelError("could not write \(file.lastPathComponent)") }
        defer { close(fd) }
        // Owner-only even when the file was there before with other permissions.
        guard fchmod(fd, 0o600) == 0 else { throw PeelError("could not protect \(file.lastPathComponent)") }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
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
