import Foundation
import Security

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
    /// The agent's connected model and its API key: in the Keychain for an
    /// app profile, in an owner-only file beside the words for a
    /// development one. Never in a database (docs/phases/09-agents.md).
    public let agentCredential: any SecretItem
    /// The key Peel's strut encrypts its secrets with (`STRUT_SECRET_KEY`),
    /// made when it first starts (`BundledStrut`).
    public let strutKey: any SecretItem
    /// The account's home server, its address and `STRUT_API_KEY`
    /// (`Brain`, `docs/peel-brain.md`); none kept is Peel's own strut.
    public let brain: any SecretItem
    /// The Hive device this Mac or iPhone paired, its `hivedev_` credential
    /// and the orgs' peer records (`HiveLink`, docs/connectors-and-authoring.md,
    /// "Peers"): in the Keychain for an app profile.
    public let hive: any SecretItem
    /// Face ID in place of the PIN, opt-in (`BiometricUnlock`); nil for a
    /// development profile, which has no PIN.
    public let biometrics: BiometricUnlock?

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
            // Readable while the Mac is locked once it has been unlocked since
            // it started: a scheduled run uses the agent's key then. The rest
            // stays readable only unlocked: strut starts with the account,
            // behind the PIN, and keeps its key in memory after.
            agentCredential = KeychainItem(service: "dev.peel.agent", account: name,
                                           accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            strutKey = KeychainItem(service: "dev.peel.strut", account: name)
            brain = KeychainItem(service: "dev.peel.brain", account: name)
            // Renewed while the Mac is locked too, like the agent's key.
            hive = KeychainItem(service: "dev.peel.hive", account: name,
                                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            biometrics = BiometricUnlock(secrets: secrets, keeper: KeychainBiometricKeeper(account: name))
        case .development:
            directory = root.appendingPathComponent("dev/\(name)")
            (secrets, agentCredential, strutKey, brain, hive) = Self.files(in: directory)
            biometrics = nil
        }
    }

    /// A development profile in a directory of the caller's choosing: the
    /// integration tests' temporary accounts (`@testable` only).
    init(developmentAt directory: URL) {
        name = directory.lastPathComponent
        kind = .development
        self.directory = directory
        (secrets, agentCredential, strutKey, brain, hive) = Self.files(in: directory)
        biometrics = nil
    }

    /// A development profile's words, agent key, strut's key, home server
    /// and Hive device, in files beside its database.
    private static func files(in directory: URL) -> (any SecretStore, any SecretItem, any SecretItem, any SecretItem, any SecretItem) {
        (FileSecretStore(file: directory.appendingPathComponent("mnemonic")),
         FileItem(file: directory.appendingPathComponent("agent-credential")),
         FileItem(file: directory.appendingPathComponent("strut-key")),
         FileItem(file: directory.appendingPathComponent("brain")),
         FileItem(file: directory.appendingPathComponent("hive")))
    }

    /// Where the agent's database lives, beside the account's.
    public var agentDatabase: URL { directory.appendingPathComponent("agent.sqlite") }

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

    /// The balance the server last reported, read without the PIN, for
    /// before the account is open (the lock screen's Forget); nil if none
    /// was recorded or there is no database to read.
    public func storedBalanceMsat() -> UInt64? {
        guard Storage.exists(in: directory) else { return nil }
        return try? Storage(directory: directory, readOnly: true).balanceMsat()
    }

    /// Reseals the words under a new PIN. A wrong old PIN throws
    /// `SecretStoreFailure.wrongPIN` and changes nothing. Slow, like `words`.
    public func changePIN(from oldPIN: String, to newPIN: String) throws {
        guard requiresPIN else { throw PeelError("this profile has no PIN") }
        try secrets.changePIN(from: oldPIN, to: newPIN)
        biometrics?.pinChanged(to: newPIN)
    }

    /// Removes the words and everything stored with them, the agent's key,
    /// strut's key and the home server first. A failure to remove any is reported, and
    /// the database is then kept with them.
    public func delete() throws {
        try agentCredential.delete()
        // The memory server #219 kept (an old strut key), if this Mac has it still.
        try? KeychainItem(service: "dev.peel.memory", account: name).delete()
        // The automation token #221 kept; strut is now handed one per launch.
        try? KeychainItem(service: "dev.peel.automations", account: name).delete()
        try strutKey.delete()
        try brain.delete()
        try hive.delete()
        try biometrics?.turnOff()
        try secrets.deleteMnemonic()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
