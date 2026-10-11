import Foundation
import Testing
@testable import PeelCore

struct MnemonicTests {
    @Test func wordsSplitOnWhitespaceAndCommasAndLowercase() {
        #expect(Engine.words(in: "  Apple, BANANA\ncherry\t,, date ") == ["apple", "banana", "cherry", "date"])
        #expect(Engine.words(in: "").isEmpty)
        #expect(Engine.words(in: " ,\n ").isEmpty)
    }

    @Test func validateReturnsCanonicalWords() throws {
        let messy = "  " + abandon.map { $0.uppercased() }.joined(separator: ",\n ") + " "
        #expect(try Engine.validate(mnemonic: messy) == abandon.joined(separator: " "))
    }

    @Test func generatedMnemonicIsTwelveValidWords() throws {
        let mnemonic = try Engine.generateMnemonic()
        #expect(Engine.words(in: mnemonic).count == 12)
        #expect(try Engine.validate(mnemonic: mnemonic) == mnemonic)
        #expect(try Engine.generateMnemonic() != mnemonic)
    }
}

struct InviteTests {
    /// Builds an invite the way the core's `invite_qr` does.
    private func invite(host: String, code: [UInt8], contact: (key: [UInt8], lsp: [UInt8], scid: UInt64, alias: String)?) -> String {
        var link = "sphinx.chat://?action=i&d=" + base64URL(code + Array(host.utf8))
        if let contact {
            let scid = withUnsafeBytes(of: contact.scid.bigEndian, Array.init)
            link += "&c=" + base64URL(contact.key + contact.lsp + scid + Array(contact.alias.utf8))
        }
        return link
    }

    private func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    @Test func parsesHostAndCode() throws {
        let code = [UInt8](0..<32)
        let parsed = try Engine.parseInvite("  " + invite(host: "broker.example.com:8883", code: code, contact: nil) + "\n")
        #expect(parsed.code == code.map { String(format: "%02x", $0) }.joined())
        #expect(parsed.server == "broker.example.com:8883")
        #expect(parsed.inviterContactInfo == nil)
        #expect(parsed.inviterAlias == nil)
    }

    @Test func parsesInviter() throws {
        let key = [UInt8](repeating: 2, count: 33)
        let lsp = [UInt8](repeating: 3, count: 33)
        let link = invite(host: "h:1", code: Array(repeating: 0, count: 32), contact: (key, lsp, 1234, "Ann"))
        let parsed = try Engine.parseInvite(link)
        #expect(parsed.inviterContactInfo == "\(String(repeating: "02", count: 33))_\(String(repeating: "03", count: 33))_1234")
        #expect(parsed.inviterAlias == "Ann")
    }

    @Test func rejectsInviteWithoutData() {
        #expect(throws: (any Error).self) { try Engine.parseInvite("sphinx.chat://?action=i&x=1") }
        #expect(throws: (any Error).self) { try Engine.parseInvite("d=!!!") }
    }
}

struct EngineOfflineTests {
    let profile = TempProfile()

    @Test func freshAccountIsUnregisteredWithNoContacts() async throws {
        let storage = try profile.storage()
        let engine = try testEngine(storage)
        #expect(await engine.isRegistered == false)
        #expect(try await engine.contacts().isEmpty)
        #expect(try Engine.contacts(in: storage).isEmpty)
        #expect(await engine.connection == .offline(retryIn: nil))
    }

    @Test func deviceIDIsCreatedOnceAndKept() throws {
        let deviceID: String?
        do {
            let storage = try profile.storage()
            _ = try testEngine(storage)
            deviceID = try storage.value(for: .deviceID)
        }
        #expect(deviceID != nil)
        let storage = try profile.storage()
        _ = try testEngine(storage)
        #expect(try storage.value(for: .deviceID) == deviceID)
    }
}

/// Whether the twelve words were written down (finding N5): stored per
/// account, set by three words typed back or by a restore, never by a
/// new account on its own.
struct WordsConfirmationTests {
    let profile = TempProfile()
    let server = ServerAddress("127.0.0.1:1")!

    /// A restore typed all twelve words; a new account has had none typed back.
    @Test(arguments: [false, true]) func onlyARestoreStartsConfirmed(restore: Bool) async throws {
        let local = Profile(developmentAt: profile.url)
        let engine = if restore {
            try await Account.restore(local, mnemonic: abandon.joined(separator: " "), alias: "Ann", pin: "", server: server)
        } else {
            try await Account.create(local, alias: "Ann", pin: "", server: server).engine
        }
        #expect(try await engine.wordsConfirmed() == restore)
    }

    @Test func rightWordsConfirmAndAreKept() async throws {
        do {
            let engine = try testEngine(try profile.storage())
            #expect(try await engine.wordsConfirmed() == false)
            // As typed from paper: any case, stray spaces.
            try await engine.confirmWords(
                [0: " Abandon", 5: "abandon ", 11: "ABOUT"], mnemonic: abandon.joined(separator: " ")
            )
            #expect(try await engine.wordsConfirmed())
        }
        #expect(try await testEngine(try profile.storage()).wordsConfirmed())
    }

    @Test func wrongWordsNameTheirPositionsAndConfirmNothing() async throws {
        let engine = try testEngine(try profile.storage())
        let words = abandon.joined(separator: " ")
        // The account's own words, but not the ones at these places.
        await #expect(throws: Engine.Failure.wrongWords(positions: [6, 12])) {
            try await engine.confirmWords([0: "abandon", 5: "about", 11: "abandon"], mnemonic: words)
        }
        // Another account's words, typed back right, are not this one's.
        let others = try Engine.generateMnemonic()
        let answers = Dictionary(uniqueKeysWithValues: [1, 4, 9].map { ($0, Engine.words(in: others)[$0]) })
        await #expect(throws: Engine.Failure.notThisAccountsWords) { try await engine.confirmWords(answers, mnemonic: others) }
        // One word, right as it is, is not the check.
        await #expect(throws: PeelError.self) { try await engine.confirmWords([11: "about"], mnemonic: words) }
        #expect(try await engine.wordsConfirmed() == false)
        // What the person reads names positions, never a word.
        #expect("\(Engine.Failure.wrongWords(positions: [6, 12]))" == "words 6 and 12 do not match")
    }
}
