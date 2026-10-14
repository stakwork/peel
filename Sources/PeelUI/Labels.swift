import PeelCore

extension Conversation {
    /// "#tribe" or the contact's name, where a chat is named outside its own header.
    public var title: String { isTribe ? "#\(name)" : name }
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
    /// What to show when a PIN was not accepted.
    public static func problem(_ error: any Error) -> String {
        error as? SecretStoreFailure == .wrongPIN ? "Wrong PIN. Try again." : PeelError.problem(error)
    }
}
