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

/// Who a message from the core is from, and which chat it goes in. The core
/// recovers a sender from its signature; a live message's topic names the
/// contact too, and only when the two agree does the sender's name and
/// photo count. History from a sender the core does not know is dropped.
struct SenderTests {
    let profile = TempProfile()

    /// A text as the core hands it over, with the sender it claims.
    private func msg(_ n: Int, claims pubkey: String? = nil, alias: String = "Mallory", fromMe: Bool = false,
                     sentTo: String? = nil, type: Int = MessageType.text, body: String = #"{"content":"hi"}"#) -> Msg {
        let sender = pubkey.map { #"{"pubkey":"\#($0)","alias":"\#(alias)","photo_url":"https://img/\#(alias).png"}"# }
        return Msg(
            message: body, type: UInt8(type), uuid: uuid(n), tag: nil, index: String(n), sender: sender, msat: nil,
            timestamp: UInt64(n) * 1_000, sentTo: sentTo, fromMe: fromMe, paymentHash: nil, error: nil
        )
    }

    /// An engine whose core knows `keyG` as a contact.
    private func engine() throws -> (Engine, Storage) {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            state: registeredState.merging(coreContact(keyG, contactKey: key3G)) { $1 }, contacts: [(keyG, true)]
        ))
        return (try testEngine(storage), storage)
    }

    private func stored() throws -> [(chat: String, fromMe: Bool)] {
        try rows(profile, "SELECT chat, fromMe FROM message ORDER BY id").map { ($0["chat"], $0["fromMe"]) }
    }

    private func alias(of pubkey: String) throws -> String? {
        try rows(profile, "SELECT alias FROM contact WHERE pubkey = '\(pubkey)'").first?["alias"]
    }

    /// A live message goes in the chat its topic names; a sender claiming
    /// to be someone else renames no one.
    @Test func aLiveMessageClaimingAnotherSenderRenamesNoOne() async throws {
        let (engine, _) = try engine()
        _ = try await engine.commit(coreResult(msgs: [msg(1, claims: key2G)]), time: "1", expectedSender: keyG)
        #expect(try stored().map(\.chat) == [keyG])
        #expect(try alias(of: keyG) == nil)
        #expect(try alias(of: key2G) == nil)
        // The contact naming itself is believed.
        _ = try await engine.commit(coreResult(msgs: [msg(2, claims: keyG, alias: "Ann")]), time: "2", expectedSender: keyG)
        #expect(try alias(of: keyG) == "Ann")
    }

    /// From history (no topic), the claimed sender must be a contact the
    /// core knows; anyone else's message is dropped, not filed under them.
    @Test func historyFromAStrangerIsDropped() async throws {
        let (engine, _) = try engine()
        _ = try await engine.commit(coreResult(msgs: [msg(1, claims: strangerKey)]), time: "1", expectedSender: nil)
        _ = try await engine.commit(coreResult(msgs: [msg(2)]), time: "2", expectedSender: nil)
        #expect(try stored().isEmpty)
        _ = try await engine.commit(coreResult(msgs: [msg(3, claims: keyG, alias: "Ann")]), time: "3", expectedSender: nil)
        #expect(try stored().map(\.chat) == [keyG])
        #expect(try alias(of: keyG) == "Ann")
    }

    /// Our own copy goes in the chat it was sent to, and with none it is dropped.
    @Test func ourOwnCopyGoesWhereItWasSent() async throws {
        let (engine, _) = try engine()
        _ = try await engine.commit(coreResult(msgs: [msg(1, fromMe: true)]), time: "1", expectedSender: nil)
        #expect(try stored().isEmpty)
        _ = try await engine.commit(coreResult(msgs: [msg(2, fromMe: true, sentTo: keyG)]), time: "2", expectedSender: nil)
        #expect(try stored().map(\.chat) == [keyG])
        #expect(try stored().map(\.fromMe) == [true])
    }

    /// A tribe forwarding our post proves the server took it: its copy takes
    /// over the row written at send (one row, delivered, the tribe's uuid),
    /// never a row of ours in another chat, and a replay of it adds nothing.
    @Test func aTribesCopyOfOurPostTakesOverItsRow() async throws {
        let (club, other) = ("02c1ab", "02c2ab")
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: club), Tribe(pubkey: other)])
        let sent = { (n: Int, chat: String) in
            Message.fixture(uuid: uuid(n), chat: chat, fromMe: true, content: "hi", tag: "t\(n)",
                            status: Message.Delivery.pending.rawValue)
        }
        _ = try storage.apply(Storage.Commit(messages: [(sent(1, club), false, nil), (sent(2, other), false, nil)]))
        let engine = try testEngine(storage)
        func echo(_ n: Int, of original: Int, in chat: String) -> Msg {
            msg(n, fromMe: true, sentTo: chat, body: #"{"content":"hi","originalUuid":"\#(uuid(original))"}"#)
        }
        _ = try await engine.commit(coreResult(msgs: [echo(11, of: 1, in: club)]), time: "1", expectedSender: nil)
        // Our post in another tribe is not taken over by a copy naming it.
        _ = try await engine.commit(coreResult(msgs: [echo(12, of: 2, in: club)]), time: "2", expectedSender: nil)
        _ = try await engine.commit(coreResult(msgs: [echo(11, of: 1, in: club)]), time: "3", expectedSender: nil)
        let rows = try rows(profile, "SELECT uuid, chat, tag, status FROM message ORDER BY id")
        #expect(rows.map { $0["uuid"] as String } == [uuid(11), uuid(2), uuid(12)])
        #expect(rows.map { $0["chat"] as String } == [club, other, club])
        #expect(rows[0]["tag"] as String? == "t1")
        #expect(rows[0]["status"] as String? == Message.Delivery.delivered.rawValue)
        #expect(rows[1]["status"] as String? == Message.Delivery.pending.rawValue)
    }

    /// A payment request asks for what its invoice says, whatever its JSON claims.
    @Test func aRequestAsksForWhatItsInvoiceSays() async throws {
        let seed = try Sphinxrs.mnemonicToSeed(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let bolt11 = try #require(try Sphinxrs.makeInvoice(
            seed: seed, uniqueTime: String(Date().millisecondsSince1970), state: StateCodec.encode(registeredState),
            amtMsat: 10_000, description: "lunch"
        ).invoice)
        let invoice = try Invoice(bolt11)
        let body = #"{"invoice":"\#(bolt11)","amount":99000000,"paymentHash":"\#(uuid(9))","content":"forged"}"#
        let (engine, storage) = try engine()
        let request = msg(1, claims: keyG, type: MessageType.invoice, body: body)
        _ = try await engine.commit(coreResult(msgs: [request]), time: "1", expectedSender: keyG)
        let id: Int64 = try #require(try rows(profile, "SELECT id FROM message").first?["id"])
        let stored = try #require(try storage.message(id: id))
        #expect(stored.amountMsat == 10_000)
        #expect(stored.paymentHash == invoice.paymentHash)
        #expect(stored.content == "lunch")
    }
}
