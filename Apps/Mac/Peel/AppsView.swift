import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// All apps, the store (Tom, 2026-11-27): what Apps' column's All apps
/// opens (`AppsColumn`, which holds Favorites and Recent). The search has
/// the keyboard as it opens; every app listed, grouped by where it comes
/// from (Yours, Built-in, then each workspace, as `WorkspaceApp.sources`),
/// as cards to open (`WorkspaceAppView`) and star. Typing drops the groups
/// for one list of matches and lights the first: Down and Up move it,
/// Return opens it, Escape clears the search. A search covers names, what
/// they are for and where they come from, beside which source to show when
/// there are several (docs/apps-browser.md). Opening it reads them again,
/// so an app just built shows.
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    @State private var query = ""
    /// The source shown (`WorkspaceApp.source`); nil for all of them.
    @State private var source: String?
    /// The card the arrows moved to (`WorkspaceApp.id`); while none, the
    /// first match of a search.
    @State private var highlighted: String?
    @State private var keys = KeyMonitor()
    /// The search has the keyboard: the arrows, Return and Escape are the
    /// store's only then, or while nothing else has it.
    @State private var searchHasKeys = false

    var body: some View {
        let apps = model.stadeum.apps
        VStack(spacing: 0) {
            DetailHeader(title: String(localized: "All apps"), subtitle: apps.isEmpty ? nil : Formatting.count(apps.count, .app),
                         subtitleInline: true) {
                // No icon: the title starts where every page's does.
                EmptyView()
            } trailing: {
                // The person's own and the workspaces' now, not at the rail's next read.
                IconButton("arrow.clockwise", help: String(localized: "Refresh"), working: model.stadeum.readingApps) {
                    model.refreshApps(force: true)
                }
                .disabled(model.stadeum.readingApps)
            }
            if !apps.isEmpty {
                list
            } else {
                // Building one is the way in; a workspace's come with Stadeum.
                EmptyState(String(localized: "Ask Peel to build you one. Apps your Hive workspaces pin show here too."),
                           title: String(localized: "No apps yet")) {
                    HStack(spacing: Theme.Space.sm) {
                        Button("Ask Peel") { model.destination = .agent }.buttonStyle(.peel(.primary))
                        if model.stadeum.live.isEmpty {
                            Button("Connect Hive") { model.openAccount(.connections) }.buttonStyle(.peel(.outline))
                        }
                    }
                }
            }
        }
        .task { model.refreshApps(workspaces: false) }
        .onChange(of: query) { highlighted = nil }
        .onChange(of: source) { highlighted = nil }
        .onAppear { keys.start { handle($0) } }
        .onDisappear { keys.stop() }
    }

    /// The cards shown: from the source chosen, matching the search.
    private var shown: [WorkspaceApp] {
        let sources = model.appSources
        // A source no longer listed, or the only one: all of them, as the choice then shows none.
        let shownSource = sources.count > 1 && sources.contains(source ?? "") ? source : nil
        return WorkspaceApp.filter(model.stadeum.apps, query: query, source: shownSource)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `shown` by where they come from, in `WorkspaceApp.sources`' order;
    /// one group, untitled, while searching.
    private func groups(_ shown: [WorkspaceApp]) -> [(source: String?, apps: [WorkspaceApp])] {
        if searching { return [(nil, shown)] }
        return WorkspaceApp.sources(of: shown).map { source in (source, shown.filter { $0.source == source }) }
    }

    /// The cards in the order drawn, for the arrows.
    private var ordered: [WorkspaceApp] { groups(shown).flatMap(\.apps) }

    /// The card lit: the one the arrows moved to, else a search's first.
    private func lit(in shown: [WorkspaceApp]) -> String? {
        if let highlighted, shown.contains(where: { $0.id == highlighted }) { return highlighted }
        return searching ? shown.first?.id : nil
    }

    @ViewBuilder
    private var list: some View {
        let sources = model.appSources
        let shown = ordered
        let lit = lit(in: shown)
        let grouped = groups(shown)
        HStack(spacing: Theme.Space.md) {
            SearchField(text: $query, prompt: String(localized: "Search apps"), focusRequest: model.sidebarSearchFocus,
                        focusOnAppear: true, focusChanged: { searchHasKeys = $0 }).frame(maxWidth: 440)
            if sources.count > 1 {
                SegmentedChoice(selection: Binding(get: { sources.contains(source ?? "") ? source : nil }, set: { source = $0 }),
                                options: [(nil, String(localized: "All"))] + sources.map { ($0, $0) })
            }
            Spacer(minLength: 0)
            if lit != nil {
                Text("↓↑ to move · Return to open · Esc to clear")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.md)
        if shown.isEmpty {
            // Only a search empties it: the choice lists no source without apps.
            EmptyState(String(localized: "No apps match “\(query.trimmingCharacters(in: .whitespaces))”."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        ForEach(grouped, id: \.source) { group in
                            if let source = group.source {
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                                    Text(source)
                                        .font(Theme.font(13, .bold))
                                        .accessibilityAddTraits(.isHeader)
                                    Text(group.apps.count, format: .number)
                                        .font(Theme.font(12))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                                .padding(.top, group.source == grouped.first?.source ? 0 : Theme.Space.md)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.md, alignment: .top)],
                                      spacing: Theme.Space.md) {
                                ForEach(group.apps) { app in
                                    // A group says where they come from; one list of matches, each card.
                                    AppCard(app: app, showsSource: group.source == nil && model.showsAppSources,
                                            lit: app.id == lit).id(app.id)
                                }
                            }
                        }
                    }
                    .padding(Theme.Space.xl)
                }
                .onChange(of: lit) { if let lit { proxy.scrollTo(lit) } }
            }
        }
    }

    /// While Apps is up in the main window, with no menu, panel or viewer
    /// over it: Down and Up move the light through the cards, Return opens
    /// the lit one, Escape empties the search (the field keeps the cursor).
    private func handle(_ event: NSEvent) -> Bool {
        guard model.phase == .ready, !model.isLockDue, model.destination == .apps, model.viewer == nil,
              presenter?.takesKeys(event) ?? false,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              // Its own search, or nothing, has the keyboard: never the web pane beside it.
              searchHasKeys || event.window?.firstResponder === event.window,
              // An input method composing keeps its Return and arrows.
              (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true
        else { return false }
        let shown = ordered
        let lit = lit(in: shown)
        switch event.keyCode {
        case KeyCode.down, KeyCode.up:
            guard !shown.isEmpty else { return false }
            // The chat list's step: clamped at the ends, the first from none.
            guard let next = Sidebar.step(shown.map(\.id), from: lit, by: event.keyCode == KeyCode.down ? 1 : -1) else { return false }
            highlighted = next
            if let title = shown.first(where: { $0.id == next })?.title {
                AccessibilityNotification.Announcement(title).post()
            }
        case KeyCode.return, KeyCode.enter:
            guard let lit, let app = shown.first(where: { $0.id == lit }) else { return false }
            model.destination = .app(peer: app.peer, name: app.name)
        case KeyCode.escape:
            guard searching || highlighted != nil else { return false }
            query = ""
            highlighted = nil
        default:
            return false
        }
        return true
    }
}

/// One app in the store: its icon, title and what it is for; at its foot
/// its source (in a search's one list, when the apps come from several) and
/// version, and its status (`AppStatus`, without the release). A click opens
/// it; its star shows while it is a favorite or under the pointer, its link
/// to share under the pointer. `lit` is the card the keyboard is on.
private struct AppCard: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp
    let showsSource: Bool
    let lit: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            model.destination = .app(peer: app.peer, name: app.name)
        } label: {
            Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // A one-line title centred on the icon, a two-line one from its top.
                HStack(alignment: .top, spacing: 10) {
                    WorkspaceAppIcon(app, size: 17)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: Theme.AvatarSize.md, height: Theme.AvatarSize.md)
                        .background(Theme.input, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    Text(app.title)
                        .font(Theme.font(14, .semibold))
                        .lineLimit(2)
                        .frame(minHeight: Theme.AvatarSize.md)
                }
                .padding(.trailing, 56)
                Text(app.about ?? "")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2, reservesSpace: true)
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
                    AppStatus(app: app, showsRelease: false)
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
        .overlay {
            if lit {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if hovering { AppShareButton(app: app) }
                if hovering || model.isPinned(app) { FavoriteButton(app: app) }
            }
            .padding(Theme.Space.sm)
        }
        .onHover { hovering = $0 }
        .help(app.about ?? app.title)
    }
}
