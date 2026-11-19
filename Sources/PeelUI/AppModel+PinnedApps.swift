import Foundation
import PeelCore

/// The apps pinned under the Apps row, on the Mac's sidebar and the iPhone's
/// Chats: one list, kept with the account's sidebar layout
/// (`ChatSections.Layout.pinnedApps`), none until the person pins one.
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
    }
}
