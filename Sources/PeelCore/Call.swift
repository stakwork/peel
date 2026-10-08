import Foundation

/// A LiveKit call link as the official apps post them:
/// `https://<call server>/rooms/sphinx.call.<name>`, with `startAudioOnly=true`
/// for an audio call, and `callKey` or `hiveToken` on a Hive call. A message
/// carries it bare (the Mac app) or as `call::{"link":…}` (iOS and Android).
///
/// Anyone can write a call message, so a link is only ever a link that
/// passed these checks against the account's own call server: https (plain
/// http only when that server is this machine), its exact host and port, no
/// credentials or fragment, the path `/rooms/<room>` with a strict room name,
/// and only known query keys. Everything else in it is dropped: `url` and
/// `message` are rebuilt from the parsed parts, never the text received.
public struct CallLink: Sendable, Equatable {
    /// The call server the link was checked against, as `host[:port]`.
    public let server: String
    /// `sphinx.call.` and up to 128 letters, digits, `.`, `_` or `-`: the
    /// Mac and iOS timestamps, Android's milliseconds, a Hive room
    /// (`sphinx.call.-<host>-.<stamp>`) and Peel's random names.
    public let room: String
    /// Only how the call starts (no camera); not a property of the room.
    public let audioOnly: Bool
    /// What a Hive link passes on to the token request: the Mac app's
    /// `callKey`, iOS's `hiveToken`.
    public let callKey: String?
    public let hiveToken: String?
    /// `server` as a URL: https, or http for this machine.
    private let base: URL

    /// The longest message content read as a call.
    static let maxContent = 4096

    /// The link in a call message's content, bare or in the `call::` form;
    /// nil for anything that does not pass the checks.
    public init?(message content: String, server: String) {
        guard let link = Self.linkText(in: content) else { return nil }
        self.init(link: link, server: server)
    }

    /// The call a message links to, as the Mac app reads calls: a call
    /// message, or text that is only a call link. Nil when deleted, and for
    /// anything that does not pass the checks against `server`.
    public init?(in message: Message, server: String) {
        guard !message.deleted, [MessageType.call, MessageType.text].contains(message.type),
              let content = message.content,
              // Most text is no call: skip the parse (a room is never percent-encoded).
              message.type == MessageType.call || content.contains(Self.roomPrefix) else { return nil }
        self.init(message: content, server: server)
    }

    /// What a call message's content links to, unchecked: the `call::`
    /// form's link, or the content itself. A call message that is not a
    /// valid call shows this as plain text.
    public static func linkText(in content: String) -> String? {
        guard content.utf8.count <= maxContent else { return nil }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix) else { return text }
        struct Form: Decodable { let link: String }
        return (try? JSONDecoder().decode(Form.self, from: Data(text.dropFirst(prefix.count).utf8)))?.link
    }

    /// "Audio call" or "Video call", for a preview, when a call message's link (`linkText`)
    /// reads as a room link on any host; nil otherwise. Only a label: whether it
    /// is a call Peel joins is `init(message:server:)`'s to say.
    public static func mode(ofLink link: String) -> String? {
        guard let parts = URLComponents(string: link),
              parts.percentEncodedPath.hasPrefix(roomsPath),
              isRoom(String(parts.percentEncodedPath.dropFirst(roomsPath.count))) else { return nil }
        let audio = parts.queryItems?.contains { $0.name == "startAudioOnly" && $0.value == "true" } == true
        return audio ? "Audio call" : "Video call"
    }

    /// A link on `server` (`host[:port]`), checked as above.
    public init?(link: String, server: String) {
        guard let base = TribeLink.baseURL(server), let scheme = base.scheme, let host = base.host?.lowercased(),
              link.utf8.count <= Self.maxContent, let parts = URLComponents(string: link),
              parts.scheme?.lowercased() == scheme, parts.percentEncodedHost?.lowercased() == host,
              Self.port(parts.port, scheme) == Self.port(base.port, scheme),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix(Self.roomsPath) else { return nil }
        let room = String(parts.percentEncodedPath.dropFirst(Self.roomsPath.count))
        guard Self.isRoom(room) else { return nil }
        var query: [String: String] = [:]
        for item in parts.percentEncodedQueryItems ?? [] where Self.queryKeys.contains(item.name) {
            // The same key twice is a link written to be read two ways.
            guard query[item.name] == nil, let value = item.value?.removingPercentEncoding,
                  item.name == "startAudioOnly" || Self.isToken(value) else { return nil }
            query[item.name] = value
        }
        self.init(
            server: server, base: base, room: room, audioOnly: query["startAudioOnly"] == "true",
            callKey: query["callKey"], hiveToken: query["hiveToken"]
        )
    }

    private init(server: String, base: URL, room: String, audioOnly: Bool, callKey: String?, hiveToken: String?) {
        self.server = server
        self.base = base
        self.room = room
        self.audioOnly = audioOnly
        self.callKey = callKey
        self.hiveToken = hiveToken
    }

    /// A new room on `server` (`host[:port]`) named with 128 random bits
    /// from the system's secure generator, as the words are, where the
    /// official apps' timestamps can be guessed from when a call started.
    /// Peel never makes Hive links.
    public static func new(server: String, audioOnly: Bool) throws -> CallLink {
        guard let base = TribeLink.baseURL(server) else { throw Engine.Failure.unreadableCallServer(server) }
        let name = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        return CallLink(
            server: server, base: base, room: roomPrefix + name, audioOnly: audioOnly, callKey: nil, hiveToken: nil
        )
    }

    /// The link, rebuilt from its parts with every query value strictly
    /// percent-encoded.
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = base.scheme
        parts.host = base.host
        parts.port = base.port
        parts.percentEncodedPath = Self.roomsPath + room
        let items = [
            audioOnly ? URLQueryItem(name: "startAudioOnly", value: "true") : nil,
            callKey.map { URLQueryItem(name: "callKey", value: Self.encoded($0)) },
            hiveToken.map { URLQueryItem(name: "hiveToken", value: Self.encoded($0)) },
        ].compactMap { $0 }
        parts.percentEncodedQueryItems = items.isEmpty ? nil : items
        // Every part was checked or built from a checked value.
        return parts.url!
    }

    /// The content of a call message in the `call::` form iOS and Android
    /// send, which all three official apps read as a call. The link holds
    /// only URL-safe characters, so it needs no JSON escaping.
    public var message: String {
        #"\#(Self.prefix){"link":"\#(url.absoluteString)","recurring":false,"cron":""}"#
    }

    static let prefix = "call::"
    static let roomPrefix = "sphinx.call."
    private static let roomsPath = "/rooms/"
    private static let queryKeys: Set = ["startAudioOnly", "callKey", "hiveToken"]

    static func isRoom(_ room: String) -> Bool {
        guard room.hasPrefix(roomPrefix) else { return false }
        let name = room.utf8.dropFirst(roomPrefix.utf8.count)
        return (1...128).contains(name.count) && name.allSatisfy { isAlphanumeric($0) || "._-".utf8.contains($0) }
    }

    /// A Hive key or token: base64, base64url or JWT characters, at most 2 KB.
    static func isToken(_ value: String) -> Bool {
        (1...2048).contains(value.utf8.count) && value.utf8.allSatisfy { isAlphanumeric($0) || "-._~+/=".utf8.contains($0) }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// Unreserved characters only, so `+`, `/` and `=` are always escaped.
    static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    private static func port(_ port: Int?, _ scheme: String) -> Int {
        port ?? (scheme == "https" ? 443 : 80)
    }
}
