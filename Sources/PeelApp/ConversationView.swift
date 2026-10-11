import SwiftUI
import PeelCore

/// A chat: its header, the conversation and the composer, with the open
/// thread beside it. On a window too narrow for both, the thread takes the
/// conversation's place rather than covering it.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    /// Dragged on its divider; remembered on this Mac (a convenience).
    @AppStorage("threadWidth") private var threadWidth: Double = ThreadPanel.width

    /// The narrowest the conversation gets beside a thread.
    private static let minimumWidth: CGFloat = 380
    /// How narrow and how wide the thread may be dragged.
    private static let threadRange = 300.0...560.0

    var body: some View {
        let thread = model.openThread.flatMap { $0.chat == conversation.chat ? $0 : nil }
        SidePanelSplit(isOpen: thread != nil, width: $threadWidth, range: Self.threadRange,
                       standard: ThreadPanel.width, minimumMain: Self.minimumWidth) {
            // Its draft lives in the model, so it survives being covered.
            ChatColumn(conversation: conversation)
        } panel: { beside in
            if let thread {
                ThreadPanel(conversation: conversation, ref: thread, beside: beside)
            }
        }
    }
}

/// A column with a panel beside it on the right (a thread, the web pane),
/// resizable on its divider. On a window too narrow for both, the panel
/// takes the column's place rather than covering it.
struct SidePanelSplit<Main: View, Panel: View>: View {
    let isOpen: Bool
    /// Dragged on the divider.
    @Binding var width: Double
    /// How narrow and how wide the panel may be dragged.
    let range: ClosedRange<Double>
    /// Where a double-click on the divider puts it.
    let standard: Double
    /// The narrowest the column gets beside the panel.
    let minimumMain: CGFloat
    @ViewBuilder let main: () -> Main
    /// Told whether it is beside the column, or in its place.
    @ViewBuilder let panel: (_ beside: Bool) -> Panel

    var body: some View {
        // Always inside the reader, so opening the panel keeps the column
        // (its scroll position and drafts) rather than making it again.
        GeometryReader { geometry in
            // Beside the column, the panel gets what is left up to the width
            // it was dragged to, so a drag or a narrow window shrinks it
            // before it has to take the column's place.
            let room = Double(geometry.size.width - minimumMain - 1)
            let both = room >= range.lowerBound
            HStack(spacing: 0) {
                if !isOpen || both {
                    main()
                }
                if isOpen {
                    if both {
                        PaneDivider(width: $width, range: range.lowerBound...min(range.upperBound, room),
                                    standard: standard, growsTo: .leading)
                    }
                    panel(both)
                        .frame(width: both ? min(width, room) : nil)
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }
}

extension Conversation {
    /// "#tribe" or the contact's name, where a chat is named outside its own header.
    var title: String { isTribe ? "#\(name)" : name }
}

/// A chat's header, conversation and composer. Its own view, so resizing the
/// window or opening a thread does not redraw it.
private struct ChatColumn: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let tribe = conversation.isTribe ? model.tribes[conversation.chat] : nil
        let composer = ComposerID.chat(conversation.chat)
        VStack(spacing: 0) {
            if conversation.isTribe {
                TribeHeader(conversation: conversation, tribe: tribe)
                if let tribe, let pinned = model.pinnedMessage, pinned.chat == conversation.chat {
                    PinnedMessageBar(message: pinned, tribe: tribe)
                }
            } else {
                // Its own per contact, so one's local time never shows under another.
                DirectHeader(conversation: conversation)
                    .id(conversation.chat)
            }
            if let search = model.search, search.chat == conversation.chat {
                ChatSearchBar(search: search, placeholder: "Search in \(conversation.title)")
            }
            MessageList(rows: model.chatRows, composer: composer, canAnswer: tribe?.canManage == true)
            // A fresh scroll view per chat: reusing one across chats left the
            // lazy stack blank at the bottom anchor until it was scrolled.
            // Made again once the messages have loaded, so it starts at
            // the bottom of them rather than of an empty list.
            .id(model.timeline.messages.isEmpty ? nil : conversation.chat)
            ChatFooter(
                conversation: conversation, tribe: tribe, composer: composer,
                placeholder: conversation.isTribe ? "Message #\(conversation.name)" : "Message \(conversation.name)",
                paysTo: conversation.isTribe ? nil : conversation.name
            )
        }
        .fileDrop(into: composer, for: conversation)
        .onAppear {
            // Opened from the sidebar's keys, the keys stay there.
            if !model.sidebarHasKeys { model.composerFocus[composer, default: 0] += 1 }
        }
    }
}

/// Under a chat or its thread: the chat's notice (a send refused, from
/// either composer), then the composer, or why the tribe takes no posts.
struct ChatFooter: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe?
    let composer: ComposerID
    let placeholder: String
    var paysTo: String?
    /// The notice shows once: under the thread only when the thread has
    /// taken the chat's place.
    var showsNotice = true

    var body: some View {
        if showsNotice, let notice = model.conversationNotices[conversation.chat] {
            NoticeBar(text: notice) { model.dismissNotice(in: conversation.chat) }
                .padding(.horizontal, 20)
                .padding(.top, 6)
        }
        if let tribe, !tribe.canPost {
            TribeStatusBar(conversation: conversation, tribe: tribe)
        } else {
            Composer(
                composer: composer, placeholder: placeholder,
                loadMentionable: conversation.isTribe ? model.mentionLoader(conversation.chat) : nil,
                paysTo: paysTo
            )
            .id(composer)
        }
    }
}

/// An error to show until dismissed: one that belongs to a conversation,
/// such as a send the server refused, or the engine's own across the main
/// window. Quiet, not red: nothing was destroyed.
struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.attention)
            Text(text)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 8)
            IconButton("xmark", help: "Dismiss", size: .sm, action: dismiss)
                // Its hover square reaches into the bar's padding, so the bar keeps its height.
                .padding(.vertical, -6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .panelBoxed()
    }
}


/// A tribe's name, what it is about and what a message costs, then Call
/// and More (H1): Browser, the second brain and the app (tabs in the web pane), Members,
/// Tribe details (⌘I), the link, Notifications, Edit tribe for the owner and
/// Leave, confirmed in the menu. Members, Tribe details and Edit open below
/// More, the details from a click on the tribe's name or icon too.
struct TribeHeader: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe?

    @State private var panel: HeaderPanel?

    /// Which of the tribe's panels is open below More.
    private enum HeaderPanel: Equatable { case members, details, edit }

    private var subtitle: String? {
        guard let tribe else { return nil }
        return [
            tribe.isPrivate ? "Private" : nil, tribe.summary?.trimmed.nilIfEmpty,
            "\(tribe.messagePrice.text) a message",
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        DetailHeader(title: conversation.name, subtitle: subtitle, onTitle: { panel = .details }) {
            ConversationIcon(conversation: conversation, size: 32)
        } trailing: {
            HStack(spacing: 4) {
                SearchHeaderButton(chat: conversation.chat)
                if tribe?.canPost != false {
                    CallHeaderButton(chat: conversation.chat)
                }
                HeaderMoreButton(
                    chat: conversation.chat, detailsTitle: "Tribe details", showsDetails: shows(.details), entries: entries
                ) {
                    details
                }
                .peelPopover(isPresented: shows(.members)) {
                    TribeMembersPanel(conversation: conversation, tribe: tribe) { panel = nil }
                }
                .peelPopover(isPresented: shows(.edit)) {
                    if let tribe { TribeSettingsForm(editing: tribe) { panel = nil } }
                }
            }
        }
        // A panel asked for in one tribe never opens over the next.
        .onChange(of: conversation.chat) { panel = nil }
    }

    @ViewBuilder private var details: some View {
        if let tribe {
            TribeDetailsPanel(
                conversation: conversation, tribe: tribe, members: { panel = .members }, edit: { panel = .edit }
            ) { panel = nil }
        }
    }

    private func entries(details: MenuEntry) -> [MenuEntry] {
        var edit: [MenuEntry] = []
        if let tribe, tribe.canManage {
            edit.append(.button("Edit tribe…", systemImage: "slider.horizontal.3") { panel = .edit })
        }
        return .sections(
            WebMenuEntries.entries(for: tribe, pane: model.web),
            [.button("Members", systemImage: "person.2") { panel = .members },
             details]
                + (tribe.map(ConversationMenu.link) ?? [])
                + [ConversationMenu.notifications(for: conversation, model: model)],
            edit + (tribe.map { ConversationMenu.leave(conversation, $0, model: model) } ?? [])
        )
    }

    private func shows(_ which: HeaderPanel) -> Binding<Bool> {
        Binding { panel == which } set: { shown in
            if shown { panel = which } else if panel == which { panel = nil }
        }
    }
}

/// A chat header's More (•••): its menu below it, and the chat's details
/// panel, which opens below it however it is asked for: the menu's Details
/// (handed to `entries` to place), ⌘I from anywhere in the chat, or a click
/// on the header's name or icon (the header sets `showsDetails`).
struct HeaderMoreButton<Details: View>: View {
    let chat: String
    /// "Details" for a contact, "Tribe details" for a tribe.
    var detailsTitle = "Details"
    @Binding var showsDetails: Bool
    /// The menu, given its Details entry.
    let entries: @MainActor (_ details: MenuEntry) -> [MenuEntry]
    @ViewBuilder let details: () -> Details

    var body: some View {
        let open = $showsDetails
        MenuButton(systemImage: "ellipsis", help: "More", source: "more-\(chat)") {
            entries(.button(detailsTitle, systemImage: "info.circle", shortcut: .command("i")) { open.wrappedValue = true })
        }
        .hiddenShortcut(KeyboardShortcut("i", modifiers: .command)) { showsDetails = true }
        .peelPopover(isPresented: $showsDetails, content: details)
    }
}

/// Who is in the tribe, its link, and leaving it. Only the owner gets the
/// full list from the tribes server; everyone else sees who has posted.
struct TribeMembersPanel: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe?
    let done: () -> Void

    @State private var members: TribeMembers?
    @State private var problem: String?

    var body: some View {
        Panel(members?.complete == false ? "Seen in #\(conversation.name)" : "Members", compact: true, close: done) {
            if members?.complete == false {
                Text("Only the tribe's owner gets the full member list.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            memberList
        } actions: {
            if let link = tribe?.link {
                CopyButton("Copy link", text: link, systemImage: "link", iconOnly: true)
            }
        } footer: {
            let exit = tribe?.exit
            if exit != nil || problem != nil {
                FormFooter(problem: problem) {
                    if let exit {
                        InlineConfirm(trigger: exit.title, confirm: exit.confirm(conversation.name)) {
                            await model.leave(conversation.chat)
                            done()
                        }
                    }
                }
            }
        }
        .task(id: conversation.chat) { await load() }
    }

    @ViewBuilder private var memberList: some View {
        if let members {
            let pending = members.members.filter(\.pending)
            let confirmed = members.members.filter { !$0.pending }
            let me = model.myPubkey
            let canManage = tribe?.canManage == true
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Requests to join a private tribe come first, as in the Mac app.
                    if !pending.isEmpty {
                        SectionLabel("Waiting for approval")
                        ForEach(pending) { member in
                            MemberRow(alias: member.alias, photoURL: member.photoURL, hue: model.hue(of: member), note: nil) {
                                JoinRequestButtons { approve in await answer(member, approve: approve) }
                            }
                            .peelMenu {
                                .sections(
                                    [
                                        .button("Approve", systemImage: "checkmark") {
                                            Task { await answer(member, approve: true) }
                                        },
                                        .button("Decline", systemImage: "xmark") {
                                            Task { await answer(member, approve: false) }
                                        },
                                    ],
                                    [.copy("Copy name", text: member.alias)]
                                )
                            }
                        }
                        SectionLabel("Members")
                    }
                    // The server's list includes this account; the seen list does not.
                    if !members.complete {
                        let me = model.me(in: conversation.chat)
                        MemberRow(alias: me.name, photoURL: me.photoURL, hue: me.hue, note: "you")
                    }
                    ForEach(confirmed) { member in
                        let isMe = member.pubkey != nil && member.pubkey == me
                        MemberRow(alias: member.alias, photoURL: member.photoURL, hue: model.hue(of: member),
                                  note: isMe ? "you, owner" : nil) {
                            if let pubkey = member.pubkey, !isMe, canManage {
                                InlineConfirm(trigger: "Remove", confirm: "Remove \(member.alias)", style: .text) {
                                    await kick(pubkey)
                                }
                                .font(Theme.font(12, .medium))
                                .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .peelMenu {
                            var remove: [MenuEntry] = []
                            if let pubkey = member.pubkey, !isMe, canManage {
                                remove.append(.destructive("Remove from tribe", systemImage: "person.badge.minus",
                                                           confirm: "Remove \(member.alias)") { Task { await kick(pubkey) } })
                            }
                            return .sections(
                                [.copy("Copy name", text: member.alias)], remove
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        } else if problem == nil {
            TribeServerProgress()
        }
    }

    private func load() async {
        do {
            members = try await model.tribeMembers(conversation.chat)
        } catch {
            problem = PeelError.problem(error, couldNot: "load the members")
        }
    }

    private func answer(_ member: TribeMember, approve: Bool) async -> Bool {
        guard let pubkey = member.pubkey else { return false }
        problem = nil
        do {
            try await model.answerJoinRequest(
                in: conversation.chat, .member(pubkey: pubkey, alias: member.alias), approve: approve
            )
        } catch {
            problem = PeelError.problem(error, couldNot: approve ? "approve" : "decline")
            return false
        }
        await load()
        return true
    }

    private func kick(_ pubkey: String) async {
        problem = nil
        do {
            try await model.kick(pubkey, from: conversation.chat)
            await load()
        } catch {
            problem = PeelError.problem(error, couldNot: "remove the member")
        }
    }
}

struct MemberRow<Actions: View>: View {
    let alias: String
    let photoURL: String?
    let hue: PersonHue
    let note: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 9) {
            Avatar(name: alias, url: photoURL, size: 24, hue: hue)
            Text(alias)
                .font(Theme.font(13))
                .foregroundStyle(hue.name)
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 6)
            actions
        }
    }
}

extension MemberRow where Actions == EmptyView {
    init(alias: String, photoURL: String?, hue: PersonHue, note: String?) {
        self.init(alias: alias, photoURL: photoURL, hue: hue, note: note) { EmptyView() }
    }
}

/// "Name joined", "Name left" and the owner's decisions, between the
/// messages of a tribe, worded as the Mac app words them.
struct MembershipNote: View {
    let message: Message
    /// The row's sender (`People.sender(of:inTribe:)`).
    let sender: Sender

    private var text: String {
        let who = sender.label
        switch message.type {
        case MessageType.groupLeave: return "\(who) left"
        case MessageType.groupKick: return "The owner removed you from this tribe"
        case MessageType.memberRequest: return "You asked to join"
        // The tribe names the approved member as the sender.
        case MessageType.memberApprove: return "\(Sender(member: message).name) was approved"
        case MessageType.memberReject:
            return message.fromMe ? "You declined a request to join" : "The owner declined your request to join"
        case MessageType.tribeDelete: return "The owner deleted this tribe"
        default: return "\(who) joined"
        }
    }

    var body: some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

struct DayDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            Theme.divider.frame(height: 1)
            Text(Formatting.dayHeading(date))
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                // Circular ends: the continuous capsule's stroke draws square
                // stubs past its ends at this height.
                .overlay(Capsule(style: .circular).strokeBorder(Theme.divider))
                .fixedSize()
            Theme.divider.frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

/// "New messages" above the first message that was unread when the chat
/// opened; blue, because blue is unread.
struct NewMessagesDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Theme.accent.frame(height: 1)
            Text("New messages")
                .font(Theme.font(12, .semibold))
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
        .padding(.vertical, 6)
    }
}

/// "Not delivered" (or "Not uploaded", or for a payment or boost "Not
/// sent") with Retry and Discard. Discard asks once, in place. A payment's
/// Retry goes through `PaymentAttempt`: over the threshold it first asks
/// an orange "Send 1,000 sats" (or "Boost …") to click again.
struct UndeliveredActions: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var confirmingDiscard = false
    @State private var attempt = PaymentAttempt()

    private var isPayment: Bool { MessageType.payments.contains(message.type) }
    private var what: String {
        message.type == MessageType.boost ? "boost" : message.type == MessageType.directPayment ? "payment"
            : message.type == MessageType.invoice ? "request" : "message"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let armed = attempt.armed {
                Button { Task { await retry() } } label: {
                    Text("\(message.type == MessageType.boost ? "Boost" : "Send") \(Sats.format(msat: armed))")
                        .buttonProgress(attempt.working, size: .mini)
                }
                .monospacedDigit()
                .foregroundStyle(Theme.attention)
                .disabled(attempt.working)
                ConfirmHint()
                Button("Cancel") { attempt.armed = nil }
                    .foregroundStyle(Theme.secondaryText)
            } else {
                if !confirmingDiscard {
                    Text(label)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                    // Ours from history or another device is never paid again from here.
                    if message.isRetryable() {
                        Button { Task { await retry() } } label: { Text("Retry").buttonProgress(attempt.working, size: .mini) }
                            .foregroundStyle(Theme.accent)
                            .disabled(attempt.working)
                    }
                }
                if message.isDiscardable {
                    InlineConfirm(
                        trigger: "Discard", prompt: "Discard this \(what)?", confirm: "Discard", style: .text,
                        confirming: $confirmingDiscard
                    ) {
                        await model.discard(message)
                    }
                    .foregroundStyle(Theme.secondaryText)
                }
            }
            if let problem = attempt.problem {
                ProblemText(problem)
            }
        }
        .buttonStyle(.plain)
        .font(Theme.font(11, .medium))
    }

    private var label: String {
        // An attachment the memes server never got says so, as the Mac app.
        if message.uploadState == .failed { return "Not uploaded" }
        guard isPayment else { return "Not delivered" }
        if message.type == MessageType.boost, let msat = message.amountMsat {
            return "Boost of \(Sats.format(msat: msat)) not sent"
        }
        return "Not sent"
    }

    private func retry() async {
        guard isPayment else { return await model.resend(message) }
        _ = await attempt.run { await model.retryPayment(message, confirmedMsat: $0) }
    }
}

/// Styles the inline markup of message text (`MessageMarkup.inlines`): https
/// links clickable, mentions and inline code set apart, emphasis in bold,
/// italic or struck through. Anything else stays plain text.
enum LinkText {
    /// Mentions as a soft chip, gold when it names you (by one of `myAliases`,
    /// `AppModel.mentionAliases`) or @all; inline code in a monospaced face
    /// on a soft fill, without its backticks; https links in the link
    /// colour, as `MessageMarkup.linkLabel` words them (the host always
    /// whole; the full address is what opens); a `[text](https://…)` link as
    /// its text with its host beside it, so where it goes is never hidden.
    static func attributed(_ text: String, myAliases: Set<String>) -> AttributedString {
        var result = AttributedString()
        for inline in MessageMarkup.inlines(text) {
            var shown = AttributedString(inline.text)
            switch inline.kind {
            case nil:
                break
            case .mention:
                let you = mentions(inline.text, aliases: myAliases)
                shown.font = Theme.font(14, you ? .semibold : .medium)
                shown.foregroundColor = you ? Theme.mentionYouText : Theme.mentionText
                shown.backgroundColor = you ? Theme.mentionYouFill : Theme.mentionFill
            case .code:
                shown.font = Theme.code(13)
                shown.backgroundColor = Theme.codeFill
            case .link(let url):
                shown = AttributedString(MessageMarkup.linkLabel(inline.text, url: url))
                shown.link = url
                shown.foregroundColor = Theme.link
            case .namedLink(let url):
                shown.foregroundColor = Theme.link
                // Isolated left to right, so a direction override in the
                // text before it cannot turn the host around.
                var host = AttributedString(" (\u{2066}\(MessageMarkup.host(of: url) ?? url.absoluteString)\u{2069})")
                host.foregroundColor = Theme.secondaryText
                shown += host
                shown.link = url
            }
            var intent: InlinePresentationIntent = []
            if inline.emphasis.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if inline.emphasis.contains(.italic) { intent.insert(.emphasized) }
            if inline.emphasis.contains(.strikethrough) { intent.insert(.strikethrough) }
            if !intent.isEmpty { shown.inlinePresentationIntent = intent }
            result += shown
        }
        return result
    }
}

