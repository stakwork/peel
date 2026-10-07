import ImageIO
import SwiftUI
import PeelCore

/// Slack-style layout: sidebar, conversation; see docs/design/README.md.
/// Content runs under the hidden title bar; the sidebar keeps clear of the
/// traffic lights.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 260)
            Theme.divider.frame(width: 1)
            VStack(spacing: 0) {
                Detail()
                if model.usesFileSecrets {
                    FileSecretsBanner()
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .foregroundStyle(Theme.text)
    }
}

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
                        SidebarLink("Threads", systemImage: "bubble.left", to: .threads)
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
            SidebarFooter()
        }
        .padding(.horizontal, 10)
        .padding(.top, 34) // clear of the window's traffic lights
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

struct SidebarHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Peel")
                    .font(Theme.font(15, .bold))
                if let balance = model.balanceMsat {
                    Text(Formatting.sats(msat: balance))
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            ConnectionBolt()
        }
        .padding(.horizontal, 4)
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
        .padding(.horizontal, 9)
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
        .contextMenu {
            Picker("Notify", selection: Binding(
                get: { level },
                set: { newLevel in Task { await model.setMute(conversation.chat, newLevel) } }
            )) {
                Text("All messages").tag(MuteLevel.all)
                // The tribes server only marks mentions in tribes.
                if conversation.isTribe {
                    Text("Mentions only").tag(MuteLevel.mentionsOnly)
                }
                Text("Nothing (mute)").tag(MuteLevel.muted)
            }
            .pickerStyle(.inline)
        }
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
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
        .popover(isPresented: $showing, arrowEdge: .bottom) {
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
    let conversation: Conversation
    let size: CGFloat

    var body: some View {
        if conversation.isTribe {
            TribeIcon(name: conversation.name, url: conversation.photoURL, size: size)
        } else {
            Avatar(name: conversation.name, url: conversation.photoURL, size: size)
        }
    }
}

/// A tribe's image on a rounded square, or `#` like a Slack channel.
struct TribeIcon: View {
    let name: String
    let url: String?
    let size: CGFloat

    var body: some View {
        if url != nil {
            Avatar(name: name, url: url, size: size, shape: .roundedSquare)
        } else {
            Text("#")
                .font(Theme.font(size * 0.85, .medium))
                .frame(width: size, height: size)
        }
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
                    TribeIcon(name: info.name, url: info.img, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.name)
                            .font(Theme.font(14, .medium))
                        if let summary = info.summary?.trimmed.nilIfEmpty {
                            Text(summary)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(3)
                        }
                        Text("Joining costs \(Formatting.sats(msat: info.joinAmountMsat)) · \(Formatting.sats(msat: info.messageAmountMsat)) a message")
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            FormFooter(problem: problem, working: working) {
                if info == nil {
                    Button("Look up") { Task { await lookUp() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || link.trimmed.isEmpty)
                } else {
                    Button("Join") { Task { await join() } }
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
            if link == looked { problem = "\(error)" }
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
            problem = "\(error)"
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
        .popover(isPresented: $showing, arrowEdge: .trailing) {
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
            FormFooter(problem: problem, working: working) {
                Button("Add") { Task { await add() } }
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
            problem = "\(error)"
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

/// A popover form's last row: what went wrong, a spinner while working, and its buttons.
struct FormFooter<Buttons: View>: View {
    let problem: String?
    let working: Bool
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack {
            if let problem { ProblemText(problem) }
            Spacer()
            if working { ProgressView().controlSize(.small) }
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

/// You, at the foot of the sidebar: opens the account screen (also ⌘,).
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.destination = .account
        } label: {
            HStack(spacing: 9) {
                Avatar(name: model.myAlias ?? "?", url: model.myPhotoURL, size: 24)
                Text(model.myAlias ?? "You")
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
        }
        .buttonStyle(SidebarRowStyle(selected: model.destination == .account))
        .help("Your account (⌘,)")
        .padding(.top, 8)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
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
                EmptyPlace(title: "Threads", message: "Threads you start or reply to show up here.")
            case .mentions:
                MentionsView()
            case .payments:
                EmptyPlace(title: "Payments", message: "Payments you send and receive show up here.")
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

/// A contact's photo, or their initial on a colour picked from their name.
/// Only https photos are ever loaded.
struct Avatar: View {
    enum Shape { case circle, roundedSquare }

    let name: String
    let url: String?
    let size: CGFloat
    var shape: Shape = .circle

    private static let tones: [Color] = [
        Color(light: 0x7E9A8C, dark: 0x7E9A8C), Color(light: 0x9B8BB0, dark: 0x9B8BB0),
        Color(light: 0xB08B7E, dark: 0xB08B7E), Color(light: 0x8E969C, dark: 0x8E969C),
        Color(light: 0x5B8A72, dark: 0x5B8A72), Color(light: 0x3E6189, dark: 0x3E6189),
    ]

    private var photo: URL? {
        url?.httpsOnly.flatMap(URL.init)
    }

    /// Stable across launches, unlike `hashValue`.
    private var tone: Color {
        Self.tones[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.tones.count]
    }

    @State private var loaded: CGImage?

    var body: some View {
        Group {
            if let image = loaded ?? photo.flatMap(PhotoCache.shared.cached) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                tone.overlay {
                    if size >= 24 {
                        Text(name.prefix(1).uppercased())
                            .font(Theme.font(size * 0.42, .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .task(id: photo) {
            loaded = nil
            if let photo { loaded = await PhotoCache.shared.image(for: photo) }
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
    private var loads: [URL: Task<(image: CGImage?, answered: Bool), Never>] = [:]
    /// URLs whose server gave no image, not asked for again this session.
    /// A fetch that never reached the server is tried again next time.
    private var failed: Set<URL> = []

    func cached(_ url: URL) -> CGImage? { images[url] }

    func image(for url: URL) async -> CGImage? {
        if let image = images[url] { return image }
        guard !failed.contains(url) else { return nil }
        let load = loads[url] ?? Task.detached(priority: .utility) {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return (nil, false) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return (nil, true) }
            return (CGImageSourceCreateImageAtIndex(source, 0, nil), true)
        }
        loads[url] = load
        let result = await load.value
        loads[url] = nil
        if let image = result.image {
            images[url] = image
        } else if result.answered {
            failed.insert(url)
        }
        return result.image
    }
}

extension View {
    /// The quiet panel box behind notices, bars and suggestion lists.
    func panelBoxed() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.divider))
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
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

    /// Sats from msat, exact, since prices are shown before paying: "1 sat",
    /// "3 sats", "1.999 sats".
    static func sats(msat: UInt64) -> String {
        guard msat % 1000 != 0 else {
            let sats = msat / 1000
            return "\(sats.formatted()) \(sats == 1 ? "sat" : "sats")"
        }
        return "\((Decimal(msat) / 1000).formatted()) sats"
    }
}
