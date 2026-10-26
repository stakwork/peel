import Foundation

/// strut's UI showing one thing alone (`&solo=1`, strut's specs/API.md
/// §14.3): a file through its viewer (`?artifact=`) or an app's page
/// (`?app=`), at the UI's own address on a strut: `/`, or a host's mount
/// such as a swarm's `/lab/`.
public enum StrutUI {
    /// The page at `base` showing `value` as `name` (`artifact` or `app`)
    /// alone; with `key`, the strut's key handed over as `?key=` (Peel's own
    /// strut, on this Mac). Nil for a base that is not a URL's parts.
    public static func page(on base: URL, key: String? = nil, _ name: String, _ value: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        // Only unreserved characters left as they are: `+` would read as a space.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        // The UI's folder with its `/`: without it the host redirects, and a
        // web view does not carry a request's credential across a redirect.
        let path = parts.percentEncodedPath
        parts.percentEncodedPath = path.hasSuffix("/") ? path : path + "/"
        parts.percentEncodedQuery = (key.map { "key=\(encoded($0))&" } ?? "") + "\(name)=\(encoded(value))&solo=1"
        parts.fragment = nil
        return parts.url
    }
}

/// A deliverable from the agent's DM as a device with no strut of its own
/// opens it (the iPhone; strut's specs/DESKTOP.md, "A device with no strut
/// of its own"): on its org's own strut, through that strut's UI showing it
/// alone, with the person's token for the org (`HivePeer`).
public struct OrgPage: Sendable, Equatable {
    /// The org: its peer id, which the person reads as `@<id>`.
    public let peer: String
    /// strut's UI query naming it there: `artifact` (a file) or `app`.
    public let query: String
    /// The file's path or the app's name on the org's strut.
    public let value: String

    /// The page on the org's strut whose UI is at `base` (its peer record's `baseUrl`).
    public func url(on base: URL) -> URL? {
        StrutUI.page(on: base, query, value)
    }
}

extension AgentArtifact.Handle {
    /// Where this opens on its org's own strut. A handle names a deliverable
    /// as the brain's strut reads it through (`/peers/<org>/…`,
    /// `@<org>/<name>`), so that first hop comes off; a second one stays,
    /// for the org's own read-through. Nil for one of the brain's own strut,
    /// which only the brain can reach.
    public var onOrg: OrgPage? {
        guard let peer else { return nil }
        switch self {
        case .file(let path):
            // What follows `/peers/<org>`, starting with its `/`.
            return OrgPage(peer: peer, query: "artifact", value: String(path.dropFirst("/peers/".count + peer.count)))
        case .app(let app):
            // What follows `@<org>/`.
            return OrgPage(peer: peer, query: "app", value: String(app.dropFirst(peer.count + 2)))
        }
    }
}
