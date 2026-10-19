import Foundation

/// What notifies, and where it stays quiet: the decisions behind the app's
/// local notifications, as the official Mac app makes them, without the
/// notification center. One per decision, made from what the app shows at
/// that moment.
public struct NotificationPolicy: Sendable {
    /// What a message notifies as.
    public enum Kind: Sendable, Equatable {
        /// Text or an attachment.
        case message
        /// Someone asking this account for sats.
        case paymentRequest
        /// A call someone started (`CallLink.isAnnounced`), never a ring.
        case call
        /// A request to join a tribe this account owns.
        case joinRequest
    }

    /// The chat open in front of you: nil while Peel is not the app in
    /// front, is locked, or shows no chat. Nothing notifies for it.
    public var chatInView: String?
    public var readStates: [String: ChatReadState]

    public init(chatInView: String?, readStates: [String: ChatReadState]) {
        self.chatInView = chatInView
        self.readStates = readStates
    }

    /// What a message would notify as, wherever it is: someone else's, not
    /// deleted, with words (`hasNoWords`), not a control message, and of a type that counts as
    /// unread (`MessageType.unreadTypes`), or a join request. A call only
    /// while it is fresh and its link passes the checks against `callServer`.
    /// Payments notify as money, once per arrival, not here.
    public static func kind(of message: Message, callServer: String?, now: Date = .now) -> Kind? {
        guard !message.fromMe, !message.deleted, !message.hasNoWords, message.isControl != true else { return nil }
        if message.isContent { return .message }
        switch message.type {
        case MessageType.invoice: return .paymentRequest
        case MessageType.call: return CallLink.isAnnounced(by: message, server: callServer, now: now) ? .call : nil
        case MessageType.memberRequest: return .joinRequest
        default: return nil
        }
    }

    /// Whether `chat` stays quiet: open in front of you, or its mute level
    /// holds back what arrived (all, only what mentions this account, or
    /// nothing). Sats and new contacts mention nobody.
    public func isQuiet(_ chat: String, mentioningMe: Bool = false) -> Bool {
        chat == chatInView || !(readStates[chat]?.mute ?? .all).notifies(mentioningMe: mentioningMe)
    }

    /// What a message that just arrived notifies as, nil for nothing: one
    /// `kind(of:)` lets through, past its chat's read marker, a join
    /// request only when this account owns the tribe (`ownsTribe`), and
    /// not where it is quiet.
    public func notifies(_ message: Message, ownsTribe: Bool, callServer: String?, now: Date = .now) -> Kind? {
        guard let kind = Self.kind(of: message, callServer: callServer, now: now),
              (message.serverIndex ?? .max) > (readStates[message.chat]?.lastRead ?? -1),
              kind != .joinRequest || ownsTribe,
              !isQuiet(message.chat, mentioningMe: message.mentionsMe) else { return nil }
        return kind
    }
}
