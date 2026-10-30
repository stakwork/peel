import AgentKit
import Foundation
import PeelCore

// A Stadeum workspace's apps on the Mac (PeelCore's `WorkspaceApp`): Peel's
// own strut is a window onto them. Its read-through lists the apps a
// workspace pinned as tabs (`GET /peers/<id>/apps`), and its UI shows one
// app's page alone (`/?app=@<id>/<name>&solo=1`), framing the page and
// relaying its calls to the workspace with the person's token. The token
// never leaves strut's peers file, and the page never talks to the workspace
// itself. Apps on Peel's own strut, the person's (the agent's builder
// publishes them there), are listed and shown the same way, without a peer
// (`GET /apps`, `?app=<name>`).

extension AutomationsClient {
    /// The apps `peer` pinned as tabs, in the order its strut lists them,
    /// read through Peel's strut.
    public func pinnedApps(of peer: String) async throws -> [WorkspaceApp] {
        let id = try Self.peerID(peer)
        let answer = try await call("GET", "peers/\(id)/apps", what: "the workspace's apps")
        return try WorkspaceApp.listing(Data(answer.jsonString.utf8), peer: id)
    }

    /// The person's own apps, every one on this strut, in the order it
    /// lists them.
    public func ownApps() async throws -> [WorkspaceApp] {
        let answer = try await call("GET", "apps", what: "your apps")
        return try WorkspaceApp.listing(Data(answer.jsonString.utf8), peer: nil)
    }

    /// One of the person's own apps' versions and releases
    /// (`GET /apps/:name/versions`). A workspace's are its own to change.
    public func versions(of name: String) async throws -> AppVersions {
        let answer = try await call("GET", "apps/\(Self.escaped(path: name))/versions", what: "the app's versions")
        guard let versions = AppVersions(reply: Data(answer.jsonString.utf8)) else {
            throw PeelError("strut's reply named no live version.")
        }
        return versions
    }

    /// Changes what everyone who opens the person's own app `name` gets
    /// (`PUT /apps/:name/active`): strut takes the release and its lock.
    public func makeLive(_ name: String, _ target: AppLiveTarget) async throws {
        let body = AgentKit.JSONValue.object(target.body.mapValues { .string($0) })
        _ = try await call("PUT", "apps/\(Self.escaped(path: name))/active", body, what: "the app's live version")
    }
}

extension MemoryServer {
    /// strut's UI showing `app`'s page and nothing else, with this strut's
    /// key handed over as `?key=` (its UI keeps it for the tab and takes it
    /// out of the address), opened at the view `input` when there is one.
    /// Peel's own strut only. The address carries the key, so it is
    /// handed to the web view and never shown, logged or kept.
    public func page(of app: WorkspaceApp, version: String? = nil, input: String? = nil) -> URL? {
        // `name@vN`: that version rather than the one everyone opens.
        page("app", version.map { "\(app.id)@\($0)" } ?? app.id, input: input)
    }

    /// strut's UI showing a deliverable from the agent's DM alone, as for an
    /// app: a file through its viewer (`?artifact=`, stakwork/strut#314),
    /// an app's page (`?app=`, at the view `input`). An org's is read
    /// through to it with the person's token, as an app is.
    public func page(showing handle: AgentArtifact.Handle, input: String? = nil) -> URL? {
        switch handle {
        case .file(let path): page("artifact", path)
        case .app(let app): page("app", app, input: input)
        }
    }

    private func page(_ name: String, _ value: String, input: String? = nil) -> URL? {
        StrutUI.page(on: base, key: key, name, value, input: input)
    }

    /// The app a page of this strut's UI links to (`StrutAppLink`), from a
    /// page of the org `peer`'s app or of one of this strut's own (nil);
    /// nil for a link to anything else, or anywhere else.
    public func appLink(_ url: URL, from peer: String?) -> StrutAppLink? {
        servesPage(url) ? StrutAppLink(url, folder: uiFolder, from: peer.map { .peer($0) } ?? .own) : nil
    }

    /// Whether `url` is this strut's UI itself, not a file it serves.
    public func servesPage(_ url: URL) -> Bool {
        serves(url) && StrutUI.isPage(url, in: uiFolder)
    }

    /// The path strut's UI is served at, with its `/`.
    private var uiFolder: String {
        let path = base.path(percentEncoded: true)
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Whether `url` is on this strut: same scheme, host and port.
    public func serves(_ url: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased()
            && url.port == base.port
    }
}
