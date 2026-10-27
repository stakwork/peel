import PeelCore
import PeelUI
import SwiftUI

/// A chat (docs/design/iphone.md, screen 2): the header (back, the name
/// and its second line, Call and More sharing one glass capsule), the
/// model's rows (`AppModel.chatRows`) as flat rows, and the composer
/// floating at the bottom, riding the keyboard. A thread opens over it as
/// a sheet (`PhoneRouter.thread`). The tab bar is hidden here (`ChatsTab`).
struct ConversationScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    let chat: String
    /// The agent's DM (`AppModel.agentChat`): AGENT in the header, "Ask
    /// Peel", no bolt or call. Its cards stay on the Mac (decision 9).
    private var isAgent: Bool { model.agentChat == chat }

    /// A contact's local time, when they shared one and it is not yours.
    @State private var localTime: LocalTime?
    /// A call waiting for "Leave and start", while on another.
    @State private var pendingCall: PendingCall?

    private var conversation: Conversation? {
        model.conversations.first { $0.chat == chat }
    }

    /// The rows last shown while the chat was open: the model clears its
    /// rows as the chat is left (Back, another tab) and while a window
    /// reloads, and the list keeps showing these through the pop and the
    /// reload rather than going blank. Not observed.
    @State private var held = HeldRows()
    /// Where the list opens, worked out once, as its messages first load:
    /// here, not in the body, which would then follow what it reads.
    @State private var start: MessageList.Start?

    var body: some View {
        let live = isLive
        let tribe = model.tribes[chat]
        Group {
            if let start {
                // Made once per chat, with its messages, so it opens placed
                // among them; kept, with its place, while the chat is away.
                MessageList(rows: live ? model.chatRows : held.rows, composer: .chat(chat), live: live, start: start)
                    .id(chat)
            } else {
                Color.clear
            }
        }
        .onChange(of: live, initial: true) { _, live in
            if live, start == nil { start = MessageList.start(of: .chat(chat), rows: model.chatRows, in: model) }
        }
        .onChange(of: model.chatRows, initial: true) { _, rows in
            if isLive { held.rows = rows }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .floatingBar(.bottom) { footer(tribe: tribe) }
        .onCallBannerInset()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { header(tribe: tribe) }
        .callSwitchConfirmation($pendingCall, model: model, router: router)
        .sheet(item: threadHere, onDismiss: router.threadDismissed) { thread in
            ThreadSheet(thread: thread, conversation: conversation)
        }
    }

    /// The model's rows are this chat's, loaded.
    private var isLive: Bool {
        model.selectedChat == chat && model.loadedChat == chat
    }

    final class HeldRows {
        var rows: [ChatRow] = []
    }

    /// The thread sheet's item: the router's, for this chat only.
    private var threadHere: Binding<ThreadRef?> {
        Binding { router.thread.wrappedValue.flatMap { $0.chat == chat ? $0 : nil } } set: { router.thread.wrappedValue = $0 }
    }

    // MARK: Header

    @ToolbarContentBuilder private func header(tribe: Tribe?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    Text(conversation?.name ?? "")
                        .phoneFont(PhoneFont.row.weight(.bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if isAgent { AgentTag() }
                }
                TimelineView(.everyMinute) { context in
                    if let subtitle = subtitle(at: context.date) {
                        Text(subtitle)
                            .phoneFont(.time)
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .task(id: chat) {
                if conversation?.isTribe == true {
                    await model.loadKnownMembers(chat)
                } else if !isAgent {
                    localTime = await model.localTime(of: chat, member: nil)
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isAgent, tribe?.canPost != false {
                // An account with no call server has no calls to start, as on the Mac.
                if model.calls.server != nil {
                    Menu("Call", systemImage: "phone") {
                        Button("Audio call", systemImage: "phone") {
                            PendingCall.start(chat: chat, audioOnly: true).ask(model, router, pending: $pendingCall)
                        }
                        Button("Video call", systemImage: "video") {
                            PendingCall.start(chat: chat, audioOnly: false).ask(model, router, pending: $pendingCall)
                        }
                    }
                    .disabled(model.calls.startingIn != nil || model.calls.joiningRoom != nil)
                }
            }
            Menu("More", systemImage: "ellipsis") { moreMenu(tribe: tribe) }
        }
    }

    /// A tribe's member count as its details count it; a person's local time.
    private func subtitle(at now: Date) -> String? {
        if conversation?.isTribe == true {
            return model.knownMembers[chat]?.countLabel
        }
        return model.localTimeLine(localTime, at: now)
    }

    @ViewBuilder private func moreMenu(tribe: Tribe?) -> some View {
        if let pinned = model.pinnedMessage, pinned.chat == chat {
            Button("Pinned message", systemImage: "pin") { router.open(pinned) }
        }
        if let link = tribe?.link {
            Button("Copy tribe link", systemImage: "link") {
                Clipboard.copy(link)
                CopyFeedback.announce()
            }
        }
        Section {
            Text("Members and details are coming to iPhone.")
        }
    }

    // MARK: Footer

    @ViewBuilder private func footer(tribe: Tribe?) -> some View {
        VStack(spacing: Theme.Space.sm) {
            if let notice = model.conversationNotices[chat] {
                NoticeBar(text: notice) { model.dismissNotice(in: chat) }
            }
            if let tribe, !tribe.canPost {
                Text(tribe.exit == nil ? "You can't post in this tribe." : "You can't post in this tribe any more.")
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Space.md)
            } else if let conversation {
                PhoneComposer(
                    composer: .chat(chat),
                    placeholder: isAgent ? "Ask Peel" : "Message \(conversation.title)",
                    loadMentionable: conversation.isTribe ? model.mentionLoader(chat) : nil,
                    paysTo: conversation.isTribe || isAgent ? nil : conversation.name
                )
            }
        }
    }
}

/// The chat's notice (a send refused, a call that could not start), over
/// the composer, dismissed with its ✕.
struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.attention)
                .accessibilityHidden(true)
            Text(text)
                .phoneFont(.secondary)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Theme.Space.md)
        .padding(.vertical, 4)
        .background(Theme.menu, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.attention.opacity(0.28)))
        .padding(.horizontal, Theme.Space.md)
        .accessibilityElement(children: .combine)
    }
}
