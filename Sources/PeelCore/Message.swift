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
        /// A payment or boost the server handed to the recipient, who has the
        /// message, but that did not settle in the mixer's window; it says
        /// nothing more about it. The sats may never have moved (a local
        /// payment) or may still be in flight (Lightning), so it is neither
        /// delivered nor retried; a later COMPLETE or FAILED still lands.
        case unsettled = "UNSETTLED"
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
    /// For a payment or boost: the msat it moved to or from this account, or,
    /// for one seen without sats (a tribe boost on someone else's message),
    /// the amount the sender declared.
    public var amountMsat: Int64?
    /// The `tz` the sender put in this message's `metadata`, as sent; the
    /// database works it out from `body` (v14), and `senderTimeZone` reads it.
    public var senderTZ: String?
    /// For someone else's payment or boost with sats: whether the server's
    /// payment history shows them arriving (`Storage.reconcile`); nil until
    /// a history fetched after it came has been looked at. False means the
    /// message came but the sats never did (payments review F2).
    public var arrived: Bool?
    /// For a send of ours sent again: when it was first sent (ms; v22).
    public var firstSentAt: Int64?
    /// When a reconnect sent it again by itself (ms; v22).
    public var autoResentAt: Int64?
    /// A control message in a direct message (`control`, v27), as stored:
    /// drawn as a line or not at all, so never unread and never notified.
    public var isControl: Bool?

    public var date: Date { Date(millisecondsSince1970: timestamp ?? 0) }

    /// Known only for messages we sent.
    public var delivery: Delivery? { status.flatMap(Delivery.init(rawValue:)) }

    public var uploadState: Upload? { upload.flatMap(Upload.init(rawValue:)) }

    /// What kind of attachment this is, by its declared type; nil for anything
    /// but an attachment. A download checks the bytes against it.
    public var attachmentKind: AttachmentKind? {
        type == MessageType.attachment && !deleted ? AttachmentKind(mediaType: mediaType) : nil
    }

    var hasMediaKey: Bool { AttachmentFields.decode(body)?.mediaKey?.isEmpty == false }

    /// What a paid attachment costs, in msat, from the price its media token
    /// carries; nil for a free attachment or anything else.
    public var attachmentPriceMsat: UInt64? {
        guard type == MessageType.attachment, let token = AttachmentFields.decode(body)?.mediaToken,
              let sats = MediaToken(token)?.priceSats else { return nil }
        let (msat, overflow) = sats.multipliedReportingOverflow(by: 1000)
        return overflow ? nil : msat
    }

    /// How long a send may wait for the server before it can be sent again, as
    /// in the official apps.
    public static let confirmationTimeout: TimeInterval = 30

    /// How long after sending a payment the server's having no record of it
    /// means it never got it (it records a send as soon as it handles it).
    static let unrecordedPaymentTimeout: TimeInterval = 30 * 60

    /// How long a pending payment of ours counts as waiting for its
    /// recipient (`Storage.waitingMsat`): a week.
    public static let waitingLimit: TimeInterval = 7 * 24 * 60 * 60

    /// One of our text messages or attachments that failed, or that the
    /// server has not confirmed within the timeout, and so may be sent again
    /// or discarded. An attachment still uploading is neither. An
    /// unconfirmed one that may have paid (`mayHavePaid`: a tribe's price)
    /// waits, as a payment or boost does: sending it again would pay twice.
    /// A payment or boost goes again only once it failed, and only if sent
    /// from this Mac, which keeps the sats it sent (`msat`): a row of ours
    /// from history or another device carries none, and Retry would pay the
    /// amount its body declares to its chat, which a message the core only
    /// takes for ours (`Engine.cappedToArrived`) could have chosen. A
    /// payment request moves no money, so it goes again like text.
    public func isRetryable(now: Date = .now) -> Bool {
        guard fromMe, !deleted else { return false }
        if MessageType.payments.contains(type) { return delivery == .failed && msat != nil }
        guard MessageType.resendable.contains(type), uploadState != .pending else { return false }
        switch delivery {
        case .failed: return true
        case .pending: return !mayHavePaid && now.timeIntervalSince(date) > Self.confirmationTimeout
        case .delivered, .unsettled, nil: return false
        }
    }

    /// Ours on its way: faint until the server has it, unless it may be
    /// sent again or is still uploading (those show why instead).
    public func isSending(now: Date = .now) -> Bool {
        delivery == .pending && !isRetryable(now: now) && !(fromMe && uploadState == .pending)
    }

    /// Ours, sent with sats: a payment, boost or purchase, or a message that
    /// paid a tribe's price, that left (it has a tag, written before anything
    /// is published; one with none, such as an attachment's draft, never
    /// left). Until the server says how it went it may have paid, so it is
    /// never sent again and waits for the server (`isRetryable`,
    /// `Storage.mayHavePaidSQL`).
    public var mayHavePaid: Bool {
        fromMe && tag != nil && ((msat ?? 0) > 0 || MessageType.moneySends.contains(type))
    }

    /// How old an undelivered message may be and still go again by itself
    /// when the connection comes back.
    public static let autoResendWindow: TimeInterval = 60 * 60

    /// How long a send of ours may still be on its way with the server
    /// holding no record of it: the mixer records a send only once it has
    /// finished, which for a contact on another server can take a while.
    /// A pending one younger than this is not sent again by itself.
    public static let inFlightLimit: TimeInterval = 2 * 60

    /// When this send of ours was first sent (a resend moves `timestamp`).
    public var firstSent: Date { Date(millisecondsSince1970: firstSentAt ?? timestamp ?? 0) }

    /// One of ours that a reconnect may send again by itself
    /// (`Engine.resendRecent`), once: retryable, never sent again that way
    /// before, first sent at most `autoResendWindow` ago, and of a kind that
    /// moves no money: text, an attachment already uploaded and not for
    /// sale, or a payment request. Nothing that carries sats, so never a
    /// payment, a boost or a tribe message (which pays the tribe's price):
    /// those may have paid, and wait for Retry.
    public func isAutoResendable(now: Date = .now) -> Bool {
        guard isRetryable(now: now), autoResentAt == nil, MessageType.resendable.contains(type), (msat ?? 0) == 0,
              now.timeIntervalSince(firstSent) <= Self.autoResendWindow else { return false }
        guard type == MessageType.attachment else { return true }
        return uploadState == .done && attachmentPriceMsat == nil && BodyFields.decode(body)?.price == nil
    }

    /// One of ours that never went and may be dropped: a retryable send, or
    /// a failed call, which is never sent again (its room would be stale).
    public var isDiscardable: Bool {
        isRetryable() || (notSent && !deleted && type == MessageType.call)
    }

    /// One of ours the server refused or never took.
    public var notSent: Bool { fromMe && delivery == .failed }

    /// Someone else's message that can be boosted, as the Mac app allows it
    /// (`isBoostActionAllowed`): text or an attachment (a paid one, bought or
    /// not, included) with a uuid, never a call or a call link. Payments
    /// and requests, which the Mac app also leaves out, are not content.
    public var isBoostable: Bool {
        !fromMe && !deleted && uuid?.isEmpty == false && isContent && !(content.map(CallLink.isLink) ?? false)
    }

    var senderInfo: SenderInfo? {
        JSON.decode(SenderInfo.self, from: sender)
    }

    /// The name the sender gave. In a tribe this is the member, made unique
    /// within the tribe by the tribes server; the sender pubkey is the tribe's.
    public var senderAlias: String? { senderInfo?.alias?.nilIfEmpty }

    /// The sender's photo, https only.
    public var senderPhotoURL: String? { senderInfo?.photoURL }

    /// Both, decoding the sender once, for code that needs the two together.
    public var senderDetails: (alias: String?, photoURL: String?) {
        let info = senderInfo
        return (info?.alias?.nilIfEmpty, info?.photoURL)
    }

    /// A text message every member holds under this uuid: anyone else's, or
    /// ours once the tribe's copy (with the tribe's uuid) has come back.
    public var isPinnable: Bool {
        uuid != nil && type == MessageType.text && (!fromMe || delivery == .delivered)
    }

    /// Text or an attachment: what people say, as opposed to membership notes.
    public var isContent: Bool { MessageType.content.contains(type) }

    /// What people say, calls included: a message row in a chat rather than
    /// a note, a payment or a request.
    public var isSaid: Bool { isContent || type == MessageType.call }

    /// In a tribe's timeline, whether this message stands for its collapsed
    /// thread: text or an attachment in one, as the timeline counts thread
    /// messages. Anything else in a thread (a call, a payment) is never
    /// hidden by the collapse, so it keeps its own row; taking it for the
    /// thread too would give the thread two rows.
    public var standsForThread: Bool { threadUUID != nil && isContent }

    /// A GIF from Giphy (`giphy::` text), shown as the GIF and its caption.
    public var giphy: Giphy? {
        type == MessageType.text && !deleted ? Giphy(content: content) : nil
    }

    /// The words a row shows, trimmed: the content, for a GIF its caption,
    /// or for a call message the link it carries (all a call Peel cannot
    /// join shows, as plain text).
    public var shownText: String { Self.shownText(type: type, content: content) }

    private static func shownText(type: Int, content: String?) -> String {
        if type == MessageType.text, let giphy = Giphy(content: content) {
            return giphy.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return words(type: type, content: content)
    }

    /// `shownText` of anything but a GIF.
    private static func words(type: Int, content: String?) -> String {
        let text = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard type == MessageType.call else { return text }
        return CallLink.linkText(in: text) ?? text
    }

    /// A text or call message with no words (nothing but spaces or invisible
    /// characters), whatever its status: what the `noWords` column stores
    /// (and keeps through a delete), which unread counts, threads and
    /// previews leave out. A deleted one still shows that it was deleted,
    /// and an attachment its file.
    public var hasNoWords: Bool { !deleted && Self.hasNoWords(type: type, content: content) }

    /// The rule of `hasNoWords` for a message that is not deleted. Raise
    /// `Storage.noWordsVersion` when it changes, and check that
    /// `Storage.markNoWords` still reads every row it could mark.
    static func hasNoWords(type: Int, content: String?) -> Bool {
        // A GIF without a caption still shows its GIF (its content was never blank).
        guard type == MessageType.text || type == MessageType.call, Giphy(content: content) == nil else { return false }
        return words(type: type, content: content).unicodeScalars
            .allSatisfy { $0.properties.isWhitespace || $0.properties.generalCategory == .format }
    }

    /// A message with no words and nothing of its own to show: our own
    /// unsent one still shows its Retry and Discard (any pending or failed
    /// send, not only once `isDiscardable`, so the rows do not change with
    /// the clock).
    public var isBlank: Bool {
        hasNoWords && delivery != .pending && delivery != .failed
    }

    /// Unread past `marker`, as a row counts it (`Storage.readStates` also
    /// counts others' boosts on our messages): someone else's text,
    /// attachment or payment, if it has words and is not a control message.
    public func countsAsUnread(after marker: Int64) -> Bool {
        !fromMe && MessageType.unreadTypes.contains(type) && (serverIndex ?? -1) > marker && !hasNoWords
            && isControl != true
    }

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

    /// One line for a quote, a list or a pin: the text without its markup,
    /// for a GIF "GIF" and its caption, or for an attachment with no
    /// caption what it is ("Image", "File: notes.pdf").
    public var preview: String {
        if deleted { return "Message deleted" }
        if let giphy {
            let caption = MessageMarkup.plainText(giphy.text)
            return caption.isEmpty ? "GIF" : "GIF: \(caption)"
        }
        if type == MessageType.call, let link = content.flatMap(CallLink.linkText(in:)) {
            return CallLink.mode(ofLink: link) ?? MessageMarkup.plainText(link)
        }
        if let text = content.map(MessageMarkup.plainText), !text.isEmpty { return text }
        switch attachmentKind {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf, .text, .file: return "File: \(fileName ?? "file")"
        case nil: return ""
        }
    }
}

extension Message {
    /// The newest reply as a thread's row shows it: its complete text (never
    /// cut), or for a message with no words what it is ("Photo", "Video", "Voice message", "File", "Payment"…).
    public var threadReplyPreview: String {
        if deleted { return "Message deleted" }
        if giphy == nil, let text = content.map(MessageMarkup.plainText), !text.isEmpty {
            return text
        }
        switch type {
        case MessageType.directPayment, MessageType.boost: return "Payment"
        case MessageType.invoice: return "Payment request"
        case MessageType.call: return "Call"
        default: break
        }
        if giphy != nil { return preview }
        switch attachmentKind {
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Voice message"
        case .pdf, .text, .file: return "File"
        case nil: return preview
        }
    }
}

extension Message {
    /// Read by hand: several times faster than `Decodable` on the reads every
    /// write re-runs. Must read every stored property.
    public init(row: Row) throws {
        id = row["id"]
        uuid = row["uuid"]
        serverIndex = row["serverIndex"]
        type = row["type"]
        chat = row["chat"]
        fromMe = row["fromMe"]
        sender = row["sender"]
        body = row["body"]
        content = row["content"]
        msat = row["msat"]
        timestamp = row["timestamp"]
        tag = row["tag"]
        paymentHash = row["paymentHash"]
        status = row["status"]
        mentionsMe = row["mentionsMe"]
        replyUUID = row["replyUUID"]
        threadUUID = row["threadUUID"]
        mediaType = row["mediaType"]
        fileName = row["fileName"]
        fileSize = row["fileSize"]
        upload = row["upload"]
        deleted = row["deleted"]
        amountMsat = row["amountMsat"]
        senderTZ = row["senderTZ"]
        arrived = row["arrived"]
        firstSentAt = row["firstSentAt"]
        autoResentAt = row["autoResentAt"]
        isControl = row["isControl"]
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
    /// Sats sent in a chat, with an optional note in `content`.
    public static let directPayment = 5
    /// Sats sent for a message, named by `replyUuid`; the JSON's `amount` is
    /// what the sender declared.
    public static let boost = 29
    /// The types that carry money to someone in a chat.
    public static let payments = [directPayment, boost]
    /// A payment request in a chat: `{"content": memo, "invoice": bolt11}`.
    /// Its amount and payment hash are read from the invoice, never from
    /// the JSON.
    public static let invoice = 2
    /// The payment of a request, which the core sends with the invoice's
    /// payment (`pay_contact_invoice`): `paymentHash` names the request.
    public static let invoicePayment = 3
    /// Buying a paid attachment: the price, with the attachment's media
    /// token and its uuid (`replyUuid`).
    public static let purchase = 7
    /// The seller's answers: the key (with the same token), or a refund.
    public static let purchaseAccept = 8
    public static let purchaseDeny = 9
    /// Everything of ours that carries sats: never sent twice, tracked until
    /// the server says how it went.
    static let moneySends = payments + [purchase, purchaseDeny]
    /// Types sent again as they were when undelivered: they move no money.
    static let resendable = content + [invoice]
    /// Types that count as unread whoever they are for; a boost counts only
    /// on this account's own message. A request asks something of you, and
    /// so does a call.
    public static let unreadTypes = content + [directPayment, invoice, call]
    /// Types as an SQL `IN` list.
    static func sqlList(_ types: [Int]) -> String { types.map(String.init).joined(separator: ", ") }
    /// Every type a conversation shows: text, attachments, direct payments,
    /// payment requests, calls and the membership notes. Boosts show under
    /// the message they boost.
    static let shownInChats = [text, attachment, directPayment, invoice, call, groupJoin, groupLeave, groupKick, memberRequest, memberApprove, memberReject, tribeDelete]
    /// A call: a LiveKit room link in `content`, bare or in the `call::`
    /// form (`CallLink`). Never `content` or `resendable`: a call is never
    /// sent again, and neither list may change under a migration.
    public static let call = 32
    /// This account telling its other devices about a contact.
    public static let contactKeyRecord = 33
    /// Someone adding this account: the first message of a key exchange,
    /// which the core answers on its own (type 11, `contactKeyConfirmation`).
    /// From someone who used one of our invites, its sender names the code.
    public static let contactKey = 10
    public static let contactKeyConfirmation = 11
    /// What a contact's removal deletes from the server by index, asked
    /// with the account's own key, as the official apps do
    /// (`Chat.getOkKeyMessages`): the key exchange and the money. The rest
    /// goes with everything on the contact's child key.
    static let accountKeyTypes = [invoicePayment, directPayment, purchase, boost, contactKey, contactKeyConfirmation]
}

/// What a message says about who sent it. Self-declared: trust it only when the
/// engine has matched it against the key that decrypted the message.
struct SenderInfo: Decodable {
    let pubkey: String
    let alias: String?
    /// The sender's photo as an https link, already normalised
    /// (`String.recoverablePhotoURL`), or nil.
    let photoURL: String?
    /// Set by a tribes server on the joins it forwards.
    let host: String?
    /// Set by a tribes server on what it forwards: 0 when the owner sent it.
    let role: Int?
    /// On a key exchange (type 10): the invite code the sender joined with.
    let code: String?

    enum CodingKeys: String, CodingKey {
        case pubkey, alias, host, role, code
        case photoURL = "photo_url"
        case photoUrl, senderPic = "sender_pic", senderPicCamel = "senderPic"
    }

    /// Only the pubkey is required: an oddly typed optional field never
    /// costs the message its sender.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pubkey = try c.decode(String.self, forKey: .pubkey)
        alias = try? c.decodeIfPresent(String.self, forKey: .alias)
        host = try? c.decodeIfPresent(String.self, forKey: .host)
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        if let number = try? c.decodeIfPresent(Int.self, forKey: .role) {
            role = number
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .role) {
            role = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            role = nil
        }
        var photo: String?
        for key in [CodingKeys.photoURL, .photoUrl, .senderPic, .senderPicCamel] {
            if let value = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil, let link = value.recoverablePhotoURL {
                photo = link
                break
            }
        }
        photoURL = photo
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
    /// On a payment request (type 2): the bolt11.
    let invoice: String?
    /// On an invoice payment (type 3): the request it pays, as its sender wrote it.
    let paymentHash: String?
    /// On an attachment of ours waiting to upload: the sats it is to be sold
    /// for, kept in the row until the media token carries it; never sent.
    let price: String?

    static func decode(_ body: String?) -> BodyFields? {
        JSON.decode(BodyFields.self, from: body)
    }
}

/// On a payment or boost: the msat the sender says it carries (the core
/// writes it from the amount sent). Read on its own so that an odd value
/// never costs a message its other fields.
enum DeclaredAmount {
    private struct Field: Decodable { let amount: UInt64 }

    static func decode(_ body: String?) -> Int64? {
        JSON.decode(Field.self, from: body).map { Int64(clamping: $0.amount) }
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

    /// A photo link from a message, made usable for recovering the account's
    /// own photo and shown on senders: trimmed, repeated schemes collapsed,
    /// scheme-less and `//host` links given https, http upgraded to https (media hosts serve https),
    /// and percent-encoded when it holds spaces or non-ASCII characters
    /// (existing escapes are kept). Nil if empty or still not https. `httpsOnly` stays strict.
    var recoverablePhotoURL: String? {
        var link = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return nil }
        // Doubled schemes (`https://https://h/x`): the inner URL is the link.
        func hasWebScheme(_ value: String) -> Bool {
            let lower = value.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://")
        }
        func dropScheme(_ value: String) -> String {
            String(value.dropFirst(value.lowercased().hasPrefix("https://") ? "https://".count : "http://".count))
        }
        if link.hasPrefix("//") {
            link = "https:" + link
        } else if !link.contains("://") {
            // Scheme-less `host.tld/path`: a host-like first part with a dot.
            let host = link.prefix { $0 != "/" }
            guard host.contains("."), !host.hasPrefix("."), !host.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "#" })
            else { return nil }
            link = "https://" + link
        }
        while hasWebScheme(link), hasWebScheme(dropScheme(link)) { link = dropScheme(link) }
        if link.lowercased().hasPrefix("http://") { link = "https://" + link.dropFirst("http://".count) }
        // Always, not only when `URL(string:)` already refuses it: on Apple's
        // platforms that initializer tolerates a raw space or accented
        // character, so its nilness is no signal that one is missing.
        // `%` is kept allowed, so an existing escape passes through as is.
        let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%#"))
        guard let encoded = link.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        link = encoded
        guard let url = URL(string: link), !(url.host ?? "").isEmpty else { return nil }
        return link.httpsOnly
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
