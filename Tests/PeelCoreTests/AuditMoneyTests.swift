import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

private let seller = keyG
private let tribe = key2G
private let memesHost = "memes.sphinx.chat"

/// A media token for `host`, priced by its meta's `amt` when given.
private func mediaToken(host: String = memesHost, amt: String? = nil) -> String {
    let meta = amt.map { MediaToken.base64URLEncode(Data("amt=\($0)&ttl=31536000".utf8)) } ?? ""
    return "\(MediaToken.base64URLEncode(Data(host.utf8))).muid1.\(MediaToken.base64URLEncode(Data())).AAAAAA.\(meta).c2ln"
}

/// The money audit (docs/reviews/2026-10-08-audit-keys-money.md): the gate
/// on the paths `MoneyRefusalTests` does not reach (paid attachments, a
/// retried tribe message), and amounts that must never wrap.
struct AuditMoneyTests {
    let profile = TempProfile()

    private func engine(
        balanceMsat: UInt64? = 1_000_000, server: String? = nil, tribes: [Tribe] = [], messages: [Message] = []
    ) throws -> (Engine, Storage) {
        let storage = try profile.storage()
        try storage.save(tribes)
        var settings: [Setting: String] = [.memesHost: memesHost]
        settings[.balanceMsat] = balanceMsat.map(String.init)
        settings[.server] = server
        let state = registeredState.merging(coreContact(seller, contactKey: key3G)) { $1 }
        _ = try storage.apply(Storage.Commit(
            state: state, settings: settings, contacts: [(seller, true)], messages: messages.map { ($0, false, nil) }
        ))
        return (try testEngine(storage), storage)
    }

    private func id(_ n: Int, in chat: String = seller, _ storage: Storage) throws -> Int64 {
        try #require(try storage.message(uuid: uuid(n), in: chat)?.id)
    }

    /// An attachment in the seller's chat; one of ours carries its `key`.
    private func attachment(_ n: Int, token: String, fromMe: Bool = false, key: String? = nil) -> Message {
        let key = key.map { #","mediaKeyForSelf":"\#($0)""# } ?? ""
        return .fixture(
            uuid: uuid(n), type: MessageType.attachment, chat: seller, fromMe: fromMe,
            body: #"{"content":"","mediaToken":"\#(token)","mediaType":"image/jpg"\#(key)}"#, content: "",
            timestamp: Int64(n) * 1_000
        )
    }

    // MARK: Paid attachments

    /// A purchase goes through the same balance and threshold as a payment,
    /// for exactly the price its token names.
    @Test func aPurchaseIsHeldToTheBalanceAndTheThreshold() async throws {
        let (engine, storage) = try engine(balanceMsat: 150_000, messages: [
            attachment(1, token: mediaToken(amt: "200")), attachment(2, token: mediaToken(amt: "120")),
        ])
        await #expect(throws: Engine.Failure.insufficientBalance) {
            try await engine.buyAttachment(messageID: try id(1, storage), confirmedMsat: 200_000)
        }
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 120_000)) {
            try await engine.buyAttachment(messageID: try id(2, storage))
        }
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 120_000)) {
            try await engine.buyAttachment(messageID: try id(2, storage), confirmedMsat: 119_000)
        }
    }

    @Test func aPurchaseWaitsForTheBalance() async throws {
        let (engine, storage) = try engine(balanceMsat: nil, messages: [attachment(1, token: mediaToken(amt: "1"))])
        await #expect(throws: Engine.Failure.balanceUnknown) {
            try await engine.buyAttachment(messageID: try id(1, storage), confirmedMsat: 1_000)
        }
    }

    /// Our own attachment, a free one, and one whose price cannot be counted
    /// in msat are not for sale; one kept on another host is never paid for.
    @Test func onlySomeoneElsesPricedAttachmentFromOurHostIsBought() async throws {
        let (engine, storage) = try engine(messages: [
            attachment(1, token: mediaToken(amt: "50"), fromMe: true),
            attachment(2, token: mediaToken()),
            attachment(3, token: mediaToken(amt: String(UInt64.max))),
            attachment(4, token: mediaToken(host: "memes.example.com", amt: "50")),
            .fixture(uuid: uuid(5), chat: seller, content: "not an attachment"),
        ])
        for n in [1, 2, 3, 5] {
            let id = try id(n, storage)
            await #expect(throws: Engine.Failure.notAPaidAttachment) {
                try await engine.buyAttachment(messageID: id, confirmedMsat: 50_000)
            }
        }
        await #expect(throws: Engine.Failure.untrustedMediaHost("memes.example.com")) {
            try await engine.buyAttachment(messageID: try id(4, storage), confirmedMsat: 50_000)
        }
    }

    /// A purchase already on its way, or one already answered with the key,
    /// is never paid again.
    @Test func aPurchaseIsPaidOnce() async throws {
        let token = mediaToken(amt: "50")
        let purchase = Message.fixture(
            uuid: uuid(2), type: MessageType.purchase, chat: seller, fromMe: true,
            body: #"{"content":"","mediaToken":"\#(token)","replyUuid":"\#(uuid(1))"}"#, timestamp: 2_000,
            tag: "p1", status: "PENDING", amountMsat: 50_000
        )
        let (engine, storage) = try engine(messages: [attachment(1, token: token), purchase])
        let id = try id(1, storage)
        await #expect(throws: Engine.Failure.purchaseInProgress) {
            try await engine.buyAttachment(messageID: id, confirmedMsat: 50_000)
        }
        let accept = Message.fixture(uuid: uuid(3), type: MessageType.purchaseAccept, chat: seller,
                                     body: #"{"mediaToken":"\#(token)","mediaKey":"k"}"#, timestamp: 3_000)
        _ = try storage.apply(Storage.Commit(messages: [(accept, false, nil)]))
        await #expect(throws: Engine.Failure.alreadyBought) {
            try await engine.buyAttachment(messageID: id, confirmedMsat: 50_000)
        }
    }

    /// The seller's side (bug hunt N3): a purchase stored but never
    /// answered (Peel stopped), whose answer failed, or whose answer is
    /// still pending long after it went (it never left), is answered by the
    /// next connection, once; one whose answer may still be on its way, or
    /// that brought too little, is not.
    @Test func aPurchaseOwedItsKeyIsAnsweredOnceByTheNextConnection() async throws {
        let owed = mediaToken(amt: "50"), stuck = mediaToken(amt: "40"), going = mediaToken(amt: "30")
        let dear = mediaToken(amt: "200")
        // The core sends a key only as 32 bytes of hex.
        let key = String(repeating: "42", count: 32)
        func bought(_ n: Int, _ token: String, msat: Int64) -> Message {
            .fixture(uuid: uuid(n), type: MessageType.purchase, chat: seller,
                     body: #"{"content":"","mediaToken":"\#(token)"}"#, msat: msat, timestamp: Int64(n) * 1_000)
        }
        /// Our answer with the key, pending since `sent` (ms).
        func answer(_ n: Int, _ token: String, sent: Int64) -> Message {
            .fixture(uuid: uuid(n), type: MessageType.purchaseAccept, chat: seller, fromMe: true,
                     body: #"{"content":"","mediaKey":"\#(key)","mediaToken":"\#(token)"}"#, timestamp: sent,
                     tag: "answer \(n)", status: Message.Delivery.pending.rawValue)
        }
        let (engine, _) = try engine(messages: [
            attachment(1, token: owed, fromMe: true, key: key), bought(2, owed, msat: 50_000),
            attachment(3, token: stuck, fromMe: true, key: key), bought(4, stuck, msat: 40_000),
            answer(5, stuck, sent: 5_000),
            attachment(6, token: going, fromMe: true, key: key), bought(7, going, msat: 30_000),
            answer(8, going, sent: Date.now.millisecondsSince1970),
            attachment(9, token: dear, fromMe: true, key: key), bought(10, dear, msat: 100_000),
        ])
        /// Our answers' statuses by the token they answer, oldest first.
        func answers() throws -> [String: [String?]] {
            var answers: [String: [String?]] = [:]
            for row in try rows(profile, "SELECT status, body FROM message WHERE type = \(MessageType.purchaseAccept) ORDER BY id") {
                let fields = AttachmentFields.decode(row["body"])
                #expect(fields?.mediaKey == key)
                answers[fields?.mediaToken ?? "", default: []].append(row["status"])
            }
            return answers
        }
        let (pending, failed) = (Message.Delivery.pending.rawValue, Message.Delivery.failed.rawValue)

        // A connection that goes as it answers: the answers fail.
        let gone = goneTransport()
        await engine.useTransportForTesting(gone)
        await engine.answerOwedPurchases(on: gone)
        let first = try answers()
        #expect(first == [owed: [failed], stuck: [pending, failed], going: [pending]])
        await engine.disconnect()

        // The next answers each again, once; never the one still on its
        // way, or the one that brought too little.
        let taking = Transport(publishing: { _, _ in })
        await engine.useTransportForTesting(taking)
        await engine.answerOwedPurchases(on: taking)
        await engine.answerOwedPurchases(on: taking)
        let next = try answers()
        #expect(next == [owed: [failed, pending], stuck: [pending, failed, pending], going: [pending]])
        await engine.disconnect()
    }

    // MARK: Tribe prices

    /// A failed tribe message is sent again only at the price it was first
    /// sent at, never at a price the owner raised since.
    @Test func aRetriedTribeMessageNeverPaysARaisedPrice() async throws {
        let raised = Tribe(pubkey: tribe, pricePerMessageMsat: 10_000)
        let failed = Message.fixture(
            uuid: uuid(1), chat: tribe, fromMe: true, body: #"{"content":"hi"}"#, msat: 3_000, tag: "t1",
            status: Message.Delivery.failed.rawValue
        )
        let (engine, storage) = try engine(tribes: [raised], messages: [failed])
        await #expect(throws: Engine.Failure.tribePriceRose(boost: false)) {
            try await engine.resend(messageID: try id(1, in: tribe, storage))
        }
    }

    /// The price to join (F5) is held to the balance and the threshold, as a
    /// payment: refused over the balance, asked over the threshold, and
    /// nothing recorded until it may go.
    @Test func aJoinIsHeldToTheBalanceAndTheThreshold() async throws {
        let stub = try await HTTPStub { _ in
            #"{"pubkey":"\#(tribe)","route_hint":"0:0:0","name":"Paid","price_to_join":200000}"#
        }
        defer { stub.stop() }
        let link = "sphinx.chat://?action=tribeV2&pubkey=\(tribe)&host=127.0.0.1:\(stub.port)"

        // A loopback tribe link is for an account on a local test stack.
        let (engine, storage) = try engine(balanceMsat: 150_000, server: "mqtt://127.0.0.1:1")
        await #expect(throws: Engine.Failure.insufficientBalance) {
            try await engine.joinTribe(link: link, agreedJoinMsat: 200_000, confirmedMsat: 200_000)
        }
        try storage.set("1000000", for: .balanceMsat)
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 200_000)) {
            try await engine.joinTribe(link: link, agreedJoinMsat: 200_000)
        }
        #expect(try storage.tribes().isEmpty)
        // Confirmed, it goes past the gate to the (absent) connection.
        await #expect(throws: Engine.Failure.notConnected) {
            try await engine.joinTribe(link: link, agreedJoinMsat: 200_000, confirmedMsat: 200_000)
        }
    }

    /// Prices come from the tribes server: a sum that would wrap saturates.
    @Test func aTribesPriceNeverWraps() {
        #expect(Tribe.messageAmount(pricePerMessage: .max, escrow: .max) == UInt64(Int64.max))
        #expect(Tribe.messageAmount(pricePerMessage: -5, escrow: -5) == 3_000)
        #expect(Engine.boostTotalMsat(tipMsat: .max, in: Tribe(pubkey: tribe, pricePerMessageMsat: 1)) == nil)
    }

    // MARK: Amounts

    /// An amount and its fee reserve that would wrap are refused, not wrapped
    /// into a small number that passes.
    @Test func anAmountAndItsReserveNeverWrap() async throws {
        let (engine, _) = try engine(balanceMsat: .max)
        await #expect(throws: Engine.Failure.insufficientBalance) {
            try await engine.checkPayment(.max, .unasked, reserveMsat: 1)
        }
        #expect(Engine.feeReserveMsat(for: .max) == UInt64.max / 100)
    }

    /// A confirmation covers exactly the amount confirmed, and nothing at
    /// or under the threshold asks.
    @Test func aConfirmationCoversExactlyItsAmount() {
        #expect(!Engine.needsConfirmation(100, confirmedMsat: nil, thresholdMsat: 100))
        #expect(Engine.needsConfirmation(101, confirmedMsat: nil, thresholdMsat: 100))
        #expect(Engine.needsConfirmation(101, confirmedMsat: 100, thresholdMsat: 100))
        #expect(Engine.needsConfirmation(101, confirmedMsat: 102, thresholdMsat: 100))
        #expect(!Engine.needsConfirmation(101, confirmedMsat: 101, thresholdMsat: 100))
        #expect(Engine.needsConfirmation(1, confirmedMsat: nil, thresholdMsat: 0))
    }

    /// What a person types for sats, in every amount field and the CLI:
    /// whole, above zero, ASCII, commas and surrounding spaces allowed, and
    /// small enough to count in msat.
    @Test func typedSatsAreWholeASCIIAndCountable() {
        #expect(Sats.msat("1") == 1_000)
        #expect(Sats.msat(" 2,500 ") == 2_500_000)
        #expect(Sats.msat("1,000") == 1_000_000)
        #expect(Sats.msat(String(UInt64.max / 1000)) == UInt64.max / 1000 * 1000)
        for text in [
            "0", "0,000", "-1", "", " ", "1.5", "1e3", "0x10", "abc", "1 000", "\t5\n", "１２", "٣",
            String(UInt64.max / 1000 + 1), String(UInt64.max),
        ] {
            #expect(Sats.msat(text) == nil, "\(text)")
        }
    }
}
