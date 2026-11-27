import PeelCore
import PeelUI
import SwiftUI

/// Chats (docs/design/iphone.md, screen 1; Tom, 2026-11-26, after the Mac's
/// rail): one list, newest first, Peel's own row first, unread chats bold
/// with their counts in place: no sections, no Separated / Recent, no rows
/// above the chats unless the person pinned Mentions or Threads from •••.
/// The bar: ••• (Mentions and Threads, and which of them show above the
/// chats), then the connection bolt and New chat (Add contact, Invite
/// someone, Join a tribe, Create a tribe). No search (Tom, 2026-11-27): the
/// list is newest first. Its stack is the router's `chats`.
struct ChatsTab: View {
    @Environment(PhoneRouter.self) private var router
    @Environment(AppModel.self) private var model
    /// The form or invite open over the list, as a sheet.
    @State private var sheet: PeopleSheet?

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.chats) {
            ChatList(sheet: $sheet)
                .onCallBannerInset()
                .navigationTitle("Chats")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { ChatsMoreMenu() }
                    ToolbarItem(placement: .topBarTrailing) { ConnectionBolt() }
                    ToolbarItem(placement: .topBarTrailing) { NewChatMenu(sheet: $sheet) }
                }
                .chatsDestinations()
        }
        .sheet(item: $sheet) { $0.screen }
    }
}

extension View {
    /// What Chats pushes, by `ChatsRoute`: a conversation hides
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
            }
        }
    }
}

/// The pages ••• opens on the iPhone, A–Z: Mentions and Threads
/// (Automations and Segments are the Mac's for now). A pinned one shows
/// above the chats, kept with the account's layout
/// (`AppModel.isPagePinned`).
enum ChatsPage: String, CaseIterable, Identifiable {
    case mentions, threads

    var id: String { rawValue }

    var route: ChatsRoute { self == .mentions ? .mentions : .threads }

    var title: String { self == .mentions ? String(localized: "Mentions") : String(localized: "Threads") }

    var systemImage: String { self == .mentions ? "at" : "bubble.left" }

    @MainActor func count(in model: AppModel) -> Int {
        self == .mentions ? model.unreadMentions : model.unreadThreads
    }
}

/// ••• on Chats: Mentions and Threads with how many are new, each pushing
/// its page. Each is pinned above the chats from its own page's bar
/// (`PinPageButton`), as the Mac pins from a page's header (Tom, 2026-11-27).
private struct ChatsMoreMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        Menu {
            ForEach(ChatsPage.allCases) { page in
                let count = page.count(in: model)
                Button {
                    router.chats.append(page.route)
                } label: {
                    Label {
                        Text(page.title)
                        if count > 0 { Text("\(count) new") }
                    } icon: {
                        Image(systemName: page.systemImage)
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityHint("Mentions and Threads")
    }
}

/// The pin in a Mentions or Threads page's bar: shows the page as a chip
/// above the chats, or takes it off; accent while pinned.
struct PinPageButton: View {
    @Environment(AppModel.self) private var model
    let page: ChatsPage

    var body: some View {
        let pinned = model.isPagePinned(page.rawValue)
        Button(pinned ? String(localized: "Remove from Chats") : String(localized: "Show on Chats"),
               systemImage: pinned ? "pin.fill" : "pin") {
            model.setPagePinned(page.rawValue, !pinned)
        }
        .tint(pinned ? Theme.accent : Theme.text)
    }
}

/// New chat on Chats: the four ways in, each opening its form as a sheet.
private struct NewChatMenu: View {
    @Binding var sheet: PeopleSheet?

    var body: some View {
        Menu {
            Button("Add contact", systemImage: "person.badge.plus") { sheet = .addContact }
            Button("Invite someone", systemImage: "envelope") { sheet = .inviteSomeone }
            Button("Join a tribe", systemImage: "person.3") { sheet = .joinTribe }
            Button("Create a tribe", systemImage: "plus.bubble") { sheet = .createTribe }
        } label: {
            Label("New chat", systemImage: "plus")
        }
    }
}

/// Pending invites, Peel's row, then every chat newest first
/// (`AppModel.latestChats`); above them, the pages pinned from •••.
struct ChatList: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: PeopleSheet?

    var body: some View {
        let chats = model.latestChats
        // Read once here and passed down: a row redraws only when its own state changes.
        let states = model.readStates
        // The agent's DM is its own row, first.
        let agent = model.agentChat.flatMap { chat in model.conversations.first { $0.chat == chat } }
        let pinned = ChatsPage.allCases.filter { model.isPagePinned($0.rawValue) }
        List {
            if !pinned.isEmpty {
                Section { PinnedPages(pages: pinned) }
                    .phoneRows()
                    .listRowSeparator(.hidden)
            }
            if model.diagnosticsNotice {
                Section { DiagnosticsNotice() }
                    .phoneRows()
            }
            if model.conversations.isEmpty {
                Section { NoChats(sheet: $sheet) }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(model.pendingInvites) { invite in
                    PendingInviteRow(invite: invite) { sheet = .invite(invite.code) }
                }
                if let agent {
                    ChatLink(conversation: agent, state: states[agent.chat], isAgent: true)
                }
                ForEach(chats) { ChatLink(conversation: $0, state: states[$0.chat]) }
            }
            .phoneRows()
            .listRowInsets(.vertical, 2)
        }
        .phoneList()
        .scrollEdges()
        // Reconnects if need be, then catches up from where history stands.
        .refreshable { await model.refresh() }
    }
}

/// The pages pinned from •••, above the chats: each a chip with its icon,
/// title and how many are new, pushing its page; Remove from Chats in its
/// menu.
private struct PinnedPages: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    let pages: [ChatsPage]

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(pages) { page in
                let count = page.count(in: model)
                Chip(.field, action: { router.chats.append(page.route) }) {
                    HStack(spacing: 6) {
                        Image(systemName: page.systemImage)
                            .foregroundStyle(Theme.secondaryText)
                        Text(page.title)
                            .foregroundStyle(Theme.text)
                        if count > 0 {
                            Text(Badge.text(count))
                                .monospacedDigit()
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .phoneFont(.secondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                }
                .accessibilityValue(count > 0 ? String(localized: "\(count) new") : "")
                .contextMenu {
                    Button("Remove from Chats", systemImage: "pin.slash") { model.setPagePinned(page.rawValue, false) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.xs)
    }
}

/// No chats on the account yet: what fills the list, in Peel's words, or
/// that a restore is still bringing them, with the ways in.
private struct NoChats: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: PeopleSheet?

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
                Text("Add someone or join a tribe, and they show here.")
            } actions: {
                Button("Add contact") { sheet = .addContact }
                    .buttonStyle(.peel(.primary, size: .touch))
                Button("Join a tribe") { sheet = .joinTribe }
                    .buttonStyle(.peel(.outline, size: .touch))
                Button("Invite someone") { sheet = .inviteSomeone }
                    .buttonStyle(.peel(.ghost, size: .touch))
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
