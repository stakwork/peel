import PeelCore
import PeelUI
import SwiftUI

/// Chats (docs/design/iphone.md, screen 1): the large title with the
/// connection bolt in its glass capsule (green when connected, orange when
/// not), the top rows, then Unread, Tribes and Direct messages in the Mac
/// sidebar's order and trimming (`AppModel.sidebarSections`), each section
/// ending in its actions as on the Mac; or, with Recent chosen, one list of
/// both, newest first. Its stack is the router's `chats`.
struct ChatsTab: View {
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.chats) {
            ChatList()
                .onCallBannerInset()
                .navigationTitle("Chats")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { ConnectionBolt() }
                }
                .chatsDestinations()
        }
    }
}

extension View {
    /// What Chats and Search push, by `ChatsRoute`: a conversation hides
    /// the tab bar.
    func chatsDestinations() -> some View {
        navigationDestination(for: ChatsRoute.self) { route in
            switch route {
            case .chat(let chat):
                ConversationScreen(chat: chat)
                    .toolbar(.hidden, for: .tabBar)
            case .details(let chat):
                ChatDetailsScreen(chat: chat)
                    .toolbar(.hidden, for: .tabBar)
            case .members(let chat):
                TribeMembersScreen(chat: chat)
                    .toolbar(.hidden, for: .tabBar)
            case .threads:
                ThreadsScreen()
                    .onCallBannerInset()
            case .mentions:
                MentionsScreen()
                    .onCallBannerInset()
            case .automations:
                AutomationsScreen()
                    .onCallBannerInset()
            case .apps:
                AppsScreen()
                    .onCallBannerInset()
            }
        }
    }
}

/// The top rows, then the chats by section, Tribes ending in Join and
/// Create a tribe and Direct messages in the pending invites, Add contact
/// and Invite someone, as the Mac's sidebar ends them. Recent (the layout's
/// `combinedView`, shared with the Mac) puts tribes and people in one list,
/// newest first, trimmed to ten, ending in all those actions. Search shows it too,
/// filtered by name: then only the matching chats, every section open, no
/// actions.
struct ChatList: View {
    @Environment(AppModel.self) private var model
    /// The form or invite open over the list, as a sheet.
    @State private var sheet: PeopleSheet?

    var body: some View {
        @Bindable var model = model
        let sections = model.sidebarSections
        // Read once here and passed down: a row redraws only when its own state changes.
        let states = model.readStates
        // The agent's DM is its own row, first in Direct messages, as on the
        // Mac (never in the sections), and found by its name as a chat is.
        let agent = model.agentChat.flatMap { chat in model.conversations.first { $0.chat == chat } }
            .flatMap { ChatSections.matches($0.name, query: model.searchQuery) ? $0 : nil }
            // Unread, it is in the Unread section instead.
            .flatMap { agent in sections.unread.contains { $0.chat == agent.chat } ? nil : agent }
        let empty = sections.unread.isEmpty && sections.tribes.isEmpty && sections.direct.isEmpty && agent == nil
        let recent = model.sidebarLayout.combinedView && !sections.searching
        // The apps under the Apps row, A–Z, as the Mac's sidebar shows them: the
        // pinned ones while open (the chevron only with some), or, searching,
        // every app that matches. Only with Stadeum connected here.
        let stadeumLive = !model.stadeum.live.isEmpty
        let livePeers = Set(model.stadeum.live.map(\.id))
        let listedApps = model.stadeum.apps.filter { $0.peer.map(livePeers.contains) ?? false }
        let hasPins = stadeumLive && !model.sidebarLayout.pinned(listedApps).isEmpty
        let pinnedApps: [WorkspaceApp] = {
            guard stadeumLive else { return [] }
            if sections.searching { return listedApps.filter { $0.matches(model.searchQuery) } }
            return model.sidebarLayout.appsOpen ? model.sidebarLayout.pinned(listedApps) : []
        }()
        let showsSources = Set(listedApps.compactMap(\.peer)).count > 1
        List {
            if !sections.searching {
                Section {
                    // The workspaces' apps and Talk, once Stadeum is connected here
                    // (or a development profile names a home, docs/talk.md).
                    if !model.stadeum.live.isEmpty || model.talk.developmentHome != nil {
                        NavigationLink(value: ChatsRoute.apps) {
                            NavRow(title: String(localized: "Apps"), icon: WorkspaceAppIcon(nil, size: 20))
                        }
                        .overlay(alignment: .trailing) {
                            if hasPins { AppsFoldButton(open: $model.sidebarLayout.appsOpen) }
                        }
                        ForEach(pinnedApps) { PinnedAppRow(app: $0, showsSource: showsSources) }
                    }
                    // Automations is Mac-only for now; hidden on iOS until ready.
                    NavigationLink(value: ChatsRoute.threads) {
                        NavRow(title: String(localized: "Threads"), systemImage: "bubble.left", count: model.unreadThreads)
                    }
                    NavigationLink(value: ChatsRoute.mentions) {
                        NavRow(title: String(localized: "Mentions"), systemImage: "at", count: model.unreadMentions)
                    }
                }
                .phoneRows()
                .listRowInsets(.vertical, 2)
                .navigationLinkIndicatorVisibility(.hidden)
            }
            // Searching hides the top rows, but the apps that match still show.
            if sections.searching, !pinnedApps.isEmpty {
                Section {
                    ForEach(pinnedApps) { PinnedAppRow(app: $0, showsSource: showsSources) }
                }
                .phoneRows()
                .listRowInsets(.vertical, 2)
            }
            if model.diagnosticsNotice, !sections.searching {
                Section { DiagnosticsNotice() }
                    .phoneRows()
            }
            if model.conversations.isEmpty, !sections.searching {
                Section { NoChats() }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if !sections.unread.isEmpty {
                ChatsSection(title: String(localized: "Unread")) {
                    ForEach(sections.unread) {
                        ChatLink(conversation: $0, state: states[$0.chat], isAgent: $0.chat == model.agentChat)
                    }
                }
            }
            if !sections.searching {
                Section {
                    Picker("Chats", selection: $model.sidebarLayout.combinedView) {
                        Text("Separated").tag(false)
                        Text("Recent").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, Theme.Space.lg)
                    .listRowSeparator(.hidden)
                }
                .phoneRows()
            }
            if recent {
                ChatsSection(title: String(localized: "Recent")) {
                    if let agent {
                        ChatLink(conversation: agent, state: states[agent.chat], isAgent: true)
                    }
                    ForEach(sections.combined) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allCombined {
                        ShowAll(kind: .chats(all), all: $model.sidebarLayout.allRecent)
                    }
                    ActionRow(title: String(localized: "Join a tribe")) { sheet = .joinTribe }
                    ActionRow(title: String(localized: "Create a tribe")) { sheet = .createTribe }
                    ForEach(model.pendingInvites) { invite in
                        PendingInviteRow(invite: invite) { sheet = .invite(invite.code) }
                    }
                    ActionRow(title: String(localized: "Add contact")) { sheet = .addContact }
                    ActionRow(title: String(localized: "Invite someone")) { sheet = .inviteSomeone }
                }
            } else {
                // Searching shows every match, a section only with matches,
                // with no chevron to say otherwise or to change the saved
                // layout, and no actions. Otherwise a section is always there,
                // for its actions.
                if !sections.searching || !sections.tribes.isEmpty {
                    ChatsSection(title: String(localized: "Tribes"),
                                 expanded: sections.searching ? nil : $model.sidebarLayout.tribesOpen) {
                        ForEach(sections.tribes) { ChatLink(conversation: $0, state: states[$0.chat]) }
                        if let all = sections.allTribes {
                            ShowAll(kind: .tribes(all), all: $model.sidebarLayout.allTribes)
                        }
                        if sections.tribesOpen, !sections.searching {
                            ActionRow(title: String(localized: "Join a tribe")) { sheet = .joinTribe }
                            ActionRow(title: String(localized: "Create a tribe")) { sheet = .createTribe }
                        }
                    }
                }
                if !sections.searching || !sections.direct.isEmpty || agent != nil {
                    ChatsSection(title: String(localized: "Direct messages"),
                                 expanded: sections.searching ? nil : $model.sidebarLayout.directOpen) {
                        if let agent {
                            ChatLink(conversation: agent, state: states[agent.chat], isAgent: true)
                        }
                        ForEach(sections.direct) { ChatLink(conversation: $0, state: states[$0.chat]) }
                        if let all = sections.allDirect {
                            ShowAll(kind: .people(all), all: $model.sidebarLayout.allDirect)
                        }
                        if sections.directOpen, !sections.searching {
                            ForEach(model.pendingInvites) { invite in
                                PendingInviteRow(invite: invite) { sheet = .invite(invite.code) }
                            }
                            ActionRow(title: String(localized: "Add contact")) { sheet = .addContact }
                            ActionRow(title: String(localized: "Invite someone")) { sheet = .inviteSomeone }
                        }
                    }
                }
            }
        }
        .phoneList()
        .scrollEdges()
        // Reconnects if need be, then catches up from where history stands.
        .refreshable { await model.refresh() }
        .overlay {
            if sections.searching, empty {
                ContentUnavailableView.search(text: model.searchQuery)
            }
        }
        .sheet(item: $sheet) { $0.screen }
        // Pinned apps are read without opening Apps first, and again when the
        // workspaces change (a read under way is cut short by the next one).
        .task(id: model.stadeum.live.map(\.id)) {
            // Before any are listed there is no telling which pins are still
            // there, so the saved pins decide.
            if !model.sidebarLayout.pinnedApps.isEmpty, !model.stadeum.live.isEmpty {
                model.stadeum.readWorkspaceApps()
            }
        }
    }
}

/// The chevron over the Apps row's end: shows or hides the pinned apps under
/// it, kept with the sidebar's layout (the Mac's `AppsFoldButton`).
private struct AppsFoldButton: View {
    @Binding var open: Bool

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .rotationEffect(.degrees(open ? 0 : -90))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pinned apps")
        .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
    }
}

/// A pinned app under the Apps row: its icon and title (with its workspace
/// when the apps come from several). A tap opens it as Apps does; Unpin is
/// its swipe and its menu.
private struct PinnedAppRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    let app: WorkspaceApp
    let showsSource: Bool

    var body: some View {
        Button {
            if case .page(let page) = model.stadeum.opening(app) { router.orgPage = page }
        } label: {
            NavRow(title: showsSource ? "\(app.title) · \(app.source)" : app.title,
                   icon: WorkspaceAppIcon(app, size: 20))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens it")
        .contextMenu { PinToggle(app: app) }
        .swipeActions(edge: .trailing) { PinToggle(app: app).tint(Theme.accent) }
    }
}

/// Pin to Chats, or Unpin once it is: the menu's and the swipe's one button.
private struct PinToggle: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp

    var body: some View {
        let pinned = model.isPinned(app)
        Button(pinned ? String(localized: "Unpin") : String(localized: "Pin to Chats"), systemImage: pinned ? "pin.slash" : "pin") {
            model.setPinned(app, !pinned)
        }
    }
}

/// A section of chats under its header. The header is the section's first
/// row rather than a sticky header, which would sit see-through over the
/// rows scrolling under the glass bar.
private struct ChatsSection<Rows: View>: View {
    let title: String
    var expanded: Binding<Bool>?
    @ViewBuilder let rows: Rows

    var body: some View {
        Section {
            PhoneSectionHeader(title, expanded: expanded)
                .padding(.top, Theme.Space.lg)
                .listRowSeparator(.hidden)
            rows
        }
        .phoneRows()
        .listRowInsets(.vertical, 2)
    }
}

/// No chats on the account yet: what fills the list, in Peel's words, or
/// that a restore is still bringing them.
private struct NoChats: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.restoreProgress.restoring {
            ContentUnavailableView {
                Label("Restoring your chats", systemImage: "arrow.down.circle")
            } description: {
                Text("They show here as they arrive. This can take a few minutes.")
            }
        } else {
            ContentUnavailableView {
                Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Join a tribe or add someone below, and they show here.")
            }
        }
    }
}

/// One chat, pushed as a `ChatsRoute`. Swipe right to mark it read or
/// unread, left to mute it; a long press has the same and its
/// notification level. Pinning a chat is not in the model, so there is no
/// Pin.
private struct ChatLink: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let state: ChatReadState?
    var isAgent = false

    var body: some View {
        // Once per row build: the swipe and the menu share it.
        let read = readAction
        NavigationLink(value: ChatsRoute.chat(conversation.chat)) {
            ChatListRow(conversation: conversation, state: state, isAgent: isAgent)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let read {
                Button(read.title, systemImage: read.systemImage) { read.run() }
                    .tint(Theme.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            let muted = level == .muted
            Button(muted ? String(localized: "Unmute") : String(localized: "Mute"), systemImage: muted ? "bell" : "bell.slash") {
                setLevel(muted ? .all : .muted)
            }
            .tint(Theme.secondaryText)
        }
        .contextMenu {
            if let read {
                Button(read.title, systemImage: read.systemImage) { read.run() }
            }
            Picker("Notify me about", systemImage: "bell", selection: Binding { level } set: { setLevel($0) }) {
                ForEach(MuteLevel.choices(isTribe: conversation.isTribe), id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    private var level: MuteLevel { state?.mute ?? .all }

    /// The Mac's rule (`AppModel.readToggle`), in the phone's short words.
    private var readAction: (title: String, systemImage: String, run: () -> Void)? {
        let chat = conversation.chat
        return switch model.readToggle(for: chat) {
        case .markRead: (String(localized: "Mark read"), "checkmark.circle", { Task { await model.markRead(chat) } })
        case .markUnread: (String(localized: "Mark unread"), "envelope.badge", { Task { await model.markUnread(chat) } })
        case nil: nil
        }
    }

    private func setLevel(_ level: MuteLevel) {
        let chat = conversation.chat
        Task { await model.setMute(chat, level) }
    }
}

/// "Show all 14 tribes", then "Show fewer" ("Show fewer tribes" to
/// VoiceOver); kept with the account, as the Mac's sidebar keeps it.
private struct ShowAll: View {
    enum Kind {
        case chats(Int), tribes(Int), people(Int)

        var showAll: String {
            switch self {
            case .chats(let n): String(localized: "Show all \(n) chats")
            case .tribes(let n): String(localized: "Show all \(n) tribes")
            case .people(let n): String(localized: "Show all \(n) people")
            }
        }

        var showFewer: String {
            switch self {
            case .chats: String(localized: "Show fewer chats")
            case .tribes: String(localized: "Show fewer tribes")
            case .people: String(localized: "Show fewer people")
            }
        }
    }

    let kind: Kind
    @Binding var all: Bool

    var body: some View {
        Button {
            all.toggle()
        } label: {
            Text(all ? String(localized: "Show fewer") : kind.showAll)
                .phoneFont(.row)
                .foregroundStyle(Theme.link)
                .frame(maxWidth: .infinity, minHeight: Theme.touchTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(all ? kind.showFewer : kind.showAll)
    }
}
