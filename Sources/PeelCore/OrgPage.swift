import Foundation

/// strut's UI showing one thing alone (`&solo=1`, strut's specs/API.md
/// §14.3): a file through its viewer (`?artifact=`) or an app's page
/// (`?app=`), at the UI's own address on a strut: `/`, or a host's mount
/// such as a swarm's `/lab/`.
public enum StrutUI {
    /// The page at `base` showing `value` as `name` (`artifact` or `app`)
    /// alone; with `key`, the strut's key handed over as `?key=` (Peel's own
    /// strut, on this Mac); with `input`, an app opened at that view (strut's
    /// plans/apps.md §7.1, "Deep links"). Nil for a base that is not a URL's parts.
    public static func page(on base: URL, key: String? = nil, _ name: String, _ value: String, input: String? = nil) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        // The UI's folder with its `/`: without it the host redirects, and a
        // web view does not carry a request's credential across a redirect.
        let path = parts.percentEncodedPath
        parts.percentEncodedPath = path.hasSuffix("/") ? path : path + "/"
        parts.percentEncodedQuery = (key.map { "key=\(encoded($0))&" } ?? "") + "\(name)=\(encoded(value))"
            + (input.map { "&input=\(encoded($0))" } ?? "") + "&solo=1"
        parts.fragment = nil
        return parts.url
    }

    /// `page`, the same page at the view `input` (nil: the app's first),
    /// everything else in its address kept as it is.
    public static func page(_ page: URL, input: String?) -> URL {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return page }
        var items = (parts.percentEncodedQuery ?? "").split(separator: "&").map(String.init).filter { !$0.hasPrefix("input=") }
        if let input {
            // Beside the app it opens, where `page(on:)` puts it.
            let at = items.firstIndex { $0.hasPrefix("app=") }.map { $0 + 1 } ?? items.endIndex
            items.insert("input=\(encoded(input))", at: at)
        }
        parts.percentEncodedQuery = items.joined(separator: "&")
        return parts.url ?? page
    }

    /// Whether `url` is strut's UI itself, in its `folder` (the path it is
    /// served at, with its `/`), rather than a file the strut serves.
    public static func isPage(_ url: URL, in folder: String) -> Bool {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return false }
        return (path.hasSuffix("/") ? path : path + "/") == folder
    }

    /// Only unreserved characters left as they are: `+` would read as a
    /// space to strut's UI (`URLSearchParams`).
    private static func encoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// A link to an app that a page in strut's UI opens (strut's plans/apps.md
/// §7.1, "Deep links"; the kit's `appLink`): `?app=<key>&input=<the app's
/// own query>` on that UI's address. strut's page alone follows one to
/// itself in place, and hands one to another app to its host, which is
/// Peel: as a new window, after the person's click in the page. The input
/// is the app's, carried whole and never read here.
public struct StrutAppLink: Sendable, Equatable {
    /// The app as a deliverable names one: `<name>`, or `@<id>/<name>` for
    /// an org's, perhaps with `@vN`.
    public let app: AgentArtifact.Handle
    /// What it opens with; nil for its first view.
    public let input: String?

    /// The longest input followed, in bytes: a view's address, not a document.
    static let longestInput = 2_048

    public init(app: AgentArtifact.Handle, input: String?) {
        self.app = app
        self.input = input
    }

    /// Where the page that links lives, which says what its names mean: a
    /// page names apps where it lives (strut's `peerAppLink`), and an app on
    /// an org's own peer is that org's to open, never Peel's.
    public enum Source: Sendable, Equatable {
        /// An app of Peel's own strut: a name as written (`@<id>/<name>`
        /// for an org's, through the read-through).
        case own
        /// An org's app read through Peel's strut: a bare name is that
        /// org's; one of its own peers' is no link.
        case peer(String)
        /// An app on the org's own strut (the iPhone): its own apps only.
        case org
    }

    /// The app link `url` is: strut's UI in its `folder` (the path the UI is
    /// served at, with its `/`) naming an app by `?app=`, read from a page
    /// of `source`. Nil for a link to anything else (a run, a job, a file),
    /// an app name strut would refuse, an input past `longestInput`, and an
    /// `app` or `input` given twice or that does not decode: strut and Peel
    /// would each read such a link their own way.
    public init?(_ url: URL, folder: String, from source: Source) {
        guard StrutUI.isPage(url, in: folder), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // As strut's UI reads its address (`URLSearchParams`): `+` is a space.
        func decoded(_ part: Substring) -> String? { part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
        var app: String?
        var input: String?
        for item in (parts.percentEncodedQuery ?? "").split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decoded(pair[0]), name == "app" || name == "input" else { continue }
            guard let value = decoded(pair.count > 1 ? pair[1] : ""), (name == "app" ? app : input) == nil else { return nil }
            if name == "app" { app = value } else { input = value }
        }
        guard let key = app, !key.isEmpty else { return nil }
        if input?.isEmpty == true { input = nil }
        guard (input?.utf8.count ?? 0) <= Self.longestInput else { return nil }
        let named: String
        switch source {
        case .own:
            named = key
        case .peer(let peer):
            guard !key.hasPrefix("@") else { return nil }
            named = "@\(peer)/\(key)"
        case .org:
            guard !key.hasPrefix("@") else { return nil }
            named = key
        }
        guard let handle = AgentArtifact.Handle(app: named) else { return nil }
        self.init(app: handle, input: input)
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

    init(peer: String, query: String, value: String) {
        self.peer = peer
        self.query = query
        self.value = value
    }

    /// A workspace's app, by its name on its own strut.
    public static func app(_ name: String, on peer: String) -> OrgPage {
        OrgPage(peer: peer, query: "app", value: name)
    }

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
