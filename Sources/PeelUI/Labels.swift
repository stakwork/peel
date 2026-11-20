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
        guard complete else { return String(localized: "\((members.count + 1).formatted()) seen", table: "Shared") }
        let count = members.count { !$0.pending }
        return Formatting.count(count, .member)
    }
}

/// Leave and Remove from Peel as every place that offers them words them:
/// the menu, the members panel, the details and the status bar.
extension Tribe.Exit {
    public var title: String {
        switch self {
        case .leave: String(localized: "Leave tribe", table: "Shared")
        case .remove: String(localized: "Remove from Peel", table: "Shared")
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
        case .leave: String(localized: "Leave #\(tribeName)", table: "Shared")
        case .remove: String(localized: "Remove #\(tribeName)", table: "Shared")
        }
    }

    /// What could not be done, after "Could not".
    public var failure: String {
        switch self {
        case .leave: String(localized: "leave the tribe", table: "Shared")
        case .remove: String(localized: "remove the tribe", table: "Shared")
        }
    }
}

extension Message {
    /// A tribe's note of who joined, left or was let in, as its row says
    /// it; `sender` is the row's (`People.sender(of:inTribe:)`).
    public func membershipNote(by sender: Sender) -> String {
        let who = sender.label
        switch type {
        case MessageType.groupLeave: return String(localized: "\(who) left", table: "Shared")
        case MessageType.groupKick: return String(localized: "The owner removed you from this tribe", table: "Shared")
        case MessageType.memberRequest: return String(localized: "You asked to join", table: "Shared")
        // The tribe names the approved member as the sender.
        case MessageType.memberApprove: return String(localized: "\(Sender(member: self).name) was approved", table: "Shared")
        case MessageType.memberReject:
            return fromMe ? String(localized: "You declined a request to join", table: "Shared") : String(localized: "The owner declined your request to join", table: "Shared")
        case MessageType.tribeDelete: return String(localized: "The owner deleted this tribe", table: "Shared")
        default: return String(localized: "\(who) joined", table: "Shared")
        }
    }

    /// The longest control line shown; the sender means it to be short.
    static let controlLineLength = 200

    /// Whether this is drawn as a control message's quiet line
    /// (docs/agent-on-strut.md, "Two kinds of message in the DM"), never a
    /// bubble: only in a direct message, the device channel's (in a tribe
    /// the same metadata leaves a member's message a message), and not one
    /// of ours that failed, which keeps its bubble for Retry and Discard.
    public func isControlLine(inTribe: Bool) -> Bool {
        !inTribe && control != nil && !(fromMe && delivery == .failed)
    }

    /// A control message's line: who sent it, so nobody's text passes for
    /// Peel's own, and its text as the official apps show it, on one line
    /// as a preview shows it; empty when it has no words.
    public func controlLine(by sender: Sender) -> String {
        let text = MessageMarkup.plainText(shownText)
        guard !text.isEmpty else { return "" }
        let line = "\(sender.label): \(text)"
        return line.count > Self.controlLineLength ? String(line.prefix(Self.controlLineLength - 1)) + "…" : line
    }
}

extension PIN {
    /// What a PIN field keeps of what was typed: ASCII digits, at most six.
    public static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(length))
    }

    /// What to show when a PIN was not accepted.
    public static func problem(_ error: any Error) -> String {
        error as? SecretStoreFailure == .wrongPIN ? String(localized: "Wrong PIN. Try again.", table: "Shared") : PeelError.problem(error)
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
            ? String(localized: "It holds sats. Without your twelve words, they're lost for good.", table: "Shared")
            : String(localized: "Without your twelve words, it can't be brought back.", table: "Shared")
    }
}

/// An invite's words, as the Mac's sidebar and detail and the phone's
/// Chats and invite screen say them.
extension InviteRecord {
    /// Beside a pending invite's name: the amount once it can be shared.
    public var shortStatus: String {
        switch status {
        case .sending: String(localized: "Sending…", table: "Shared")
        case .cancelling: String(localized: "Cancelling…", table: "Shared")
        default: Sats.format(msat: amountMsat)
        }
    }

    /// "Made 3 Oct 2026 at 10:02 · waiting to be used".
    public var statusLine: String {
        let made = String(localized: "Made \(Formatting.dateAndTime(created))", table: "Shared")
        return switch status {
        case .sending: String(localized: "Setting up…", table: "Shared")
        case .ready: String(localized: "\(made) · waiting to be used", table: "Shared")
        case .cancelling: String(localized: "Cancelling, sats not back yet", table: "Shared")
        case .cancelled: String(localized: "Cancelled, sats returned", table: "Shared")
        case .used: String(localized: "Used", table: "Shared")
        case .failed: String(localized: "Payment failed", table: "Shared")
        }
    }
}

/// A tribe's details in words, for the Mac's panel and the phone's screen.
extension Tribe {
    /// "Public tribe · Created 3 Oct 2026", the date once the registry answers.
    public func detailsSubtitle(created: Date?) -> String {
        [isPrivate ? String(localized: "Private tribe", table: "Shared") : String(localized: "Public tribe", table: "Shared"), created.map { String(localized: "Created \(Formatting.date($0))", table: "Shared") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "5 sats, back after 2 hours", or None; the time once the registry answers.
    public func escrowLine(millis: Int64?) -> String {
        guard escrowMsat > 0 else { return String(localized: "None", table: "Shared") }
        let amount = Sats.exact(msat: escrowMsat)
        guard let millis, millis > 0 else { return amount }
        let hours = Sats.text(UInt64(millis), unit: Sats.millisecondsPerHour)
        return hours == "1"
            ? String(localized: "\(amount), back after \(hours) hour", table: "Shared")
            : String(localized: "\(amount), back after \(hours) hours", table: "Shared")
    }

    /// What members will read for a name typed for a tribe, only when it
    /// is not what was typed: a tribe alias is only letters, digits and
    /// underscores.
    public static func aliasNote(_ typed: String) -> String? {
        guard let typed = typed.trimmed.nilIfEmpty else { return nil }
        let sent = tribeAlias(typed)
        return sent == typed ? nil : String(localized: "Members see “\(sent)”.", table: "Shared")
    }
}

extension TribeInfo {
    /// "Joining costs 10 sats · 3 sats a message", before joining.
    public var priceLine: String {
        String(localized: "Joining costs \(joinPrice.text) · \(messagePrice.text) a message", table: "Shared")
    }
}

extension ContactCode {
    /// Who the code adds, under its name: an invite adds its inviter.
    public var previewDetail: String {
        if case .invite = self { String(localized: "Adds whoever sent this invite.", table: "Shared") } else { String(localized: "Contact info", table: "Shared") }
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

extension AgentArtifact {
    /// Whether opening it asks first: an app sent in a tribe, where anyone
    /// could have sent it, and which runs with the reader's own access to
    /// its workspace (docs/hive-tribes.md, "Deliverables").
    public func asksBeforeOpening(inTribe: Bool) -> Bool {
        inTribe && handle?.app != nil
    }

    /// What that asks: the app and version the link really opens (its
    /// title is the sender's words), and the workspace as the person reads it.
    public func tribeAppQuestion(on workspace: String) -> String {
        let app = handle?.app.map { "“\($0.name)”" + ($0.version.map { " \($0)" } ?? "") } ?? String(localized: "this app", table: "Shared")
        return String(localized: "Open the app \(app) from \(workspace)? Anyone in the tribe could have sent this link.", table: "Shared")
    }
}
