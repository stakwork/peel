import Foundation

/// A local account: its database directory and its mnemonic.
///
/// The mnemonic is kept in a plain file so development tools can run unattended.
/// That is only acceptable for throwaway accounts; Keychain storage replaces it
/// before real accounts move over.
public struct Profile: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case badName(String)
        case noAccount(URL)
        case accountExists(URL)

        public var description: String {
            switch self {
            case .badName(let name): "\"\(name)\" is not a valid profile name; use letters, digits, dot, dash or underscore"
            case .noAccount(let url): "no account in \(url.path)"
            case .accountExists(let url): "an account already exists in \(url.path)"
            }
        }
    }

    public let name: String
    public let directory: URL

    /// Names are path components, so only plain characters are allowed.
    public init(name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard (1...64).contains(name.count), name.unicodeScalars.allSatisfy(allowed.contains),
              name != ".", name != ".." else {
            throw Failure.badName(name)
        }
        self.name = name
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peel/dev/\(name)")
    }

    public var mnemonicFile: URL { directory.appendingPathComponent("mnemonic") }

    public var hasAccount: Bool { FileManager.default.fileExists(atPath: mnemonicFile.path) }

    public func loadMnemonic() throws -> String {
        guard let mnemonic = try? String(contentsOf: mnemonicFile, encoding: .utf8) else {
            throw Failure.noAccount(directory)
        }
        return mnemonic
    }

    public func save(mnemonic: String) throws {
        guard !hasAccount else { throw Failure.accountExists(directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(mnemonicFile.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PeelError("could not create \(mnemonicFile.path)") }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(mnemonic.utf8))
    }

    /// Removes the account and everything stored with it.
    public func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
