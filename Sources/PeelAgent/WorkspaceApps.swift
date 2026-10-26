import AgentKit
import Foundation
import PeelCore

// A Stadeum workspace's apps (strut's plans/apps.md §7.4; stakwork/strut#307
// and #308). An app lives on its workspace's strut, with its grants, runs and
// data. Peel's own strut is a window onto it: its read-through lists the apps
// a workspace pinned as tabs (`GET /peers/<id>/apps`), and its UI shows one
// app's page alone (`/?app=@<id>/<name>&solo=1`), framing the page and
// relaying its calls to the workspace with the person's token. The token
// never leaves strut's peers file, and the page never talks to the workspace
// itself.

/// An app a Stadeum workspace pinned as a tab.
public struct WorkspaceApp: Sendable, Hashable, Identifiable {
    /// The workspace: its peer id on Peel's strut, which the person reads as `@<peer>`.
    public let peer: String
    /// The app's name on the workspace's strut; a package prefix keeps its `/`.
    public let name: String
    /// What the person reads: its title, or its name.
    public let title: String
    /// What the app is for, in its own words.
    public let about: String?
    /// Its manifest's icon: a lucide name (`flask-conical`), or nil.
    public internal(set) var icon: String? = nil
    /// The version the workspace serves (`v14`).
    public internal(set) var version: String? = nil
    /// The release held live (`r3`) while the workspace holds one rather
    /// than following its latest version.
    public internal(set) var release: String? = nil
    /// The warnings strut's monitor raised on its live version, about how
    /// its page uses the workspace (strut's `src/apps/monitor.ts`); 0 from
    /// a strut that does not count them.
    public internal(set) var problems = 0

    /// strut's key for it, the `?app=` its UI takes: `@<peer>/<name>`.
    public var id: String { "@\(peer)/\(name)" }
}

extension WorkspaceApp {
    /// One entry of strut's `GET /apps`; nil for one not pinned, or with a
    /// name strut would not have given it.
    public init?(peer: String, json: AgentKit.JSONValue) {
        guard json["pinned"] == .bool(true), let name = json["name"]?.string, AgentArtifact.Handle.isAppName(name) else { return nil }
        self.peer = peer
        self.name = name
        let title = ChatData.clean(json["title"]?.string ?? "", max: ChatData.maxName)
        self.title = title.isEmpty ? name : title
        let about = ChatData.clean(json["description"]?.string ?? "", max: ChatData.maxText)
        self.about = about.isEmpty ? nil : about
        // strut's own words, shown as text (the icon only ever looked up
        // in Peel's table): cleaned as a name is, none when empty.
        func text(_ value: AgentKit.JSONValue?) -> String? {
            let text = ChatData.clean(value?.string ?? "", max: 64)
            return text.isEmpty ? nil : text
        }
        icon = text(json["icon"])
        version = text(json["activeVersion"])
        release = text(json["live"])
        problems = max(json["warnings"]?.int ?? 0, 0)
    }
}

extension AutomationsClient {
    /// The apps `peer` pinned as tabs, in the order its strut lists them,
    /// read through Peel's strut.
    public func pinnedApps(of peer: String) async throws -> [WorkspaceApp] {
        let id = try Self.peerID(peer)
        let apps = try await call("GET", "peers/\(id)/apps", what: "the workspace's apps")["apps"]?.array ?? []
        return apps.compactMap { WorkspaceApp(peer: id, json: $0) }
    }
}

extension MemoryServer {
    /// strut's UI showing `app`'s page and nothing else, with this strut's
    /// key handed over as `?key=` (its UI keeps it for the tab and takes it
    /// out of the address). Peel's own strut only: a home server holds no
    /// workspaces of this Mac's. The address carries the key, so it is
    /// handed to the web view and never shown, logged or kept.
    public func page(of app: WorkspaceApp) -> URL? {
        page("app", app.id)
    }

    /// strut's UI showing a deliverable from the agent's DM alone, as for an
    /// app: a file through its viewer (`?artifact=`, stakwork/strut#314),
    /// an app's page (`?app=`). An org's is read through to it with the
    /// person's token, as an app is.
    public func page(showing handle: AgentArtifact.Handle) -> URL? {
        switch handle {
        case .file(let path): page("artifact", path)
        case .app(let app): page("app", app)
        }
    }

    private func page(_ name: String, _ value: String) -> URL? {
        guard !isHomeServer, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        // Only unreserved characters left as they are: `+` would read as a space.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        parts.path = "/"
        parts.percentEncodedQuery = "key=\(encoded(key))&\(name)=\(encoded(value))&solo=1"
        return parts.url
    }

    /// Whether `url` is on this strut: same scheme, host and port.
    public func serves(_ url: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased()
            && url.port == base.port
    }
}
