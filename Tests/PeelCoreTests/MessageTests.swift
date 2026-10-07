import Foundation
import Testing
@testable import PeelCore

struct MessageTests {
    @Test(arguments: [
        ("PENDING", Message.Delivery.pending),
        ("COMPLETE", .delivered),
        ("FAILED", .failed),
    ])
    func deliveryMapsKnownStatuses(status: String, delivery: Message.Delivery) {
        #expect(Message.fixture(status: status).delivery == delivery)
    }

    @Test func deliveryIsNilForUnknownOrMissingStatus() {
        #expect(Message.fixture(status: nil).delivery == nil)
        #expect(Message.fixture(status: "complete").delivery == nil)
        #expect(Message.fixture(status: "SOMETHING").delivery == nil)
    }

    @Test func senderInfoDecodesTheCoreJSON() throws {
        let message = Message.fixture(sender: #"{"pubkey":"02ab","alias":"Ann","photo_url":"https://x/p.png","extra":1}"#)
        let info = try #require(message.senderInfo)
        #expect(info.pubkey == "02ab")
        #expect(info.alias == "Ann")
        #expect(info.photoURL == "https://x/p.png")
    }

    @Test func senderInfoToleratesMissingOptionalFields() throws {
        let info = try #require(Message.fixture(sender: #"{"pubkey":"02ab"}"#).senderInfo)
        #expect(info.alias == nil)
        #expect(info.photoURL == nil)
    }

    @Test func senderInfoIsNilForBadOrMissingJSON() {
        #expect(Message.fixture(sender: nil).senderInfo == nil)
        #expect(Message.fixture(sender: "not json").senderInfo == nil)
        #expect(Message.fixture(sender: #"{"alias":"no pubkey"}"#).senderInfo == nil)
    }

    @Test func bodyContent() {
        #expect(BodyFields.decode(#"{"content":"hello","amount":0}"#)?.content == "hello")
        #expect(BodyFields.decode(#"{"amount":0}"#)?.content == nil)
        #expect(BodyFields.decode("plain text") == nil)
        #expect(BodyFields.decode(nil) == nil)
    }

    @Test func millisecondDates() {
        let date = Date(millisecondsSince1970: 1_700_000_000_123)
        #expect(date.millisecondsSince1970 == 1_700_000_000_123)
        #expect(Message.fixture(timestamp: nil).date == Date(timeIntervalSince1970: 0))
    }
}

extension Message {
    static func fixture(
        uuid: String? = "uuid-1",
        serverIndex: Int64? = nil,
        type: Int = MessageType.text,
        chat: String = "02aa",
        fromMe: Bool = false,
        sender: String? = nil,
        body: String? = nil,
        content: String? = "hi",
        msat: Int64? = nil,
        timestamp: Int64? = 1_000,
        tag: String? = nil,
        paymentHash: String? = nil,
        status: String? = nil,
        replyUUID: String? = nil,
        threadUUID: String? = nil
    ) -> Message {
        Message(
            id: nil, uuid: uuid, serverIndex: serverIndex, type: type, chat: chat, fromMe: fromMe,
            sender: sender, body: body, content: content, msat: msat, timestamp: timestamp, tag: tag,
            paymentHash: paymentHash, status: status, replyUUID: replyUUID, threadUUID: threadUUID
        )
    }
}
