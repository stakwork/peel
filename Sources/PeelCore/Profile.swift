import Foundation

/// A local account: where its database lives and where its twelve words are kept.
public struct Profile: Sendable {
    public enum Kind: Sendable {
        /// An account the app owns: words in the Keychain, behind a PIN.
        case app
        /// A throwaway account for the command-line harness: words in a plain
        /// file, so tools can run unattended. Never for a real account.
        case development
    }

    public let name: String
    public let kind: Kind
    public let directory: URL
    public let secrets: any SecretStore

    /// Names are path components, so only plain characters are allowed.
    public init(name: String, kind: Kind) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard (1...64).contains(name.count), name.unicodeScalars.allSatisfy(allowed.contains),
              !["." , "..", "dev"].contains(name.lowercased()) else {
            throw PeelError("\"\(name)\" is not a valid profile name; use letters, digits, dot, dash or underscore")
        }
        self.name = name
        self.kind = kind
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peel")
        switch kind {
        case .app:
            directory = root.appendingPathComponent(name)
            secrets = KeychainSecretStore(account: name)
        case .development:
            directory = root.appendingPathComponent("dev/\(name)")
            secrets = FileSecretStore(file: directory.appendingPathComponent("mnemonic"))
        }
    }

    public var hasAccount: Bool { secrets.hasMnemonic }

    public var requiresPIN: Bool { secrets.requiresPIN }

    public func loadMnemonic(pin: String) throws -> String {
        try secrets.loadMnemonic(pin: pin)
    }

    /// Checks a PIN without handing the words to the caller.
    public func verifyPIN(_ pin: String) throws {
        _ = try secrets.loadMnemonic(pin: pin)
    }

    /// The twelve words, for showing to their owner after the PIN. Slow (the
    /// PIN's key is derived on purpose slowly); call it off the main thread.
    public func words(pin: String) throws -> [String] {
        Engine.words(in: try secrets.loadMnemonic(pin: pin))
    }

    /// Reseals the words under a new PIN. A wrong old PIN throws
    /// `SecretStoreFailure.wrongPIN` and changes nothing. Slow, like `words`.
    public func changePIN(from oldPIN: String, to newPIN: String) throws {
        guard requiresPIN else { throw PeelError("this profile has no PIN") }
        try secrets.changePIN(from: oldPIN, to: newPIN)
    }

    /// Removes the words and everything stored with them. A failure to remove
    /// the words is reported, and the database is then kept with them.
    public func delete() throws {
        try secrets.deleteMnemonic()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
