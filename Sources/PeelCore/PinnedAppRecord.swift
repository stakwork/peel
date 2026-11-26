import Foundation

// The one deliberate exception to "the app list is never kept": the apps the
// person pinned under the Apps row keep a minimal record (id, name, title,
// icon, version) in the account's encrypted settings, so they show at launch
// before any workspace has answered. Never a manifest, description, token or
// the whole list. Every read replaces it (`reconcile`); disconnecting
// Stadeum, a revoked or lost workspace, and forgetting the account wipe it.

/// Why a workspace's apps could not be read: the HTTP status it answered
/// with, or nil when it never did (offline, timed out).
public struct AppsReadFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: Int?

    public init(status: Int?) { self.status = status }

    /// The failure `error` is: a refusal that carried its status, else a transient one.
    public init(_ error: any Error) {
        self = (error as? AppsReadFailure) ?? AppsReadFailure(status: nil)
    }

    /// The workspace no longer lets this device in, or no longer has the
    /// app list (401, 403, 404): what was listed for it goes. Anything else
    /// (a timeout, a 5xx, no network) may pass, so what it listed stays.
    public var lostAccess: Bool {
        guard let status else { return false }
        return status == 401 || status == 403 || status == 404
    }

    public var description: String { status.map { "HTTP \($0)" } ?? "no answer" }
}

/// What is kept of one pinned workspace app.
public struct PinnedAppRecord: Codable, Equatable, Sendable {
    public var id: String
    public var peer: String?
    public var name: String
    public var title: String
    public var icon: String?
    public var version: String?

    public init(_ app: WorkspaceApp) {
        id = app.id
        peer = app.peer
        name = app.name
        title = app.title
        icon = app.icon
        version = app.version
    }

    /// The app it stands for, marked `refreshing` until a read answers for its workspace.
    public var app: WorkspaceApp {
        var app = WorkspaceApp(peer: peer, name: name, title: title, about: nil)
        app.icon = icon
        app.version = version
        app.refreshing = true
        return app
    }

    /// The records of the pinned workspace apps in `apps` (the person's own
    /// are on the Mac's strut, read at once: not kept), in the order pinned.
    public static func records(of apps: [WorkspaceApp], pinnedIDs: [String]) -> [PinnedAppRecord] {
        pinnedIDs.compactMap { id in
            apps.first(where: { $0.id == id && $0.peer != nil && !$0.refreshing }).map { PinnedAppRecord($0) }
        }
    }

    /// The records after a pin or unpin: one per id in `pinnedIDs`, from the
    /// listed app when there is one, else the record already kept.
    public static func following(pins pinnedIDs: [String], old: [PinnedAppRecord], apps: [WorkspaceApp]) -> [PinnedAppRecord] {
        pinnedIDs.compactMap { id in
            if let listed = apps.first(where: { $0.id == id && $0.peer != nil && !$0.refreshing }) { return PinnedAppRecord(listed) }
            return old.first { $0.id == id }
        }
    }

    /// The records after reads of the workspaces: a workspace that answered
    /// replaces its records with its pinned apps (removed ones drop, renamed
    /// and newer ones update); one that lost the device's access (401, 403,
    /// 404) loses them; one that did not answer keeps them. Only apps in
    /// `pinnedIDs` of workspaces in `live` are kept, in the order pinned.
    public static func reconcile(old: [PinnedAppRecord], read: [String: Result<[WorkspaceApp], AppsReadFailure>],
                                 pinnedIDs: [String], live: Set<String>) -> [PinnedAppRecord] {
        var kept: [String: PinnedAppRecord] = [:]
        for record in old {
            if let peer = record.peer, live.contains(peer), pinnedIDs.contains(record.id) { kept[record.id] = record }
        }
        for (peer, result) in read where live.contains(peer) {
            switch result {
            case .success(let apps):
                kept = kept.filter { $0.value.peer != peer }
                for app in apps where app.peer == peer && pinnedIDs.contains(app.id) { kept[app.id] = PinnedAppRecord(app) }
            case .failure(let failure):
                if failure.lostAccess { kept = kept.filter { $0.value.peer != peer } }
            }
        }
        return pinnedIDs.compactMap { kept[$0] }
    }
}
