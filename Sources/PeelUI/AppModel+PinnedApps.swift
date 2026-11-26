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
