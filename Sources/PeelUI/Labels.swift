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
