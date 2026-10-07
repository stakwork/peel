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
        VStack(alignment: .leading, spacing: 12) {
            SidebarHeader()
            SearchField(text: $model.searchQuery)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 1) {
                        SidebarLink("Threads", systemImage: "bubble.left", to: .threads)
                        SidebarLink("Mentions", systemImage: "at", to: .mentions)
                        SidebarLink("Payments", systemImage: "bolt", to: .payments)
                    }
                    SidebarSection("Tribes", expanded: $showTribes) {
                        Text("No tribes yet")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    SidebarSection("Direct messages", expanded: $showDirect) {
                        ForEach(model.filteredConversations) { conversation in
                            DirectMessageLink(conversation: conversation)
                        }
                        AddContactLink()
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
            #if os(macOS)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            #endif
            VStack(alignment: .leading, spacing: 1) {
                Text("Peel")
                    .font(Theme.font(15, .bold))
                if let balance = model.balanceMsat {
                    Text("\((balance / 1000).formatted()) sats")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
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

/// A sidebar row that selects a destination.
struct SidebarLink<Icon: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let destination: AppModel.Destination
    @ViewBuilder let icon: Icon

    init(_ title: String, to destination: AppModel.Destination, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.destination = destination
        self.icon = icon()
    }

    var body: some View {
        Button {
            model.destination = destination
        } label: {
            HStack(spacing: 9) {
                icon.frame(width: 18)
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(SidebarRowStyle(selected: model.destination == destination))
    }
}

extension SidebarLink where Icon == AnyView {
    init(_ title: String, systemImage: String, to destination: AppModel.Destination) {
        self.init(title, to: destination) {
            AnyView(Image(systemName: systemImage).font(.system(size: 13)))
        }
    }
}

struct DirectMessageLink: View {
    let conversation: Conversation

    var body: some View {
        SidebarLink(conversation.name, to: .chat(conversation.chat)) {
            Avatar(name: conversation.name, url: conversation.photoURL, size: 18)
        }
    }
}

struct AddContactLink: View {
    @State private var adding = false

    var body: some View {
        Button {
            adding = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text("Add contact")
            }
        }
        .buttonStyle(SidebarRowStyle(selected: false))
        .popover(isPresented: $adding, arrowEdge: .trailing) {
            AddContactForm { adding = false }
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
            HStack {
                if let problem {
                    Text(problem)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || contactInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

struct SidebarRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.font(14, selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.selectionText : Theme.secondaryText)
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

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            HStack(spacing: 9) {
                Avatar(name: model.myAlias ?? "?", url: nil, size: 24)
                Text(model.myAlias ?? "You")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(model.connection.label)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.top, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
        .popover(isPresented: $showingInfo, arrowEdge: .top) {
            ContactInfoCard(info: model.myContactInfo)
        }
    }
}

/// Your own contact info, to share with someone who wants to add you.
struct ContactInfoCard: View {
    let info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your contact info")
                .font(Theme.font(15, .bold))
            if let info {
                Text(info)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
                HStack {
                    Spacer()
                    Button("Copy") { Clipboard.copy(info) }
                }
            } else {
                Text("Available once the server has registered this account.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(16)
        .frame(width: 320)
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
                EmptyPlace(title: "Mentions", message: "Messages that mention you show up here.")
            case .payments:
                EmptyPlace(title: "Payments", message: "Payments you send and receive show up here.")
            case nil:
                EmptyPlace(title: "Peel", message: "Pick a conversation, or add a contact.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// The bar across the top of the detail column.
struct DetailHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.font(16, .bold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.font(12))
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

extension DetailHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
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
    let name: String
    let url: String?
    let size: CGFloat

    private static let tones: [Color] = [
        Color(light: 0x7E9A8C, dark: 0x7E9A8C), Color(light: 0x9B8BB0, dark: 0x9B8BB0),
        Color(light: 0xB08B7E, dark: 0xB08B7E), Color(light: 0x8E969C, dark: 0x8E969C),
        Color(light: 0x5B8A72, dark: 0x5B8A72), Color(light: 0x3E6189, dark: 0x3E6189),
    ]

    private var photo: URL? {
        url.flatMap(URL.init).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// Stable across launches, unlike `hashValue`.
    private var tone: Color {
        Self.tones[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.tones.count]
    }

    var body: some View {
        AsyncImage(url: photo) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            tone.overlay {
                if size >= 24 {
                    Text(name.prefix(1).uppercased())
                        .font(Theme.font(size * 0.42, .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
}

enum Formatting {
    static func dayHeading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The start and end of a public key, enough to tell two apart.
    static func shortKey(_ key: String) -> String {
        key.count > 12 ? "\(key.prefix(6))…\(key.suffix(4))" : key
    }
}
