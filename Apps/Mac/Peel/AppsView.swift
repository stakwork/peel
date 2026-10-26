import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// Apps, the sidebar's row: every app listed, the person's own and those
/// the workspaces pinned, A–Z, as cards to open (`WorkspaceAppView`) or pin
/// under the row; a search over their names, what they are for and where
/// they come from, and which of those to show when there are several
/// (docs/apps-browser.md). Opening it reads them again, so an app just
/// built shows.
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// The source shown (`WorkspaceApp.source`); nil for all of them.
    @State private var source: String?

    var body: some View {
        let apps = model.hive.apps
        VStack(spacing: 0) {
            DetailHeader(title: "Apps", subtitle: apps.isEmpty ? nil : Formatting.count(apps.count, "app")) {
                WorkspaceApp.headerIcon(WorkspaceApp.symbol)
            }
            if model.memoryServer?.isHomeServer == true {
                EmptyState("Apps open on Peel's own strut, and the memory is on a home server.",
                           title: "Not on a home server yet")
            } else if !apps.isEmpty {
                list(apps)
            } else {
                EmptyState("Apps Peel builds for you, and those your Stadeum workspaces pin, show here.",
                           title: "No apps yet") {
                    if model.hive.live.isEmpty {
                        Button("Connect Stadeum") { model.openAccount(.connections) }.buttonStyle(.peel(.outline))
                    }
                }
            }
        }
        .task { model.refreshApps(workspaces: false) }
    }

    @ViewBuilder
    private func list(_ apps: [WorkspaceApp]) -> some View {
        let sources = model.appSources
        // A source no longer listed, or the only one: all of them, as the choice then shows none.
        let shownSource = sources.count > 1 && sources.contains(source ?? "") ? source : nil
        let shown = apps.filter { (shownSource == nil || $0.source == shownSource) && $0.matches(query) }
        HStack(spacing: Theme.Space.md) {
            SearchField(text: $query, prompt: "Search apps").frame(maxWidth: 320)
            if sources.count > 1 {
                SegmentedChoice(selection: Binding(get: { shownSource }, set: { source = $0 }),
                                options: [(nil, "All")] + sources.map { ($0, $0) })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.md)
        if shown.isEmpty {
            // Only a search empties it: the choice lists no source without apps.
            EmptyState("No apps match “\(query.trimmingCharacters(in: .whitespaces))”.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.md, alignment: .top)],
                          spacing: Theme.Space.md) {
                    ForEach(shown) { AppCard(app: $0, showsSource: model.showsAppSources) }
                }
                .padding(Theme.Space.xl)
            }
        }
    }
}

/// One app in Apps: its icon, title and what it is for; at its foot its
/// source (when the apps come from several) and version, and its status
/// (`AppStatus`). A click opens it, its pin keeps it under the sidebar's
/// Apps row.
private struct AppCard: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp
    let showsSource: Bool

    var body: some View {
        Button {
            model.destination = .app(peer: app.peer, name: app.name)
        } label: {
            Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // A one-line title centred on the icon, a two-line one from its top.
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: app.iconSymbol)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: Theme.AvatarSize.md, height: Theme.AvatarSize.md)
                        .background(Theme.input, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    Text(app.title)
                        .font(Theme.font(14, .semibold))
                        .lineLimit(2)
                        .frame(minHeight: Theme.AvatarSize.md)
                }
                .padding(.trailing, 28)
                Text(app.about ?? "")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(3, reservesSpace: true)
                // The workspace at the foot of every card, whatever is above it.
                Spacer(minLength: 0)
                HStack(spacing: Theme.Space.sm) {
                    if let caption = app.caption(showsSource: showsSource) {
                        Text(caption)
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    AppStatus(app: app)
                }
                // A chip's height whether or not one shows: every card's foot on one line.
                .frame(height: 24)
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
