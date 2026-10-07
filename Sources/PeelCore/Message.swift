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

    /// Where an outgoing attachment is on its way to the memes server.
    public enum Upload: String, Sendable {
        case pending = "PENDING"
        case done = "DONE"
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
    /// For an attachment: its declared MIME type.
    public var mediaType: String?
    /// For an attachment: the file name and decrypted size, once known (ours
    /// from the start, someone else's after a download).
    public var fileName: String?
    public var fileSize: Int64?
    /// For an attachment of ours: whether the memes server has it yet.
    public var upload: String?
    /// Deleted for everyone by its sender (or a tribe's owner): the row stays
    /// for the conversation's shape, its content and key are gone.
    public var deleted = false

    public var date: Date { Date(millisecondsSince1970: timestamp ?? 0) }

    /// Known only for messages we sent.
    public var delivery: Delivery? { status.flatMap(Delivery.init(rawValue:)) }

    public var uploadState: Upload? { upload.flatMap(Upload.init(rawValue:)) }

    /// What kind of attachment this is, by its declared type; nil for anything
    /// but an attachment. A download checks the bytes against it.
    public var attachmentKind: AttachmentKind? {
        type == MessageType.attachment && !deleted ? AttachmentKind(mediaType: mediaType) : nil
    }

    /// How long a send may wait for the server before it can be sent again, as
    /// in the official apps.
    public static let confirmationTimeout: TimeInterval = 30

    /// One of our text messages or attachments that failed, or that the
    /// server has not confirmed within the timeout, and so may be sent again
    /// or discarded. An attachment still uploading is neither.
    public func isRetryable(now: Date = .now) -> Bool {
        guard fromMe, MessageType.content.contains(type), uploadState != .pending else {
            return false
        }
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

    /// Both, decoding the sender once, for code that needs the two together.
    public var senderDetails: (alias: String?, photoURL: String?) {
        let info = senderInfo
        return (info?.alias?.nilIfEmpty, info?.photoURL?.httpsOnly)
    }

    /// A text message every member holds under this uuid: anyone else's, or
    /// ours once the tribe's copy (with the tribe's uuid) has come back.
    public var isPinnable: Bool {
        uuid != nil && type == MessageType.text && (!fromMe || delivery == .delivered)
    }

    /// Text or an attachment: what people say, as opposed to membership notes.
    public var isContent: Bool { MessageType.content.contains(type) }

    /// Whether a reply or a thread message can name this one: text or an
    /// attachment that others hold under the same uuid. Our own must have
    /// been delivered (a retry gives it a new uuid), and in a tribe it must
    /// have come back from the tribe, whose uuid the row then takes (only
    /// that copy has a server index; a tribe send has no copy to self).
    public func isLinkable(inTribe: Bool) -> Bool {
        guard let uuid, MessageUUID.isValid(uuid), MessageType.content.contains(type), !deleted else { return false }
        // Restored history has no status: only a pending or failed one counts.
        let undelivered = delivery == .pending || delivery == .failed
        return !fromMe || !(undelivered || (inTribe && serverIndex == nil))
    }

    /// Whether this account may delete it for everyone, as the Mac app
    /// allows: its own, or anyone's in a tribe it owns, sent and not yet
    /// deleted, and not a thread's original while the thread has two or more
    /// messages (`threadCount`, from `Storage.threadCount`).
    public func isDeletable(inTribe: Bool, ownsTribe: Bool, threadCount: Int) -> Bool {
        (fromMe || ownsTribe) && isLinkable(inTribe: inTribe) && threadCount < 2
    }

    /// The thread this message is in, or the one it starts, as the Mac app
    /// works it out (`threadUuid ?? replyUuid ?? uuid`). Its own links came
    /// from whoever sent it; one the core could not pack is skipped.
    public var threadRoot: String {
        [threadUUID, replyUUID].compactMap { $0 }.first(where: MessageUUID.isValid) ?? uuid ?? ""
    }

    /// One line for a quote, a list or a pin: the text, or for an
    /// attachment with no caption what it is ("Image", "File: notes.pdf").
    public var preview: String {
        if deleted { return "Message deleted" }
        if let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        switch attachmentKind {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf, .text, .file: return "File: \(fileName ?? "file")"
        case nil: return ""
        }
    }
}

/// Someone who wrote in a thread, for the avatars on its summary.
public struct ThreadParticipant: Sendable, Equatable, Hashable {
    public var alias: String?
    public var photoURL: String?
    public var fromMe: Bool
}

/// Message type numbers defined by the core (`MsgType` in the sphinx crate).
public enum MessageType {
    public static let text = 0
    /// A file on the memes server; the message carries its token and key.
    public static let attachment = 6
    /// What people say to each other: text and attachments. These count as
    /// unread, end a conversation's preview, and can be sent again.
    static let content = [text, attachment]
    static let contentSQL = content.map(String.init).joined(separator: ", ")
    public static let groupJoin = 14
    public static let groupLeave = 15
    /// The owner removing a member; carries the member's key in `member`.
    public static let groupKick = 16
    /// Deletes the message `replyUuid` names, for everyone: sent by its
    /// sender, or in a tribe by the owner (the official apps' type 17).
    public static let delete = 17
    /// A request to join a private tribe, which goes only to the owner.
    public static let memberRequest = 19
    /// The owner's answers to a request; `replyUuid` names the request.
    public static let memberApprove = 20
    public static let memberReject = 21
    /// The owner deleting the tribe.
    public static let tribeDelete = 22
    /// Every type a tribe conversation shows: text and the membership notes.
    static let shownInChats = [text, attachment, groupJoin, groupLeave, groupKick, memberRequest, memberApprove, memberReject, tribeDelete]
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

    /// This string with line breaks, tabs and other control characters removed.
    var withoutControlCharacters: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    }

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
