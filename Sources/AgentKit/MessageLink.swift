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

    /// The message a tool row's summary names, as a send's does: "Sent to
    /// 'Kate' (chat=… uuid=…)". Nil for a summary that names none. Only
    /// at its very end, where the tool puts it: the same words inside a
    /// name or a message earlier in the line are not taken.
    public init?(summary: String) {
        guard let match = summary.firstMatch(of: /\(chat=([0-9a-f]{66}) uuid=([0-9a-f]{64})\)$/) else { return nil }
        self.init(chat: String(match.1), uuid: String(match.2))
    }

    /// Its address, which `init?(_ url:)` reads back.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/message"
        components.queryItems = [URLQueryItem(name: "chat", value: chat), URLQueryItem(name: "uuid", value: uuid)]
        return components.url
    }

    /// How the model is told to write one.
    public static let instruction = """
        To point the user at a message, link it as [View](https://\(host)/message?chat=<chat id>&uuid=<uuid>), \
        with the chat id and uuid exactly as a tool result gave them.
        """
}
