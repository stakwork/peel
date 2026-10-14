import PeelCore
import PeelUI
import SwiftUI

/// Unread, then tribes, then direct messages, in the Mac sidebar's order
/// (`AppModel.sidebarSections`). Its stack is the router's `chats`; F2a
/// gives it the design's top rows, sections and swipe actions
/// (docs/design/iphone.md, screen 1).
struct ChatsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.chats) {
            ChatList()
                .navigationTitle("Chats")
                .navigationSubtitle(model.connection == .connected ? "" : model.connection.label)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { ConnectionButton() }
                }
                .chatsDestinations()
        }
    }
}

extension View {
    /// What Chats and Search push, by `ChatsRoute`: a conversation hides
    /// the tab bar. Threads, Mentions and Automations come with F2a.
    func chatsDestinations() -> some View {
        navigationDestination(for: ChatsRoute.self) { route in
            switch route {
            case .chat(let chat):
                ConversationScreen(chat: chat)
                    .toolbar(.hidden, for: .tabBar)
            case .threads:
                ComingScreen(title: "Threads", detail: "Threads you started or replied in show here.")
            case .mentions:
                ComingScreen(title: "Mentions", detail: "Messages that mention you show here.")
            case .automations:
                ComingScreen(title: "Automations", detail: "What your home Mac runs for you shows here.")
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

struct ChatList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let sections = model.sidebarSections
        let states = model.readStates
        List {
            if !sections.unread.isEmpty {
                Section("Unread") {
                    ForEach(sections.unread) { ChatLink(conversation: $0, state: states[$0.chat]) }
                }
                .phoneRows()
            }
            if !sections.tribes.isEmpty {
                Section("Tribes") {
                    ForEach(sections.tribes) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allTribes {
                        ShowAll(what: "\(all) tribes", all: $model.sidebarLayout.allTribes)
                    }
                }
                .phoneRows()
            }
            if !sections.direct.isEmpty {
                Section("Direct messages") {
                    ForEach(sections.direct) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allDirect {
                        ShowAll(what: Formatting.people(all), all: $model.sidebarLayout.allDirect)
                    }
                }
                .phoneRows()
            }
        }
        .phoneList()
        .overlay {
            if model.conversations.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Tribes you join and people you add show here."))
            } else if sections.searching, sections.unread.isEmpty, sections.tribes.isEmpty, sections.direct.isEmpty {
                ContentUnavailableView.search(text: model.searchQuery)
            }
        }
    }
}

/// One chat, pushed as a `ChatsRoute`.
private struct ChatLink: View {
    let conversation: Conversation
    let state: ChatReadState?

    var body: some View {
        NavigationLink(value: ChatsRoute.chat(conversation.chat)) {
            ChatListRow(conversation: conversation, state: state)
        }
    }
}

/// "Show all 14 tribes", then "Show fewer"; kept with the account, as the
/// Mac's sidebar keeps it.
private struct ShowAll: View {
    let what: String
    @Binding var all: Bool

    var body: some View {
        Button(all ? "Show fewer" : "Show all \(what)") { all.toggle() }
            .font(Theme.font(15))
            .foregroundStyle(Theme.accent)
    }
}

/// Sphinx's bolt: green when connected, orange otherwise. A tap says the
/// state, the last error, and offers to reconnect while offline.
private struct ConnectionButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    private var offline: Bool {
        if case .offline = model.connection { true } else { false }
    }

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "bolt.fill")
                .foregroundStyle(model.connection == .connected ? Theme.confirmed : Theme.attention)
        }
        .accessibilityLabel("Connection")
        .accessibilityValue(model.connection.label)
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(model.connection.label)
                    .font(Theme.font(16, .semibold))
                    .monospacedDigit()
                if let server = model.myServer {
                    Text(server)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondaryText)
                }
                if let error = model.connectionError {
                    Text(error)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if offline {
                    Button("Reconnect now") { Task { await model.reconnectNow() } }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(20)
            .frame(minWidth: 240, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
