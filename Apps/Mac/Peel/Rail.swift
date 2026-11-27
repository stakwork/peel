import AgentKit
import AppKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

// MARK: - Rail

/// The Mac's thin rail down the window's left edge (Tom, 2026-11-26;
/// docs/design/README.md, "Rail"): always the same icons in the same
/// places (Tom, 2026-11-27). Peel's own places by use (Chats, Apps,
/// Payments), under a line Automations and Segments, and at the foot the
/// connection and you. Mentions and Threads are Chats' (its ••• and the rows pinned above the chats,
/// `SidebarColumn`); apps open from Apps' column. Icons only, each named by
/// its tooltip; it starts under the header band, where the window's
/// buttons sit.
struct Rail: View {
    @Environment(AppModel.self) private var model
    /// Whose tooltip shows, and when the next may show at once.
    @State private var tooltips = RailTooltips()
    /// MainView's: whether the chat list is put away (⌃⌘S).
    @AppStorage("chatListHidden") private var chatListHidden = false

    static let width = HeaderBand.railWidth

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            RailButton(String(localized: "Chats"), systemImage: "bubble.left.and.bubble.right", shortcut: "1",
                       selected: PeelPage.isChats(model.destination), count: model.unreadCount) {
                model.openChats()
                // ⌘1, then Down: the chats, from the keyboard; only while the list shows,
                // or the flag would wait and take the keys whenever it next appears.
                if !chatListHidden { model.chatListWantsKeys = true }
            }
            // By use (Tom, 2026-11-27): Chats, Apps, Payments; the lists under them are A–Z.
            RailButton(String(localized: "Apps"), systemImage: "square.grid.2x2", shortcut: "2",
                       selected: PeelPage.isApps(model.destination)) {
                model.openApps()
            }
            RailPaymentsButton(money: model.money)
            // The main three over the smaller pages.
            Theme.divider
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            ForEach(PeelPage.onRail) { page in
                RailButton(page.title, systemImage: page.systemImage, selected: model.destination == page.destination,
                           count: page.count(in: model)) {
                    model.destination = page.destination
                }
            }
            Spacer(minLength: Theme.Space.sm)
            ConnectionDot()
            RailButton(String(localized: "Account"), shortcut: ",", selected: model.destination == .account,
                       detail: ([model.me.name] + [model.money.shownMsat.map { Sats.format(msat: $0) }].compactMap { $0 })
                           .joined(separator: " · ")) {
                model.destination = .account
            } icon: { _ in
                Avatar(name: model.me.avatarName, url: model.myPhotoURL, size: Theme.AvatarSize.md, hue: model.myHue)
            }
        }
        .environment(tooltips)
        .padding(.top, HeaderBand.height + Theme.Space.sm)
        .padding(.bottom, Theme.Space.md)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.rail.ignoresSafeArea())
        // The rail's edge starts under the band, and no line crosses it
        // there (Tom, 2026-11-27, the board's "rail's top", option A): the
        // rail and the band are one surface, the window's buttons in it.
        .overlay(alignment: .trailing) {
            VStack(spacing: 0) {
                // From the band's line (its last point), so the two meet in one corner.
                Color.clear.frame(width: 1, height: HeaderBand.height - 1)
                Theme.divider.frame(width: 1)
            }
        }
        // A newly published app shows within minutes (or as Apps opens); the
        // workspaces or Peel's strut changing reads them at once. Here, as the
        // rail is always up.
        .task(id: AppsSource(peers: model.stadeum.live.map(\.id), server: model.memoryServer)) {
            while !Task.isCancelled {
                model.refreshApps()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}

/// The pages beside the main three (Tom, 2026-11-27): Automations and
/// Segments on the rail (`onRail`), Mentions and Threads in Chats
/// (`inChats`: its ••• and the rows pinned above the chats, kept as
/// `ChatSections.Layout.pinnedPages` under their raw values, as the
/// iPhone's).
enum PeelPage: String, Identifiable {
    case automations, mentions, segments, threads

    static let onRail: [PeelPage] = [.automations, .segments]
    static let inChats: [PeelPage] = [.mentions, .threads]

    /// Chats' pages the person pinned above the chats, in the order pinned.
    @MainActor static func pinnedInChats(_ model: AppModel) -> [PeelPage] {
        model.sidebarLayout.pinnedPages.compactMap(PeelPage.init(rawValue:)).filter(inChats.contains)
    }

    var id: String { rawValue }

    var destination: AppModel.Destination {
        switch self {
        case .threads: .threads
        case .mentions: .mentions
        case .automations: .automations
        case .segments: .segments
        }
    }

    var title: String {
        switch self {
        case .threads: String(localized: "Threads")
        case .mentions: String(localized: "Mentions")
        case .automations: String(localized: "Automations")
        case .segments: String(localized: "Segments")
        }
    }

    var systemImage: String {
        switch self {
        case .threads: "bubble.left"
        case .mentions: "at"
        case .automations: "clock.arrow.circlepath"
        case .segments: "record.circle"
        }
    }

    /// Its count: unread threads and mentions, automations whose last run
    /// did not finish.
    @MainActor func count(in model: AppModel) -> Int {
        switch self {
        case .threads: model.unreadThreads
        case .mentions: model.unreadMentions
        case .automations: model.automations.failed
        case .segments: 0
        }
    }

    /// Whether `destination` belongs to Chats: a chat, the agent, Mentions,
    /// Threads, or none open.
    static func isChats(_ destination: AppModel.Destination?) -> Bool {
        switch destination {
        case .chat?, .agent?, .mentions?, .threads?, nil: true
        default: false
        }
    }

    /// Whether `destination` belongs to Apps: the store or an app open.
    static func isApps(_ destination: AppModel.Destination?) -> Bool {
        switch destination {
        case .apps?, .app?: true
        default: false
        }
    }
}

/// One button on the rail: an icon on a rounded square, the tile and the
/// icon filled (white on the selection) while its destination is open,
/// swapped at once, as nav icons are (interface skill,
/// `motion-icon-crossfade`); a count at its corner; named by its tooltip,
/// with its shortcut when it has one (`RailTooltip`, to its right, not the
/// system's).
struct RailButton<Icon: View>: View {
    let title: String
    var shortcut: Character?
    let selected: Bool
    var count = 0
    /// After the title in the tooltip: your name and balance.
    var detail: String?
    let action: () -> Void
    /// Given whether it is selected.
    @ViewBuilder let icon: (Bool) -> Icon

    @State private var hovering = false
    @Environment(RailTooltips.self) private var tooltips: RailTooltips?

    init(_ title: String, shortcut: Character? = nil, selected: Bool, count: Int = 0, detail: String? = nil,
         action: @escaping () -> Void, @ViewBuilder icon: @escaping (Bool) -> Icon) {
        self.title = title
        self.shortcut = shortcut
        self.selected = selected
        self.count = count
        self.detail = detail
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button {
            // The tooltip goes as the button acts (a menu opening over it).
            tooltips?.dismiss()
            action()
        } label: {
            icon(selected)
        }
        .buttonStyle(RailButtonStyle(selected: selected, hovering: $hovering))
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Badge(count: count).railCutout().offset(x: 7, y: -6).allowsHitTesting(false)
            }
        }
        // To its right, over what is beside the rail (the rail draws on top).
        .overlay(alignment: .leading) {
            if tooltips?.shown == title {
                RailTooltip(title: title, detail: detail, shortcut: shortcut)
                    .fixedSize()
                    .offset(x: 34 + Theme.Space.sm)
                    .transition(tooltips?.fades == true ? .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)) : .identity)
                    .allowsHitTesting(false)
            }
        }
        .animation(tooltips?.fades == true ? .easeOut(duration: 0.15) : nil, value: tooltips?.shown == title)
        .onChange(of: hovering) { tooltips?.hover(title, on: hovering) }
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? String(localized: "\(count) unread") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(RailShortcut(key: shortcut, action: action))
    }

}

extension RailButton where Icon == Image {
    /// A symbol, its filled form while selected where it has one.
    init(_ title: String, systemImage: String, shortcut: Character? = nil, selected: Bool, count: Int = 0,
         action: @escaping () -> Void) {
        self.init(title, shortcut: shortcut, selected: selected, count: count, action: action) { on in
            Image(systemName: on ? RailButtonStyle.filled(systemImage) : systemImage)
        }
    }
}

extension View {
    /// A rail badge cut out of the tile under it by a ring in the rail's
    /// colour, so a count on the selected (accent) tile stays apart from it.
    func railCutout() -> some View {
        padding(2).background(Theme.rail, in: Capsule())
    }
}

/// A rail button's name to its right: Peel's own tooltip, a small dark
/// label with the shortcut quiet beside it (Tom, 2026-11-26: not the
/// system's yellow box).
private struct RailTooltip: View {
    let title: String
    let detail: String?
    let shortcut: Character?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.font(12, .medium)).foregroundStyle(Theme.text)
            if let detail, !detail.isEmpty {
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.secondaryText)
            }
            if let shortcut {
                Text("⌘\(String(shortcut))").font(Theme.font(12)).foregroundStyle(Theme.secondaryText)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .menuBoxed(cornerRadius: 6)
        .accessibilityHidden(true)
    }
}

/// When the rail's tooltips show (the interface skill's
/// `overlay-tooltip-delay`): the first after half a second over a button;
/// while one shows, or one went under 0.3 s ago, the next at once. The
/// first fades in; the next replace it without motion.
@MainActor @Observable
final class RailTooltips {
    private(set) var shown: String?
    private(set) var fades = true
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Whose tooltip `pending` will show: only its own exit cancels it.
    @ObservationIgnored private var pendingTitle: String?
    @ObservationIgnored private var closedAt = Date.distantPast

    /// A click: no tooltip until the pointer comes back.
    func dismiss() {
        pending?.cancel()
        if shown != nil { closedAt = .distantPast }
        shown = nil
    }

    func hover(_ title: String, on: Bool) {
        // Entering any button replaces what was pending; leaving one cancels only its own,
        // so another's exit arriving after this one's entry leaves it be.
        if on || pendingTitle == title {
            pending?.cancel()
            pendingTitle = nil
        }
        if on {
            if shown != nil || Date().timeIntervalSince(closedAt) < 0.3 {
                fades = false
                shown = title
            } else {
                pendingTitle = title
                pending = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.fades = true
                    self.shown = title
                }
            }
        } else if shown == title {
            shown = nil
            closedAt = Date()
        }
    }
}

/// The rail button's tile: hover and selection drawn inside the style, as
/// `IconButton` does, so the button keeps its tooltip.
private struct RailButtonStyle: ButtonStyle {
    let selected: Bool
    @Binding var hovering: Bool

    /// The filled form of the rail's symbols, where SF Symbols has one.
    static func filled(_ name: String) -> String {
        let filled: Set = ["bubble.left.and.bubble.right", "bolt", "square.grid.2x2", "record.circle"]
        return filled.contains(name) ? name + ".fill" : name
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16))
            .foregroundStyle(selected ? Color.white : hovering ? Theme.text : Theme.secondaryText)
            .frame(width: 34, height: 34)
            .background(selected ? Theme.accent : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// ⌘1, ⌘2, ⌘3 and ⌘, on the rail's own buttons: one owner each.
private struct RailShortcut: ViewModifier {
    let key: Character?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let key, key != "," {
            content.hiddenShortcut(KeyboardShortcut(KeyEquivalent(key), modifiers: .command), action: action)
        } else {
            // ⌘, is the app menu's Account…, which already opens it.
            content
        }
    }
}

/// Payments on the rail, its own view so an arrival redraws only it: the
/// bolt, and for a moment after sats arrive "+350" in the green of received
/// amounts at its corner (as the sidebar's row showed it).
private struct RailPaymentsButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let money: MoneyArrivals

    var body: some View {
        let msat = money.recentMsat
        RailButton(String(localized: "Payments"), systemImage: "bolt", shortcut: "3", selected: model.destination == .payments) {
            model.destination = .payments
        }
        .overlay(alignment: .bottom) {
            if msat > 0 {
                Badge(Sats.signed(msat: msat, incoming: true), .success)
                    .fixedSize()
                    .railCutout()
                    .offset(y: 9)
                    .allowsHitTesting(false)
                    .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Received \(Sats.format(msat: msat))")
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: msat)
    }
}

/// The connection, quietly: a small green dot while connected, a hollow
/// orange ring otherwise (Tom, 2026-11-26: option D). A click shows its
/// status card with a check or reconnect.
struct ConnectionDot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        @Bindable var model = model
        RailButton(String(localized: "Connection: \(model.connection.label)"), selected: model.showingConnection) {
            model.showingConnection.toggle()
        } icon: { _ in
            ZStack {
                Circle().fill(Theme.confirmed).frame(width: 8, height: 8).opacity(connected ? 1 : 0)
                Circle().strokeBorder(Theme.attention, lineWidth: 2).frame(width: 10, height: 10).opacity(connected ? 0 : 1)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: connected)
        }
        .peelPopover(isPresented: $model.showingConnection, edge: .leading) {
            ConnectionCard()
        }
    }
}

// MARK: - Header band

/// The band across the window's top: the window's buttons over the rail,
/// then the column's header and the page's own, all one row in the rail's
/// colour, `Theme.rail` (Tom, 2026-11-26).
enum HeaderBand {
    static let height: CGFloat = 52
    /// Where the window's buttons end, from the window's left edge.
    static let buttonsEnd: CGFloat = 76
    static let railWidth: CGFloat = 52
    /// The column's toggle beside the window's buttons (`ColumnToggle`).
    static let toggleWidth: CGFloat = 34
    /// From the rail's edge to the first title in the band, whatever the
    /// page (Tom, 2026-11-27: titles held still going from Chats to
    /// Payments): clear of the window's buttons and the column's toggle,
    /// shown or not.
    static let titleInset: CGFloat = buttonsEnd + toggleWidth - railWidth + 4
}

/// What the apps are read from: a change reads them again.
private struct AppsSource: Hashable {
    let peers: [String]
    let server: MemoryServer?
}

extension EnvironmentValues {
    /// How far the page header's content keeps right of the window's
    /// left edge where it starts at the rail: clear of the window's buttons
    /// (and the chat list's toggle). Zero beside the chat list.
    @Entry var headerLeadingInset: CGFloat = 0
}

/// Puts the window's close, minimise and zoom buttons in the middle of the
/// header band rather than at the top of a hidden title bar. AppKit lays
/// them out again on resize and full screen, so they are moved each time.
struct WindowButtonsInBand: View {
    var body: some View {
        WindowReader { window in
            guard let window else { return }
            WindowButtonsMover.shared.track(window)
        }
        .frame(width: 0, height: 0)
    }
}

@MainActor
private final class WindowButtonsMover {
    static let shared = WindowButtonsMover()
    private var tracked: Set<ObjectIdentifier> = []
    private var observers: [ObjectIdentifier: [any NSObjectProtocol]] = [:]

    func track(_ window: NSWindow) {
        place(window)
        let id = ObjectIdentifier(window)
        guard tracked.insert(id).inserted else { return }
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification]
        observers[id] = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    if let window { WindowButtonsMover.shared.place(window) }
                }
            }
        }
        // A window reopened can take a closed one's address: forget this one as it closes.
        observers[id]?.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                     object: window, queue: .main) { _ in
            MainActor.assumeIsolated { WindowButtonsMover.shared.forget(id) }
        })
    }

    private func forget(_ id: ObjectIdentifier) {
        tracked.remove(id)
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
    }

    /// The buttons' bar as tall as the band, the buttons centred in it.
    func place(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let bar = close.superview, let container = bar.superview
        else { return }
        var frame = container.frame
        if frame.height != HeaderBand.height {
            frame.size.height = HeaderBand.height
            frame.origin.y = window.frame.height - HeaderBand.height
            container.frame = frame
        }
        let y = (HeaderBand.height - close.frame.height) / 2
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
    }
}
