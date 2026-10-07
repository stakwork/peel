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

    public var date: Date { Date(millisecondsSince1970: timestamp ?? 0) }

    /// Known only for messages we sent.
    public var delivery: Delivery? { status.flatMap(Delivery.init(rawValue:)) }

    var senderInfo: SenderInfo? {
        sender.flatMap { try? JSONDecoder().decode(SenderInfo.self, from: Data($0.utf8)) }
    }
}

/// Message type numbers defined by the core (`MsgType` in the sphinx crate).
public enum MessageType {
    public static let text = 0
    /// This account telling its other devices about a contact.
    public static let contactKeyRecord = 33
}

/// What a message says about who sent it. Self-declared: trust it only when the
/// engine has matched it against the key that decrypted the message.
struct SenderInfo: Decodable {
    let pubkey: String
    let alias: String?
    let photoURL: String?

    enum CodingKeys: String, CodingKey {
        case pubkey, alias
        case photoURL = "photo_url"
    }
}

struct BodyFields: Decodable {
    let content: String?

    static func content(of body: String?) -> String? {
        body.flatMap { try? JSONDecoder().decode(BodyFields.self, from: Data($0.utf8)) }?.content
    }
}

extension Date {
    public init(millisecondsSince1970 milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    public var millisecondsSince1970: Int64 {
        Int64(timeIntervalSince1970 * 1000)
    }
}
