import SwiftUI
import PeelCore

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ConversationList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            if let conversation = model.selectedConversation {
                ConversationView(conversation: conversation)
            } else {
                EmptyDetail()
            }
        }
        .navigationTitle(model.selectedConversation?.name ?? "Peel")
        .navigationSubtitle(model.connection == .connected ? "" : model.connection.label)
    }
}

struct ConversationList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedChat) {
            ForEach(model.conversations) { conversation in
                ConversationRow(conversation: conversation)
                    .tag(conversation.chat)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.conversations.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: conversation.name, url: conversation.photoURL, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(conversation.lastDate.map(Formatting.short) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var preview: String {
        guard let content = conversation.lastContent, !content.isEmpty else { return "No messages yet" }
        return (conversation.lastFromMe == true ? "You: " : "") + content
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connection == .connected ? Color.green.opacity(0.8) : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(model.connection.label)
                .lineLimit(1)
            Spacer()
            if let balance = model.balanceMsat {
                Text("\(balance / 1000) sats")
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct EmptyDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView("Pick a conversation", systemImage: "bubble.left")
            if let info = model.myContactInfo {
                VStack(spacing: 6) {
                    Text("Your contact info")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(info)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: 420)
                }
            }
        }
        .padding(24)
    }
}

/// A contact's photo, or their initial. Only https photos are ever loaded.
struct Avatar: View {
    let name: String
    let url: String?
    let size: CGFloat

    private var photo: URL? {
        url.flatMap(URL.init).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    var body: some View {
        AsyncImage(url: photo) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle()
                .fill(.quaternary)
                .overlay {
                    Text(name.prefix(1).uppercased())
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

enum Formatting {
    /// Time today, otherwise the day.
    static func short(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func dayHeading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
