import PeelCore
import PeelUI
import SwiftUI

// What Chats' top rows push (docs/design/iphone.md, "Navigation map"):
// Threads and Mentions as the Mac lists them, and Automations, which the
// phone cannot reach yet. A chat opened from a list goes on top of it
// (`PhoneRouter.follow`), so Back returns to the list.

/// Threads this account started or wrote in, newest activity first, from
/// the Mac's model (`AppModel.threads`). A tap opens the chat with the
/// thread sheet over it, at the first new reply when there is one.
struct ThreadsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let threads = model.threads
        let conversations = Dictionary(model.conversations.map { ($0.chat, $0) }, uniquingKeysWith: { $1 })
        List {
            Section {
                ForEach(threads) { ThreadListRow(summary: $0, conversation: conversations[$0.chat]) }
            }
            .phoneRows()
        }
        .phoneList()
        .scrollEdges()
        .overlay {
            if threads.isEmpty {
                ContentUnavailableView {
                    Label("No threads yet", systemImage: "bubble.left")
                } description: {
                    Text("Threads you start or reply in show here, with their new replies.")
                }
            }
        }
        .navigationTitle("Threads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.unreadThreads > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mark all read") { Task { await model.markAllThreadsRead() } }
                }
            }
        }
    }
}

/// One thread: its chat and when it last moved, who started it and what
/// they said, then "2 new · 4 replies" and the newest reply's writer. New
/// replies make it bold, with the count in blue.
private struct ThreadListRow: View {
    @Environment(AppModel.self) private var model
    let summary: ThreadSummary
    let conversation: Conversation?

    var body: some View {
        let author = model.sender(of: summary.original)
        let unread = summary.unread > 0
        let chatName = conversation?.title ?? String(summary.chat.prefix(12))
        Button {
            model.openThread(summary)
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Avatar(name: author.avatarName, url: author.photoURL, size: 30, hue: author.hue)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(chatName)
                            .phoneFont(.secondary)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.sm)
                        if let lastDate = summary.lastDate {
                            TimelineView(.everyMinute) { context in
                                Text(Formatting.relative(lastDate, now: context.date))
                            }
                            .phoneFont(.time)
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    (Text(author.label + " ").foregroundColor(author.hue.name).fontWeight(.semibold)
                        + Text(summary.original.preview).foregroundColor(Theme.text)
                        .fontWeight(unread ? .semibold : .regular))
                        .phoneFont(.row)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if unread {
                            Text("\(summary.unread) new")
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.accent)
                            Text("·").foregroundStyle(Theme.tertiaryText)
                        }
                        Text(Formatting.replies(summary.count))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .phoneFont(.secondary)
                }
            }
            .padding(.vertical, 7)
            .frame(minHeight: Theme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Marks the whole chat read, as the Mac's thread menu does: no
        // full swipe, so it is never done by accident.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if unread {
                Button("Mark read", systemImage: "checkmark.circle") { markRead() }
                    .tint(Theme.accent)
            }
        }
        .contextMenu {
            Button("Open thread", systemImage: "bubble.left") { model.openThread(summary) }
            if unread {
                Button("Mark read", systemImage: "checkmark.circle") { markRead() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(author.label) in \(chatName): \(summary.original.preview)")
        .accessibilityValue(spoken)
        .accessibilityAddTraits(.isButton)
    }

    /// "2 new, 4 replies, 5 minutes ago".
    private var spoken: String {
        var parts: [String] = []
        if summary.unread > 0 { parts.append("\(summary.unread) new") }
        parts.append(Formatting.replies(summary.count))
        if let lastDate = summary.lastDate { parts.append(Formatting.relative(lastDate)) }
        return parts.joined(separator: ", ")
    }

    private func markRead() {
        let chat = summary.chat
        Task { await model.markRead(chat) }
    }
}

/// Tribe messages that mention you, newest first, followed while this is
/// open (`AppModel.mentionUpdates`), as the Mac's Mentions lists them. A
/// tap opens the tribe at the message.
struct MentionsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var mentions: [Message]?
    @State private var problem: String?

    var body: some View {
        let names = Dictionary(model.conversations.map { ($0.chat, $0.title) }, uniquingKeysWith: { $1 })
        List {
            Section {
                ForEach(mentions ?? []) { MentionListRow(message: $0, tribeName: names[$0.chat]) }
            }
            .phoneRows()
        }
        .phoneList()
        .scrollEdges()
        .overlay {
            if let problem, mentions?.isEmpty != false {
                ContentUnavailableView {
                    Label("Mentions did not load", systemImage: "at")
                } description: {
                    Text(problem)
                }
            } else if mentions?.isEmpty == true {
                ContentUnavailableView {
                    Label("No mentions yet", systemImage: "at")
                } description: {
                    Text("When someone in a tribe mentions you, it shows here.")
                }
            }
        }
        .navigationTitle("Mentions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                guard let updates = model.mentionUpdates() else { mentions = []; return }
                for try await rows in updates {
                    mentions = rows
                    problem = nil
                }
            } catch {
                problem = PeelError.problem(error, couldNot: "load mentions")
            }
        }
    }
}

/// One mention: who, in which tribe, when, and the message with you in
/// gold (`LinkText`, the Mac's).
private struct MentionListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    let message: Message
    let tribeName: String?

    var body: some View {
        let sender = Sender(member: message)
        let tribe = tribeName ?? String(message.chat.prefix(12))
        Button {
            router.open(message)
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Avatar(name: sender.avatarName, url: sender.photoURL, size: 30, hue: sender.hue)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(sender.name)
                            .phoneFont(.name)
                            .foregroundStyle(sender.hue.name)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text("in \(tribe)")
                            .phoneFont(.secondary)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.sm)
                        Text(Formatting.dateAndTime(message.date))
                            .phoneFont(.time)
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                    Text(LinkText.attributed(message.shownText, myAliases: model.mentionAliases(in: message.chat)))
                        .phoneFont(.message)
                        .foregroundStyle(Theme.text)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 7)
            .frame(minHeight: Theme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in \(tribe)", systemImage: "number") { router.open(message) }
            if let text = message.shownText.nilIfEmpty {
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(text) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sender.name) in \(tribe), \(Formatting.dateAndTime(message.date))")
        .accessibilityValue(message.shownText)
        .accessibilityAddTraits(.isButton)
    }
}

/// Automations run by the agent on your Mac, which the phone cannot reach
/// until the remote track (B3): it says so plainly rather than show a list
/// it does not have (docs/design/iphone.md, screen 5).
struct AutomationsScreen: View {
    var body: some View {
        ContentUnavailableView {
            Label("On your Mac for now", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Automations run on your home Mac, and you set them up and follow them there. They come to the phone once it can reach your Mac.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
    }
}
