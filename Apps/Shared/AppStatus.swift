import PeelCore
import PeelUI
import SwiftUI

extension WorkspaceApp {
    /// A header's icon: Apps' and an app's.
    static func headerIcon(_ icon: String?) -> some View {
        WorkspaceAppIcon(icon, size: 19)
            .foregroundStyle(Theme.secondaryText)
            .frame(width: Theme.AvatarSize.lg, height: Theme.AvatarSize.lg)
    }
}

/// What an app's page needs looked at, else a version of the person's own
/// waiting to be made live, else the release it is held at: one of them, on
/// its card and in its header (the Mac's), and on its row (the iPhone's).
/// The Mac's card leaves the release out (`showsRelease`): only what wants
/// the person shows there (Tom, 2026-11-26).
struct AppStatus: View {
    let app: WorkspaceApp
    var showsRelease = true

    var body: some View {
        if app.problems > 0 {
            HStack(spacing: 5) {
                Circle().fill(Theme.attention).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(String(localized: "\(app.problems) problems", table: "Shared"))
            }
            .font(Theme.font(12))
            .foregroundStyle(Theme.attention)
            #if os(macOS)
            .help(Text("Strut's monitor flagged how its page uses the workspace", tableName: "Shared"))
            #endif
            .accessibilityHint(Text("Strut's monitor flagged how its page uses the workspace", tableName: "Shared"))
        } else if let waiting = app.waiting {
            Text("\(waiting) waiting", tableName: "Shared")
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.attention)
            #if os(macOS)
                .help(String(localized: "\(waiting) is built and waits for you to make it live; everyone opens \(app.version ?? "")", table: "Shared"))
            #endif
        } else if showsRelease, let release = app.release {
            Chip(String(localized: "Release \(release)", table: "Shared"))
                .fixedSize()
            #if os(macOS)
                .help(String(localized: "Its workspace holds it at release \(release) while newer versions wait", table: "Shared"))
            #endif
                .accessibilityHint(String(localized: "Its workspace holds it at release \(release) while newer versions wait", table: "Shared"))
        }
    }
}
