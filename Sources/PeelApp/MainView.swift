import ImageIO
import SwiftUI
import PeelCore

/// Slack-style layout: sidebar, conversation; see docs/design/README.md.
/// Content runs under the hidden title bar; the sidebar keeps clear of the
/// traffic lights.
struct MainView: View {
    @Environment(AppModel.self) private var model
    /// Dragged on its divider; remembered on this Mac (a convenience).
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: sidebarWidth)
            PaneDivider(width: $sidebarWidth, range: 220...420, standard: 260, growsTo: .trailing)
            VStack(spacing: 0) {
                Detail()
                if let notice = model.notice {
                    NoticeBar(text: notice) { model.notice = nil }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Theme.background)
                }
                if model.usesFileSecrets {
                    FileSecretsBanner()
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .foregroundStyle(Theme.text)
        .overlay {
            if let viewer = model.viewer {
                ImageViewer(state: viewer)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.viewer == nil)
        .peelMenuHost()
    }
}

/// A 1 pt divider between two panes that resizes the pane on one side:
/// a few points either side of the line take the drag, the pointer turns
/// into the resize cursor over them, and a double-click puts the standard
/// width back.
///
/// The handle is an AppKit view rather than a SwiftUI hover and gesture:
/// beside the thread panel it sits over the conversation's scroller, which
/// otherwise takes the cursor and the click, and a cursor push on hover is
/// undone by whatever the pointer crosses next.
struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let standard: Double
    /// Which way dragging makes the pane wider: towards `.trailing` for a
    /// pane on the left (the sidebar), `.leading` for one on the right.
    let growsTo: HorizontalEdge

    /// The width when the drag began, as shown: a pane squeezed below the
    /// width it was dragged to moves from where it is.
    @State private var start = 0.0

    var body: some View {
        Theme.divider
            .frame(width: 1)
            #if os(macOS)
            .overlay {
                ResizeHandle {
                    start = fitted(width)
                } dragged: { translation in
                    let delta = Double(translation) * (growsTo == .trailing ? 1 : -1)
                    resize(to: start + delta)
                } reset: {
                    resize(to: standard)
                }
                .frame(width: 9)
            }
            #endif
            .zIndex(1)
    }

    private func fitted(_ proposed: Double) -> Double {
        min(max(proposed, range.lowerBound), range.upperBound)
    }

    /// Writes only a change: past either end every drag event proposes the same width.
    private func resize(to proposed: Double) {
        let new = fitted(proposed)
        if new != width { width = new }
    }
}

#if os(macOS)
/// The divider's hit area: owns the resize cursor (as the view under the
/// pointer, so nothing beneath can change it) and the drag, which starts on
/// the first click even in a window that is not yet key.
private struct ResizeHandle: NSViewRepresentable {
    let began: () -> Void
    /// Points the pointer has moved since the drag began.
    let dragged: (CGFloat) -> Void
    let reset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.toolTip = "Drag to resize; double-click for the standard width"
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.handle = self
    }

    final class HandleView: NSView {
        var handle: ResizeHandle?
        private var startX: CGFloat?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if trackingAreas.isEmpty {
                addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
            }
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount > 1 {
                startX = nil
                handle?.reset()
            } else {
                startX = event.locationInWindow.x
                handle?.began()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            // Kept while the pointer runs ahead of the line.
            NSCursor.resizeLeftRight.set()
            handle?.dragged(event.locationInWindow.x - startX)
        }

        /// Let go away from the handle: the cursor belongs to what is there.
        override func mouseUp(with event: NSEvent) {
            startX = nil
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
        }
    }
}
#endif

/// Shown on development profiles, whose words are not in the Keychain.
struct FileSecretsBanner: View {
    var body: some View {
        Text("Development profile: its twelve words are in a plain file. Throwaway accounts only.")
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Theme.panel)
            .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }
}

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
                        SidebarLink("Payments", systemImage: "bolt", to: .payments)
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
                        SidebarActionLink(title: "Add contact") { AddContactForm(done: $0) }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
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
                        if let balance = model.balanceMsat {
                            Text(Sats.format(msat: balance))
                                .font(Theme.font(12))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                        }
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
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
        }
        .foregroundStyle(Theme.secondaryText)
        .fieldBoxed()
    }
}

extension View {
    /// The small dark box behind the sidebar's search and the fields of
    /// Peel's panels.
    func fieldBoxed() -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
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

extension SidebarLink where Icon == AnyView, Accessory == EmptyView {
    init(_ title: String, systemImage: String, to destination: AppModel.Destination) {
        self.init(title, to: destination) {
            AnyView(Image(systemName: systemImage).font(.system(size: 13)))
        }
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
        SidebarLink(conversation.name, to: .chat(conversation.chat), unread: unread > 0, dimmed: level == .muted) {
            ConversationIcon(conversation: conversation, size: 18)
        } accessory: {
            if unread > 0 {
                UnreadBadge(count: unread)
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

struct UnreadBadge: View {
    let count: Int

    /// A count as badges show it, capped at "99+".
    static func text(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    var body: some View {
        Text(Self.text(count))
            .font(Theme.font(11, .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.buttonText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.accent, in: Capsule())
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

/// A contact's photo, or a tribe's icon.
struct ConversationIcon: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let size: CGFloat

    var body: some View {
        if conversation.isTribe {
            TribeIcon(name: conversation.name, url: conversation.photoURL, pubkey: conversation.chat, size: size)
        } else {
            Avatar(name: conversation.name, url: conversation.photoURL, size: size,
                   hue: model.hue(pubkey: conversation.chat, alias: nil, inTribe: false))
        }
    }
}

/// A tribe's image, or its initial on its own colour, on a rounded square:
/// the square is what tells a tribe from a person.
struct TribeIcon: View {
    let name: String
    let url: String?
    /// The tribe's key, which picks its colour from people's palette.
    let pubkey: String
    let size: CGFloat

    var body: some View {
        Avatar(name: name, url: url, size: size, hue: PersonHue(pubkey: pubkey, alias: nil, inTribe: false),
               shape: .roundedSquare)
    }
}

/// Paste a link, see what the tribe is and what it costs, then join.
struct JoinTribeForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var link = ""
    @State private var info: TribeInfo?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a tribe")
                .font(Theme.font(15, .bold))
            TextField("sphinx.chat://?action=tribeV2…", text: $link, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await lookUp() } }
                .onChange(of: link) { info = nil; problem = nil }
            if let info {
                HStack(alignment: .top, spacing: 10) {
                    TribeIcon(name: info.name, url: info.img, pubkey: info.pubkey, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.name)
                            .font(Theme.font(14, .medium))
                        if let summary = info.summary?.trimmed.nilIfEmpty {
                            Text(summary)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(3)
                        }
                        Text("Joining costs \(Sats.format(msat: info.joinAmountMsat)) · \(Sats.format(msat: info.messageAmountMsat)) a message")
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            FormFooter(problem: problem) {
                if info == nil {
                    Button { Task { await lookUp() } } label: { Text("Look up").buttonProgress(working) }
                        .buttonStyle(GhostButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || link.trimmed.isEmpty)
                } else {
                    Button { Task { await join() } } label: { Text("Join").buttonProgress(working) }
                        .buttonStyle(GhostButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func lookUp() async {
        guard !link.trimmed.isEmpty, !working else { return }
        working = true
        defer { working = false }
        let looked = link
        do {
            let found = try await model.previewTribe(looked)
            // A link edited during the lookup is looked up again, not shown with this answer.
            guard link == looked else { return }
            info = found
            problem = nil
        } catch {
            if link == looked { problem = PeelError.readable(error) }
        }
    }

    private func join() async {
        guard let info else { return }
        working = true
        defer { working = false }
        do {
            try await model.joinTribe(link, agreedJoinMsat: info.joinAmountMsat)
            done()
        } catch {
            problem = PeelError.readable(error)
        }
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

struct AddContactForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var contactInfo = ""
    @State private var name = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add contact")
                .font(Theme.font(15, .bold))
            TextField("Their contact info", text: $contactInfo, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
            FormFooter(problem: problem) {
                Button { Task { await add() } } label: { Text("Add").buttonProgress(working) }
                    .buttonStyle(GhostButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || contactInfo.trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func add() async {
        working = true
        defer { working = false }
        do {
            try await model.addContact(contactInfo, alias: name)
            done()
        } catch {
            problem = PeelError.readable(error)
        }
    }
}

/// Why the last attempt failed: quiet, not red, since nothing was lost.
struct ProblemText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(3)
    }
}

/// A popover form's last row: what went wrong, and its buttons (the one
/// running shows its spinner inside it, `buttonProgress`).
struct FormFooter<Buttons: View>: View {
    let problem: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack {
            if let problem { ProblemText(problem) }
            Spacer()
            buttons
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

// MARK: - Detail

struct Detail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.destination {
            case .chat:
                if let conversation = model.selectedConversation {
                    ConversationView(conversation: conversation)
                } else {
                    EmptyPlace(title: "Peel", message: "Pick a conversation.")
                }
            case .threads:
                ThreadsView()
            case .mentions:
                MentionsView()
            case .payments:
                PaymentsView()
            case .account:
                AccountView()
            case nil:
                EmptyPlace(title: "Peel", message: "Pick a conversation, or add a contact.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// The bar across the top of the detail column.
struct DetailHeader<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.font(16, .bold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }
}

extension DetailHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String) {
        self.init(title: title, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension DetailHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, leading: leading, trailing: { EmptyView() })
    }
}

struct EmptyPlace: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: title)
            Text(message)
                .font(Theme.font(14))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Shared

/// A person's photo, or their initials on their colour (`PersonHue`, from
/// `AppModel.hue`); a tribe's the same on a rounded square, coloured by its
/// key. Only https photos are ever loaded.
struct Avatar: View {
    enum Shape { case circle, roundedSquare }

    let name: String
    let url: String?
    let size: CGFloat
    let hue: PersonHue
    var shape: Shape = .circle

    private var photo: URL? {
        url?.httpsOnly.flatMap(URL.init)
    }

    /// "Tom Smith" and "Tom_Smith" are TS, "Bot" is B; a tribe its initial.
    private var initials: String {
        let words = name.split { $0 == " " || $0 == "_" }.prefix(shape == .roundedSquare ? 1 : 2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// The fetched photo, kept with its URL so a view reused for another
    /// person never shows the last one's photo while the new one loads.
    @State private var loaded: (url: URL, image: CGImage)?

    private var image: CGImage? {
        guard let photo else { return nil }
        if let loaded, loaded.url == photo { return loaded.image }
        return PhotoCache.shared.cached(photo)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                hue.avatarFill.overlay {
                    // Initials down to the sidebar's 18pt (a tribe's 16pt):
                    // the letter is how you find it there.
                    if size >= (shape == .roundedSquare ? 16 : 18) {
                        let initials = initials
                        Text(initials)
                            .font(Theme.font(size * (initials.count > 1 ? 0.38 : size < 24 ? 0.55 : 0.42), .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .task(id: photo) {
            if let photo, let image = await PhotoCache.shared.image(for: photo) { loaded = (photo, image) }
        }
        .frame(width: size, height: size)
        .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.25)))
    }
}

/// Photos fetched once per URL and kept for the session. A row in a lazy list
/// is made and dropped as it scrolls; each `AsyncImage` fetched on its own and
/// a row dropped mid-fetch was left on its initial for good, so every run of a
/// tribe member's messages after the first showed no photo. Here the fetch
/// belongs to the cache, not the row, and every row with that URL shares it.
@MainActor
final class PhotoCache {
    static let shared = PhotoCache()

    private var images: [URL: CGImage] = [:]
    /// A fetch that throws (no answer, or the server busy or failing) is tried
    /// again next time; one that returns nil got no image and joins `failed`.
    private var loads: [URL: Task<CGImage?, any Error>] = [:]
    /// URLs whose server gave no image, not asked for again this session.
    private var failed: Set<URL> = []

    func cached(_ url: URL) -> CGImage? { images[url] }

    func image(for url: URL) async -> CGImage? {
        if let image = images[url] { return image }
        guard !failed.contains(url) else { return nil }
        let load: Task<CGImage?, any Error>
        if let running = loads[url] {
            load = running
        } else {
            load = Task.detached(priority: .utility) {
                guard let data = try await Web.photo(at: url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                // Decoded here, at avatar size (the short side still covers a
                // 36pt avatar at 2x for photos up to 3:1, as it is filled), so
                // drawing neither decodes on the main thread nor keeps the full photo.
                return ImageDecoding.thumbnail(source, maxPixels: 256)
            }
            loads[url] = load
        }
        let result = await load.result
        loads[url] = nil
        switch result {
        case .success(let image?): images[url] = image; return image
        case .success(nil): failed.insert(url); return nil
        case .failure: return nil
        }
    }
}

extension View {
    /// The quiet panel box behind notices, bars and suggestion lists.
    func panelBoxed() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.divider))
    }

    /// The raised box of menus, suggestion lists and the hover bar.
    func menuBoxed(cornerRadius: CGFloat = 8, shadow: Bool = true) -> some View {
        background(Theme.menu, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.divider))
            .shadow(color: .black.opacity(shadow ? 0.25 : 0), radius: 10, y: 4)
    }
}

enum Clipboard {
    /// Returns whether it copied, like `copyImage`, for `CopyButton` and `MenuEntry.copy`.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        return true
        #endif
    }

    #if os(macOS)
    /// The pasteboard's change count right after a secret was copied, while
    /// it may still be there.
    @MainActor private static var secretChangeCount: Int?
    #endif

    /// Copies a secret: kept on this Mac (no Universal Clipboard), marked
    /// concealed so clipboard managers skip it, and cleared after
    /// `clearAfter`, on quit, or when the account is forgotten, unless
    /// something else has been copied since.
    @MainActor static func copySecret(_ text: String, clearAfter: Duration) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        secretChangeCount = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            clearSecret()
        }
        #else
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": text]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(Double(clearAfter.components.seconds))]
        )
        #endif
    }

    /// Clears a secret copied with `copySecret` if it is still on the clipboard.
    @MainActor static func clearSecret() {
        #if os(macOS)
        guard let copied = secretChangeCount else { return }
        secretChangeCount = nil
        if NSPasteboard.general.changeCount == copied { NSPasteboard.general.clearContents() }
        #endif
    }

    /// Puts the picture in a file on the clipboard; false when it cannot be read.
    static func copyImage(at file: URL) -> Bool {
        #if os(macOS)
        guard let image = NSImage(contentsOf: file) else { return false }
        return copy(image)
        #else
        guard let image = UIImage(contentsOfFile: file.path) else { return false }
        UIPasteboard.general.image = image
        return true
        #endif
    }

    #if os(macOS)
    static func copy(_ image: NSImage) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }
    #endif

    static func paste() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}

/// The app's icon, as the Dock shows it.
struct AppIcon: View {
    let size: CGFloat

    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
        #endif
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Formatting {
    static func dayHeading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "1 reply", "5 replies".
    static func replies(_ count: Int) -> String {
        count == 1 ? "1 reply" : "\(count) replies"
    }

    /// How long ago, as Slack writes it: "just now", "5 min ago", "today at
    /// 14:32", "yesterday at 09:10", "3 days ago", "2 Oct", "2 Oct 2025"
    /// (times and dates in the user's format). Everything is measured from
    /// `now`, in calendar days, so midnight and DST changes count right.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        // A few minutes of clock skew between devices reads as now; further
        // ahead, the time or date it claims.
        if seconds > -300 && seconds < 60 { return "just now" }
        if seconds >= 60 && seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "today at \(date.formatted(.dateTime.hour().minute()))"
        case 1: return "yesterday at \(date.formatted(.dateTime.hour().minute()))"
        case 2..<7: return "\(days) days ago"
        default:
            let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            return date.formatted(sameYear ? style : style.year())
        }
    }
}
