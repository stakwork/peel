import Foundation
import PeelCore

/// Who sent something, as `ChatRow.People.sender(of:inTribe:)` names them:
/// you, the contact, or a tribe member by the alias they sent.
public struct Sender: Equatable, Sendable {
    /// What someone who sent no name is called, everywhere.
    public static let unnamed = "Someone"

    /// The name they go by; nil when they sent none.
    public var alias: String?
    public var photoURL: String?
    /// Their colour, on their initials and name.
    public var hue: PersonHue
    public var isMe = false

    /// Their name as a run header shows it: yours is your alias.
    public var name: String { alias ?? (isMe ? "You" : Self.unnamed) }
    /// As quotes and lists name them: you are "You".
    public var label: String { isMe ? "You" : name }
    /// What their avatar's initials come from: "?" with no name.
    public var avatarName: String { alias ?? "?" }
}

extension Sender {
    /// A tribe member as their message names them (decoded from it), for
    /// whatever names someone else in a tribe: the rows, notes, mentions,
    /// notifications. Never you: `People` names you.
    public init(member message: Message) {
        let details = message.senderDetails
        self.init(alias: details.alias, photoURL: details.photoURL,
                  hue: PersonHue(pubkey: message.chat, alias: details.alias, inTribe: true))
    }
}

/// What a reply quotes: the parent and its sender, or a note that it is not here.
public enum Quote: Equatable, Sendable {
    case message(Message, Sender)
    /// The parent is older than this Mac's history, or the link is broken.
    case missing
}

/// One row of a conversation, worked out once per change in a single pass:
/// a message (or a run of one sender's images, or a collapsed thread), a
/// request to join, or a note; in a thread also its original and the
/// "N replies" line. Names and photos are decoded here, once per message.
public struct ChatRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message, request, note
        /// Sats sent in a direct message (type 5).
        case payment
        /// A payment request with its invoice (type 2).
        case paymentRequest
        /// A thread's original that is not stored here.
        case missingOriginal
        /// "N replies" under a thread's original.
        case replies(Int)
    }

    public let id: String
    public var kind: Kind
    /// What actions act on: the newest of an image run (Boost included; a
    /// tile's own menu offers none), the original of a collapsed thread.
    public var message: Message
    /// In a tribe: the member's name and photo show beside their messages.
    public var inTribe: Bool
    /// A run of one sender's images (two or more), oldest first.
    public var images: [Message] = []
    public var summary: ThreadSummary?
    /// The boosts on `message` (the original, for a collapsed thread).
    public var boosts: BoostSummary?
    /// Whether to offer Boost: someone else's boostable message we have not
    /// boosted yet (Tom, 2026-10-07; the official apps offer it again). Our
    /// failed boost on it offers Retry and Discard under it instead; the
    /// engine's `quickBoost` holds the same rule.
    public var canBoost: Bool { message.isBoostable && boosts?.hasOwnBoost != true }
    public var quote: Quote?
    /// For a request to join: whether the owner approved, once answered.
    public var approved: Bool?
    /// For a payment request: its invoice and whether it is paid.
    public var paymentRequest: PaymentRequest?
    /// For a paid attachment: locked, being bought, unlocked, or ours for sale.
    public var purchase: PurchaseState?
    /// A call message (or text that is only a call link) that passed the
    /// checks against the account's call server: drawn as the call card.
    public var call: CallLink?
    /// The first tribe or contact link in the text: drawn as a card under
    /// the text, which shows without it (`MessageLink.card`).
    public var card: MessageLink.Card?
    /// A GIF from Giphy: drawn above its caption, the row's text.
    public var giphy: Giphy?
    public var sender: Sender
    /// In a tribe, someone else's alias as sent; nil in a direct message.
    public var member: String? { inTribe && !sender.isMe ? sender.alias : nil }
    /// The sender's zone when they wrote it, if they shared one: the
    /// message's own offset, else the run's (`AppModel.withSenderZones`).
    /// Never for yours.
    public var senderZone: TimeZone?
    /// The messages the row stands for, oldest first: a run's images, a
    /// collapsed thread's newest, else its own.
    public var shown: [Message] {
        if let latest { return [latest] }
        return images.isEmpty ? [message] : images
    }

    /// Where the row sits in time: a collapsed thread at its newest message.
    public var date: Date
    public var startsDay = false
    /// "New messages" goes above this row: the first incoming one past the
    /// read marker the chat had when it was opened.
    public var startsNew = false
    /// For a collapsed thread: its newest message, which placed the row.
    public var latest: Message?
    public var startsRun = false
    public var endsRun = true

    /// Images sent within this long of each other, by one sender, share a grid.
    public static let imageRunGap: TimeInterval = 60

    /// Who the rows name: you, and in a direct message the contact (a
    /// tribe's members name themselves on their messages).
    public struct People: Sendable {
        public var me: Sender
        public var contact: Sender

        /// The one way a message's sender is named: you, in a tribe the
        /// member (decoded from the message), else the contact.
        public func sender(of message: Message, inTribe: Bool) -> Sender {
            if message.fromMe { return me }
            return inTribe ? Sender(member: message) : contact
        }
    }

    /// The rows of a chat (`threads` collapsed), or of a thread: with
    /// `threadRoot` set, its `original` (or a note that it is missing) and
    /// "N replies" come first. `newAfter` is the read marker that places "New messages".
    public static func rows(
        _ messages: [Message], threads: [String: ThreadSummary] = [:], parents: [String: Message],
        boosts: [String: BoostSummary] = [:], requests: [Int64: PaymentRequest] = [:],
        purchases: [Int64: PurchaseState] = [:], inTribe: Bool, people: People, callServer: String? = nil,
        threadRoot: String? = nil, original: Message? = nil, newAfter: Int64? = nil
    ) -> [ChatRow] {
        var answers: [String: Bool] = [:]
        for message in messages where message.type == MessageType.memberApprove || message.type == MessageType.memberReject {
            if let request = message.replyUUID { answers[request] = message.type == MessageType.memberApprove }
        }
        let boostsOn = { (message: Message) in message.uuid.flatMap { boosts[$0] } }
        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count + 2)
        // A thread's rows start with its original (or, when only its replies
        // are stored, a note in its place) and the reply count.
        if let threadRoot, let anchor = original ?? messages.first {
            rows.append(row(anchor, kind: original == nil ? .missingOriginal : .message, id: "o\(threadRoot)",
                            inTribe: inTribe, people: people))
            rows.append(row(anchor, kind: .replies(messages.count), id: "r\(threadRoot)", inTribe: inTribe, people: people))
        }
        var newAfter = newAfter
        for message in messages {
            // A collapsed thread's row stands for its newest message, which this is.
            let collapsed = message.standsForThread ? message.threadUUID.flatMap { threads[$0] } : nil
            // No row that would draw nothing (blank space under the last
            // row, Tom 2026-10-08), or only "Original message not
            // available": "New messages" goes to the next.
            if message.isBlank, collapsed == nil, boostsOn(message) == nil,
               (quote(message, parents: parents, threadRoot: threadRoot, inTribe: inTribe, people: people) ?? .missing)
                == .missing { continue }
            // What counts as unread (`Storage.readStates`): text, attachments, payments.
            let startsNew = newAfter.map { message.countsAsUnread(after: $0) } ?? false
            if startsNew { newAfter = nil }
            if let summary = collapsed {
                var row = row(summary.original, kind: .message, id: "t\(summary.uuid)", inTribe: inTribe, people: people)
                row.startsNew = startsNew
                row.latest = message
                row.summary = summary
                row.date = message.date
                rows.append(row)
                continue
            }
            let kind: Kind = message.isSaid ? .message
                : message.type == MessageType.directPayment ? .payment
                : message.type == MessageType.invoice ? .paymentRequest
                : message.type == MessageType.memberRequest && !message.fromMe ? .request : .note
            var row = row(message, kind: kind, id: "m\(message.id ?? 0)", inTribe: inTribe, people: people)
            if kind == .message, !startsNew, let last = rows.last,
               last.takes(message, sender: row.sender, boosted: { boostsOn($0) != nil }) {
                rows[rows.count - 1].images = (last.images.isEmpty ? [last.message] : last.images) + [message]
                rows[rows.count - 1].message = message
                continue
            }
            if kind == .message {
                row.quote = quote(message, parents: parents, threadRoot: threadRoot, inTribe: inTribe, people: people)
            }
            if kind == .request { row.approved = message.uuid.flatMap { answers[$0] } }
            row.startsNew = startsNew
            if kind == .paymentRequest { row.paymentRequest = message.id.flatMap { requests[$0] } }
            rows.append(row)
        }
        // Ids are unique by construction; should one ever repeat, the newest
        // row keeps it. A repeated id leaves the lazy list room for a row it
        // never draws: blank space under the newest message.
        var seen = Set<String>()
        rows = rows.reversed().filter { seen.insert($0.id).inserted }.reversed()
        // Every message row, a collapsed thread's and a thread's original included.
        for index in rows.indices where rows[index].kind == .message {
            rows[index].call = callServer.flatMap { CallLink(in: rows[index].message, server: $0) }
            if rows[index].call == nil, !rows[index].message.deleted {
                rows[index].card = MessageLink.card(in: rows[index].message.shownText)
                rows[index].giphy = rows[index].message.giphy
            }
            rows[index].boosts = boostsOn(rows[index].message)
            rows[index].purchase = rows[index].message.id.flatMap { purchases[$0] }
        }
        // Only boosts on our messages are new: above the first of those.
        if let after = newAfter, let index = rows.firstIndex(where: { row in
            row.message.fromMe && (row.boosts?.boosts.contains { !$0.fromMe && ($0.serverIndex ?? -1) > after } ?? false)
        }) {
            rows[index].startsNew = true
        }
        // Runs: one sender, a few minutes apart, on one day. The last of a run
        // shows the time under it; in a tribe the first shows the name.
        for index in rows.indices {
            guard index > 0 else {
                rows[index].startsDay = true
                rows[index].startsRun = true
                continue
            }
            let previous = rows[index - 1], row = rows[index]
            let startsDay = !Calendar.current.isDate(row.date, inSameDayAs: previous.date)
            let startsRun = startsDay || row.startsNew || row.kind != .message || previous.kind != .message
                || row.summary != nil || previous.summary != nil || previous.message.fromMe != row.message.fromMe
                || row.date.timeIntervalSince(previous.date) > 5 * 60 || row.sender.name != previous.sender.name
            rows[index - 1].endsRun = startsRun
            rows[index].startsDay = startsDay
            rows[index].startsRun = startsRun
        }
        return rows
    }

    /// A row for one message, its sender worked out once.
    private static func row(_ message: Message, kind: Kind, id: String, inTribe: Bool, people: People) -> ChatRow {
        ChatRow(id: id, kind: kind, message: message, inTribe: inTribe,
                sender: people.sender(of: message, inTribe: inTribe), date: message.date)
    }

    /// Only text and attachments are quoted, and not one with no words (it
    /// has no row to go to); a reply to the thread's own original is not,
    /// inside that thread. The parent's sender is named here, not while drawing.
    private static func quote(
        _ message: Message, parents: [String: Message], threadRoot: String?, inTribe: Bool, people: People
    ) -> Quote? {
        guard let reply = message.replyUUID, reply != threadRoot else { return nil }
        guard let parent = parents[reply] else { return .missing }
        guard parent.isContent, !parent.isBlank else { return nil }
        return .message(parent, people.sender(of: parent, inTribe: inTribe))
    }

    /// The uuids a jump finds this row by: its own, its run of images', and
    /// the original of its thread. None for a row that is not a message's.
    public var heldUUIDs: [String] {
        guard [.message, .payment, .paymentRequest].contains(kind) else { return [] }
        return ([message.uuid] + images.map(\.uuid) + [summary?.original.uuid]).compactMap { $0 }
    }

    /// Whether this is the row a jump to the message with `uuid` goes to.
    public func holds(_ uuid: String?) -> Bool {
        guard let uuid else { return false }
        return heldUUIDs.contains(uuid)
    }

    /// Whether `next` joins this row's run of images. A run's row carries
    /// only its newest image's boosts, and its tiles offer no Boost, so a
    /// boosted image keeps a row of its own, its chip under it alone.
    private func takes(_ next: Message, sender: Sender, boosted: (Message) -> Bool) -> Bool {
        guard kind == .message, summary == nil, message.attachmentKind == .image, next.attachmentKind == .image,
              (message.content ?? "").isEmpty, message.fromMe == next.fromMe, sender.name == self.sender.name,
              message.replyUUID == next.replyUUID, message.threadUUID == next.threadUUID,
              Self.settled(message), Self.settled(next),
              // A paid image is bought on its own, never in a grid.
              message.attachmentPriceMsat == nil, next.attachmentPriceMsat == nil,
              !boosted(message), !boosted(next),
              next.date.timeIntervalSince(message.date) <= Self.imageRunGap else { return false }
        return true
    }

    /// Not still uploading, sending or failed: those keep their own row and actions.
    private static func settled(_ message: Message) -> Bool {
        guard message.fromMe else { return true }
        return message.uploadState != .pending && message.uploadState != .failed
            && (message.delivery == .delivered || message.delivery == nil)
    }
}
