import PeelCore

/// One row of the iPhone's Apps: an app a Stadeum workspace pinned, or a
/// public app opened on this phone (a worker's Tasks), listed together.
public enum AppsListRow: Identifiable, Equatable, Sendable {
    case workspace(WorkspaceApp)
    case opened(OpenedPublicApp)

    public var id: String {
        switch self {
        case .workspace(let app): "workspace \(app.id)"
        case .opened(let app): "opened \(app.id)"
        }
    }

    public var title: String {
        switch self {
        case .workspace(let app): app.title
        case .opened(let app): app.title
        }
    }

    /// Where it comes from: a workspace app's own source, an opened app's host.
    public var source: String {
        switch self {
        case .workspace(let app): app.source
        case .opened(let app): app.link?.host ?? app.origin
        }
    }

    /// Whether a search finds it, each kind by its own rule.
    public func matches(_ query: String) -> Bool {
        switch self {
        case .workspace(let app): app.matches(query)
        case .opened(let app): app.matches(query)
        }
    }

    /// The sources to filter by: the workspaces' (as `WorkspaceApp.sources`),
    /// then the opened apps' hosts, in the order they first appear, once each.
    public static func sources(workspace: [WorkspaceApp], opened: [OpenedPublicApp]) -> [String] {
        var all = WorkspaceApp.sources(of: workspace)
        for host in opened.map({ AppsListRow.opened($0).source }) where !all.contains(host) { all.append(host) }
        return all
    }

    /// The list: the workspace apps in their order, then the opened apps,
    /// last opened first (as given), kept to `source` (all when nil) and to
    /// what a search for `query` finds.
    public static func merged(workspace: [WorkspaceApp], opened: [OpenedPublicApp],
                              query: String, source: String?) -> [AppsListRow] {
        (workspace.map(AppsListRow.workspace) + opened.map(AppsListRow.opened))
            .filter { (source == nil || $0.source == source) && $0.matches(query) }
    }
}
