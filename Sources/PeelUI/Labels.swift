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
