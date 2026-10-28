import PeelCore
import PeelUI
import SwiftUI

extension WorkspaceApp {
    /// A header's icon: Apps' and an app's.
    static func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: Theme.AvatarSize.lg, height: Theme.AvatarSize.lg)
    }
}

/// What an app's page needs looked at, else the release its workspace holds
/// it at: one of them, on its card and in its header (the Mac's), and on its
/// row (the iPhone's).
struct AppStatus: View {
    let app: WorkspaceApp

    var body: some View {
        if app.problems > 0 {
            HStack(spacing: 5) {
                Circle().fill(Theme.attention).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(Formatting.count(app.problems, "problem"))
            }
            .font(Theme.font(12))
            .foregroundStyle(Theme.attention)
            #if os(macOS)
            .help("Strut's monitor flagged how its page uses the workspace")
            #endif
            .accessibilityHint("Strut's monitor flagged how its page uses the workspace")
        } else if let release = app.release {
            Chip("Release \(release)")
                .fixedSize()
            #if os(macOS)
                .help("Its workspace holds it at release \(release) while newer versions wait")
            #endif
                .accessibilityHint("Its workspace holds it at release \(release) while newer versions wait")
        }
    }
}
