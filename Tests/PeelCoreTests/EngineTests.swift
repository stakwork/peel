import Foundation
import Sphinxrs
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

/// What the core calls ours is kept only when our key signed it, or a tribe
/// we know signed it in its own chat: the tag and the date that make it
/// ours are a contact's to arrange (docs/phases/04-money.md, "Who may write
/// ours"). `keyG` is a tribe, `key2G` a person, `strangerKey` anyone.
struct OursTests {
    let profile = TempProfile()

    private static func copy(
        signedBy signer: String, to chat: String?, fromMe: Bool = true, type: Int = MessageType.text, host: String? = nil
    ) -> Msg {
        Msg(message: #"{"content":"hi"}"#, type: UInt8(type), uuid: uuid(1), tag: "aa", index: "7",
            sender: sender(signer, host: host), msat: nil, timestamp: 1_000, sentTo: chat, fromMe: fromMe,
            paymentHash: nil, error: nil)
    }

    /// The row the copy left in `chat`, if any, with the core's `state`
    /// changes and the tribes stored first.
    private func stored(
        _ msg: @Sendable () -> Msg, in chat: String, expectedSender: String? = nil, state: [String: Data] = [:], tribes: [Tribe] = []
    ) async throws -> Message? {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(tribes: tribes))
        let engine = try testEngine(storage)
        _ = try await engine.commit(coreResult(msgs: [msg()], state: state), time: "1", expectedSender: expectedSender)
        return try storage.message(uuid: uuid(1), in: chat)
    }

    @Test func ourKeysCopyIsKept() async throws {
        let other = TempProfile()
        let ours = await (try testEngine(other.storage())).accountKey
        let row = try #require(try await stored({ Self.copy(signedBy: ours, to: key2G) }, in: key2G))
        #expect(row.fromMe)
    }

    @Test func aKnownTribesForwardOfOursIsKept() async throws {
        let row = try #require(try await stored({ Self.copy(signedBy: keyG, to: keyG) }, in: keyG, tribes: [Tribe(pubkey: keyG)]))
        #expect(row.fromMe)
    }

    /// Our own join forwarded back with the tribe's host, as on a restore,
    /// makes the tribe known, and is kept.
    @Test func ourJoinThatIntroducesTheTribeIsKept() async throws {
        let row = try await stored({
            Self.copy(signedBy: keyG, to: keyG, type: MessageType.groupJoin, host: "tribes.example")
        }, in: keyG, state: coreContact(keyG, contactKey: nil))
        #expect(row?.fromMe == true)
        #expect(try profile.storage().tribes().contains { $0.pubkey == keyG })
    }

    /// Signed by us it is ours wherever it is filed, a tribe Peel does not
    /// know included (our echo on another device).
    @Test func ourKeysCopyInAnUnknownTribeShapedChatIsKept() async throws {
        let other = TempProfile()
        let ours = await (try testEngine(other.storage())).accountKey
        let row = try await stored({ Self.copy(signedBy: ours, to: keyG) }, in: keyG, state: coreContact(keyG, contactKey: nil))
        #expect(row?.fromMe == true)
    }

    @Test func aCopyWithNoSenderIsDropped() async throws {
        let msg: @Sendable () -> Msg = {
            Msg(message: #"{"content":"hi"}"#, type: UInt8(MessageType.text), uuid: uuid(1), tag: "aa", index: "7",
                sender: nil, msat: nil, timestamp: 1_000, sentTo: key2G, fromMe: true, paymentHash: nil, error: nil)
        }
        #expect(try await stored(msg, in: key2G) == nil)
    }

    @Test func aCopySignedByTheChatsPersonIsDropped() async throws {
        #expect(try await stored({ Self.copy(signedBy: key2G, to: key2G) }, in: key2G) == nil)
    }

    @Test func aDMCopySignedByAnotherKeyIsDropped() async throws {
        #expect(try await stored({ Self.copy(signedBy: strangerKey, to: key2G) }, in: key2G) == nil)
    }

    @Test func aCopyInATribeSignedByAnotherKeyIsDropped() async throws {
        #expect(try await stored({ Self.copy(signedBy: strangerKey, to: keyG) }, in: keyG, tribes: [Tribe(pubkey: keyG)]) == nil)
    }

    /// The core files a signer as a contact at the index it wrote to,
    /// without a contact key if they leave it out: tribe-shaped, not a tribe.
    /// With no host to introduce it, it is no tribe Peel knows (with one, it
    /// would be: documented residual).
    @Test func aCopyInAContactThatOnlyLooksLikeATribeIsDropped() async throws {
        let minted = coreContact(strangerKey, contactKey: nil)
        #expect(try await stored({ Self.copy(signedBy: strangerKey, to: strangerKey) }, in: strangerKey, state: minted) == nil)
    }

    /// Someone else's message is filed by the topic as before.
    @Test func notOursIsUnchanged() async throws {
        let row = try #require(try await stored({ Self.copy(signedBy: key2G, to: nil, fromMe: false) }, in: key2G, expectedSender: key2G))
        #expect(!row.fromMe)
    }
}
