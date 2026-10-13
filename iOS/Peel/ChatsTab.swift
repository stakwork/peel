import PeelCore
import PeelUI
import SwiftUI

/// Unread, then tribes, then direct messages, in the Mac sidebar's order
/// (`AppModel.sidebarSections`). A chat pushes in; the open one is the
/// model's `destination`, so it is read as on the Mac.
struct ChatsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: openChat) {
            ChatList()
                .navigationTitle("Chats")
                .navigationSubtitle(model.connection == .connected ? "" : model.connection.label)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { ConnectionButton() }
                }
                .searchable(text: $model.searchQuery, prompt: "Search chats")
                .navigationDestination(for: String.self) { chat in
                    ConversationScreen(chat: chat)
                }
        }
    }

    /// The pushed chat, as the model's `destination`.
    private var openChat: Binding<[String]> {
        Binding {
            model.selectedChat.map { [$0] } ?? []
        } set: { path in
            model.destination = path.last.map { .chat($0) }
        }
    }
}

private struct ChatList: View {
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
            }
            if !sections.tribes.isEmpty {
                Section("Tribes") {
                    ForEach(sections.tribes) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allTribes {
                        ShowAll(what: "\(all) tribes", all: $model.sidebarLayout.allTribes)
                    }
                }
            }
            if !sections.direct.isEmpty {
                Section("Direct messages") {
                    ForEach(sections.direct) { ChatLink(conversation: $0, state: states[$0.chat]) }
                    if let all = sections.allDirect {
                        ShowAll(what: Formatting.people(all), all: $model.sidebarLayout.allDirect)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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

/// One chat: its picture and name, when it last moved, and its count.
private struct ChatLink: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let state: ChatReadState?

    var body: some View {
        let level = state?.mute ?? .all
        let unread = state?.sidebarCount ?? 0
        NavigationLink(value: conversation.chat) {
            HStack(spacing: Theme.Space.md) {
                ConversationIcon(conversation: conversation, size: 36)
                Text(conversation.name)
                    .font(Theme.font(16, unread > 0 ? .semibold : .regular))
                    .foregroundStyle(unread > 0 ? Theme.text : Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                if unread > 0 {
                    CountBadge(count: unread, mentionsYou: state?.mentions ?? 0 > 0)
                } else if state?.isNew == true {
                    // Someone who added you; nothing to answer.
                    Text("New")
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(Theme.accent)
                } else if level == .muted {
                    Image(systemName: "bell.slash").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                } else if level == .mentionsOnly {
                    Image(systemName: "at").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
                if let date = conversation.lastDate {
                    Text(Formatting.when(date))
                        .font(Theme.font(13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
            .opacity(level == .muted && unread == 0 ? 0.6 : 1)
        }
        .listRowBackground(Theme.background)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unread > 0 ? "\(unread) unread" + (state?.mentions ?? 0 > 0 ? ", mentions you" : "") : "")
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
            .listRowBackground(Theme.background)
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
