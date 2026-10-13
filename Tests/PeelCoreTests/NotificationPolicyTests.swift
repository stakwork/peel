import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

private let server = "chat.sphinx.chat"
private let callLink = "https://chat.sphinx.chat/rooms/sphinx.call.781603422.512"
private let now = Date(timeIntervalSince1970: 1_800_000_000)

struct NotificationPolicyTests {
    private func message(type: Int = MessageType.text, chat: String = "02aa", content: String? = "hi",
                         serverIndex: Int64? = 10, mentionsMe: Bool = false) -> Message {
        var message = Message.fixture(serverIndex: serverIndex, type: type, chat: chat, content: content,
                                      timestamp: Int64((now.timeIntervalSince1970 - 60) * 1000))
        message.mentionsMe = mentionsMe
        return message
    }

    private func kind(_ message: Message) -> NotificationPolicy.Kind? {
        NotificationPolicy.kind(of: message, callServer: server, now: now)
    }

    @Test func whatNotifiesAndAsWhat() {
        #expect(kind(message()) == .message)
        #expect(kind(message(type: MessageType.attachment, content: nil)) == .message)
        // A payment request notifies like a message.
        #expect(kind(message(type: MessageType.invoice, content: nil)) == .paymentRequest)
        #expect(kind(message(type: MessageType.call, content: callLink)) == .call)
        #expect(kind(message(type: MessageType.memberRequest, content: nil)) == .joinRequest)
        // Text that is only a call link is a message; a call that fails the checks is nothing.
        #expect(kind(message(content: callLink)) == .message)
        #expect(kind(message(type: MessageType.call, content: "https://evil.example/rooms/x")) == nil)
        // Payments notify as money, and notes are not news.
        #expect(kind(message(type: MessageType.directPayment)) == nil)
        #expect(kind(message(type: MessageType.boost)) == nil)
        #expect(kind(message(type: MessageType.groupJoin)) == nil)
    }

    @Test func ownDeletedAndBlankNeverNotify() {
        var own = message()
        own.fromMe = true
        var deleted = message()
        deleted.deleted = true
        #expect(kind(own) == nil)
        #expect(kind(deleted) == nil)
        #expect(kind(message(content: " \u{200B}\n")) == nil)
        #expect(kind(message(type: MessageType.call, content: "  ")) == nil)
    }

    @Test func everyUnreadTypeButPaymentsNotifies() {
        for type in MessageType.unreadTypes where !MessageType.payments.contains(type) {
            #expect(kind(message(type: type, content: type == MessageType.call ? callLink : "hi")) != nil)
        }
    }

    @Test func readMarkerOwnershipAndTheChatInView() {
        let read = ChatReadState(chat: "02aa", unread: 0, mentions: 0, muteLevel: 0, lastRead: 10)
        let policy = NotificationPolicy(chatInView: "02bb", readStates: ["02aa": read])
        func notifies(_ message: Message, owns: Bool = false) -> NotificationPolicy.Kind? {
            policy.notifies(message, ownsTribe: owns, callServer: server, now: now)
        }
        #expect(notifies(message(serverIndex: 11)) == .message)
        #expect(notifies(message(serverIndex: 10)) == nil)
        // Not yet given an index by the server: past any marker.
        #expect(notifies(message(serverIndex: nil)) == .message)
        let request = message(type: MessageType.memberRequest, serverIndex: 11)
        #expect(notifies(request) == nil)
        #expect(notifies(request, owns: true) == .joinRequest)
        #expect(notifies(message(chat: "02bb")) == nil)
        #expect(policy.isQuiet("02bb"))
        #expect(!policy.isQuiet("02aa"))
    }

    @Test func aChatsLevelDecidesWhatGetsThrough() {
        let states = [
            "all": ChatReadState(chat: "all", unread: 0, mentions: 0, muteLevel: 0),
            "mentions": ChatReadState(chat: "mentions", unread: 0, mentions: 0, muteLevel: 1),
            "muted": ChatReadState(chat: "muted", unread: 0, mentions: 0, muteLevel: 2),
        ]
        let policy = NotificationPolicy(chatInView: nil, readStates: states)
        func notifies(_ message: Message) -> Bool {
            policy.notifies(message, ownsTribe: true, callServer: server, now: now) != nil
        }
        for type in [MessageType.text, MessageType.invoice, MessageType.call] {
            let content = type == MessageType.call ? callLink : "hi"
            #expect(notifies(message(type: type, chat: "all", content: content)))
            // A call or a request mentions nobody.
            #expect(!notifies(message(type: type, chat: "mentions", content: content)))
            #expect(!notifies(message(type: type, chat: "muted", content: content)))
        }
        #expect(notifies(message(chat: "mentions", mentionsMe: true)))
        #expect(!notifies(message(chat: "muted", mentionsMe: true)))
        // Sats and new contacts mention nobody; a chat with no state is loud.
        #expect(!policy.isQuiet("all"))
        #expect(policy.isQuiet("mentions"))
        #expect(policy.isQuiet("muted"))
        #expect(!policy.isQuiet("unknown"))
    }
}
