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
            .webPaneBeside(model.web)
        }
        .opensLinksInWebPane(model.web)
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
    /// A click on the icon or the title (a tribe's details).
    var onTitle: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

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
        .padding(.horizontal, 20)
        .frame(height: 60)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }

    private var identity: some View {
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
        }
        .contentShape(Rectangle())
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
