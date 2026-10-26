import Foundation
import PeelCore

/// Where the agent's memory and automations live (`docs/peel-brain.md`):
/// Peel's own strut on this Mac, or the account's home server. An account
/// has exactly one, and a home server is never stood in for by this Mac's.
/// Peel Home moved to a home server (`PeelHomeMove`) is the third: this
/// Mac's strut and bridge are never started while it is kept.
public enum Brain: Sendable, Equatable {
    case thisMac
    case homeServer(MemoryServer)
    case moved(MovedHome)

    /// The home server's address and key, nil on this Mac.
    public var homeServer: MemoryServer? {
        if case .homeServer(let server) = self { server } else { nil }
    }

    /// Where Peel Home went, nil while it is on this Mac or with the old home server mode.
    public var moved: MovedHome? {
        if case .moved(let home) = self { home } else { nil }
    }

    /// The account's choice, kept in `item` (`Profile.brain`): nothing kept
    /// is this Mac. Throws when it cannot be read, so a Keychain that fails
    /// is never taken for "this Mac".
    public static func kept(in item: any SecretItem) throws -> Brain {
        guard let data = try item.read() else { return .thisMac }
        let kept = try? JSONDecoder().decode(Kept.self, from: data)
        // Moved, and nothing else: a record mixing both is not one Peel wrote.
        if let moved = kept?.moved, kept?.url == nil, kept?.key == nil { return .moved(moved) }
        guard let kept, kept.moved == nil, let url = kept.url.flatMap(URL.init(string:)), let key = kept.key,
              let server = MemoryServer(base: url, key: key, home: true) else {
            throw PeelError("The home server Peel kept is not one it can use. Set it again in Account › Brain.")
        }
        return .homeServer(server)
    }

    /// Keeps it in `item`: a home server's address and key, where Peel Home
    /// moved, or nothing for this Mac.
    public func keep(in item: any SecretItem) throws {
        switch self {
        case .thisMac: try item.delete()
        case .homeServer(let server):
            try item.write(JSONEncoder().encode(Kept(url: server.base.absoluteString, key: server.key)))
        case .moved(let home):
            try item.write(JSONEncoder().encode(Kept(moved: home)))
        }
    }

    private struct Kept: Codable {
        var url: String?
        var key: String?
        var moved: MovedHome?
    }

    /// The home server a pairing link names, as `brain/setup.sh` prints it:
    /// `peel://brain?url=<address, percent-encoded>&key=<STRUT_API_KEY>`.
    /// Nil for any other link, a name given twice, anything else in it, or
    /// an address or key `MemoryServer` refuses.
    public static func pairing(_ link: URL) -> MemoryServer? {
        guard let values = peelLink(link, host: "brain", names: ["url", "key"]),
              let url = values["url"].flatMap(URL.init(string:)), let key = values["key"] else { return nil }
        return MemoryServer(base: url, key: key, home: true)
    }
}

/// The values of a `peel://<host>?…` link that names exactly `names`, each
/// once, and nothing else: no path, user or fragment. Nil for any other
/// link. Any page can open one, so each kind is read only through here.
func peelLink(_ link: URL, host: String, names: Set<String>) -> [String: String]? {
    guard link.scheme?.lowercased() == "peel", link.host?.lowercased() == host,
          link.path.isEmpty || link.path == "/", link.user == nil, link.fragment == nil,
          let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
          items.count == names.count, Set(items.map(\.name)) == names else { return nil }
    var values: [String: String] = [:]
    for item in items {
        guard let value = item.value else { return nil }
        values[item.name] = value
    }
    return values
}

/// Peel Home on a home server (`PeelHomeMove`): where it went and when,
/// whether the agent has answered from there, and this Mac's copy of its
/// folders, kept under the names they were set aside as.
public struct MovedHome: Codable, Sendable, Equatable {
    /// The box's address, from the link (`HomeLink.host`).
    public var host: String
    public var date: Date
    /// The agent answered from the box. Until it has, the move may or may
    /// not have arrived: this Mac's strut and bridge stay stopped all the same.
    public var answered: Bool
    /// This Mac's copy of strut's and the bridge's folders, by their names
    /// beside the originals (`Strut.moved-<date>`); nil until they are set aside.
    public var strutCopy: String?
    public var bridgeCopy: String?

    public init(host: String, date: Date, answered: Bool = false, strutCopy: String? = nil, bridgeCopy: String? = nil) {
        self.host = host
        self.date = date
        self.answered = answered
        self.strutCopy = strutCopy
        self.bridgeCopy = bridgeCopy
    }
}
