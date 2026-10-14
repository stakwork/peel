import Foundation
import PeelCore

extension Conversation {
    /// "#tribe" or the contact's name, where a chat is named outside its own header.
    public var title: String { isTribe ? "#\(name)" : name }
}

extension TribeMembers {
    /// How many are in the tribe, counted as the Members panel lists them:
    /// for the owner, the tribes server's list ("12 members", requests to
    /// join not counted); for anyone else, who has posted and themself ("4
    /// seen", as its "Seen in #tribe"). Never the registry's `member_count`:
    /// an edit or pin from the official apps drops it, a kick after that
    /// counts down from nothing to 0, and a leave never counts down.
    public var countLabel: String {
        guard complete else { return "\((members.count + 1).formatted()) seen" }
        let count = members.count { !$0.pending }
        return Formatting.count(count, "member")
    }
}

/// Leave and Remove from Peel as every place that offers them words them:
/// the menu, the members panel, the details and the status bar.
extension Tribe.Exit {
    public var title: String {
        switch self {
        case .leave: "Leave tribe"
        case .remove: "Remove from Peel"
        }
    }

    public var systemImage: String {
        switch self {
        case .leave: "rectangle.portrait.and.arrow.right"
        case .remove: "trash"
        }
    }

    /// The second click's words.
    public func confirm(_ tribeName: String) -> String {
        switch self {
        case .leave: "Leave #\(tribeName)"
        case .remove: "Remove #\(tribeName)"
        }
    }

    /// What could not be done, after "Could not".
    public var failure: String {
        switch self {
        case .leave: "leave the tribe"
        case .remove: "remove the tribe"
        }
    }
}

extension Message {
    /// A tribe's note of who joined, left or was let in, as its row says
    /// it; `sender` is the row's (`People.sender(of:inTribe:)`).
    public func membershipNote(by sender: Sender) -> String {
        let who = sender.label
        switch type {
        case MessageType.groupLeave: return "\(who) left"
        case MessageType.groupKick: return "The owner removed you from this tribe"
        case MessageType.memberRequest: return "You asked to join"
        // The tribe names the approved member as the sender.
        case MessageType.memberApprove: return "\(Sender(member: self).name) was approved"
        case MessageType.memberReject:
            return fromMe ? "You declined a request to join" : "The owner declined your request to join"
        case MessageType.tribeDelete: return "The owner deleted this tribe"
        default: return "\(who) joined"
        }
    }
}

extension PIN {
    /// What a PIN field keeps of what was typed: ASCII digits, at most six.
    public static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(length))
    }

    /// What to show when a PIN was not accepted.
    public static func problem(_ error: any Error) -> String {
        error as? SecretStoreFailure == .wrongPIN ? "Wrong PIN. Try again." : PeelError.problem(error)
    }
}

extension AppModel {
    /// What forgetting the account loses without the words: Forget asks for
    /// no proof of them, so a lost PIN can start again. Never how many sats:
    /// the PIN guards that, as a locked notification says only "Sats
    /// received". Never "no sats" either: the balance stored before the PIN
    /// may predate sats received since.
    public static func forgetWarning(holdsSats: Bool) -> String {
        holdsSats
            ? "It holds sats. Without your twelve words, they're lost for good."
            : "Without your twelve words, it can't be brought back."
    }
}

/// An invite's words, as the Mac's sidebar and detail and the phone's
/// Chats and invite screen say them.
extension InviteRecord {
    /// Beside a pending invite's name: the amount once it can be shared.
    public var shortStatus: String {
        switch status {
        case .sending: "Sending…"
        case .cancelling: "Cancelling…"
        default: Sats.format(msat: amountMsat)
        }
    }

    /// "Made 3 Oct 2026 at 10:02 · waiting to be used".
    public var statusLine: String {
        let made = "Made \(Formatting.dateAndTime(created))"
        return switch status {
        case .sending: "Setting up…"
        case .ready: "\(made) · waiting to be used"
        case .cancelling: "Cancelling, sats not back yet"
        case .cancelled: "Cancelled, sats returned"
        case .used: "Used"
        case .failed: "Payment failed"
        }
    }
}

/// A tribe's details in words, for the Mac's panel and the phone's screen.
extension Tribe {
    /// "Public tribe · Created 3 Oct 2026", the date once the registry answers.
    public func detailsSubtitle(created: Date?) -> String {
        [isPrivate ? "Private tribe" : "Public tribe", created.map { "Created \(Formatting.date($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "5 sats, back after 2 hours", or None; the time once the registry answers.
    public func escrowLine(millis: Int64?) -> String {
        guard escrowMsat > 0 else { return "None" }
        let amount = Sats.exact(msat: escrowMsat)
        guard let millis, millis > 0 else { return amount }
        let hours = Sats.text(UInt64(millis), unit: Sats.millisecondsPerHour)
        return "\(amount), back after \(hours) \(hours == "1" ? "hour" : "hours")"
    }

    /// What members will read for a name typed for a tribe, only when it
    /// is not what was typed: a tribe alias is only letters, digits and
    /// underscores.
    public static func aliasNote(_ typed: String) -> String? {
        guard let typed = typed.trimmed.nilIfEmpty else { return nil }
        let sent = tribeAlias(typed)
        return sent == typed ? nil : "Members see \u{201C}\(sent)\u{201D}."
    }
}

extension TribeInfo {
    /// "Joining costs 10 sats · 3 sats a message", before joining.
    public var priceLine: String {
        "Joining costs \(joinPrice.text) · \(messagePrice.text) a message"
    }
}

extension ContactCode {
    /// Who the code adds, under its name: an invite adds its inviter.
    public var previewDetail: String {
        if case .invite = self { "Adds whoever sent this invite." } else { "Contact info" }
    }

    /// Why this code adds nobody though it reads: a tribe link is joined, not added.
    public var addRefusal: String? {
        if case .tribe = self { PeelError.problem(Engine.Failure.tribeLinkNotContact) } else { nil }
    }
}

extension Conversation {
    /// Whether its details offer the time zone switch: a person or a
    /// private tribe; a public tribe never gets your offset.
    public func offersTimeZoneSwitch(tribe: Tribe?) -> Bool {
        !isTribe || tribe?.isPrivate == true
    }
}
