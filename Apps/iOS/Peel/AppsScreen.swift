import PeelCore
import PeelUI
import SwiftUI

/// Apps, from Chats' top rows: the apps the Stadeum workspaces pinned as
/// tabs, A–Z, each read and opened on its workspace's own strut with the
/// person's token (`Stadeum.readApps`, `Stadeum.opening`; strut's
/// specs/DESKTOP.md, "A device with no strut of its own"). A tap opens one
/// in the org page sheet; pulling reads them again. The Mac's twin is
/// `AppsView`, which also lists the person's own, on its strut.
struct AppsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        let stadeum = model.stadeum
        // The workspace on each row only when there are several.
        let several = Set(stadeum.apps.compactMap(\.peer)).count > 1
        List {
            Section {
                ForEach(stadeum.apps) { app in
                    Button {
                        if case .page(let page) = stadeum.opening(app) { router.orgPage = page }
                    } label: {
                        AppRow(app: app, showsSource: several)
                    }
                    .buttonStyle(.plain)
                }
            }
            .phoneRows()
        }
        .phoneList()
        .scrollEdges()
        .overlay {
            if stadeum.apps.isEmpty {
                if stadeum.live.isEmpty {
                    ContentUnavailableView {
                        Label("No Stadeum here yet", systemImage: WorkspaceApp.symbol)
                    } description: {
                        Text("Connect Stadeum under You to open the apps your workspaces pin.")
                    }
                } else if stadeum.readingApps {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No apps yet", systemImage: WorkspaceApp.symbol)
                    } description: {
                        Text("Apps your Stadeum workspaces pin show here.")
                    }
                }
            }
        }
        .refreshable { await stadeum.readWorkspaceApps()?.value }
        // Read again on opening, and when the workspaces change.
        .task(id: stadeum.live.map(\.id)) { stadeum.readWorkspaceApps() }
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One app: its icon, its title and what it is for, and under them where it
/// comes from (with several workspaces) and its version.
private struct AppRow: View {
    let app: WorkspaceApp
    let showsSource: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: app.iconSymbol)
                .font(.system(size: 19))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.title)
                    .phoneFont(.row)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let about = app.about {
                    Text(about)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                if let caption = app.caption(showsSource: showsSource) {
                    Text(caption)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .frame(minHeight: Theme.touchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens it")
    }
}
