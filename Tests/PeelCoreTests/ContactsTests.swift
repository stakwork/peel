import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import GRDB
import Testing
@testable import PeelCore

/// Contact info for `keyG` on `key3G`'s server.
private let info = "\(keyG)_\(key3G)_1234"

/// An invite naming `keyG` as its inviter, built as the core's `invite_qr` does.
private func inviteLink(alias: String = "Ann", contact: Bool = true) -> String {
    func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    var link = "sphinx.chat://?action=i&d=" + base64URL([UInt8](repeating: 7, count: 32) + Array("h:1".utf8))
    if contact {
        let scid = withUnsafeBytes(of: UInt64(1234).bigEndian, Array.init)
        link += "&c=" + base64URL(Array(hex(keyG)) + Array(hex(key3G)) + scid + Array(alias.utf8))
    }
    return link
}

struct ContactCodeTests {
    @Test func readsContactInfoInAnyCaseAroundSpace() throws {
        #expect(try ContactCode.read("  \(info.uppercased())\n") == .contact(info: info))
        #expect(try ContactCode.read(info).pubkey == keyG)
    }

    @Test func readsTheOfficialAppsShareContactLink() throws {
        #expect(try ContactCode.read("sphinx.chat://?action=share_contact&pubKey=\(info)") == .contact(info: info))
        #expect(throws: Engine.Failure.keyWithoutRoute) {
            try ContactCode.read("sphinx.chat://?action=share_contact&pubKey=\(keyG)")
        }
    }

    @Test func anInviteAddsItsInviter() throws {
        let code = try ContactCode.read(inviteLink())
        #expect(code.contactInfo == info)
        guard case .invite(let invite) = code else { Issue.record("not an invite"); return }
        #expect(invite.inviterAlias == "Ann")
        #expect(throws: Engine.Failure.inviteWithoutInviter) { try ContactCode.read(inviteLink(contact: false)) }
    }

    @Test func aTribeLinkIsReadButAddsNobody() throws {
        let code = try ContactCode.read("sphinx.chat://?action=tribeV2&pubkey=\(key2G)&host=tribes.example.com")
        guard case .tribe(let link) = code else { Issue.record("not a tribe"); return }
        #expect(link.pubkey == key2G)
        #expect(code.contactInfo == nil)
    }

    @Test(arguments: [
        "",
        "hello",
        "lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypq",
        "\(keyG)_\(key3G)",  // no channel
        "\(keyG)_\(key3G)_12_3",  // four parts
        "\(keyG)_\(key3G)_-1",
        "\(keyG)_\(key3G)_1e3",
        "\(keyG)_\(key3G)_99999999999999999999999",  // past UInt64
        "04\(keyG.dropFirst(2))_\(key3G)_1",  // not a compressed key
        "\(keyG)_zz\(key3G.dropFirst(2))_1",
        "https://\(info)",
        "sphinx.chat://evil.example.com/?action=share_contact&pubKey=\(info)",  // a host
        "sphinx.chat://?action=auth&pubKey=\(info)",  // another action
        "sphinx.chat://?action=share_contact",
        "sphinx.chat://?action=i&d=!!!",
        "sphinx.chat://?action=tribeV2&pubkey=\(key2G)&host=evil.com/path",
    ])
    func refusesAnythingElse(text: String) {
        #expect(throws: (any Error).self) { try ContactCode.read(text) }
    }

    @Test func refusesABareKeyAndOverlongText() {
        #expect(throws: Engine.Failure.keyWithoutRoute) { try ContactCode.read(keyG) }
        #expect(throws: Engine.Failure.notAContactCode) {
            try ContactCode.read(info + String(repeating: " x", count: 2000))
        }
    }
}

struct QRImageTests {
    private func png(_ text: String) throws -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        let image = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let padded = image.composited(over: CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -40, dy: -40)))
        let context = CIContext()
        return try #require(context.pngRepresentation(of: padded, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
    }

    @Test func readsTheCodeInAPicture() throws {
        #expect(try QRImage.codes(in: png(info)) == [info])
    }

    @Test func aPictureWithoutACodeHasNone() throws {
        let blank = try #require(CIContext().pngRepresentation(
            of: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ))
        #expect(try QRImage.codes(in: blank).isEmpty)
        #expect(throws: (any Error).self) { try QRImage.codes(in: Data("not a picture".utf8)) }
    }
}

struct InviteStorageTests {
    let profile = TempProfile()

    private func record(_ code: String = String(repeating: "ab", count: 32), status: InviteRecord.Status = .sending) -> InviteRecord {
        InviteRecord(
            code: code, link: "sphinx.chat://?action=i&d=x", amountMsat: 2_000_000, nickname: "Cat", message: "hi",
            tag: "tag-\(code.prefix(4))", status: status, createdAt: 1_000
        )
    }

    @Test func theServersStatusMovesASendingInviteOnly() throws {
        let storage = try profile.storage()
        let sending = record()
        let other = record(String(repeating: "cd", count: 32))
        _ = try storage.apply(Storage.Commit(invites: [sending, other]))
        _ = try storage.apply(Storage.Commit(statuses: [(sending.tag!, "COMPLETE"), (other.tag!, "FAILED")]))
        #expect(try storage.invite(code: sending.code)?.status == .ready)
        #expect(try storage.invite(code: other.code)?.status == .failed)
        // Once settled, a later status changes nothing.
        _ = try storage.apply(Storage.Commit(statuses: [(sending.tag!, "FAILED")]))
        #expect(try storage.invite(code: sending.code)?.status == .ready)
        #expect(try storage.listPendingInvites().map(\.code) == [sending.code])
        #expect(try storage.sendingInvites().isEmpty)
    }

    /// Someone who signs up with the invite adds this account with its code.
    @Test func aKeyExchangeWithTheCodeMarksItUsed() throws {
        let storage = try profile.storage()
        let invite = record(status: .ready)
        _ = try storage.apply(Storage.Commit(invites: [invite]))
        let sender = #"{"pubkey":"\#(keyG)","alias":"Cat","code":"\#(invite.code.uppercased())"}"#
        let exchange = Message.fixture(
            uuid: uuid(1), serverIndex: 4, type: MessageType.contactKey, chat: keyG, sender: sender, body: nil, content: nil
        )
        _ = try storage.apply(Storage.Commit(messages: [(exchange, true, nil)]))
        let used = try #require(try storage.invite(code: invite.code))
        #expect(used.status == .used)
        #expect(used.usedBy == keyG)
        #expect(try storage.listPendingInvites().isEmpty)
    }

    /// An untrusted sender (not matched to the key that decrypted it) cannot mark one.
    @Test func anUntrustedKeyExchangeChangesNothing() throws {
        let storage = try profile.storage()
        let invite = record(status: .ready)
        _ = try storage.apply(Storage.Commit(invites: [invite]))
        let sender = #"{"pubkey":"\#(keyG)","code":"\#(invite.code)"}"#
        let exchange = Message.fixture(uuid: uuid(1), type: MessageType.contactKey, chat: keyG, sender: sender, content: nil)
        _ = try storage.apply(Storage.Commit(messages: [(exchange, false, nil)]))
        #expect(try storage.invite(code: invite.code)?.status == .ready)
    }

    @Test func cancellingMovesOnlyFromTheNamedStatuses() throws {
        let storage = try profile.storage()
        let invite = record(status: .used)
        _ = try storage.apply(Storage.Commit(invites: [invite]))
        #expect(try storage.setInviteStatus(code: invite.code, to: .cancelling, from: [.ready]) == false)
        #expect(try storage.invite(code: invite.code)?.status == .used)
    }

    /// Someone who adds this account is new until their chat is opened, once:
    /// the same key exchange again (a catch-up) does not make them new again,
    /// and a restore replays without marking anyone.
    @Test func someoneWhoAddedUsIsNewUntilOpened() async throws {
        let storage = try profile.storage()
        let theirs = Message.fixture(
            uuid: uuid(1), serverIndex: 0, type: MessageType.contactKey, chat: keyG, sender: sender(keyG), content: nil
        )
        let replayed = Message.fixture(
            uuid: uuid(2), serverIndex: 1, type: MessageType.contactKey, chat: key2G, sender: sender(key2G), content: nil
        )
        var commit = Storage.Commit(contacts: [(keyG, true), (key2G, true)], messages: [(theirs, true, nil)])
        commit.marksNewContacts = true
        #expect(try storage.apply(commit).addedUs.map(\.chat) == [keyG])
        _ = try storage.apply(Storage.Commit(messages: [(replayed, true, nil)]))
        var rows = try await readStates(storage)
        #expect(rows[keyG]?.isNew == true)
        #expect(rows[key2G]?.isNew == false)
        #expect(try storage.clearNewContact(keyG))
        #expect(try storage.apply(commit).addedUs.isEmpty)
        rows = try await readStates(storage)
        #expect(rows[keyG]?.isNew == false)
    }

    private func readStates(_ storage: Storage) async throws -> [String: ChatReadState] {
        for try await states in storage.readStates() { return states }
        return [:]
    }
}

struct ContactEngineTests {
    let profile = TempProfile()

    private func engine(balanceMsat: UInt64? = 1_000_000, ownInfo: String? = nil) throws -> (Engine, Storage) {
        let storage = try profile.storage()
        var settings: [Setting: String] = [:]
        settings[.balanceMsat] = balanceMsat.map(String.init)
        settings[.contactInfo] = ownInfo
        _ = try storage.apply(Storage.Commit(state: coreContact(key2G, contactKey: key3G), settings: settings))
        return (try testEngine(storage), storage)
    }

    @Test func addingRefusesTribeLinksAndOneself() async throws {
        let (engine, _) = try engine(ownInfo: info)
        await #expect(throws: Engine.Failure.tribeLinkNotContact) {
            try await engine.addContact(code: "sphinx.chat://?action=tribeV2&pubkey=\(key2G)&host=t.example.com")
        }
        await #expect(throws: Engine.Failure.ownContactInfo) { try await engine.addContact(code: info) }
    }

    /// Someone already a contact is not sent another key exchange (and its sats).
    @Test func anExistingContactIsNotAddedAgain() async throws {
        // Nothing is paid, so a zero balance does not matter.
        let (engine, _) = try engine(balanceMsat: 0)
        let result = try await engine.addContact(code: "\(key2G)_\(key3G)_9")
        #expect(result.pubkey == key2G)
        #expect(result.added == false)
    }

    /// Offline, nobody is asked to confirm 5 sats that cannot go.
    @Test func addingSomeoneOfflineAsksNothing() async throws {
        let (engine, _) = try engine()
        try await engine.setPaymentConfirmation(msat: 0)
        await #expect(throws: Engine.Failure.notConnected) { try await engine.addContact(code: "\(strangerKey)_\(key3G)_9") }
    }

    /// An invite the server has not confirmed in time is returned still
    /// sending, not thrown: its payment may have gone, so the form shows it
    /// waiting rather than offering to pay again.
    @Test func anUnconfirmedInviteIsReturnedStillSending() async throws {
        let (engine, storage) = try engine()
        let sending = InviteRecord(
            code: String(repeating: "ab", count: 32), link: "x", amountMsat: 1_000, tag: "t1", status: .sending, createdAt: 1
        )
        let failed = InviteRecord(
            code: String(repeating: "cd", count: 32), link: "y", amountMsat: 1_000, tag: "t2", status: .failed, createdAt: 1
        )
        _ = try storage.apply(Storage.Commit(invites: [sending, failed]))
        let waited = try await engine.confirmedInvite(code: sending.code, wait: .milliseconds(300))
        #expect(waited.status == .sending)
        await #expect(throws: Engine.Failure.inviteFailed) {
            try await engine.confirmedInvite(code: failed.code, wait: .milliseconds(300))
        }
    }

    /// The balance and the connection are checked before anyone is asked
    /// to confirm (always, whatever the threshold; seen against the local
    /// server), and nothing is written before the payment can go.
    @Test func anInviteChecksTheBalanceBeforeAsking() async throws {
        let (engine, storage) = try engine(balanceMsat: 50_000)
        await #expect(throws: Engine.Failure.insufficientBalance) { try await engine.makeInvite(amountMsat: 60_000) }
        await #expect(throws: Engine.Failure.invalidAmount) { try await engine.makeInvite(amountMsat: 0) }
        await #expect(throws: Engine.Failure.notConnected) { try await engine.makeInvite(amountMsat: 1_000) }
        #expect(try storage.listPendingInvites().isEmpty)
    }

    @Test func anInviteWaitsForAKnownBalanceAndRefusesLongNotes() async throws {
        let (engine, _) = try engine(balanceMsat: nil)
        await #expect(throws: Engine.Failure.balanceUnknown) {
            try await engine.makeInvite(amountMsat: 1_000)
        }
        await #expect(throws: Engine.Failure.nicknameTooLong) {
            try await engine.makeInvite(amountMsat: 1_000, nickname: String(repeating: "n", count: 101), confirmedMsat: 1_000)
        }
        await #expect(throws: Engine.Failure.inviteMessageTooLong) {
            try await engine.makeInvite(amountMsat: 1_000, message: String(repeating: "m", count: 501), confirmedMsat: 1_000)
        }
    }

    @Test func cancellingNeedsAWaitingInvite() async throws {
        let (engine, storage) = try engine()
        await #expect(throws: Engine.Failure.noSuchInvite) { try await engine.cancelInvite(code: "00") }
        let used = InviteRecord(
            code: String(repeating: "ef", count: 32), link: "x", amountMsat: 1_000, tag: "t", status: .used, createdAt: 1
        )
        _ = try storage.apply(Storage.Commit(invites: [used]))
        await #expect(throws: Engine.Failure.inviteNotPending) { try await engine.cancelInvite(code: used.code.uppercased()) }
        let ready = InviteRecord(
            code: String(repeating: "aa", count: 32), link: "x", amountMsat: 1_000, tag: "u", status: .ready, createdAt: 1
        )
        _ = try storage.apply(Storage.Commit(invites: [ready]))
        await #expect(throws: Engine.Failure.notConnected) { try await engine.cancelInvite(code: ready.code) }
        #expect(try storage.invite(code: ready.code)?.status == .ready)
        // Only one whose cancel went unanswered can be dropped from the list.
        await #expect(throws: Engine.Failure.inviteNotPending) { try await engine.forgetInvite(code: ready.code) }
        _ = try storage.setInviteStatus(code: ready.code, to: .cancelling, from: [.ready])
        try await engine.forgetInvite(code: ready.code)
        #expect(try storage.invite(code: ready.code)?.status == .cancelled)
    }
}
