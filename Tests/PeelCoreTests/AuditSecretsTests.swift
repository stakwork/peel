import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The secrets audit (docs/reviews/2026-10-08-audit-keys-money.md): the
/// twelve words sealed under the PIN, the development profile's plain file,
/// the profile directory, and what errors and the database say.
struct AuditSecretsTests {
    let profile = TempProfile()

    // MARK: The PIN box

    /// Each seal derives a key (about 0.4 s), so the box is opened sparingly.
    @Test func thePINBoxOpensOnlyWithItsPINAndNeverSealsTheSameTwice() throws {
        let words = abandon.joined(separator: " ")
        let sealed = try PINBox.seal(words, pin: "123456")
        #expect(!sealed.contains(Data(words.utf8)))
        #expect(try PINBox.open(sealed, pin: "123456") == words)
        #expect(throws: SecretStoreFailure.wrongPIN) { try PINBox.open(sealed, pin: "123457") }
        // A fresh salt and nonce each time.
        #expect(try PINBox.seal(words, pin: "123456") != sealed)

        // A changed byte of the box reads as a wrong PIN, never as words.
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: SecretStoreFailure.wrongPIN) { try PINBox.open(tampered, pin: "123456") }
    }

    /// A blob that names fewer iterations (an attacker's cheaper one) or
    /// another version is refused before any key is derived.
    @Test func thePINBoxRefusesAnotherFormatOrIterationCount() throws {
        var blob = Data([1]) + Data(repeating: 7, count: 16)
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Array($0) })
        blob.append(Data(repeating: 0, count: 60))
        #expect(throws: PeelError.self) { try PINBox.open(blob, pin: "123456") }
        blob[0] = 2
        #expect(throws: PeelError.self) { try PINBox.open(blob, pin: "123456") }
        #expect(throws: PeelError.self) { try PINBox.open(Data([1, 2, 3]), pin: "123456") }
    }

    @Test(arguments: ["12345", "1234567", "12345a", " 12345", "١٢٣٤٥٦", "１２３４５６", ""])
    func aPINIsSixASCIIDigits(pin: String) {
        #expect(throws: PeelError.self) { try PIN.validate(pin) }
    }

    @Test func sixASCIIDigitsAreAPIN() throws {
        try PIN.validate("000000")
        try PIN.validate("987654")
    }

    // MARK: Files at rest

    /// The development profile's words: a new file only, owner-only, in an
    /// owner-only folder; a second account never overwrites the first.
    @Test func theDevelopmentFileIsOwnerOnlyAndNeverOverwritten() throws {
        let file = profile.url.appendingPathComponent("dev/mnemonic")
        let store = FileSecretStore(file: file)
        try store.save(mnemonic: "first words", pin: "")
        #expect(try permissions(file) == 0o600)
        #expect(try permissions(file.deletingLastPathComponent()) == 0o700)
        #expect(throws: SecretStoreFailure.accountExists) { try store.save(mnemonic: "second words", pin: "") }
        #expect(try store.loadMnemonic(pin: "") == "first words")
        try store.deleteMnemonic()
        #expect(!store.hasMnemonic)
        #expect(throws: SecretStoreFailure.noAccount) { try store.loadMnemonic(pin: "") }
    }

    /// The agent's model key and strut's secret store key on a development
    /// profile: owner-only files, and gone with the profile.
    @Test func theAgentsKeysAreOwnerOnlyAndGoWithTheProfile() throws {
        let dev = Profile(developmentAt: profile.url.appendingPathComponent("agent-secrets"))
        try dev.agentCredential.write(Data("model key".utf8))
        try dev.strutKey.write(Data("strut key".utf8))
        #expect(try permissions(dev.directory.appendingPathComponent("agent-credential")) == 0o600)
        #expect(try permissions(dev.directory.appendingPathComponent("strut-key")) == 0o600)
        try dev.delete()
        #expect(try dev.agentCredential.read() == nil && dev.strutKey.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: dev.directory.path))
    }

    /// A profile folder made readable by others before is closed again.
    @Test func theProfileFolderIsOwnerOnly() throws {
        try FileManager.default.createDirectory(
            at: profile.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        _ = try profile.storage()
        #expect(try permissions(profile.url) == 0o700)
    }

    /// Neither the words nor the seed derived from them reach the profile's
    /// files: the engine holds the seed in memory only, and the words check
    /// (finding N5) keeps only that it passed. Any two neighbouring
    /// words, in order, count as a leak, so a torn page or a cut-off line is
    /// still caught. A single word is not: the schema's own SQL holds words
    /// of the list (" invite ", " message ", " payment "), which made a check
    /// for one word fail about once in 57 runs.
    @Test func theProfileFilesNeverHoldTheWordsOrTheSeed() async throws {
        let words = try Engine.generateMnemonic()
        let list = Engine.words(in: words)
        let seed: String
        do {
            let engine = try Engine(mnemonic: words, storage: profile.storage())
            seed = await engine.seed
            try await engine.setAlias("audit")
            try await engine.setServer(#require(ServerAddress("127.0.0.1:1883")))
            try await engine.confirmWords([0: list[0], 1: list[1], 2: list[2]], mnemonic: words)
        }
        let files = try FileManager.default.subpathsOfDirectory(atPath: profile.url.path)
            .map { profile.url.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        var read = 0
        for file in files {
            let bytes = try Data(contentsOf: file)
            read += 1
            #expect(!bytes.contains(Data(seed.utf8)), "\(file.lastPathComponent) holds the seed")
            #expect(!bytes.contains(Data(words.utf8)), "\(file.lastPathComponent) holds the words")
            for (word, next) in zip(list, list.dropFirst()) {
                #expect(!bytes.contains(Data("\(word) \(next)".utf8)), "\(file.lastPathComponent) holds two words")
            }
        }
        #expect(read > 0)
    }

    // MARK: What errors say

    /// Mistyped words are refused without repeating any of them, so an
    /// error shown, printed or reported never carries the account.
    @Test(arguments: [
        Array(abandon.dropLast()) + ["peelauditword"],
        Array(repeating: "abandon", count: 12),  // bad checksum
        Array(abandon.dropLast()),
        Array(repeating: "abandon", count: 5),
        [],
    ])
    func refusedWordsAreNeverRepeated(words: [String]) {
        let text = words.joined(separator: " ")
        for attempt in [{ _ = try Engine.validate(mnemonic: text) }, { _ = try testEngineWithWords(text) }] {
            do {
                try attempt()
                Issue.record("\(words.last ?? "") was accepted")
            } catch {
                for said in [String(describing: error), PeelError.readable(error)] {
                    #expect(!said.contains("abandon"))
                    #expect(!said.contains("peelauditword"))
                }
            }
        }
    }

    private func testEngineWithWords(_ words: String) throws -> Engine {
        try Engine(mnemonic: words, storage: profile.storage())
    }

    // MARK: Profiles

    /// The app's account and the harness's never share a folder or a store,
    /// and no app profile can be named after the harness's folder.
    @Test func developmentProfilesLiveApartFromTheApps() throws {
        let app = try Profile(name: "default", kind: .app)
        let development = try Profile(name: "default", kind: .development)
        #expect(app.directory != development.directory)
        #expect(development.directory.path.hasSuffix("/Peel/dev/default"))
        #expect(app.requiresPIN)
        #expect(!development.requiresPIN)
        #expect(development.secrets is FileSecretStore)
        #expect(app.secrets is KeychainSecretStore)
        for name in ["dev", "DEV", "..", ".", "a/b", "", String(repeating: "a", count: 65)] {
            #expect(throws: PeelError.self) { try Profile(name: name, kind: .app) }
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
}
