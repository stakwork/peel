import PeelCore
import PeelUI
import SwiftUI

/// Apps' column (Tom, 2026-11-27; the board's "Favorites B"): on Apps and
/// while an app is open, beside the page as the chat list is on Chats, so
/// going from one app to another is one click. All apps (the store,
/// `AppsView`), then the favorites A–Z, then the apps
/// opened last that are not favorites. ⌃⌘S puts it away (`ColumnToggle`).
struct AppsColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let favorites = model.favoriteApps
        let starred = Set(favorites.map(\.id))
        let recent = Array(model.recentApps.filter { !starred.contains($0.id) }.prefix(5))
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(title: String(localized: "Apps")) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ListRow(selected: model.destination == .apps, minHeight: 32, action: { model.destination = .apps }) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 20)
                    } title: {
                        Text("All apps")
                    } detail: {
                        EmptyView()
                    } trailing: {
                        if !model.stadeum.apps.isEmpty {
                            Text(model.stadeum.apps.count, format: .number)
                                .font(Theme.font(12))
                                .monospacedDigit()
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    SectionHeader(String(localized: "Favorites"))
                        .padding(.horizontal, 8)
                        .padding(.top, Theme.Space.md)
                        .padding(.bottom, 4)
                    if favorites.isEmpty {
                        NoFavorites()
                    } else {
                        ForEach(favorites) { AppsColumnRow(app: $0) }
                    }
                    if !recent.isEmpty {
                        SectionHeader(String(localized: "Recent"))
                            .padding(.horizontal, 8)
                            .padding(.top, Theme.Space.md)
                            .padding(.bottom, 4)
                        ForEach(recent) { AppsColumnRow(app: $0) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, Theme.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

/// Favorites before the first: how to make one, in place of the list.
private struct NoFavorites: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "star")
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text("Star an app to keep it here, one click from any app.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

/// One app in the column: its icon and title, a click to open it; its star
/// while the pointer is over it.
private struct AppsColumnRow: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp
    @State private var hovering = false

    var body: some View {
        let destination = AppModel.Destination.app(peer: app.peer, name: app.name)
        ListRow(selected: model.destination == destination, minHeight: 32, action: { model.destination = destination }) {
            WorkspaceAppIcon(app, size: 13)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20)
        } title: {
            Text(app.title).lineLimit(1)
        } detail: {
            EmptyView()
        } trailing: {
            // Room for the star, so the title never runs under it.
            Color.clear.frame(width: 20, height: 1)
        }
        .overlay(alignment: .trailing) {
            if hovering { FavoriteButton(app: app, small: true).padding(.trailing, 4) }
        }
        .onHover { hovering = $0 }
        .help(app.about ?? app.title)
    }
}

/// The star that makes an app a favorite or takes it out (Apps' column):
/// filled in the accent while it is one. On a store card, in an open app's
/// header and on a column row under the pointer.
struct FavoriteButton: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp
    var small = false

    var body: some View {
        let on = model.isPinned(app)
        IconButton(help: on ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                   size: small ? .sm : .md) {
            model.setPinned(app, !on)
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
        }
    }
}
