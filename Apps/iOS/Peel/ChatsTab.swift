import PeelCore
import PeelUI
import SwiftUI

/// Chats (docs/design/iphone.md, screen 1): the large title with the
/// connection bolt in its glass capsule (green when connected, orange when
/// not), the top rows, then Unread, Tribes and Direct messages in the Mac
/// sidebar's order and trimming (`AppModel.sidebarSections`), each section
/// ending in its actions as on the Mac. Its stack is the router's `chats`.
struct ChatsTab: View {
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.chats) {
            ChatList()
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
            case .mentions:
                MentionsScreen()
            case .automations:
                AutomationsScreen()
            }
        }
    }
}

/// The top rows, then the chats by section, Tribes ending in Join and
/// Create a tribe and Direct messages in the pending invites, Add contact
/// and Invite someone, as the Mac's sidebar ends them. Search shows it too,
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
        let empty = sections.unread.isEmpty && sections.tribes.isEmpty && sections.direct.isEmpty && agent == nil
        List {
            if !sections.searching {
                Section {
                    NavigationLink(value: ChatsRoute.automations) {
                        NavRow(title: "Automations", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(value: ChatsRoute.threads) {
                        NavRow(title: "Threads", systemImage: "bubble.left", count: model.unreadThreads)
                    }
                    NavigationLink(value: ChatsRoute.mentions) {
                        NavRow(title: "Mentions", systemImage: "at", count: model.unreadMentions)
                    }
                }
                .phoneRows()
                .listRowInsets(.vertical, 2)
                .navigationLinkIndicatorVisibility(.hidden)
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
                ChatsSection(title: "Unread") {
                    ForEach(sections.unread) { ChatLink(conversation: $0, state: states[$0.chat]) }
                }
            }
            // Searching shows every match, a section only with matches,
            // with no chevron to say otherwise or to change the saved
            // layout, and no actions. Otherwise a section is always there,
            // for its actions.
            if !sections.searching || !sections.tribes.isEmpty {
                ChatsSection(title: "Tribes",
                             expanded: sections.searching ? nil : $model.sidebarLayout.tribesOpen) {
                    ForEach(sections.tribes) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allTribes {
                        ShowAll(what: "\(all) tribes", fewer: "tribes", all: $model.sidebarLayout.allTribes)
                    }
                    if sections.tribesOpen, !sections.searching {
                        ActionRow(title: "Join a tribe") { sheet = .joinTribe }
                        ActionRow(title: "Create a tribe") { sheet = .createTribe }
                    }
                }
            }
            if !sections.searching || !sections.direct.isEmpty || agent != nil {
                ChatsSection(title: "Direct messages",
                             expanded: sections.searching ? nil : $model.sidebarLayout.directOpen) {
                    if let agent {
                        ChatLink(conversation: agent, state: states[agent.chat], isAgent: true)
                    }
                    ForEach(sections.direct) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allDirect {
                        ShowAll(what: Formatting.people(all), fewer: "people", all: $model.sidebarLayout.allDirect)
                    }
                    if sections.directOpen, !sections.searching {
                        ForEach(model.pendingInvites) { invite in
                            PendingInviteRow(invite: invite) { sheet = .invite(invite.code) }
                        }
                        ActionRow(title: "Add contact") { sheet = .addContact }
                        ActionRow(title: "Invite someone") { sheet = .inviteSomeone }
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
            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") {
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
        case .markRead: ("Mark read", "checkmark.circle", { Task { await model.markRead(chat) } })
        case .markUnread: ("Mark unread", "envelope.badge", { Task { await model.markUnread(chat) } })
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
    /// "14 tribes", "10 people".
    let what: String
    /// "tribes", "people".
    let fewer: String
    @Binding var all: Bool

    var body: some View {
        Button {
            all.toggle()
        } label: {
            Text(all ? "Show fewer" : "Show all \(what)")
                .phoneFont(.row)
                .foregroundStyle(Theme.link)
                .frame(maxWidth: .infinity, minHeight: Theme.touchTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(all ? "Show fewer \(fewer)" : "Show all \(what)")
    }
}
