import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// Apps, from Chats' top rows: the apps the Stadeum workspaces pinned as
/// tabs, A–Z, each read and opened on its workspace's own strut with the
/// person's token (`Stadeum.readApps`, `Stadeum.opening`; strut's
/// specs/DESKTOP.md, "A device with no strut of its own"). A tap opens one
/// in the org page sheet; pulling or Refresh reads them again. The Mac's
/// twin is `AppsView`, which also lists the person's own, on its strut.
struct AppsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    @State private var query = ""
    /// A source (`@workspace`) the list is kept to; nil for all.
    @State private var source: String?

    var body: some View {
        let stadeum = model.stadeum
        // Only workspaces still in use: none once Stadeum no longer knows this iPhone.
        let live = Set(stadeum.live.map(\.id))
        let apps = stadeum.apps.filter { $0.peer.map(live.contains) ?? false }
        // The workspace on each row only when there are several.
        let several = Set(apps.compactMap(\.peer)).count > 1
        let sources = WorkspaceApp.sources(of: apps)
        // A source no longer listed, or the only one: all of them.
        let shownSource = sources.count > 1 && sources.contains(source ?? "") ? source : nil
        let shown = WorkspaceApp.filter(apps, query: query, source: shownSource)
        let unread = stadeum.unreadApps.compactMap { id in stadeum.live.first { $0.id == id }?.name }
        List {
            Section {
                ForEach(shown) { app in
                    Button {
                        if case .page(let page) = stadeum.opening(app) { router.orgPage = page }
                    } label: {
                        AppRow(app: app, showsSource: several)
                    }
                    .buttonStyle(.plain)
                    // Copies a link to the app: nothing is sent, and it opens
                    // here only for someone with that workspace connected.
                    .contextMenu {
                        if let link = app.shareLink() {
                            Button("Share link", systemImage: "link") {
                                Clipboard.copy(link.absoluteString)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                CopyFeedback.announce("Link copied")
                            }
                        }
                    }
                }
            } footer: {
                if !unread.isEmpty, !apps.isEmpty {
                    UnreadNote(names: unread)
                }
            }
            .phoneRows()
        }
        .phoneList()
        .scrollEdges()
        .searchable(text: $query, prompt: "Search apps")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Off while a read is under way: another would cut it short.
                Button("Refresh", systemImage: "arrow.clockwise") { stadeum.readWorkspaceApps() }
                    .disabled(stadeum.live.isEmpty || stadeum.readingApps)
            }
            if sources.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Source", selection: Binding(get: { shownSource }, set: { source = $0 })) {
                            Text("All").tag(String?.none)
                            ForEach(sources, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    } label: {
                        Label("Filter by source", systemImage: shownSource == nil
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
        .overlay {
            if !apps.isEmpty, shown.isEmpty {
                ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespaces))
            } else if apps.isEmpty {
                if stadeum.live.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No Stadeum here yet") } icon: { WorkspaceAppIcon(nil, size: 44) }
                    } description: {
                        Text("Connect Stadeum under You to open the apps your workspaces pin.")
                    }
                } else if stadeum.readingApps {
                    ProgressView()
                } else if !unread.isEmpty {
                    ContentUnavailableView {
                        Label { Text("Couldn't read the apps") } icon: { WorkspaceAppIcon(nil, size: 44) }
                    } description: {
                        Text("\(unread.joined(separator: ", ")) did not answer. Pull to try again.")
                    }
                } else {
                    ContentUnavailableView {
                        Label { Text("No apps yet") } icon: { WorkspaceAppIcon(nil, size: 44) }
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
            WorkspaceAppIcon(app, size: 20)
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
                AppStatus(app: app)
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

/// Under the list: the workspaces whose apps the last read could not
/// read, their earlier ones still shown.
private struct UnreadNote: View {
    let names: [String]

    var body: some View {
        Text("Couldn't read \(names.joined(separator: ", ")) just now. Pull to try again.")
            .phoneFont(.secondary)
            .foregroundStyle(Theme.tertiaryText)
    }
}
