import PeelCore
import PeelUI
import SwiftUI

/// Chats (docs/design/iphone.md, screen 1): the large title with its glass
/// capsule (the orange bolt only when not connected, then New message), the
/// top rows, then Unread, Tribes and Direct messages in the Mac sidebar's
/// order and trimming (`AppModel.sidebarSections`). Its stack is the
/// router's `chats`.
struct ChatsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    @State private var connectionShown = false
    @State private var newMessageShown = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.chats) {
            ChatList()
                .navigationTitle("Chats")
                .modifier(ConnectionSubtitle())
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if model.connection != .connected {
                            Button { connectionShown = true } label: {
                                Image(systemName: "bolt.fill").foregroundStyle(Theme.attention)
                            }
                            .tint(Theme.attention)
                            .accessibilityLabel(model.connection == .connecting ? "Connecting" : "Not connected")
                            .accessibilityHint("Shows the connection and Reconnect now")
                            .popover(isPresented: $connectionShown) {
                                ConnectionPanel()
                                    .presentationCompactAdaptation(.popover)
                            }
                        }
                        Button { newMessageShown = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New message")
                    }
                }
                .sheet(isPresented: $newMessageShown) {
                    NavigationStack {
                        ComingScreen(title: "New message",
                                     detail: "Starting a chat from the phone comes next. Add people and join tribes on your Mac for now.")
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Close", systemImage: "xmark") { newMessageShown = false }
                                }
                            }
                    }
                }
                .chatsDestinations()
        }
        // Connected again: nothing to show the panel about.
        .onChange(of: model.connection == .connected) { _, connected in
            if connected { connectionShown = false }
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

/// A screen the design has and this build does not yet: its title and
/// what it will hold, never an empty page.
struct ComingScreen: View {
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "hourglass", description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The top rows, then the chats by section. Search shows it too, filtered
/// by name: then only the matching chats, every section open.
struct ChatList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let sections = model.sidebarSections
        // Read once here and passed down: a row redraws only when its own state changes.
        let states = model.readStates
        let empty = sections.unread.isEmpty && sections.tribes.isEmpty && sections.direct.isEmpty
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
            if !sections.unread.isEmpty {
                ChatsSection(title: "Unread") {
                    ForEach(sections.unread) { ChatLink(conversation: $0, state: states[$0.chat]) }
                }
            }
            // Searching shows every match: no chevron to say otherwise or
            // to change the saved layout.
            if !sections.tribes.isEmpty || !sections.tribesOpen {
                ChatsSection(title: "Tribes",
                             expanded: sections.searching ? nil : $model.sidebarLayout.tribesOpen) {
                    ForEach(sections.tribes) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allTribes {
                        ShowAll(what: "\(all) tribes", fewer: "tribes", all: $model.sidebarLayout.allTribes)
                    }
                }
            }
            if !sections.direct.isEmpty || !sections.directOpen {
                ChatsSection(title: "Direct messages",
                             expanded: sections.searching ? nil : $model.sidebarLayout.directOpen) {
                    ForEach(sections.direct) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allDirect {
                        ShowAll(what: Formatting.people(all), fewer: "people", all: $model.sidebarLayout.allDirect)
                    }
                }
            }
            if model.conversations.isEmpty, !sections.searching {
                Section { NoChats() }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
                Text("Tribes you join and people you add show here.")
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

    var body: some View {
        // Once per row build: the swipe and the menu share it.
        let read = readAction
        NavigationLink(value: ChatsRoute.chat(conversation.chat)) {
            ChatListRow(conversation: conversation, state: state)
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
