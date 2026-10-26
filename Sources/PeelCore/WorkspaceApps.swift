import Foundation

// A Stadeum workspace's apps (strut's plans/apps.md §7.4; stakwork/strut#307
// and #308). An app lives on its workspace's strut, with its grants, runs and
// data. The Mac lists and opens one through its own strut, which reads
// through to the workspace with the person's token (PeelAgent's
// `pinnedApps(of:)`, `MemoryServer.page(of:)`); the iPhone, which has no
// strut, reads and opens it on the workspace's own strut with that token
// (`pinned(on:)`, `Stadeum.opening(_:)`; strut's specs/DESKTOP.md, "A device
// with no strut of its own"). Apps on the Mac's own strut, the person's (the
// agent's builder publishes them there), are listed the same way, without a
// peer.

/// An app a Stadeum workspace pinned as a tab, or one on Peel's own strut.
public struct WorkspaceApp: Sendable, Hashable, Identifiable {
    /// The workspace: its peer id, which the person reads as `@<peer>`; nil
    /// for an app of the person's own, on Peel's strut.
    public let peer: String?
    /// The app's name on the strut it lives on; a package prefix keeps its `/`.
    public let name: String
    /// What the person reads: its title, or its name.
    public let title: String
    /// What the app is for, in its own words.
    public let about: String?
    /// Its manifest's icon: a lucide name (`flask-conical`), or nil.
    public internal(set) var icon: String? = nil
    /// The version its strut serves (`v14`).
    public internal(set) var version: String? = nil
    /// The release held live (`r3`) while the workspace holds one rather
    /// than following its latest version.
    public internal(set) var release: String? = nil
    /// The warnings strut's monitor raised on its live version, about how
    /// its page uses the workspace (strut's `src/apps/monitor.ts`); 0 from
    /// a strut that does not count them.
    public internal(set) var problems = 0

    /// strut's key for it, the `?app=` its UI takes: `@<peer>/<name>`, or
    /// the name alone for one of the person's own.
    public var id: String { peer.map { "@\($0)/\(name)" } ?? name }
}

extension WorkspaceApp {
    /// One entry of strut's `GET /apps`, as JSON; nil for a workspace's not
    /// pinned as a tab, for one strut seeds on Peel's own (`publisher:
    /// strut`: its `strut/views`, components other apps import, not the
    /// person's), or with a name strut would not have given it.
    public init?(peer: String?, entry: Data) {
        guard let entry = try? JSONDecoder().decode(JSONValue.self, from: entry) else { return nil }
        self.init(peer: peer, value: entry)
    }

    init?(peer: String?, value: JSONValue) {
        guard case .object(let json) = value else { return nil }
        let listed = peer == nil ? json["publisher"]?.string != "strut" : json["pinned"] == .bool(true)
        guard listed, let name = json["name"]?.string, AgentArtifact.Handle.isAppName(name) else { return nil }
        self.peer = peer
        self.name = name
        let title = TextLine.clean(json["title"]?.string ?? "", max: TextLine.maxName)
        self.title = title.isEmpty ? name : title
        let about = TextLine.clean(json["description"]?.string ?? "", max: 400)
        self.about = about.isEmpty ? nil : about
        // strut's own words, shown as text (the icon only ever looked up
        // in Peel's table): cleaned as a name is, none when empty.
        func text(_ value: JSONValue?) -> String? {
            let text = TextLine.clean(value?.string ?? "", max: 64)
            return text.isEmpty ? nil : text
        }
        icon = text(json["icon"])
        version = text(json["activeVersion"])
        release = text(json["live"])
        if case .int(let count)? = json["warnings"] { problems = Int(clamping: max(count, 0)) }
    }

    /// The apps in strut's `GET /apps` answer (`{ apps: [...] }`), in its
    /// order, as `init(peer:entry:)` keeps them.
    public static func listing(_ answer: Data, peer: String?) throws -> [WorkspaceApp] {
        guard case .object(let json) = try JSONDecoder().decode(JSONValue.self, from: answer),
              case .array(let apps)? = json["apps"] else { return [] }
        return apps.compactMap { WorkspaceApp(peer: peer, value: $0) }
    }

    /// The apps `peer` pinned as tabs, read on its own strut with the
    /// person's token: the iPhone's way, which has no strut to read through.
    public static func pinned(on peer: HivePeer) async throws -> [WorkspaceApp] {
        guard let base = URL(string: peer.baseUrl) else { throw PeelError("\(peer.name)'s address could not be read.") }
        let (status, data) = try await Web.requestStrut("GET", base.appending(path: "apps"), bearer: peer.token,
                                                        limit: 2 * 1024 * 1024, what: "\(peer.name)'s apps", timeout: 30)
        guard status == 200 else { throw PeelError("\(peer.name) did not list its apps (HTTP \(status)).") }
        return try listing(data, peer: peer.id)
    }

    /// `apps` A–Z by title, as they are listed.
    public static func byTitle(_ apps: [WorkspaceApp]) -> [WorkspaceApp] {
        apps.sorted {
            switch $0.title.localizedStandardCompare($1.title) {
            case .orderedAscending: true
            case .orderedDescending: false
            // One title in two places: always the same way round.
            case .orderedSame: $0.id < $1.id
            }
        }
    }
}
