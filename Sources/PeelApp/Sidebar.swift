import SwiftUI
import PeelCore

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showTribes = true
    @State private var showDirect = true

    var body: some View {
        @Bindable var model = model
        let unreadMentions = model.unreadMentions
        VStack(alignment: .leading, spacing: 12) {
            SidebarHeader()
            SearchField(text: $model.searchQuery)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 1) {
                        let unreadThreads = model.unreadThreads
                        SidebarLink("Threads", to: .threads, unread: unreadThreads > 0) {
                            Image(systemName: "bubble.left").font(.system(size: 13))
                        } accessory: {
                            if unreadThreads > 0 { UnreadBadge(count: unreadThreads) }
                        }
                        SidebarLink("Mentions", to: .mentions, unread: unreadMentions > 0) {
                            Image(systemName: "at").font(.system(size: 13))
                        } accessory: {
                            if unreadMentions > 0 { UnreadBadge(count: unreadMentions) }
                        }
                        PaymentsLink(money: model.money)
                    }
                    SidebarSection("Tribes", expanded: $showTribes) {
                        ForEach(model.tribeConversations) { conversation in
                            ConversationLink(conversation: conversation)
                        }
                        SidebarActionLink(title: "Join a tribe") { JoinTribeForm(done: $0) }
                        SidebarActionLink(title: "Create a tribe") { TribeSettingsForm(editing: nil, done: $0) }
                    }
                    SidebarSection("Direct messages", expanded: $showDirect) {
                        ForEach(model.directConversations) { conversation in
                            ConversationLink(conversation: conversation)
                        }
                        ContactsSidebarRows()
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            if let call = model.call {
                OnCallBar(call: call)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 34) // clear of the window's traffic lights
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

/// You, at the top of the sidebar like a workspace switcher: your photo,
/// name and balance, opening a menu with the account screen and your
/// contact info; the connection bolt beside it.
struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter

    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                presenter?.show(entries, at: frame, source: "you")
            } label: {
                HStack(spacing: 9) {
                    Avatar(name: model.myAlias ?? "?", url: model.myPhotoURL, size: 30, hue: model.myHue)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(model.myAlias ?? "You")
                                .font(Theme.font(15, .bold))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        BalanceLabel(money: model.money)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(hovering || presenter?.source == AnyHashable("you") ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .help("You")
            ConnectionBolt()
        }
    }

    /// Who you are (name, short key, balance), the account screen and your
    /// contact info. Receiving sats and invites join it when they are built.
    private var entries: [MenuEntry] {
        let detail = [model.myPubkey.map { "\($0.prefix(6))…\($0.suffix(4))" },
                      model.balanceMsat.map { Sats.format(msat: $0) }].compactMap { $0 }.joined(separator: " · ")
        var actions: [MenuEntry] = [
            .button("Account…", systemImage: "person", shortcut: .command(",")) { model.destination = .account },
        ]
        if let info = model.myContactInfo {
            actions.append(.copy("Copy contact info", text: info))
        }
        return .sections(
            [.view(AnyView(MenuIdentity(name: model.myAlias ?? "You", detail: detail, photoURL: model.myPhotoURL,
                                        hue: model.myHue)))],
            actions
        )
    }
}

/// The header of the "you" menu: photo, name, short key and balance.
private struct MenuIdentity: View {
    let name: String
    let detail: String
    let photoURL: String?
    let hue: PersonHue

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: name, url: photoURL, size: 34, hue: hue)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(Theme.font(14, .bold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        FormTextField(label: "Search", prompt: "Search", text: $text, boxed: true, systemImage: "magnifyingglass")
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _expanded = expanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Text(title)
                        .font(Theme.font(13, .medium))
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content
            }
        }
    }
}

/// A sidebar row that selects a destination, with an optional trailing accessory.
struct SidebarLink<Icon: View, Accessory: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let destination: AppModel.Destination
    var unread = false
    var dimmed = false
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    init(
        _ title: String, to destination: AppModel.Destination, unread: Bool = false, dimmed: Bool = false,
        @ViewBuilder icon: () -> Icon, @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.destination = destination
        self.unread = unread
        self.dimmed = dimmed
        self.icon = icon()
        self.accessory = accessory()
    }

    var body: some View {
        Button {
            model.destination = destination
        } label: {
            HStack(spacing: 9) {
                icon.frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                accessory
            }
            .opacity(dimmed ? 0.6 : 1)
        }
        .buttonStyle(SidebarRowStyle(selected: model.destination == destination, unread: unread))
    }
}

/// A direct message or a tribe in the sidebar: bold with a count when unread,
/// dimmed with a crossed-out bell when muted. A tribe set to mentions only
/// counts only the messages that mention you, with an @ beside it. The
/// notification level is set from its context menu.
struct ConversationLink: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    let conversation: Conversation

    var body: some View {
        let state = model.readStates[conversation.chat]
        let level = state?.mute ?? .all
        let unread = state?.shownUnread ?? 0
        let onCall = model.liveCallCount(in: conversation.chat)
        SidebarLink(conversation.name, to: .chat(conversation.chat), unread: unread > 0, dimmed: level == .muted) {
            ConversationIcon(conversation: conversation, size: 18)
        } accessory: {
            if onCall > 0 {
                let people = Formatting.people(onCall)
                Image(systemName: "phone.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.confirmed)
                    .help("Call in progress, \(people)")
                    .accessibilityLabel("Call in progress, \(people)")
            }
            if unread > 0 {
                UnreadBadge(count: unread)
            } else if state?.isNew == true {
                NewContactBadge()
            } else if level == .muted {
                Image(systemName: "bell.slash")
                    .font(.system(size: 11))
                    .help("Muted")
            } else if level == .mentionsOnly {
                Image(systemName: "at")
                    .font(.system(size: 11))
                    .help("Mentions only")
            }
        }
        .overlay {
            if presenter?.source == AnyHashable(conversation.chat) {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
        .peelMenu(source: conversation.chat) { ConversationMenu.entries(for: conversation, model: model) }
    }
}

/// A sidebar row's menu: Mark as read (or unread), the notification level, and for a
/// tribe its link and leaving it (confirmed in place). Direct messages have
/// no Leave, and no Delete chat: the engine cannot delete a conversation.
@MainActor
enum ConversationMenu {
    static func entries(for conversation: Conversation, model: AppModel) -> [MenuEntry] {
        let chat = conversation.chat
        let level = model.readStates[chat]?.mute ?? .all
        let unread = model.readStates[chat]?.unread ?? 0
        var read: [MenuEntry] = []
        if unread > 0 {
            read.append(.button("Mark as read", systemImage: "checkmark.circle") { Task { await model.markRead(chat) } })
        } else if (try? model.engine?.storage.newestIncomingIndex(in: chat)) != nil {
            read.append(.button("Mark as unread", systemImage: "envelope.badge") { Task { await model.markUnread(chat) } })
        }
        var levels: [MenuEntry] = [.header("Notify me about")]
        // The tribes server only marks mentions in tribes.
        let choices: [(MuteLevel, String)] = conversation.isTribe
            ? [(.all, "All messages"), (.mentionsOnly, "Mentions only"), (.muted, "Nothing (mute)")]
            : [(.all, "All messages"), (.muted, "Nothing (mute)")]
        for (choice, title) in choices {
            levels.append(.button(title, checked: choice == level) { Task { await model.setMute(chat, choice) } })
        }
        guard conversation.isTribe, let tribe = model.tribe(chat) else { return .sections(read, levels) }
        let link: [MenuEntry] = tribe.link.map { link in
            [.copy("Copy tribe link", text: link, systemImage: "link")]
        } ?? []
        var leave: [MenuEntry] = []
        if tribe.status != .active {
            leave.append(.destructive("Remove from Peel", systemImage: "trash", confirm: "Remove #\(conversation.name)") {
                Task { await model.leave(chat) }
            })
        } else if !tribe.isOwner {
            // The owner cannot leave, only delete the tribe (under Edit tribe).
            leave.append(.destructive("Leave tribe", systemImage: "rectangle.portrait.and.arrow.right",
                                      confirm: "Leave #\(conversation.name)") {
                Task { await model.leave(chat) }
            })
        }
        return .sections(read, levels, link, leave)
    }
}

/// Sphinx's bolt for the connection: green when connected, orange otherwise.
/// Click for the state, the retry countdown and the last connection error.
struct ConnectionBolt: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13))
                .foregroundStyle(connected ? Theme.confirmed : Theme.attention)
                .receivedGlow(model.money)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.connection.label)
        .accessibilityLabel(model.connection.label)
        .peelPopover(isPresented: $showing) {
            ConnectionCard()
        }
    }
}

struct ConnectionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(label(at: context.date))
                    .font(Theme.font(14, .medium))
                    .monospacedDigit()
            }
            if let error = model.connectionError {
                Text(error)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            if case .offline = model.connection {
                Button("Reconnect now") { Task { await model.reconnectNow() } }
                    .buttonStyle(.plain)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private func label(at now: Date) -> String {
        guard case .offline = model.connection, let at = model.reconnectAt else { return model.connection.label }
        let seconds = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
        return seconds > 0 ? "Offline, retrying in \(seconds)s" : "Offline, retrying"
    }
}

/// A "+" row at the end of a sidebar section that opens a form in a popover.
struct SidebarActionLink<Form: View>: View {
    let title: String
    @ViewBuilder let form: (_ done: @escaping () -> Void) -> Form
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(title)
            }
        }
        .buttonStyle(SidebarRowStyle(selected: false))
        .peelPopover(isPresented: $showing) {
            form { showing = false }
        }
    }
}

struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    /// Unread rows are bold and bright, as in Slack.
    var unread = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected, unread: unread)
    }

    private struct Row: View {
        let configuration: Configuration
        let selected: Bool
        let unread: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.font(14, unread ? .bold : selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.selectionText : unread ? Theme.text : Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Theme.selection : hovering ? Theme.hover : .clear)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
