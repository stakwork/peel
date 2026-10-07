import Foundation
import Security

/// Where an account's twelve words live.
public protocol SecretStore: Sendable {
    func loadMnemonic() throws -> String?
    func save(mnemonic: String) throws
    func deleteMnemonic() throws
}

/// The login Keychain. Items are tied to the signed app that wrote them, so the
/// app needs a stable signing identity or every rebuild prompts.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String

    public init(service: String = "dev.peel", account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadMnemonic() throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let words = String(data: data, encoding: .utf8) else {
                throw PeelError("the Keychain item for \(account) is unreadable")
            }
            return words
        case errSecItemNotFound:
            return nil
        default:
            throw PeelError("Keychain read failed: \(Self.message(status))")
        }
    }

    public func save(mnemonic: String) throws {
        let attributes = query.merging([
            kSecValueData as String: Data(mnemonic.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Peel account \(account)",
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status != errSecDuplicateItem else { throw PeelError("an account named \(account) already exists in the Keychain") }
        guard status == errSecSuccess else { throw PeelError("Keychain write failed: \(Self.message(status))") }
    }

    public func deleteMnemonic() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeelError("Keychain delete failed: \(Self.message(status))")
        }
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }
}

/// A plain file with owner-only permissions. Only for throwaway accounts used
/// by the command-line harness, which has to run unattended.
public struct FileSecretStore: SecretStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func loadMnemonic() throws -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    public func save(mnemonic: String) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw PeelError(errno == EEXIST ? "an account already exists at \(file.path)" : "could not create \(file.path)")
        }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(mnemonic.utf8))
    }

    public func deleteMnemonic() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
