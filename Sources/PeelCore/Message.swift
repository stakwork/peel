import Foundation
import GRDB

/// One chat message as stored locally. `sender` and `body` keep the JSON the core
/// produced, so fields we do not model yet are never lost.
public struct Message: Codable, Sendable, Identifiable, Equatable, FetchableRecord {
    /// Where an outgoing message is on its way to the server.
    public enum Delivery: String, Sendable {
        case pending = "PENDING"
        case delivered = "COMPLETE"
        case failed = "FAILED"
    }

    public var id: Int64?
    public var uuid: String?
    /// The server's index for this message, used to page through history.
    public var serverIndex: Int64?
    public var type: Int
    /// Public key of the other side of the conversation.
    public var chat: String
    public var fromMe: Bool
    public var sender: String?
    public var body: String?
    public var content: String?
    public var msat: Int64?
    /// Milliseconds since 1970.
    public var timestamp: Int64?
    /// Identifies an outgoing message until the server confirms it.
    public var tag: String?
    public var paymentHash: String?
    public var status: String?
    /// A tribe message from someone else that mentions this account.
    public var mentionsMe = false
    /// The message this one answers, by uuid (`replyUuid` in the JSON).
    public var replyUUID: String?
    /// The original message of the thread this one is in (`threadUuid`).
    public var threadUUID: String?

    public var date: Date { Date(millisecondsSince1970: timestamp ?? 0) }

    /// Known only for messages we sent.
    public var delivery: Delivery? { status.flatMap(Delivery.init(rawValue:)) }

    /// How long a send may wait for the server before it can be sent again, as
    /// in the official apps.
    public static let confirmationTimeout: TimeInterval = 30

    /// One of our text messages that failed, or that the server has not
    /// confirmed within the timeout, and so may be sent again or discarded.
    public func isRetryable(now: Date = .now) -> Bool {
        guard fromMe, type == MessageType.text else { return false }
        switch delivery {
        case .failed: return true
        case .pending: return now.timeIntervalSince(date) > Self.confirmationTimeout
        case .delivered, nil: return false
        }
    }

    var senderInfo: SenderInfo? {
        sender.flatMap { try? JSONDecoder().decode(SenderInfo.self, from: Data($0.utf8)) }
    }

    /// The name the sender gave. In a tribe this is the member, made unique
    /// within the tribe by the tribes server; the sender pubkey is the tribe's.
    public var senderAlias: String? { senderInfo?.alias?.nilIfEmpty }

    /// The sender's photo, https only.
    public var senderPhotoURL: String? { senderInfo?.photoURL?.httpsOnly }

    /// A text message every member holds under this uuid: anyone else's, or
    /// ours once the tribe's copy (with the tribe's uuid) has come back.
    public var isPinnable: Bool {
        uuid != nil && type == MessageType.text && (!fromMe || delivery == .delivered)
    }
}

/// Message type numbers defined by the core (`MsgType` in the sphinx crate).
public enum MessageType {
    public static let text = 0
    public static let groupJoin = 14
    public static let groupLeave = 15
    /// The owner removing a member; carries the member's key in `member`.
    public static let groupKick = 16
    /// A request to join a private tribe, which goes only to the owner.
    public static let memberRequest = 19
    /// The owner's answers to a request; `replyUuid` names the request.
    public static let memberApprove = 20
    public static let memberReject = 21
    /// The owner deleting the tribe.
    public static let tribeDelete = 22
    /// Every type a tribe conversation shows: text and the membership notes.
    static let shownInChats = [text, groupJoin, groupLeave, groupKick, memberRequest, memberApprove, memberReject, tribeDelete]
    /// This account telling its other devices about a contact.
    public static let contactKeyRecord = 33
}

/// What a message says about who sent it. Self-declared: trust it only when the
/// engine has matched it against the key that decrypted the message.
struct SenderInfo: Decodable {
    let pubkey: String
    let alias: String?
    let photoURL: String?
    /// Set by a tribes server on the joins it forwards.
    let host: String?
    /// Set by a tribes server on what it forwards: 0 when the owner sent it.
    let role: Int?

    enum CodingKeys: String, CodingKey {
        case pubkey, alias, host, role
        case photoURL = "photo_url"
    }
}

/// The fields Peel reads from a message's JSON.
struct BodyFields: Decodable {
    let content: String?
    /// On a message a tribe forwarded: the uuid the sender gave it.
    let originalUuid: String?
    /// On a message a tribe forwarded: when the tribe took it, in milliseconds.
    let date: Int64?
    let replyUuid: String?
    let threadUuid: String?

    static func decode(_ body: String?) -> BodyFields? {
        body.flatMap { try? JSONDecoder().decode(BodyFields.self, from: Data($0.utf8)) }
    }
}

/// A uuid as the core issues them and as `replyUuid`/`threadUuid` must be:
/// the core packs those as exactly 32 bytes, so anything else would make
/// the message unreadable for everyone who receives it.
enum MessageUUID {
    static func isValid(_ uuid: String) -> Bool {
        uuid.utf8.count == 64 && uuid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }

    /// This string if it is an https URL, else nil: photos are never fetched
    /// over anything else.
    public var httpsOnly: String? { URL(string: self)?.scheme?.lowercased() == "https" ? self : nil }
}

extension Date {
    public init(millisecondsSince1970 milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    public var millisecondsSince1970: Int64 {
        Int64(timeIntervalSince1970 * 1000)
    }
}
