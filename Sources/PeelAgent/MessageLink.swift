import Foundation

/// A link in the agent's reply to one Sphinx message, by the chat id and
/// uuid a tool result gave: `https://peel.invalid/message?chat=…&uuid=…`.
/// The app opens it in place of the web; `.invalid` never resolves, so the
/// same link anywhere else leads nowhere.
public struct AgentMessageLink: Sendable, Equatable {
    public static let host = "peel.invalid"

    public let chat: String
    public let uuid: String

    public init(chat: String, uuid: String) {
        self.chat = chat
        self.uuid = uuid
    }

    /// The message `url` names; nil for any other link.
    public init?(_ url: URL) {
        guard url.scheme == "https", url.host() == Self.host, url.path() == "/message", url.user == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let chat = items.first(where: { $0.name == "chat" })?.value, !chat.isEmpty,
              let uuid = items.first(where: { $0.name == "uuid" })?.value, !uuid.isEmpty
        else { return nil }
        self.init(chat: chat, uuid: uuid)
    }

    /// How the model is told to write one.
    public static let instruction = """
        To point the user at a message, link it as [View](https://\(host)/message?chat=<chat id>&uuid=<uuid>), \
        with the chat id and uuid exactly as a tool result gave them.
        """
}
