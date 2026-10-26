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
        isHomeServer ? nil : StrutUI.page(on: base, key: key, name, value)
    }

    /// Whether `url` is on this strut: same scheme, host and port.
    public func serves(_ url: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased()
            && url.port == base.port
    }
}
