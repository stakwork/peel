import Foundation
import PeelCore

/// Where the agent's memory and automations live (`docs/peel-brain.md`):
/// Peel's own strut on this Mac, or the account's home server. An account
/// has exactly one, and a home server is never stood in for by this Mac's.
public enum Brain: Sendable, Equatable {
    case thisMac
    case homeServer(MemoryServer)

    /// The home server's address and key, nil on this Mac.
    public var homeServer: MemoryServer? {
        if case .homeServer(let server) = self { server } else { nil }
    }

    /// The account's choice, kept in `item` (`Profile.brain`): nothing kept
    /// is this Mac. Throws when it cannot be read, so a Keychain that fails
    /// is never taken for "this Mac".
    public static func kept(in item: any SecretItem) throws -> Brain {
        guard let data = try item.read() else { return .thisMac }
        guard let kept = try? JSONDecoder().decode(Kept.self, from: data), let url = URL(string: kept.url),
              let server = MemoryServer(base: url, key: kept.key, home: true) else {
            throw PeelError("The home server Peel kept is not one it can use. Set it again in Account › Brain.")
        }
        return .homeServer(server)
    }

    /// Keeps it in `item`: a home server's address and key, or nothing for this Mac.
    public func keep(in item: any SecretItem) throws {
        switch self {
        case .thisMac: try item.delete()
        case .homeServer(let server):
            try item.write(JSONEncoder().encode(Kept(url: server.base.absoluteString, key: server.key)))
        }
    }

    private struct Kept: Codable {
        let url: String
        let key: String
    }

    /// The home server a pairing link names, as `brain/setup.sh` prints it:
    /// `peel://brain?url=<address, percent-encoded>&key=<STRUT_API_KEY>`.
    /// Nil for any other link, a name given twice, anything else in it, or
    /// an address or key `MemoryServer` refuses.
    public static func pairing(_ link: URL) -> MemoryServer? {
        guard link.scheme?.lowercased() == "peel", link.host?.lowercased() == "brain",
              link.path.isEmpty || link.path == "/", link.user == nil, link.fragment == nil,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 2, Set(items.map(\.name)) == ["url", "key"],
              let address = items.first(where: { $0.name == "url" })?.value, let url = URL(string: address),
              let key = items.first(where: { $0.name == "key" })?.value else { return nil }
        return MemoryServer(base: url, key: key, home: true)
    }
}
