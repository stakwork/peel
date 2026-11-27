import Foundation
import PeelCore

/// The apps pinned under the Apps row, on the Mac's sidebar and the iPhone's
/// Chats: one list, kept with the account's sidebar layout
/// (`ChatSections.Layout.pinnedApps`), none until the person pins one. Each
/// pinned workspace app's id, name, title, icon and version are also kept in the
/// account's encrypted settings (`PinnedAppRecord`, wiped with Stadeum's
/// disconnect and the account), so the row shows at launch before any workspace answers.
extension AppModel {
    /// Whether the person pinned `app`.
    public func isPinned(_ app: WorkspaceApp) -> Bool {
        sidebarLayout.isPinned(app.id)
    }

    /// Pins `app` under the Apps row, or takes it off, kept with the
    /// account's sidebar layout. The first pin opens the fold.
    public func setPinned(_ app: WorkspaceApp, _ pinned: Bool) {
        var layout = sidebarLayout
        layout.setPinned(app.id, pinned)
        if layout != sidebarLayout { sidebarLayout = layout }
        // Its minimal record is kept (or let go) with the pin: it shows at launch before a workspace answers.
        stadeum.pinsChanged()
    }
}

/// The apps opened last (Recent in the iPhone's Apps) and the pages pinned
/// above the iPhone's chats, kept with the account's sidebar layout. The
/// iPhone no longer pins apps (Tom, 2026-11-26): Apps and its Recent row are
/// the way in.
extension AppModel {
    /// The apps opened last that are still listed, newest first, at most
    /// `limit`: Recent in Apps.
    public func recentApps(limit: Int = 5) -> [WorkspaceApp] {
        let listed = Dictionary(stadeum.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(sidebarLayout.recentApps.compactMap { listed[$0] }.prefix(limit))
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

    /// Pins the page `key` above the chats or takes it off, kept with the
    /// account's sidebar layout.
    public func setPagePinned(_ key: String, _ pinned: Bool) {
        var layout = sidebarLayout
        layout.setPagePinned(key, pinned)
        if layout != sidebarLayout { sidebarLayout = layout }
    }
}
