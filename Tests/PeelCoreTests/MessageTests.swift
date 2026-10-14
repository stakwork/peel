import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

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

    @Test func blankIsATextOrCallWithNoWords() {
        #expect(Message.fixture(content: "").isBlank)
        #expect(Message.fixture(content: nil).isBlank)
        #expect(Message.fixture(content: " \n ").isBlank)
        #expect(Message.fixture(content: "\u{200B}\u{FEFF}").isBlank)
        // Ours, unsent: its row offers Retry and Discard.
        #expect(!Message.fixture(fromMe: true, content: "", status: "FAILED").isBlank)
        #expect(!Message.fixture(fromMe: true, content: "", status: "PENDING").isBlank)
        #expect(Message.fixture(fromMe: true, content: "", status: "COMPLETE").isBlank)
        #expect(Message.fixture(type: MessageType.call, content: "").isBlank)
        #expect(!Message.fixture(content: "hi").isBlank)
        // A call Peel cannot join still shows its link as text.
        #expect(!Message.fixture(type: MessageType.call, content: "https://meet.example/x").isBlank)
        // An attachment shows its file, a note and a payment their own lines.
        #expect(!Message.fixture(type: MessageType.attachment, content: "").isBlank)
        #expect(!Message.fixture(type: MessageType.groupJoin, content: "").isBlank)
        #expect(!Message.fixture(type: MessageType.directPayment, content: "").isBlank)
        var deleted = Message.fixture(content: "")
        deleted.deleted = true
        #expect(!deleted.isBlank)
    }

    /// The Mac app's `isBoostActionAllowed`: someone else's message with a
    /// uuid, not a payment, a request or a call.
    @Test func someoneElsesTextOrAttachmentIsBoostable() {
        #expect(Message.fixture().isBoostable)
        #expect(Message.fixture(type: MessageType.attachment, content: "").isBoostable)
        #expect(Message.fixture(type: MessageType.attachment, content: "look").isBoostable)
        // Only words that start with the link: the Mac app's rule.
        #expect(Message.fixture(content: "see https://x.example/sphinx.call.1").isBoostable)
        #expect(!Message.fixture(fromMe: true).isBoostable)
        #expect(!Message.fixture(type: MessageType.attachment, fromMe: true).isBoostable)
        #expect(!Message.fixture(uuid: nil).isBoostable)
        #expect(!Message.fixture(uuid: "").isBoostable)
        var deleted = Message.fixture(type: MessageType.attachment)
        deleted.deleted = true
        #expect(!deleted.isBoostable)
        for type in [MessageType.directPayment, MessageType.invoice, MessageType.call, MessageType.boost,
                     MessageType.groupJoin, MessageType.memberRequest] {
            #expect(!Message.fixture(type: type).isBoostable, "type \(type)")
        }
        // Words that are a call link, on any host, are a call to the Mac app,
        // an attachment's caption too.
        #expect(!Message.fixture(type: MessageType.attachment, content: "https://x.example/sphinx.call.1").isBoostable)
        #expect(!Message.fixture(content: " https://chat.sphinx.chat/rooms/sphinx.call.1 ").isBoostable)
        #expect(!Message.fixture(content: "HTTPS://jitsi.sphinx.chat/sphinx.call.781603422").isBoostable)
    }

    @Test func millisecondDates() {
        let date = Date(millisecondsSince1970: 1_700_000_000_123)
        #expect(date == Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(date.millisecondsSince1970 == 1_700_000_000_123)
        #expect(Message.fixture(timestamp: nil).date == Date(timeIntervalSince1970: 0))
    }
}

