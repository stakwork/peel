import AgentKit
import SwiftUI
import PeelCore
import PeelUI

/// The rail, the chat list on Chats, and the page (Tom, 2026-11-26); see
/// docs/design/README.md. Content runs under the hidden title bar: the
/// window's buttons sit in the header band across the top
/// (`WindowButtonsInBand`), over the rail.
struct MainView: View {
    @Environment(AppModel.self) private var model
    /// The column beside the rail, the chat list's and Apps' alike, so its
    /// edge stays put going between them: dragged on its divider,
    /// remembered on this Mac (a convenience).
    @AppStorage("sidebarWidth") private var sidebarWidth = PaneDivider.columnStandard
    /// The chat list put away (⌃⌘S): Chats full width, as Payments is.
    @AppStorage("chatListHidden") private var chatListHidden = false
    /// Apps' column put away (⌃⌘S): an app full width.
    @AppStorage("appsColumnHidden") private var appsColumnHidden = false
    /// Payments' list put away (⌃⌘S; `PaymentsView` draws its own column).
    @AppStorage("paymentsListHidden") private var paymentsListHidden = false

    var body: some View {
        let onChats = PeelPage.isChats(model.destination)
        let onApps = PeelPage.isApps(model.destination)
        let showsList = onChats && !chatListHidden
        let showsApps = onApps && !appsColumnHidden
        HStack(spacing: 0) {
            Rail()
                // Its tooltips draw over the chat list or the page beside it.
                .zIndex(1)
            if showsList {
                SidebarColumn()
                    .frame(width: sidebarWidth)
                PaneDivider.column($sidebarWidth)
            }
            if showsApps {
                AppsColumn()
                    .frame(width: sidebarWidth)
                PaneDivider.column($sidebarWidth)
            }
            VStack(spacing: 0) {
                Detail()
                if let notice = model.notice {
                    Callout(detail: notice, icon: .problem, dismiss: { model.notice = nil })
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, Theme.Space.sm)
                        .background(Theme.background)
                }
                if model.diagnosticsNotice {
                    DiagnosticsNotice()
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, Theme.Space.sm)
                        .background(Theme.background)
                }
                if model.usesFileSecrets {
                    FileSecretsBanner()
                }
            }
            // Where the page starts at the rail, its title starts where a
            // column's does (`HeaderBand.titleInset`), toggle or not.
            .environment(\.headerLeadingInset, showsList || showsApps ? 0 : HeaderBand.titleInset - Theme.Space.xl)
            .webPaneBeside(model.web)
        }
        .overlay(alignment: .topLeading) {
            // In one place on every page, as Mail's and Notes' (Tom, 2026-11-27):
            // off where the page has no column.
            ColumnToggle(column: onChats ? (.chats, $chatListHidden) : onApps ? (.apps, $appsColumnHidden)
                            : model.destination == .payments ? (.payments, $paymentsListHidden) : nil)
                .padding(.leading, HeaderBand.buttonsEnd)
                .frame(height: HeaderBand.height)
        }
        // Where the rail and the band meet whatever is beside the rail, a
        // rounded corner (Tom, 2026-11-27, the board's "inner corner").
        .overlay(alignment: .topLeading) {
            InnerCorner()
                .offset(x: HeaderBand.railWidth - 1, y: HeaderBand.height - 1)
                .allowsHitTesting(false)
        }
        .background(WindowButtonsInBand())
        // A box's page goes with its link.
        .onChange(of: model.boxes.links) { model.web.boxesChanged(model.boxes) }
        // A Hive link to a paired workspace's app opens the app; any other
        // link goes where a message's link goes (`WebPane.linkAction`).
        .environment(\.openURL, OpenURLAction { url in
            if model.openHiveAppLink(url) { return .handled }
            // A tribe link opens in Peel: its chat, or the Join form; never the system's.
            if model.openTribeLink(url.absoluteString) { return .handled }
            // A public app's link opens in Peel's web pane, as an external peel:// link does.
            if PublicAppLink(peelLink: url) != nil, model.openPeelLink(url) { return .handled }
            model.web.linkAction(url)
            return .handled
        })
        // The Join form a tapped tribe link asked for (`AppModel.openTribeLink`).
        .peelPopover(isPresented: Binding(
            get: { model.joiningTribeLink != nil },
            set: { if !$0 { model.joiningTribeLink = nil } }
        )) {
            JoinTribeForm(link: model.joiningTribeLink ?? "") { model.joiningTribeLink = nil }
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
        // A box's link waiting for a yes (`BoxLinkConfirm`), and the call
        // being joined that is on another device of yours too: asked here,
        // before anything connects, since the call window is not up yet.
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if let offer = model.boxes.asking {
                    BoxLinkConfirm(offer: offer)
                        .frame(maxWidth: 460)
                        .padding(Theme.Space.md)
                }
                if model.calls.choosingDevice != nil {
                    CallDeviceConfirm(
                        cancel: { model.calls.cancelDeviceChoice() },
                        stay: { model.calls.stayOnBothDevices() },
                        switchHere: { model.calls.switchToThisDevice() }
                    )
                    .frame(maxWidth: 460)
                    .padding(Theme.Space.md)
                }
            }
        }
        .peelMenuHost(main: true)
        .sheet(item: Binding(get: { model.diagnosticsRecord }, set: { model.diagnosticsRecord = $0 })) {
            DiagnosticRecordSheet(record: $0)
                .environment(model)
        }
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
        view.toolTip = String(localized: "Drag to resize; double-click for the standard width")
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
        Text("Development profile. Throwaway accounts only.")
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Theme.panel)
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
                    if conversation.chat == model.agentChat, let agent = model.agent {
                        AgentChatView(agent: agent, dm: conversation.chat)
                    } else {
                        ConversationView(conversation: conversation)
                    }
                } else {
                    start(String(localized: "Pick a conversation."))
                }
            case .threads:
                ThreadsView()
            case .segments:
                SegmentsView()
            case .mentions:
                MentionsView()
            case .automations:
                AutomationsView()
            case .payments:
                PaymentsView(model: model)
            case .account:
                AccountView()
            case .agent:
                if let agent = model.agent {
                    AgentChatView(agent: agent)
                } else {
                    start(String(localized: "The agent chat could not be opened."))
                }
            case .apps:
                AppsView()
            case .app(let peer, let name):
                if let app = model.app(peer: peer, name: name) {
                    // One view per app: a version picked or read in one is not another's.
                    WorkspaceAppView(app: app).id(app.id)
                } else {
                    start(String(localized: "This app is no longer listed."))
                }
            case nil:
                start(String(localized: "Pick a conversation, or add a contact."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        // An app no longer listed keeps no page.
        .onChange(of: model.stadeum.apps.map(\.id)) { _, listed in
            model.appPages.evict(owners: { !listed.contains($0) })
        }
    }

    /// No chat open: the app's name over what to do.
    private func start(_ message: String) -> some View {
        VStack(spacing: 0) {
            DetailHeader(title: String(localized: "Peel"))
            EmptyState(message)
        }
    }
}

extension PaneDivider {
    /// The column beside the rail's (the chat list's, Apps' and Payments'
    /// alike), so its edge stays put going between them.
    static let columnStandard = 260.0

    static func column(_ width: Binding<Double>) -> PaneDivider {
        PaneDivider(width: width, range: 220...420, standard: columnStandard, growsTo: .trailing)
    }
}

/// Put the column beside the rail away, or back (⌃⌘S): beside the window's
/// buttons, the chat list on Chats, Apps' column on Apps and the history on
/// Payments.
struct ColumnToggle: View {
    static let width = HeaderBand.toggleWidth

    enum Column {
        case chats, apps, payments

        func help(hidden: Bool) -> String {
            switch self {
            case .chats: hidden ? String(localized: "Show chat list (⌃⌘S)") : String(localized: "Hide chat list (⌃⌘S)")
            case .apps: hidden ? String(localized: "Show apps list (⌃⌘S)") : String(localized: "Hide apps list (⌃⌘S)")
            case .payments: hidden ? String(localized: "Show payments list (⌃⌘S)") : String(localized: "Hide payments list (⌃⌘S)")
            }
        }
    }

    /// The page's column and its hidden state; nil on a page with no column,
    /// where the toggle stays in its place, off.
    let column: (Column, Binding<Bool>)?

    var body: some View {
        if case let (column, hidden)? = column {
            let help = column.help(hidden: hidden.wrappedValue)
            IconButton("sidebar.left", help: help, size: .sm) { hidden.wrappedValue.toggle() }
                .hiddenShortcut(KeyboardShortcut("s", modifiers: [.control, .command])) { hidden.wrappedValue.toggle() }
                .frame(width: Self.width, alignment: .leading)
        } else {
            IconButton("sidebar.left", help: String(localized: "No list on this page"), size: .sm) {}
                .disabled(true)
                .frame(width: Self.width, alignment: .leading)
        }
    }
}

/// The corner where the rail and the band meet what is beside the rail
/// (the chat list, Apps' column or a page), rounded: the chrome's colour
/// outside a quarter circle, and the divider along its curve, joining the
/// rail's edge and the band's line.
struct InnerCorner: View {
    static let radius: CGFloat = 10

    var body: some View {
        let r = Self.radius
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: r + 1, height: r + 1))
                path.move(to: CGPoint(x: 0.5, y: r + 1))
                path.addArc(center: CGPoint(x: r + 1, y: r + 1), radius: r + 0.5,
                            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                path.addLine(to: CGPoint(x: r + 1, y: r + 1))
                path.closeSubpath()
            }
            .fill(Theme.rail, style: FillStyle(eoFill: true))
            Path { path in
                path.addArc(center: CGPoint(x: r + 1, y: r + 1), radius: r + 0.5,
                            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            }
            .stroke(Theme.divider, lineWidth: 1)
        }
        .frame(width: r + 1, height: r + 1, alignment: .topLeading)
    }
}

/// The header of the column beside the rail, in the band: its title, clear
/// of the window's buttons and `ColumnToggle`, then its own buttons (the
/// chat list's search and +).
struct ColumnHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.font(16, .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.sm)
            trailing
        }
        .padding(.leading, HeaderBand.titleInset)
        .padding(.trailing, Theme.Space.sm)
        .frame(height: HeaderBand.height)
        .background(Theme.rail)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }
}

/// The bar across the top of the detail column, in the header band: the
/// chrome's colour (`Theme.rail`), as tall as the band, clear of the window's buttons
/// where it starts at the rail (`headerLeadingInset`).
struct DetailHeader<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// A click on the icon or the title: the chat's details, which open
    /// in the side panel (`ChatDetailsPanel`), not here.
    var onTitle: (() -> Void)?
    /// Beside the title: the agent chat's AGENT.
    var showsAgentTag = false
    /// The subtitle on the title's line, after it, rather than under it: a
    /// page's own header (Payments, All apps), so its title sits where a
    /// column's does and does not move up for a second line.
    var subtitleInline = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.headerLeadingInset) private var inset

    var body: some View {
        HStack(spacing: 10) {
            if let onTitle {
                Button(action: onTitle) { identity }
                    .buttonStyle(.plain)
                    .help("Details")
            } else {
                identity
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.leading, inset)
        .frame(height: HeaderBand.height)
        .background(Theme.rail)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(Theme.font(16, .bold))
                        .lineLimit(1)
                    if showsAgentTag { AgentTag() }
                    if subtitleInline, let subtitle { subtitleText(subtitle) }
                }
                if !subtitleInline, let subtitle { subtitleText(subtitle) }
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitleText(_ subtitle: String) -> some View {
        Text(subtitle)
            .font(Theme.font(12))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
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

