import Foundation
import GRDB

/// The account's own state and configuration. What the person chooses
/// (boost amount, thresholds, time zones, notifications) is a `Preference`;
/// window state (the sidebar's layout) stays here, as pane widths stay in
/// `UserDefaults`.
public enum Setting: String, Sendable {
    case network
    case server
    case deviceID
    case alias
    case photoURL
    case contactInfo
    case balanceMsat
    case clock
    /// "1" while an account brought back from its words still needs its history.
    case needsRestore
    /// The tribes server this account's own tribes are listed on, as `host[:port]`.
    case tribeHost
    /// The memes server attachments go to, as `host[:port]`; `memes.sphinx.chat` when unset.
    case memesHost
    /// The highest server index of a message dropped unstored (from a left
    /// tribe), so catching up does not fetch it again.
    case droppedIndex
    /// The aliases stored tribe messages were last checked for mentions of
    /// this account (`MentionScan`); a change checks them again.
    case mentionScan
    /// The `Storage.noWordsVersion` stored messages were last checked by
    /// for having no words; a new version checks them again.
    case noWordsScan
    /// The call server calls are started on and links are checked against,
    /// as `host[:port]`; `chat.sphinx.chat` when unset.
    case callServer
    /// Which sidebar sections are open and shown in full
    /// (`ChatSections.Layout`, as JSON).
    case sidebarLayout
    /// The invite a new account signed up with (`Engine.Invite`, as JSON):
    /// every register names its code until the server confirms one, and
    /// once online the inviter is added (`Engine.addInviterIfPending`); ""
    /// after. Never logged or shown.
    case invite
}

/// One chat in the sidebar: a contact or a tribe, plus the newest text message or attachment.
public struct Conversation: Codable, Sendable, Identifiable, Equatable, FetchableRecord {
    public var chat: String
    /// The contact's alias or the tribe's name.
    public var alias: String?
    public var photoURL: String?
    public var isTribe: Bool
    public var lastContent: String?
    public var lastTimestamp: Int64?
    public var lastFromMe: Bool?

    public var id: String { chat }

    public var name: String {
        if let alias, !alias.isEmpty { return alias }
        return String(chat.prefix(12))
    }

    public var lastDate: Date? { lastTimestamp.map(Date.init(millisecondsSince1970:)) }
}

/// How loud a chat is allowed to be, as the server stores it.
public enum MuteLevel: Int, Sendable {
    case all = 0
    case mentionsOnly = 1
    case muted = 2

    /// Whether a notification gets through: for everything, only for what
    /// mentions this account (a call, sats or a new contact mention nobody),
    /// or for nothing. `NotificationPolicy.isQuiet` asks it.
    public func notifies(mentioningMe: Bool) -> Bool {
        switch self {
        case .all: true
        case .mentionsOnly: mentioningMe
        case .muted: false
        }
    }
}

/// Unread count and mute level for one chat.
public struct ChatReadState: Codable, Sendable, Equatable, FetchableRecord {
    public var chat: String
    public var unread: Int
    /// Unread messages that mention this account.
    public var mentions: Int
    public var muteLevel: Int
    /// The server index of the newest message read, if any.
    public var lastRead: Int64? = nil
    /// A contact who added this account, live or while it was offline, and
    /// whose chat has not been read on this Mac since. The core accepts them
    /// at once: there is no request to answer.
    public var isNew = false
    /// Someone else's message past the marker, of any type: the server's
    /// badge count and the official apps' unread take every one (joins,
    /// others' boosts), where `unread` takes only what Peel counts. Our own
    /// need no marker: the server moves it to each one we send.
    public var isBehind = false

    public var mute: MuteLevel { MuteLevel(rawValue: muteLevel) ?? .all }

    /// What the sidebar counts: every unread message, only mentions, or
    /// nothing, by the chat's mute level.
    public var shownUnread: Int {
        switch mute {
        case .all: unread
        case .mentionsOnly: mentions
        case .muted: 0
        }
    }

    /// A sidebar row's count: `shownUnread`, except that a muted chat still
    /// counts what mentions this account (Tom, 2026-10-09), as the Mentions
    /// row does. The Dock badge stays `shownUnread`: a muted chat never
    /// counts there.
    public var sidebarCount: Int { mute == .muted ? mentions : shownUnread }

    /// In the sidebar's Unread section (`ChatSections`).
    public var isUnread: Bool { sidebarCount > 0 || isNew }

}

/// What a chat's main conversation shows.
public struct Timeline: Sendable, Equatable {
    /// The newest 200 messages shown, oldest first. In a tribe, a thread of
    /// two or more messages is one row, its newest message (see `threads`);
    /// the rest of the thread and its original are left out.
    public var messages: [Message]
    /// The messages replied to, by uuid, however far back they are.
    public var parents: [String: Message]
    /// The collapsed threads among `messages`, by the original's uuid.
    public var threads: [String: ThreadSummary]

    /// Before the first emission.
    public static let empty = Timeline(messages: [], parents: [:], threads: [:])
    /// The boosts on `messages` and the collapsed threads' originals, by
    /// the boosted message's uuid.
    public var boosts: [String: BoostSummary] = [:]
    /// The payment requests among `messages` (type 2), by row id.
    public var requests: [Int64: PaymentRequest] = [:]
    /// The paid attachments among `messages`, by row id.
    public var purchases: [Int64: PurchaseState] = [:]
}

/// The boosts on one message, summed as the Mac app shows them. Deleted
/// boosts are left out, and our own failed ones are kept apart (`failed`),
/// out of the count and total.
public struct BoostSummary: Sendable, Equatable {
    public struct Boost: Sendable, Equatable {
        /// The booster's name as their message gave it; nil for our own.
        public var alias: String?
        public var photoURL: String?
        public var fromMe: Bool
        public var amountMsat: Int64
        /// For our own boost the server has not confirmed yet: when it went.
        public var pendingSince: Date?
        /// Our own boost the server passed on but never settled (`Delivery.unsettled`).
        public var unsettled = false
        /// Where it sits against the read marker.
        public var serverIndex: Int64?
    }

    /// Oldest first.
    public var boosts: [Boost] = []
    /// Our own boosts on it that failed, oldest first: each may be sent
    /// again or discarded.
    public var failed: [Message] = []
    /// When our oldest unconfirmed boost on it went, if one is.
    public var pendingSince: Date? { boosts.compactMap(\.pendingSince).min() }

    public var count: Int { boosts.count }
    public var totalMsat: Int64 { boosts.reduce(0) { $0 &+ $1.amountMsat } }
    public var boostedByMe: Bool { boosts.contains(where: \.fromMe) }
    /// Any boost of ours on it, failed ones included (`Engine.quickBoost`
    /// boosts a message once).
    public var hasOwnBoost: Bool { boostedByMe || !failed.isEmpty }
    /// Our own boosts on it the server passed on but never settled.
    public var unsettled: [Boost] { boosts.filter(\.unsettled) }
}

/// One thread: the message that started it and what has been said in it.
public struct ThreadSummary: Sendable, Identifiable, Equatable {
    public var original: Message
    /// Messages in the thread, not counting the original.
    public var count: Int
    public var lastTimestamp: Int64?
    /// Other people's thread messages past the chat's read marker.
    public var unread: Int
    /// The newest thread message.
    public var latest: Message?
    /// Who wrote in the thread, most recent first, at most three.
    public var participants: [ThreadParticipant] = []

    public var chat: String { original.chat }
    /// The original's uuid, which every message in the thread names.
    public var uuid: String { original.uuid ?? "" }
    public var id: String { "\(chat)/\(uuid)" }
    public var lastDate: Date? { lastTimestamp.map(Date.init(millisecondsSince1970:)) }
}

/// A thread as its own view shows it.
public struct ChatThread: Sendable, Equatable {
    /// Nil until the original is stored (it may come later in history).
    public var original: Message?
    /// The newest 200 thread messages, oldest first.
    public var messages: [Message]
    /// The messages replied to inside the thread, by uuid.
    public var parents: [String: Message]
    /// The boosts on the original and `messages`, by the boosted uuid.
    public var boosts: [String: BoostSummary] = [:]
    /// The paid attachments among the original and `messages`, by row id.
    public var purchases: [Int64: PurchaseState] = [:]
}
