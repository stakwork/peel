import Foundation
import PeelCore

/// The person's favorite apps, starred on the Mac (Tom, 2026-11-27: the
/// Apps column's Favorites; pins are the rail's, for pages): one list, kept
/// with the account's sidebar layout as `ChatSections.Layout.pinnedApps`,
/// so the apps pinned before, the iPhone's and the Mac's sidebar's, come
/// back as favorites. Each one's id, name, title, icon and version are
/// also kept in the account's encrypted settings (`PinnedAppRecord`, wiped
/// with Stadeum's disconnect and the account), so Favorites shows at launch
/// before any workspace answers.
extension AppModel {
    /// Whether `app` is one of the person's favorites.
    public func isPinned(_ app: WorkspaceApp) -> Bool {
        sidebarLayout.isPinned(app.id)
    }

    /// Makes `app` a favorite (last) or takes it out, kept with the
    /// account's sidebar layout.
    public func setPinned(_ app: WorkspaceApp, _ pinned: Bool) {
        var layout = sidebarLayout
        layout.setPinned(app.id, pinned)
        if layout != sidebarLayout { sidebarLayout = layout }
        // Its minimal record is kept (or let go) with the pin: it shows at launch before a workspace answers.
        stadeum.pinsChanged()
    }

    /// The favorites still listed, A–Z by title, as the lists beside them
    /// are (Tom, 2026-11-27).
    public var favoriteApps: [WorkspaceApp] {
        WorkspaceApp.byTitle(sidebarLayout.pinned(stadeum.apps))
    }
}

/// The apps opened last (Recent in Apps' column) and the pages pinned
/// above the chats, kept with the account's sidebar layout.
extension AppModel {
    /// The apps opened last that are still listed, newest first: Recent in
    /// Apps' column.
    public var recentApps: [WorkspaceApp] {
        let listed = Dictionary(stadeum.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sidebarLayout.recentApps.compactMap { listed[$0] }
    }

    /// The app `name` (of the workspace `peer`, nil for the person's own)
    /// was opened, kept with the account's sidebar layout for Recent.
    public func noteOpenedApp(peer: String?, name: String) {
        var layout = sidebarLayout
        layout.noteOpened(WorkspaceApp.id(peer: peer, name: name))
        if layout != sidebarLayout { sidebarLayout = layout }
    }

    /// Whether the page `key` (threads, mentions) is pinned above the chats.
    public func isPagePinned(_ key: String) -> Bool {
        sidebarLayout.pinnedPages.contains(key)
    }

    /// Pins the page `key` or takes it off, kept with the account's sidebar
    /// layout.
    public func setPagePinned(_ key: String, _ pinned: Bool) {
        var layout = sidebarLayout
        layout.setPagePinned(key, pinned)
        if layout != sidebarLayout { sidebarLayout = layout }
    }
}

/// The iPhone's Recent row. The iPhone no longer pins apps (Tom,
/// 2026-11-26): Apps and its Recent row are the way in.
extension AppModel {
    /// The apps opened last that are still listed, newest first, at most
    /// `limit`: Recent in the iPhone's Apps.
    public func recentApps(limit: Int = 5) -> [WorkspaceApp] {
        Array(recentApps.prefix(limit))
    }
}
