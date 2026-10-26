import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// Apps, the sidebar's row: every app the workspaces pinned, A–Z, as cards
/// to open (`WorkspaceAppView`) or pin under the row; a search over their
/// names, what they are for and their workspaces, and the workspace to show
/// when there are several (docs/apps-browser.md).
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// The workspace shown, by its peer id; nil for all of them.
    @State private var workspace: String?

    var body: some View {
        let apps = model.hive.apps
        VStack(spacing: 0) {
            DetailHeader(title: "Apps", subtitle: apps.isEmpty ? nil : Formatting.count(apps.count, "app")) {
                WorkspaceApp.headerIcon
            }
            if model.memoryServer?.isHomeServer == true {
                EmptyState("Apps open on Peel's own strut, and the memory is on a home server.",
                           title: "Not on a home server yet")
            } else if !apps.isEmpty {
                list(apps)
            } else if model.hive.live.isEmpty {
                EmptyState("The apps your Stadeum workspaces pin show here.", title: "No workspaces") {
                    Button("Open Account") { model.openAccount(.connections) }.buttonStyle(.peel(.outline))
                }
            } else {
                EmptyState("The apps your workspaces pin show here.", title: "No apps yet")
            }
        }
    }

    @ViewBuilder
    private func list(_ apps: [WorkspaceApp]) -> some View {
        let peers = model.appWorkspaces
        // A workspace no longer listed, or the only one: all of them, as the choice then shows none.
        let shownWorkspace = peers.count > 1 && peers.contains(workspace ?? "") ? workspace : nil
        let shown = apps.filter { (shownWorkspace == nil || $0.peer == shownWorkspace) && $0.matches(query) }
        HStack(spacing: Theme.Space.md) {
            SearchField(text: $query, prompt: "Search apps").frame(maxWidth: 320)
            if peers.count > 1 {
                SegmentedChoice(selection: Binding(get: { shownWorkspace }, set: { workspace = $0 }), options: [(nil, "All")] + peers.map { ($0, "@\($0)") })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.md)
        if shown.isEmpty {
            // Only a search empties it: the workspace choice lists none without apps.
            EmptyState("No apps match “\(query.trimmingCharacters(in: .whitespaces))”.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.md, alignment: .top)],
                          spacing: Theme.Space.md) {
                    ForEach(shown) { AppCard(app: $0, showsWorkspace: peers.count > 1) }
                }
                .padding(Theme.Space.xl)
            }
        }
    }
}

/// One app in Apps: its icon, title and what it is for, and its workspace
/// when the apps come from several; a click opens it, its pin keeps it
/// under the sidebar's Apps row.
private struct AppCard: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp
    let showsWorkspace: Bool

    var body: some View {
        Button {
            model.destination = .app(peer: app.peer, name: app.name)
        } label: {
            Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: 10) {
                    Image(systemName: WorkspaceApp.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: Theme.AvatarSize.md, height: Theme.AvatarSize.md)
                        .background(Theme.input, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    Text(app.title)
                        .font(Theme.font(14, .semibold))
                        .lineLimit(1)
                }
                .padding(.trailing, 28)
                Text(app.about ?? "")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2, reservesSpace: true)
                if showsWorkspace {
                    Text("@\(app.peer)")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(Theme.Space.md)
            // As tall as the row's tallest, one without a description too.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            AppPinButton(app: app).padding(Theme.Space.sm)
        }
        .help(app.about ?? app.title)
    }
}
