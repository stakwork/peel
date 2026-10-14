import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import GRDB
import Sphinxrs
import Testing
@testable import PeelCore
@testable import PeelTestSupport

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

/// A tribe link on a tribes server.
private let tribe = "sphinx.chat://?action=tribeV2&pubkey=\(key2G)&host=tribes.example.com"

/// Tribe and contact links in message text, for the cards under them.
struct MessageLinkTests {

    @Test func findsATribeLinkInProseAndMarkdown() {
        let expected = TribeLink(tribe).map(MessageLink.tribe)
        #expect(expected != nil)
        #expect(MessageLink.card(in: "Join us: \(tribe).")?.link == expected)
        #expect(MessageLink.card(in: "[our tribe](\(tribe))")?.link == expected)
        #expect(MessageLink.card(in: "<\(tribe)>")?.link == expected)
    }

    @Test func findsContactInfoBareOrShared() {
        #expect(MessageLink.card(in: "add me \(info.uppercased())!")?.link == .contact(info: info))
        #expect(MessageLink.card(in: "sphinx.chat://?action=share_contact&pubKey=\(info)")?.link == .contact(info: info))
        #expect(MessageLink.card(in: "*\(info)*")?.link.pubkey == keyG)
    }

    @Test func takesTheFirstOfSeveral() {
        #expect(MessageLink.card(in: "\(info) then \(tribe)")?.link == .contact(info: info))
        #expect(MessageLink.card(in: "\(tribe) then \(info)")?.link.pubkey == key2G)
    }

    @Test func neverCardsCode() {
        #expect(MessageLink.card(in: "`\(tribe)`") == nil)
        #expect(MessageLink.card(in: "try ``\(info)`` here") == nil)
        #expect(MessageLink.card(in: "```\n\(tribe)\n```") == nil)
        // A link after the code is still read.
        #expect(MessageLink.card(in: "`\(tribe)` or \(info)")?.text == "`\(tribe)` or")
    }

    /// The text shown above the card: the link it stands for taken out.
    @Test(arguments: [
        ("\(tribe)", ""),
        ("  <\(tribe)>.  ", ""),
        ("Join us: \(tribe)", "Join us:"),
        ("Join us: <\(tribe)>.", "Join us:"),
        ("Come and \(tribe)!", "Come and!"),
        ("\(tribe) is where we talk", "is where we talk"),
        ("See \(tribe) today", "See today"),
        ("See (\(tribe)) today", "See today"),
        ("(see \(tribe))", "(see)"),
        ("**\(tribe)** first", "first"),
        ("Hi all\n\(tribe)\nsee you there", "Hi all\nsee you there"),
        ("Links:\n- \(tribe)\n- https://example.com", "Links:\n- https://example.com"),
        ("> \(tribe)", ""),
        ("Join [here](\(tribe)) now", "Join here now"),
        ("[**our tribe**](\(tribe))", "**our tribe**"),
        ("\(tribe) and \(tribe)", "and \(tribe)"),
        ("Join \(tribe)\r\nthanks", "Join\nthanks"),
        ("add me: \(info)", "add me:"),
    ])
    func showsTheTextWithoutItsLink(_ text: String, _ shown: String) {
        #expect(MessageLink.card(in: text)?.text == shown)
    }

    @Test(arguments: [
        "",
        "hello https://example.com",
        "a bare key \(keyG) has no route",
        "sphinx.chat://?action=share_contact&pubKey=\(keyG)",
        "sphinx.chat://?action=tribeV2&pubkey=\(key2G)&host=evil.example.com/path",
        "sphinx.chat://?action=tribeV2&pubkey=\(key2G)&host=user@evil.example.com",
        "sphinx.chat://?action=tribeV2&pubkey=nothex&host=tribes.example.com",
        "sphinx.chat://?action=tribe&uuid=abc&host=tribes.example.com",
        "sphinx.chat://?action=invoice&invoice=lnbc1",
        "https://sphinx.chat/?action=tribeV2&pubkey=\(key2G)&host=tribes.example.com",
        "\(keyG)_\(key3G)_12_3",
    ])
    func ignoresAnythingElse(_ text: String) {
        #expect(MessageLink.card(in: text)?.link == nil)
    }

    @Test func leavesInvitesOut() {
        #expect(MessageLink.card(in: inviteLink())?.link == nil)
    }

    @Test func aLinkCardKeepsOnlyTheLink() throws {
        let link = try #require(TribeLink(tribe + "&extra=1"))
        #expect(link.text == tribe)
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
        #expect(try storage.pendingSendTags(textBefore: .max).isEmpty)
    }

    /// Q2: a funding payment the mixer left unsettled is still on its way.
    /// The invite stays sending, is asked about on the next connect, and
    /// moves once the server has the last word.
    @Test func anUnsettledFundingPaymentLeavesTheInviteSending() throws {
        let storage = try profile.storage()
        let invite = record()
        _ = try storage.apply(Storage.Commit(invites: [invite]))
        _ = try storage.apply(Storage.Commit(statuses: [(invite.tag!, "UNSETTLED")]))
        #expect(try storage.invite(code: invite.code)?.status == .sending)
        #expect(try storage.pendingSendTags(textBefore: 0).map(\.tag) == [invite.tag!])
        _ = try storage.apply(Storage.Commit(statuses: [(invite.tag!, "COMPLETE")]))
        #expect(try storage.invite(code: invite.code)?.status == .ready)
    }

    /// The one forward-only rule: a failed funding payment the server had
    /// after all makes the invite ready, as it would a payment delivered.
    @Test func aFailedInviteTheServerConfirmsAfterAllIsReady() throws {
        let storage = try profile.storage()
        let invite = record(status: .failed)
        _ = try storage.apply(Storage.Commit(invites: [invite]))
        _ = try storage.apply(Storage.Commit(statuses: [(invite.tag!, "UNSETTLED")]))
        #expect(try storage.invite(code: invite.code)?.status == .failed)
        _ = try storage.apply(Storage.Commit(statuses: [(invite.tag!, "COMPLETE")]))
        #expect(try storage.invite(code: invite.code)?.status == .ready)
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

/// Removing a contact (`Engine.deleteContact`): what goes, what stays, and
/// the refusals made before anything is sent.
struct ContactDeleteTests {
    let profile = TempProfile()

    /// `keyG` and `key2G` are people and `key3G` a tribe, each with
    /// messages, a mute level and a time zone switch; `keyG`'s chat has an
    /// attachment, a payment of ours, an invoice paid and its history row.
    private func storage(payment status: Message.Delivery = .delivered) throws -> Storage {
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: key3G)])
        let state = coreContact(keyG, contactKey: key3G).merging(coreContact(key2G, contactKey: key3G)) { $1 }
            .merging(coreContact(key3G, contactKey: nil)) { $1 }
        let attachment = Message.fixture(
            uuid: uuid(3), serverIndex: 3, type: MessageType.attachment, chat: keyG, body: #"{"mediaToken":"x"}"#
        )
        let payment = Message.fixture(
            uuid: uuid(4), type: MessageType.directPayment, chat: keyG, fromMe: true, content: "",
            tag: "t4", status: status.rawValue, amountMsat: 1_000
        )
        let messages = [text(1, chat: keyG), attachment, payment, text(5, chat: key2G), text(6, chat: key3G)]
        _ = try storage.apply(Storage.Commit(
            state: state, contacts: [(keyG, true), (key2G, true)],
            messages: messages.map { ($0, true, nil) }, mutes: [keyG: 2, key2G: 1, key3G: 1],
            payments: [PaymentRecord(rhash: "r1", ts: 1, amountMsat: 1_000, incoming: false, remote: false)]
        ))
        for chat in [keyG, key2G, key3G] {
            try storage.setPreference(.timeZoneSharing, TimeZoneSharing(enabled: false, identifier: nil), for: chat)
        }
        try storage.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO invoice (paymentHash, incoming, bolt11, amountMsat, payee, createdAt, status, chat)
                    VALUES ('h1', 0, 'lnbc1', 1000, ?1, 1, 'COMPLETE', ?1)
                    """,
                arguments: [keyG]
            )
        }
        return storage
    }

    private func count(_ table: String, _ column: String = "chat", is value: String, _ storage: Storage) throws -> Int {
        try storage.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?", arguments: [value]) ?? 0
        }
    }

    @Test func storageRemovesTheChatAndNothingElse() throws {
        let storage = try storage()
        #expect(try storage.deleteContact(keyG).map(\.uuid) == [uuid(3)])
        for (table, column) in [("message", "chat"), ("chatState", "chat"), ("contact", "pubkey")] {
            #expect(try count(table, column, is: keyG, storage) == 0, "\(table)")
            #expect(try count(table, column, is: key2G, storage) == 1, "\(table)")
        }
        // The time zone switch is the account's preference, kept for a contact added again.
        #expect(try storage.chatTimeZone(keyG)?.enabled == false)
        #expect(try count("message", is: key3G, storage) == 1)
        #expect(try count("chatState", is: key3G, storage) == 1)
        let state = try storage.loadCoreState()
        #expect(state["c/\(keyG)"] == nil)
        #expect(state["c/\(key2G)"] != nil && state["c/\(key3G)"] != nil)
        // The money tables are history.
        #expect(try count("invoice", is: keyG, storage) == 1)
        #expect(try count("payment", "rhash", is: "r1", storage) == 1)
    }

    @Test func theEngineForgetsThemAndTheChatLeavesTheList() async throws {
        let storage = try storage()
        let engine = try testEngine(storage)
        try await engine.forgetContact(keyG)
        #expect(try await engine.contacts().map(\.pubkey).sorted() == [key2G, key3G].sorted())
        #expect(await engine.isContact(keyG) == false)
        for try await list in storage.conversations() {
            #expect(list.map(\.chat).sorted() == [key2G, key3G].sorted())
            break
        }
        // A fresh engine reads the same from what was stored.
        #expect(try Engine.contacts(in: storage).map(\.pubkey).sorted() == [key2G, key3G].sorted())
    }

    @Test func refusesATribeAStrangerAndOffline() async throws {
        let storage = try storage()
        let engine = try testEngine(storage)
        for pubkey in [key3G, strangerKey] {
            await #expect(throws: Engine.Failure.notAContact) { try await engine.deleteContact(pubkey) }
        }
        // The server's copy must go first: offline, nothing is removed.
        await #expect(throws: Engine.Failure.notConnected) { try await engine.deleteContact(keyG) }
        #expect(await engine.isContact(keyG))
        #expect(try count("message", is: keyG, storage) == 3)
    }

    @Test func aPaymentStillOnItsWayKeepsTheContact() async throws {
        let storage = try storage(payment: .pending)
        let engine = try testEngine(storage)
        await #expect(throws: Engine.Failure.paymentWithContactPending) { try await engine.deleteContact(keyG) }
        #expect(try count("message", is: keyG, storage) == 3)
        #expect(try storage.hasPendingPayment(in: keyG))
        #expect(try storage.hasPendingPayment(in: key2G) == false)
    }
}

/// Live contact records (type 33), kept only when this account signed them
/// (`Engine.isForeignContactRecord`), with the core's answers made up; the
/// journeys run the real core (`Journeys.Contacts`).
struct ContactRecordTests {
    let profile = TempProfile()

    /// `keyG` holds child key 1 and `key2G` child key 2, both ready.
    private let known = coreContact(keyG, contactKey: key3G, index: 1)
        .merging(coreContact(key2G, contactKey: key3G, index: 2)) { $1 }

    private func engine() throws -> (Engine, Storage) {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(state: known, contacts: [(keyG, true), (key2G, true)]))
        return (try testEngine(storage), storage)
    }

    /// A record naming `target`, read on child key `index` as `receive` reads
    /// a live message, signed by `signer`: by default the key's holder, or
    /// someone else on a key nobody here holds. The core writes the contact
    /// with the record's route and key and gives `target` as the sender (the
    /// bindings hand back the whole state with it); once the record is in
    /// the state it is given, it writes nothing and gives the signer.
    private func receive(naming target: String, index: UInt64, signedBy signer: String? = nil, on engine: Engine) async throws {
        let holder = Engine.index(try Engine.contacts(in: known))[index]
        let entry = coreContact(target, contactKey: strangerKey, lsp: keyG, index: index)
        func record(from pubkey: String, writing state: [String: Data]? = nil) -> RunReturn {
            let msg = Msg(
                message: #"{"content":""}"#, type: UInt8(MessageType.contactKeyRecord), uuid: "r33", tag: nil, index: "5",
                sender: sender(pubkey, alias: "Bob"), msat: nil, timestamp: 1, sentTo: nil, fromMe: false,
                paymentHash: nil, error: nil
            )
            return coreResult(msgs: [msg], state: state)
        }
        let writes = record(from: target, writing: known.merging(entry) { $1 })
        let signed = record(from: signer ?? holder ?? strangerKey)
        try await engine.runLive(expectedSender: holder) { _, state in
            try StateCodec.decode(state)["c/\(target)"] == entry["c/\(target)"] ? signed : writes
        }
    }

    /// Someone else's record changes nothing, whichever key it comes on: the
    /// one its signer holds, the account key, or one nobody here holds.
    @Test(arguments: [
        (key2G, UInt64(1)),        // a contact rewrites another
        (strangerKey, UInt64(1)),  // a contact plants someone new
        (strangerKey, UInt64(0)),  // anyone, on the account key
        (key2G, UInt64(7)),        // rewrites a contact, on a key nobody holds
        (strangerKey, UInt64(7)),  // plants someone new, on a key nobody holds
    ])
    func aRecordSomeoneElseSignedChangesNothing(target: String, index: UInt64) async throws {
        let (engine, storage) = try engine()
        try await receive(naming: target, index: index, on: engine)
        #expect(try storage.loadCoreState() == known)
        #expect(await engine.state == known)
        #expect(try rows(profile, "SELECT * FROM message").isEmpty)
    }

    /// The account's other devices sign with its own key: a record of theirs
    /// adds someone this device does not have yet, or moves a contact to the
    /// child key they gave them (both devices answered the same key exchange,
    /// each on a key of its own).
    @Test(arguments: [strangerKey, key2G])
    func aRecordThisAccountSignedIsKept(target: String) async throws {
        let (engine, storage) = try engine()
        let own = await engine.accountKey
        try await receive(naming: target, index: 7, signedBy: own, on: engine)
        let kept = try #require(Engine.contact(target, in: storage.loadCoreState()))
        #expect(kept.childIndex == 7 && kept.contactKey == strangerKey)
        #expect(await engine.isContact(target))
        #expect(try storage.message(uuid: "r33", in: target) != nil)
    }
}

private extension Engine {
    /// `run` for a live message, its result left on the actor (`RunReturn` is not `Sendable`).
    func runLive(expectedSender: String?, _ call: (_ time: String, _ state: Data) throws -> RunReturn) async throws {
        try await run(expectedSender: expectedSender, live: true, call)
    }
}
