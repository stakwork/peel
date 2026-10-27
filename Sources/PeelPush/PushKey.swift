import Foundation
#if canImport(Security)
import Security
#endif

/// Where the push key is kept: a Keychain group the app and its
/// notification extension share.
public protocol PushKeyStoring: Sendable {
    func load() throws -> String?
    func save(_ key: String) throws
}

/// The 32-byte key (64 hex characters) the core encrypts a push's child
/// index with, and the extension decrypts it with. Made once on the device.
public enum PushKey {
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public static func isValid(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// The kept key and never a new one, for the extension: only the app
    /// makes the key, or a push made under another key could not be read.
    public static func existing(in store: some PushKeyStoring) -> String? {
        guard let kept = try? store.load(), isValid(kept) else { return nil }
        return kept
    }

    /// The kept key, or a new one kept now (as `SphinxOnionManager.pushKey`
    /// does). Nil only when the store cannot keep it. A kept value that is
    /// not a key is replaced.
    public static func loadOrCreate(in store: some PushKeyStoring) -> String? {
        if let kept = try? store.load(), isValid(kept) { return kept }
        let key = generate()
        do { try store.save(key) } catch { return nil }
        return key
    }
}

#if canImport(Security)
/// The push key as a generic password in the shared access group. Readable
/// after the first unlock, since the extension runs while the phone is locked.
public struct KeychainPushKeyStore: PushKeyStoring {
    public static let service = "peel-push"
    public static let account = "push_key"
    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    public func load() throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PushError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let added = SecItemAdd(query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]) { $1 } as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw PushError.keychain(status) }
        } else if added != errSecSuccess {
            throw PushError.keychain(added)
        }
    }
}
#endif

public enum PushError: Error, Equatable {
    case keychain(Int32)
    case notConfigured
}
