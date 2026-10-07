import Foundation

/// A local account: its database directory and its mnemonic.
///
/// The mnemonic is kept in a plain file so development tools can run unattended.
/// That is only acceptable for throwaway accounts; Keychain storage replaces it
/// before real accounts move over.
public struct Profile: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case noAccount(URL)
        case accountExists(URL)
        case cannotWrite(URL)

        public var description: String {
            switch self {
            case .noAccount(let url): "no account in \(url.path)"
            case .accountExists(let url): "an account already exists in \(url.path)"
            case .cannotWrite(let url): "could not write \(url.path)"
            }
        }
    }

    public let name: String
    public let directory: URL

    public init(name: String) {
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let written = FileManager.default.createFile(
            atPath: mnemonicFile.path, contents: Data(mnemonic.utf8), attributes: [.posixPermissions: 0o600]
        )
        guard written else { throw Failure.cannotWrite(mnemonicFile) }
    }
}
