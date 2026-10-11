import SwiftUI
import PeelCore

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    /// Keyboard: the row the arrows are on, nil at the selected one.
    @State private var highlighted: AppModel.Destination?
    @FocusState private var focused: Bool
    #if os(macOS)
    @State private var keys = KeyMonitor()
    /// Keys typed here, for the composer once it has the cursor.
    @State private var typedAhead: [NSEvent] = []
    #endif

    var body: some View {
        @Bindable var model = model
        let unreadMentions = model.unreadMentions
        let sections = model.sidebarSections
        // Read here, where the mentions count already reads them all, and
        // passed down: one chat's tick redraws only its own row.
        let readStates = model.readStates
        VStack(alignment: .leading, spacing: 12) {
            SidebarHeader()
            SearchField(text: $model.searchQuery, focusRequest: model.sidebarSearchFocus)
            ScrollViewReader { proxy in
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
                        if !sections.unread.isEmpty {
                            SidebarSection("Unread") {
                                ForEach(sections.unread) { conversation in
                                    ConversationLink(conversation: conversation, state: readStates[conversation.chat])
                                }
                            }
                        }
                        // Searching shows every match: no chevron to say otherwise or
                        // to change the saved layout.
                        SidebarSection("Tribes", expanded: sections.searching ? nil : $model.sidebarLayout.tribesOpen) {
                            ForEach(sections.tribes) { conversation in
                                ConversationLink(conversation: conversation, state: readStates[conversation.chat])
                            }
                            if sections.tribesOpen {
                                if let all = sections.allTribes {
                                    SidebarShowAll(what: "\(all) tribes", fewer: "tribes", all: $model.sidebarLayout.allTribes)
                                }
                                SidebarActionLink(title: "Join a tribe") { JoinTribeForm(done: $0) }
                                SidebarActionLink(title: "Create a tribe") { TribeSettingsForm(editing: nil, done: $0) }
                            }
                        }
                        SidebarSection("Direct messages",
                                       expanded: sections.searching ? nil : $model.sidebarLayout.directOpen) {
                            ForEach(sections.direct) { conversation in
                                ConversationLink(conversation: conversation, state: readStates[conversation.chat])
                            }
                            if sections.directOpen {
                                if let all = sections.allDirect {
                                    SidebarShowAll(what: Formatting.people(all), fewer: "people",
                                                   all: $model.sidebarLayout.allDirect)
                                }
                                ContactsSidebarRows()
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
                .onChange(of: highlighted) { if let highlighted { proxy.scrollTo(highlighted) } }
                // Opened by Go › Next Unread Chat, a jump or a notification:
                // in view, and the arrows go on from it.
                .onChange(of: model.destination) {
                    highlighted = nil
                    if let destination = model.destination { proxy.scrollTo(destination) }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .environment(\.sidebarHighlight, highlighted)
            .environment(\.sidebarClicked) {
                highlighted = nil
                // Now, not on the focus change: the chat this click opens
                // reads it as it appears.
                model.sidebarHasKeys = true
                focused = true
            }
            if let call = model.call {
                OnCallBar(call: call)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 34) // clear of the window's traffic lights
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
        .onChange(of: focused) {
            model.sidebarHasKeys = focused
            highlighted = nil
            #if os(macOS)
            if focused {
                // The responder that has the keys now; any other (a field,
                // the web page, a composer) and the keys are its own.
                let responder = presenter?.hostWindow?.firstResponder
                keys.start { handle($0, responder: responder) }
            } else {
                keys.stop()
                replayTypedAhead()
            }
            #endif
        }
        .onDisappear {
            // Locked or gone: nothing kept, nothing typed on.
            model.sidebarHasKeys = false
            #if os(macOS)
            keys.stop()
            typedAhead = []
            #endif
        }
    }

    /// The rows the arrows move through, top to bottom, as shown: not the
    /// "+" or "Show all" rows or invites.
    private var rows: [(destination: AppModel.Destination, title: String)] {
        let sections = model.sidebarSections
        let chats = sections.unread + sections.tribes + sections.direct
        return [(.threads, "Threads"), (.mentions, "Mentions"), (.payments, "Payments")]
            + chats.map { (.chat($0.chat), $0.name) }
    }

    /// The row `offset` from `current` (the selection when nothing is
    /// highlighted), stopping at the ends; the first or last row from
    /// anywhere else.
    static func step(_ rows: [AppModel.Destination], from current: AppModel.Destination?, by offset: Int)
        -> AppModel.Destination? {
        guard let index = current.flatMap(rows.firstIndex(of:)) else { return offset > 0 ? rows.first : rows.last }
        return rows[min(max(index + offset, 0), rows.count - 1)]
    }

    #if os(macOS)
    /// While the sidebar has focus, in the main window, unlocked, with no
    /// menu, panel or viewer up: Down and Up move the highlight, Return
    /// opens it, Escape clears it. Typing goes to the open chat.
    private func handle(_ event: NSEvent, responder: NSResponder?) -> Bool {
        guard model.phase == .ready, !model.isLockDue, let window = presenter?.hostWindow, event.window === window,
              responder != nil, !(responder is NSText), window.firstResponder === responder,
              presenter?.anythingOpen != true, model.viewer == nil, !event.modifierFlags.contains(.control)
        else { return false }
        // Typing ahead: the keys after the first go the same way, in order,
        // for the second a composer has to take the cursor.
        if let first = typedAhead.first {
            guard event.timestamp - first.timestamp > 1 else {
                typedAhead.append(event)
                return true
            }
            typedAhead = []
        }
        let rows = rows
        let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .shift])
        switch event.keyCode {
        case 125 where plain, 126 where plain: // Down, Up
            let next = Self.step(rows.map(\.destination), from: highlighted ?? model.destination,
                                 by: event.keyCode == 125 ? 1 : -1)
            highlighted = next
            if let title = rows.first(where: { $0.destination == next })?.title {
                AccessibilityNotification.Announcement(title).post()
            }
        case 36 where plain, 76 where plain:
            // Return, Enter: taken even with nothing highlighted, so a
            // second press never reaches a pane's default button (Pay).
            if let highlighted, rows.contains(where: { $0.destination == highlighted }) {
                model.destination = highlighted
                self.highlighted = nil
            }
        case 53 where plain: // Escape
            guard highlighted != nil else { return false }
            highlighted = nil
        default:
            return typeAhead(event)
        }
        return true
    }

    /// A character (or a dead key, or ⌘V) typed here: the open chat's
    /// composer takes the cursor and gets the key once it has it
    /// (`replayTypedAhead`), so input methods, accents and paste work as
    /// typed there. Not Tab, Delete or the other arrows.
    private func typeAhead(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let printable = event.characters?.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        } ?? false
        guard command ? event.charactersIgnoringModifiers == "v" : printable,
              case .chat(let chat) = model.destination, model.tribes[chat]?.canPost ?? true
        else { return false }
        typedAhead.append(event)
        model.composerFocus[.chat(chat), default: 0] += 1
        return true
    }

    /// The keys typed ahead, in order, once a composer has the cursor;
    /// dropped if anything else took it (a field, the PIN), Peel locked, or
    /// they are over a second old.
    private func replayTypedAhead() {
        let events = typedAhead
        typedAhead = []
        let now = ProcessInfo.processInfo.systemUptime
        guard model.phase == .ready, !model.isLockDue, let window = presenter?.hostWindow,
              let composer = window.firstResponder as? NSTextView, !composer.isFieldEditor
        else { return }
        for event in events.reversed() where event.window === window && now - event.timestamp < 1 {
            NSApp.postEvent(event, atStart: true)
        }
    }
    #endif
}

extension EnvironmentValues {
    /// The sidebar row the arrow keys are on.
    @Entry var sidebarHighlight: AppModel.Destination?
    /// A sidebar row was clicked: the sidebar takes the keys.
    @Entry var sidebarClicked: @MainActor () -> Void = {}
}

/// You, at the top of the sidebar like a workspace switcher: your photo,
/// name and balance, opening a menu with the account screen and your
/// contact info; the connection bolt beside it.
struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter

    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                presenter?.show(entries, at: anchor, source: "you")
            } label: {
                HStack(spacing: 9) {
                    Avatar(name: model.me.avatarName, url: model.myPhotoURL, size: 30, hue: model.myHue)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(model.me.name)
                                .font(Theme.font(15, .bold))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        BalanceLabel(money: model.money, waitingMsat: model.waitingMsat)
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
            .menuAnchor(anchor)
            .help("You")
            ConnectionBolt()
        }
    }

    /// Who you are (name, short key, balance), the account screen and your
    /// contact info. Receiving sats and invites join it when they are built.
    private var entries: [MenuEntry] {
        let detail = [model.myPubkey.map { "\($0.prefix(6))…\($0.suffix(4))" },
                      model.balanceText].compactMap { $0 }.joined(separator: " · ")
        var actions: [MenuEntry] = [
            .button("Account…", systemImage: "person", shortcut: .command(",")) { model.destination = .account },
        ]
        if let info = model.myContactInfo {
            actions.append(.copy("Copy contact info", text: info))
        }
        return .sections(
            [.view(AnyView(MenuIdentity(name: model.me.name, detail: detail, photoURL: model.myPhotoURL,
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
    var focusRequest = 0

    var body: some View {
        FormTextField(label: "Search", prompt: "Search", text: $text, systemImage: "magnifyingglass",
                      focusRequest: focusRequest)
    }
}

/// A sidebar section: its title, with a chevron that opens and closes it
/// when given `expanded` (without one, the title sits flush with the rows'
/// icons), over its rows. The rows are the caller's: a closed section still shows
/// the open chat (`ChatSections`).
struct SidebarSection<Content: View>: View {
    let title: String
    let expanded: Binding<Bool>?
    @ViewBuilder let content: Content

    init(_ title: String, expanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.expanded = expanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let expanded {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    header(open: expanded.wrappedValue)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            } else {
                header(open: nil)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
    }

    private func header(open: Bool?) -> some View {
        HStack(spacing: 6) {
            if let open {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(Theme.font(13, .medium))
        }
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
    }
}

/// A sidebar row that selects a destination, with an optional trailing accessory.
struct SidebarLink<Icon: View, Accessory: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.sidebarClicked) private var clicked
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
            clicked()
        } label: {
            HStack(spacing: 9) {
                icon.frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                accessory
            }
            .opacity(dimmed ? 0.6 : 1)
        }
        .buttonStyle(SidebarRowStyle(selected: model.destination == destination, unread: unread,
                                     highlighted: highlight == destination))
        .id(destination)
    }
}

/// A direct message or a tribe in the sidebar: bold with a count when unread,
/// the count gold when they mention you; dimmed with a crossed-out bell when
/// muted. A tribe set to mentions only (an @ beside it), or muted, counts
/// only the messages that mention you. The notification level is set from
/// its context menu.
struct ConversationLink: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    let conversation: Conversation
    /// The chat's unread count and level, `model.readStates[chat]`.
    let state: ChatReadState?

    var body: some View {
        let level = state?.mute ?? .all
        let unread = state?.sidebarCount ?? 0
        let onCall = model.liveCallCount(in: conversation.chat)
        // A muted chat that mentions you is in Unread at full strength.
        SidebarLink(conversation.name, to: .chat(conversation.chat), unread: unread > 0,
                    dimmed: level == .muted && unread == 0) {
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
                if state?.mentions ?? 0 > 0 {
                    UnreadBadge(text: UnreadBadge.text(unread), foreground: Theme.mentionYouText, fill: Theme.mentionYouFill)
                        .help("Mentions you")
                        .accessibilityLabel("\(unread) unread, mentions you")
                } else {
                    UnreadBadge(count: unread)
                }
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
/// no Leave: a contact is removed from their details (`ChatInfoPanel`),
/// where the confirm can stand beside its trigger.
/// The chat header's More menu (`HeaderMoreButton`) shares its pieces.
@MainActor
enum ConversationMenu {
    static func entries(for conversation: Conversation, model: AppModel) -> [MenuEntry] {
        let chat = conversation.chat
        let unread = model.readStates[chat]?.unread ?? 0
        var read: [MenuEntry] = []
        if unread > 0 {
            read.append(.button("Mark as read", systemImage: "checkmark.circle") { Task { await model.markRead(chat) } })
        } else if (try? model.engine?.storage.newestIncomingIndex(in: chat)) != nil {
            read.append(.button("Mark as unread", systemImage: "envelope.badge") { Task { await model.markUnread(chat) } })
        }
        guard conversation.isTribe, let tribe = model.tribes[chat] else {
            return .sections(read, levels(for: conversation, model: model))
        }
        return .sections(read, levels(for: conversation, model: model), link(tribe), leave(conversation, tribe, model: model))
    }

    /// The levels a chat offers, under "Notify me about", the current one checked.
    static func levels(for conversation: Conversation, model: AppModel) -> [MenuEntry] {
        let chat = conversation.chat
        let level = model.readStates[chat]?.mute ?? .all
        return [.header("Notify me about")] + choices(conversation).map { choice in
            .button(choice.title, checked: choice.level == level) { Task { await model.setMute(chat, choice.level) } }
        }
    }

    /// "Notifications", with the current level beside it and the levels behind it.
    static func notifications(for conversation: Conversation, model: AppModel) -> MenuEntry {
        let level = model.readStates[conversation.chat]?.mute ?? .all
        return .submenu("Notifications", systemImage: "bell",
                        detail: choices(conversation).first { $0.level == level }?.short,
                        levels(for: conversation, model: model))
    }

    /// The tribes server only marks mentions in tribes.
    private static func choices(_ conversation: Conversation) -> [(level: MuteLevel, title: String, short: String)] {
        conversation.isTribe
            ? [(.all, "All messages", "All"), (.mentionsOnly, "Mentions only", "Mentions"), (.muted, "Nothing (mute)", "Muted")]
            : [(.all, "All messages", "All"), (.muted, "Nothing (mute)", "Muted")]
    }

    static func link(_ tribe: Tribe) -> [MenuEntry] {
        tribe.link.map { [.copy("Copy tribe link", text: $0, systemImage: "link")] } ?? []
    }

    /// Leave, or Remove from Peel for a tribe this account can no longer
    /// post in; each confirmed by a second click.
    static func leave(_ conversation: Conversation, _ tribe: Tribe, model: AppModel) -> [MenuEntry] {
        let chat = conversation.chat
        if tribe.status != .active {
            return [.destructive("Remove from Peel", systemImage: "trash", confirm: "Remove #\(conversation.name)") {
                Task { await model.leave(chat) }
            }]
        }
        // The owner cannot leave, only delete the tribe (under Edit tribe).
        guard !tribe.isOwner else { return [] }
        return [.destructive("Leave tribe", systemImage: "rectangle.portrait.and.arrow.right",
                             confirm: "Leave #\(conversation.name)") {
            Task { await model.leave(chat) }
        }]
    }
}

/// Sphinx's bolt for the connection: green when connected, orange otherwise.
/// Click for the state, the retry countdown and the last connection error.
struct ConnectionBolt: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        IconButton(help: model.connection.label, size: .sm, lit: showing) {
            showing.toggle()
        } label: {
            Image(systemName: "bolt.fill")
                .foregroundStyle(connected ? Theme.confirmed : Theme.attention)
                .receivedGlow(model.money)
        }
        .peelPopover(isPresented: $showing) {
            ConnectionCard()
        }
    }
}

struct ConnectionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Ticks only while counting down to a retry.
            if case .offline = model.connection, let at = model.reconnectAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(Self.countdown(to: at, now: context.date))
                }
            } else {
                label(model.connection.label)
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
                    .buttonStyle(.peel(.link, size: .sm))
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(14, .medium))
            .monospacedDigit()
    }

    private static func countdown(to at: Date, now: Date) -> String {
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
            SidebarActionLabel(title: title, systemImage: "plus")
        }
        .buttonStyle(SidebarRowStyle(selected: false))
        .peelPopover(isPresented: $showing) {
            form { showing = false }
        }
    }
}

/// "Show all 14 tribes" under a section trimmed to its recent chats, then
/// "Show fewer" ("Show fewer tribes" to VoiceOver); which one is kept with
/// the account (`AppModel.sidebarLayout`).
struct SidebarShowAll: View {
    /// "14 tribes", "10 people".
    let what: String
    /// "tribes", "people".
    let fewer: String
    @Binding var all: Bool

    var body: some View {
        Button {
            all.toggle()
        } label: {
            SidebarActionLabel(title: all ? "Show fewer" : "Show all \(what)",
                               systemImage: all ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(SidebarRowStyle(selected: false))
        .accessibilityLabel(all ? "Show fewer \(fewer)" : "Show all \(what)")
    }
}

/// The icon and title of a sidebar row that acts rather than opens.
private struct SidebarActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 18)
            Text(title)
        }
    }
}

struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    /// Unread rows are bold and bright, as in Slack.
    var unread = false
    /// The arrow keys are on it: drawn as hovered.
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected, unread: unread, highlighted: highlighted)
    }

    private struct Row: View {
        let configuration: Configuration
        let selected: Bool
        let unread: Bool
        let highlighted: Bool
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
                        .fill(selected ? Theme.selection : hovering || highlighted ? Theme.hover : .clear)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
