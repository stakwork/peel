import AgentKit
import SwiftUI
import PeelAgent
import PeelCore
import PeelUI

// MARK: - Chat list

/// The Mac's chat list, beside the rail on Chats (Tom, 2026-11-26): the
/// pages pinned above it (`PinnedPageRows`), pending invites, Peel first,
/// then every chat newest first, unread ones bold in place
/// (`AppModel.latestChats`). No sections and no
/// Separated / Recent: one list, as in Signal. The search filters it and
/// finds messages under it.
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
        let chats = shownChats
        let searching = searching
        // Read here and passed down: one chat's tick redraws only its own row.
        let readStates = model.readStates
        let agent = shownAgent
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !searching {
                        PinnedPageRows()
                        PendingInviteRows()
                    }
                    if let agent {
                        AgentLink(agent: agent, conversation: model.conversations.first { $0.chat == model.agentChat })
                    }
                    ForEach(chats) { conversation in
                        ConversationLink(conversation: conversation, state: readStates[conversation.chat])
                    }
                    if !searching, chats.isEmpty {
                        NoChatsYet()
                    }
                    if searching {
                        SidebarMessageResults(search: model.sidebarSearch, chatsFound: !chats.isEmpty || agent != nil)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.md)
            }
            .scrollIndicators(.automatic)
            .onChange(of: highlighted) { if let highlighted { proxy.scrollTo(highlighted) } }
            // Opened by Go › Next Unread Chat, a jump or a notification:
            // in view, and the arrows go on from it.
            .onChange(of: model.destination) {
                highlighted = nil
                if let destination = model.destination { proxy.scrollTo(destination) }
            }
            // Back from another rail section, rebuilt: the open chat in view again.
            .onAppear { if let destination = model.destination { proxy.scrollTo(destination) } }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        // The rail's Chats (⌘1): the keys here, as a click on a row gives them.
        .onAppear { takeKeysIfAsked() }
        .onChange(of: model.chatListWantsKeys) { takeKeysIfAsked() }
        .onDisappear {
            // Locked, gone, or another rail section: nothing kept, nothing typed on.
            model.sidebarHasKeys = false
            #if os(macOS)
            keys.stop()
            typedAhead = []
            #endif
        }
    }

    private func takeKeysIfAsked() {
        guard model.chatListWantsKeys else { return }
        model.chatListWantsKeys = false
        highlighted = nil
        model.sidebarHasKeys = true
        focused = true
    }

    /// The rows the arrows move through, top to bottom, as shown: the
    /// pinned pages, Peel, then the chats; not invites or the message results.
    private var rows: [(destination: AppModel.Destination, title: String)] {
        let pinned = searching ? [] : PeelPage.pinnedInChats(model).map { ($0.destination, $0.title) }
        let agent = shownAgent.map { [(model.agentDestination, $0.name)] } ?? []
        return pinned + agent + shownChats.map { (.chat($0.chat), $0.name) }
    }

    private var searching: Bool { !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The chats as listed: every one, or the first matches while searching.
    private var shownChats: [Conversation] {
        searching ? SidebarSearch.capped(model.latestChats) : model.latestChats
    }

    /// Peel's row, first: always, unless a search leaves it out.
    private var shownAgent: AgentSession? {
        guard let agent = model.agent, ChatSections.matches(agent.name, query: model.searchQuery) else { return nil }
        return agent
    }

    /// The row `offset` from `current` (the selection when nothing is
    /// highlighted), stopping at the ends; the first or last row from
    /// anywhere else.
    static func step<Row: Equatable>(_ rows: [Row], from current: Row?, by offset: Int) -> Row? {
        guard let index = current.flatMap(rows.firstIndex(of:)) else { return offset > 0 ? rows.first : rows.last }
        return rows[min(max(index + offset, 0), rows.count - 1)]
    }

    #if os(macOS)
    /// While the list has focus, in the main window, unlocked, with no
    /// menu, panel or viewer up: Down and Up move the highlight, Return
    /// opens it, Escape clears it. Typing goes to the open chat.
    private func handle(_ event: NSEvent, responder: NSResponder?) -> Bool {
        guard model.phase == .ready, !model.isLockDue, PeelPage.isChats(model.destination), let presenter,
              presenter.takesKeys(event), model.viewer == nil,
              responder != nil, !(responder is NSText), event.window?.firstResponder === responder,
              !event.modifierFlags.contains(.control)
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
        case KeyCode.down where plain, KeyCode.up where plain:
            let next = Self.step(rows.map(\.destination), from: highlighted ?? model.destination,
                                 by: event.keyCode == KeyCode.down ? 1 : -1)
            highlighted = next
            if let title = rows.first(where: { $0.destination == next })?.title {
                AccessibilityNotification.Announcement(title).post()
            }
        case KeyCode.return where plain, KeyCode.enter where plain:
            // Taken even with nothing highlighted, so a
            // second press never reaches a pane's default button (Pay).
            if let highlighted, rows.contains(where: { $0.destination == highlighted }) {
                model.destination = highlighted
                self.highlighted = nil
            }
        case KeyCode.escape where plain:
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
        guard command ? event.charactersIgnoringModifiers == "v" : printable else { return false }
        let composer: ComposerID
        switch model.destination {
        case .chat(let chat) where model.tribes[chat]?.canPost ?? true: composer = .chat(chat)
        default: return false
        }
        typedAhead.append(event)
        model.composerFocus[composer, default: 0] += 1
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
    /// The chat list row the arrow keys are on.
    @Entry var sidebarHighlight: AppModel.Destination?
    /// A chat list row was clicked: the list takes the keys.
    @Entry var sidebarClicked: @MainActor () -> Void = {}
}

/// No chats yet: what to do first, as the + menu offers it.
private struct NoChatsYet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("No chats yet")
                    .font(Theme.font(14, .bold))
                Text("Add someone you know, invite a friend with a few sats, or join a tribe.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.Space.md)
            SidebarActionLink(title: String(localized: "Add contact")) { AddContactForm(done: $0) }
            SidebarActionLink(title: String(localized: "Invite someone")) { InviteForm(done: $0) }
            SidebarActionLink(title: String(localized: "Join a tribe")) { JoinTribeForm(done: $0) }
        }
    }
}

/// The chat list's column, on Chats: its header in the band ("Chats",
/// search, ••• for Mentions and Threads and +), the search when open, the list, and at its foot a
/// restore's progress and the call you are on.
struct SidebarColumn: View {
    @Environment(AppModel.self) private var model
    /// The search field shows: opened by its button or ⌘F, or holding a query.
    @State private var searchOpen = false

    var body: some View {
        @Bindable var model = model
        let showsSearch = searchOpen || !model.searchQuery.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(title: String(localized: "Chats")) {
                IconButton("magnifyingglass", help: String(localized: "Search chats (⌘F)"), size: .sm, lit: showsSearch) {
                    if showsSearch { closeSearch() } else { searchOpen = true }
                }
                ChatsPagesButton()
                NewChatButton()
            }
            if showsSearch {
                SearchField(text: $model.searchQuery, prompt: String(localized: "Search chats"),
                            focusRequest: model.sidebarSearchFocus, focusOnAppear: true, onClear: closeSearch)
                    // Escape clears the search and puts it away: the whole list again.
                    .onKeyPress(.escape) {
                        closeSearch()
                        return .handled
                    }
                    .onChange(of: model.searchQuery) { model.updateSidebarSearch() }
                    .padding(.horizontal, 10)
                    .padding(.top, Theme.Space.sm)
            }
            Sidebar()
            RestoreBar()
                .padding(.horizontal, 10)
            if let call = model.calls.session {
                OnCallBar(call: call)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
        // ⌘F with no chat open.
        .onChange(of: model.sidebarSearchFocus) { searchOpen = true }
    }

    private func closeSearch() {
        searchOpen = false
        model.clearSidebarSearch()
    }
}

/// ••• in Chats' header (Tom, 2026-11-27, as the iPhone's): Mentions and
/// Threads, each with what is new, each opening its page beside the list.
/// A dot on it while one that is not pinned above the chats has something
/// new, so nothing waits unseen.
private struct ChatsPagesButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unseen = PeelPage.inChats.contains { $0.count(in: model) > 0 && !model.isPagePinned($0.rawValue) }
        MenuButton(systemImage: "ellipsis", help: String(localized: "Mentions and Threads"), source: "chats-pages") {
            PeelPage.inChats.map { page in
                let count = page.count(in: model)
                return .button(page.title, systemImage: page.systemImage,
                               detail: count > 0 ? String(localized: "\(count) new") : nil) {
                    model.destination = page.destination
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if unseen {
                Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: -3, y: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(unseen ? String(localized: "Something new") : "")
    }
}

/// The pages pinned above the chats from their headers (`PagePinButton`):
/// rows like the chats' (Tom, 2026-11-27: pills read as filters), each
/// selected as a chat is while its page opens beside the list, with its
/// count; Remove from Chats on a right-click; a line under them. None
/// until pinned.
private struct PinnedPageRows: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter

    var body: some View {
        let pinned = PeelPage.pinnedInChats(model)
        if !pinned.isEmpty {
            ForEach(pinned) { page in
                let count = page.count(in: model)
                SidebarLink(page.title, to: page.destination, unread: count > 0) {
                    Image(systemName: page.systemImage)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                } accessory: {
                    if count > 0 { Badge(count: count) }
                }
                .menuOpenOutline(presenter?.source == AnyHashable("chats-pinned-\(page.rawValue)"))
                .peelMenu(source: "chats-pinned-\(page.rawValue)") {
                    [.button(String(localized: "Remove from Chats"), systemImage: "pin.slash") {
                        model.setPagePinned(page.rawValue, false)
                    }]
                }
            }
            Theme.divider
                .frame(height: 1)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.xs)
                .accessibilityHidden(true)
        }
    }
}

/// The pin in Mentions' and Threads' headers: shows the page as a row
/// above the chats, or takes it off; filled in the accent while it is
/// one.
struct PagePinButton: View {
    @Environment(AppModel.self) private var model
    let page: PeelPage

    var body: some View {
        let on = model.isPagePinned(page.rawValue)
        IconButton(help: on ? String(localized: "Remove from Chats") : String(localized: "Show on Chats")) {
            model.setPagePinned(page.rawValue, !on)
        } label: {
            Image(systemName: on ? "pin.fill" : "pin")
                .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
        }
    }
}

/// +: a new chat. Add contact and Invite someone, Join a tribe and Create a
/// tribe, each opening its form from the button.
private struct NewChatButton: View {
    private enum Form: Identifiable {
        case addContact, invite, joinTribe, createTribe
        var id: Self { self }
    }

    @State private var form: Form?

    var body: some View {
        MenuButton(systemImage: "plus", help: String(localized: "New chat"), source: "new-chat") {
            .sections(
                [.header(String(localized: "People")),
                 .button(String(localized: "Add contact…"), systemImage: "person.badge.plus") { form = .addContact },
                 .button(String(localized: "Invite someone…"), systemImage: "envelope") { form = .invite }],
                [.header(String(localized: "Tribes")),
                 .button(String(localized: "Join a tribe…"), systemImage: "person.3") { form = .joinTribe },
                 .button(String(localized: "Create a tribe…"), systemImage: "plus.bubble") { form = .createTribe }]
            )
        }
        .peelPopover(isPresented: Binding(get: { form != nil }, set: { if !$0 { form = nil } }), edge: .trailing) {
            switch form {
            case .addContact?: AddContactForm { form = nil }
            case .invite?: InviteForm { form = nil }
            case .joinTribe?: JoinTribeForm { form = nil }
            case .createTribe?: TribeSettingsForm(editing: nil) { form = nil }
            case nil: EmptyView()
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = String(localized: "Search")
    var focusRequest = 0
    /// Takes the keyboard as it appears: the chat list's, opened by its button or ⌘F.
    var focusOnAppear = false
    /// What the clear button does; without one it empties `text`.
    var onClear: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?

    var body: some View {
        FormTextField(label: prompt, prompt: prompt, text: $text, systemImage: "magnifyingglass",
                      focusOnAppear: focusOnAppear, focusRequest: focusRequest, focusChanged: focusChanged)
            .overlay(alignment: .trailing) {
                if !text.isEmpty {
                    IconButton("xmark", help: String(localized: "Clear search"), size: .sm) {
                        if let onClear { onClear() } else { text = "" }
                    }
                    .padding(.trailing, Theme.Space.xs)
                }
            }
    }
}

/// "Messages" while searching: the messages in every chat that match, each
/// with a line around the match lit, its chat and when; "No results" when
/// the chats found nothing either. Selecting one opens its chat at it.
struct SidebarMessageResults: View {
    @Environment(AppModel.self) private var model
    let search: SidebarSearch
    /// The chats (or the apps) above found something.
    let chatsFound: Bool

    var body: some View {
        if search.searching && search.messages.isEmpty {
            SidebarSection(String(localized: "Messages")) {
                HStack(spacing: 6) {
                    PeelSpinner(size: 12, delayed: false)
                    Text("Searching…")
                }
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, Theme.Space.md)
            }
        } else if search.failed {
            SidebarSection(String(localized: "Messages")) {
                Text("Could not search messages")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.attention)
                    .padding(.horizontal, Theme.Space.md)
            }
        } else if !search.messages.isEmpty {
            let terms = search.query?.terms ?? []
            SidebarSection(String(localized: "Messages")) {
                ForEach(Array(search.messages.enumerated()), id: \.offset) { _, message in
                    SidebarMessageRow(
                        message: message,
                        conversation: model.conversations.first { $0.chat == message.chat },
                        sender: model.sender(of: message),
                        snippet: AttributedString(search.query?.snippet(of: message.preview) ?? message.preview)
                            .highlighting(terms)
                    ) {
                        model.openSidebarMessage(message)
                    }
                }
            }
        } else if search.foundNone && !chatsFound {
            Text("No results")
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, Theme.Space.md)
        }
    }
}

/// A message found: its chat's avatar, the sender and its line with the match
/// lit, over its chat and when.
private struct SidebarMessageRow: View {
    let message: Message
    let conversation: Conversation?
    let sender: Sender
    let snippet: AttributedString
    let action: () -> Void

    var body: some View {
        ListRow(minHeight: 44, action: action) {
            if let conversation {
                ConversationIcon(conversation: conversation, size: Theme.AvatarSize.sm)
            } else {
                Avatar(name: sender.avatarName, url: sender.photoURL, size: Theme.AvatarSize.sm, hue: sender.hue)
            }
        } title: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.sm) {
                    Text(sender.label)
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(sender.hue.name)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(snippet)
                        .lineLimit(1)
                }
                .font(Theme.font(13))
                HStack(spacing: Theme.Space.sm) {
                    Text(conversation?.name ?? "")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Formatting.relative(message.date))
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
            }
        } trailing: {
            EmptyView()
        }
    }
}

/// A heading over a group of rows in the chat list (the search's Messages).
struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xs)
                .accessibilityAddTraits(.isHeader)
            content
        }
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
    /// A chat's last message, on one line under the title.
    var preview: String?
    /// When that message was sent, at the preview line's end.
    var previewDate: String?
    /// AGENT beside the name (Tom, 2026-11-27: there, the time keeps its column).
    var showsAgentTag = false
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    init(
        _ title: String, to destination: AppModel.Destination, unread: Bool = false, dimmed: Bool = false,
        preview: String? = nil, previewDate: String? = nil, showsAgentTag: Bool = false,
        @ViewBuilder icon: () -> Icon, @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.destination = destination
        self.unread = unread
        self.dimmed = dimmed
        self.preview = preview
        self.previewDate = previewDate
        self.showsAgentTag = showsAgentTag
        self.icon = icon()
        self.accessory = accessory()
    }

    var body: some View {
        Button {
            model.destination = destination
            clicked()
        } label: {
            // With a preview, two lines (Tom, 2026-11-27, the board's "Unread
            // counts", option A): the name and its time, alone at the top
            // right; under them the preview and, at its end, the accessory (a
            // count, @, the muted bell, Set up), so every time is in one column.
            HStack(alignment: .center, spacing: 9) {
                icon.frame(width: Theme.AvatarSize.sm, height: Theme.AvatarSize.sm)
                if let preview {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(title).lineLimit(1)
                            if showsAgentTag { AgentTag() }
                            Spacer(minLength: 4)
                            if let previewDate {
                                Text(previewDate)
                                    .font(Theme.font(11, .regular))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        HStack(spacing: 4) {
                            if unread {
                                Circle().fill(Theme.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                            }
                            Text(preview)
                                .font(Theme.font(11, unread ? .semibold : .regular))
                                .foregroundStyle(unread ? Theme.text : Theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            accessory
                        }
                    }
                } else {
                    Text(title).lineLimit(1)
                    if showsAgentTag { AgentTag() }
                    Spacer(minLength: 4)
                    accessory
                }
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
        let onCall = model.calls.liveCount(in: conversation.chat)
        // A muted chat that mentions you shows at full strength.
        SidebarLink(conversation.name, to: .chat(conversation.chat), unread: unread > 0,
                    dimmed: level == .muted && unread == 0,
                    preview: conversation.previewLine, previewDate: conversation.dateLabel()) {
            ConversationIcon(conversation: conversation, size: Theme.AvatarSize.sm)
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
                    Badge(count: unread, .mention)
                        .help("Mentions you")
                        .accessibilityLabel("\(unread) unread, mentions you")
                } else {
                    Badge(count: unread)
                }
            } else if state?.isNew == true {
                // Someone who added you: the core accepts them at once, so
                // there is no request to answer; this only says they are new.
                Badge(String(localized: "New"))
                    .help("Added you as a contact")
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
        .menuOpenOutline(presenter?.source == AnyHashable(conversation.chat))
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
        var read: [MenuEntry] = []
        switch model.readToggle(for: chat) {
        case .markRead:
            read.append(.button("Mark as read", systemImage: "checkmark.circle") { Task { await model.markRead(chat) } })
        case .markUnread:
            read.append(.button("Mark as unread", systemImage: "envelope.badge") { Task { await model.markUnread(chat) } })
        case nil:
            break
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
        return [.header("Notify me about")] + MuteLevel.choices(isTribe: conversation.isTribe).map { choice in
            .button(choice.title, checked: choice == level) { Task { await model.setMute(chat, choice) } }
        }
    }

    /// "Notifications", with the current level beside it and the levels behind it.
    static func notifications(for conversation: Conversation, model: AppModel) -> MenuEntry {
        let level = model.readStates[conversation.chat]?.mute ?? .all
        return .submenu("Notifications", systemImage: "bell",
                        detail: MuteLevel.choices(isTribe: conversation.isTribe).contains(level) ? level.short : nil,
                        levels(for: conversation, model: model))
    }

    static func link(_ tribe: Tribe) -> [MenuEntry] {
        tribe.link.map { [.copy("Copy tribe link", text: $0, systemImage: "link")] } ?? []
    }

    /// Leave, or Remove from Peel for a tribe this account can no longer
    /// post in (`Tribe.exit`); confirmed by a second click. The owner of a
    /// live tribe gets neither: they can only delete it (under Edit tribe).
    static func leave(_ conversation: Conversation, _ tribe: Tribe, model: AppModel) -> [MenuEntry] {
        guard let exit = tribe.exit else { return [] }
        let chat = conversation.chat
        return [.destructive(exit.title, systemImage: exit.systemImage, confirm: exit.confirm(conversation.name)) {
            Task { await model.leave(chat) }
        }]
    }
}

struct ConnectionCard: View {
    @Environment(AppModel.self) private var model

    private var offline: Bool {
        if case .offline = model.connection { true } else { false }
    }

    private var busy: Bool { model.checkingConnection || model.connection == .connecting }

    var body: some View {
        Panel(nil, compact: true, fit: true, close: {}) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: busy ? "arrow.triangle.2.circlepath" : model.connection == .connected ? "checkmark.circle" : "wifi.slash")
                    .foregroundStyle(model.connection == .connected ? Theme.confirmed : Theme.attention)
                    .accessibilityHidden(true)
                if model.checkingConnection {
                    label(String(localized: "Checking…"))
                } else if offline, model.reconnectAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        label(model.connection.label(retryAt: model.reconnectAt, now: context.date))
                    }
                } else {
                    label(model.connection.label)
                }
                Spacer(minLength: Theme.Space.sm)
                IconButton("arrow.clockwise", help: offline ? String(localized: "Reconnect now") : String(localized: "Check connection"), size: .sm, working: busy) {
                    Task { await model.checkConnection() }
                }
                .disabled(busy)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(13))
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityValue(model.connectionError ?? "")
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

/// The icon and title of a sidebar row that acts rather than opens.
private struct SidebarActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: Theme.AvatarSize.sm)
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
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(selected ? Theme.selection : hovering || highlighted ? Theme.hover : .clear)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Restore

/// A restore's progress at the sidebar's foot, or why history paused and
/// Resume (offered while connected: a reconnect resumes by itself).
struct RestoreBar: View {
    @Environment(AppModel.self) private var model

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        let progress = model.restoreProgress
        Group {
            if let reason = progress.paused {
                // A restore paused leaves the account incomplete; a catch-up's
                // blocks nothing, so it stays quiet.
                Callout(progress.restoring ? .attention : .neutral,
                        progress.restoring ? String(localized: "Restore paused") : String(localized: "Catching up paused"),
                        detail: connected ? reason : String(localized: "\(reason) It resumes when connected."),
                        icon: progress.restoring ? nil : .symbol("pause.circle", Theme.secondaryText)) {
                    if connected {
                        Button("Resume") { Task { await model.resumeHistory() } }
                            .buttonStyle(.peel(.outline, size: .sm))
                            .padding(.top, Theme.Space.xs)
                    }
                }
            } else if progress.restoring {
                running(progress)
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress.restoring || progress.paused != nil)
    }

    /// Contacts first, then messages: how far, once the server says how many.
    private func running(_ progress: AppModel.RestoreProgress) -> some View {
        // Contacts at 100% means the messages run has begun, before its first page.
        let onContacts = progress.messages == nil && (progress.contacts?.fraction ?? 0) < 1
        let fraction = connected ? (onContacts ? progress.contacts : progress.messages)?.fraction : nil
        let detail = connected
            ? fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? String(localized: "This can take a few minutes")
            : String(localized: "Waiting for a connection")
        return Callout(.neutral, onContacts ? String(localized: "Restoring contacts") : String(localized: "Restoring messages"), detail: detail,
                       icon: connected ? .progress : .symbol("wifi.slash", Theme.secondaryText)) {
            if let fraction {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A row's accent outline while its menu is open (a chat's, a pinned page's).
    func menuOpenOutline(_ open: Bool) -> some View {
        overlay {
            if open {
                RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
    }
}
