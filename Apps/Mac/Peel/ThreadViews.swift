import SwiftUI
import PeelCore
import PeelUI

/// The thread beside its conversation: the original, "N replies", the
/// replies, and a composer that posts into the thread only.
struct ThreadPanel: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let ref: ThreadRef
    /// Beside the chat, rather than in its place.
    let beside: Bool

    static let width: CGFloat = 360

    /// Its rows as they were while open, shown while the panel slides out
    /// after it closes (`SidePanelSplit`): the model's go with the close.
    @State private var closingRows: [ChatRow] = []

    /// Opens a thread. Every way to a thread from a click (its "N
    /// replies", Threads, the offscreen driver) goes here, so they all move
    /// as one. No animation of its own: `SidePanelSplit` slides the panel
    /// and changes the chat's width once.
    static func opening<Result>(_ open: () throws -> Result) rethrows -> Result {
        try open()
    }

    /// Closes the thread: its X, Escape in its composer, the offscreen
    /// driver. The slide out is `SidePanelSplit`'s, as for `opening`.
    static func closing<Result>(_ close: () throws -> Result) rethrows -> Result {
        try close()
    }

    var body: some View {
        let composer = ComposerID.thread(ref)
        let tribe = conversation.isTribe ? model.tribes[conversation.chat] : nil
        VStack(spacing: 0) {
            DetailHeader(title: "Thread", subtitle: conversation.title) {
                EmptyView()
            } trailing: {
                IconButton("xmark", help: "Close thread (Escape)") {
                    ThreadPanel.closing { model.closeThread() }
                }
            }
            let open = model.openThread == ref
            if open ? model.thread != nil : !closingRows.isEmpty {
                MessageList(rows: open ? model.threadRows : closingRows, composer: composer,
                            canAnswer: tribe?.canManage == true)
                    .id(ref)
            } else {
                Spacer()
            }
            // The chat's notices (a reply refused here among them) when
            // the chat they would show under is not drawn.
            ChatFooter(conversation: conversation, tribe: tribe, composer: composer,
                       placeholder: "Reply in thread", showsNotice: !beside)
        }
        .background(Theme.panel)
        .fileDrop(into: composer)
        .onChange(of: model.threadRows, initial: true) { _, rows in
            if model.openThread == ref { closingRows = rows }
        }
    }
}

/// Under a collapsed thread: who replied, "N replies" (bold when some are
/// new) and the newest reply's sender and time. Click to open the thread.
struct ThreadSummaryLine: View {
    @Environment(AppModel.self) private var model
    let summary: ThreadSummary
    let inTribe: Bool

    @State private var hovering = false

    var body: some View {
        Button {
            ThreadPanel.opening { model.openThread(ThreadRef(chat: summary.chat, uuid: summary.uuid)) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.sm) {
                ParticipantAvatars(participants: summary.participants, chat: summary.chat, inTribe: inTribe)
                Text(Formatting.replies(summary.count))
                    .font(Theme.font(13, summary.unread > 0 ? .bold : .medium))
                    .foregroundStyle(Theme.accent)
                if summary.unread > 0 {
                    Text("\(summary.unread) new")
                        .font(Theme.font(12, .bold))
                        .foregroundStyle(Theme.text)
                }
                if let latest = summary.latest {
                    let who = model.sender(of: latest).label
                    TimelineView(.everyMinute) { context in
                        Text("\(who) replied \(Formatting.relative(latest.date, now: context.date))")
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            if let latest = summary.latest {
                LastReplyPreview(message: latest)
            }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(hovering ? Theme.divider : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .peelMenu {
            [.button("Open thread", systemImage: "bubble.left") {
                ThreadPanel.opening { model.openThread(ThreadRef(chat: summary.chat, uuid: summary.uuid)) }
            }]
        }
        .help("Open thread")
    }
}

/// The newest reply's words under a thread's line, "Name: text", smaller
/// than the original. Its sender's photo is already in the avatars above.
struct LastReplyPreview: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let sender = model.sender(of: message)
        (Text(sender.label + ": ").font(Theme.font(12, .semibold)).foregroundColor(sender.hue.name)
            + Text(message.threadReplyPreview).font(Theme.font(12)).foregroundColor(Theme.secondaryText))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

/// Up to three of a thread's people, overlapping.
struct ParticipantAvatars: View {
    @Environment(AppModel.self) private var model
    let participants: [ThreadParticipant]
    let chat: String
    let inTribe: Bool
    var size = Theme.AvatarSize.sm

    var body: some View {
        HStack(spacing: -5) {
            ForEach(Array(participants.prefix(3).enumerated()), id: \.offset) { _, person in
                let avatar = model.avatar(fromMe: person.fromMe, alias: person.alias, photoURL: person.photoURL,
                                          chat: chat, inTribe: inTribe)
                Avatar(name: avatar.avatarName, url: avatar.photoURL, size: size, hue: avatar.hue)
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
            }
        }
    }
}

/// Threads this account started or wrote in, across tribes and direct
/// messages, newest activity first. Unread ones are marked; clicking one
/// opens it beside its conversation.
struct ThreadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let threads = model.threads
        VStack(spacing: 0) {
            DetailHeader(title: "Threads") {
                EmptyView()
            } trailing: {
                if model.unreadThreads > 0 {
                    Button("Mark all read") { Task { await model.markAllThreadsRead() } }
                        .buttonStyle(.peel(.outline, size: .sm))
                }
            }
            if threads.isEmpty {
                EmptyState("No threads yet.")
            } else {
                let conversations = Dictionary(model.conversations.map { ($0.chat, $0) }, uniquingKeysWith: { $1 })
                ScrollView {
                    LazyVStack(spacing: Theme.Space.sm) {
                        ForEach(threads) { thread in
                            ThreadCard(summary: thread, conversation: conversations[thread.chat])
                        }
                    }
                    .frame(maxWidth: 780)
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct ThreadCard: View {
    @Environment(AppModel.self) private var model
    let summary: ThreadSummary
    let conversation: Conversation?

    @State private var hovering = false

    var body: some View {
        let original = summary.original
        let isTribe = conversation?.isTribe ?? false
        let author = model.sender(of: original)
        let unread = summary.unread > 0
        Button {
            ThreadPanel.opening { model.openThread(summary) }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Circle()
                    .fill(unread ? Theme.accent : .clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 15)
                Avatar(name: author.avatarName, url: author.photoURL, size: Theme.AvatarSize.lg, hue: author.hue)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(isTribe ? "#\(conversation?.name ?? "")" : conversation?.name ?? "")
                            .muted()
                        Spacer()
                        if let lastDate = summary.lastDate {
                            TimelineView(.everyMinute) { context in
                                Text(Formatting.relative(lastDate, now: context.date))
                            }
                            .monospacedDigit()
                            .muted()
                        }
                    }
                    (Text(author.label + " ").font(Theme.font(14, .bold)).foregroundColor(author.hue.name)
                        + Text(original.preview).font(Theme.font(14, unread ? .bold : .regular))
                        .foregroundColor(unread ? Theme.text : Theme.text.opacity(0.85)))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if unread {
                            Text("\(summary.unread) new")
                                .font(Theme.font(13, .bold))
                                .foregroundStyle(Theme.accent)
                            Text("·").foregroundStyle(Theme.secondaryText)
                        }
                        Text(Formatting.replies(summary.count))
                            .foregroundStyle(Theme.secondaryText)
                        if let latest = summary.latest {
                            let sender = model.sender(of: latest)
                            Text("·").foregroundStyle(Theme.secondaryText)
                            Avatar(name: sender.avatarName, url: sender.photoURL, size: Theme.AvatarSize.xs, hue: sender.hue)
                            (Text(sender.label + ": ")
                                .font(Theme.font(13, .medium))
                                .foregroundColor(sender.hue.name)
                                + Text(latest.preview))
                                .lineLimit(1)
                        }
                    }
                    .font(Theme.font(13))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Theme.Space.md)
            .background(hovering ? Theme.hover : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.divider))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .peelMenu {
            var entries: [MenuEntry] = [.button("Open thread", systemImage: "bubble.left") {
                ThreadPanel.opening { model.openThread(summary) }
            }]
            if summary.unread > 0 {
                entries.append(.button("Mark as read", systemImage: "checkmark.circle") {
                    Task { await model.markRead(summary.chat) }
                })
            }
            return entries
        }
    }
}
