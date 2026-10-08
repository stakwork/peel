#if os(macOS)
import AppKit
#endif
import SwiftUI

// MARK: - Presenting

/// Shows Peel's menus and panels (forms and cards that used to be native
/// popovers) in their own borderless windows beside what opened them.
///
/// Their own windows, not SwiftUI overlays: an overlay is drawn over the
/// window's AppKit views (every `ScrollView`, the composer's text view, the
/// search field) but AppKit gives clicks to those views first, so menu rows
/// drawn over the sidebar or the conversation never got their clicks. A
/// window also never clips a menu to its parent and needs no host per popover.
@MainActor @Observable
final class MenuPresenter {
    struct Open {
        var entries: [MenuEntry]
        var highlighted: Int?
        var confirming: Int?
        /// The menu's width at least, for a dropdown as wide as its button.
        var minWidth: CGFloat = 0
    }

    private(set) var open: Open?
    /// Set only when a menu opens or closes, apart from `open` (which changes
    /// as the pointer moves over items), so the views that read these are
    /// not redrawn on every hover: whether a menu is open, and what opened
    /// it, so that view can show it is the menu's subject.
    private(set) var isOpen = false
    private(set) var source: AnyHashable?

    /// A short note at the bottom of the host window, such as "Copied".
    struct Toast: Equatable {
        let id = UUID()
        let text: String
    }

    private(set) var toast: Toast?

    /// Gives floating content the environment of the window it opens from.
    @ObservationIgnored var environment: (AnyView) -> AnyView = { $0 }
    #if os(macOS)
    /// The window whose root hosts this presenter, where its menus and
    /// panels open unless a trigger names another (a panel's own window).
    @ObservationIgnored weak var hostWindow: NSWindow?
    @ObservationIgnored private let menuWindow = FloatingWindow()
    @ObservationIgnored private let panelWindow = FloatingWindow()
    /// Never takes the keyboard; hidden with Peel when another app comes
    /// to the front.
    @ObservationIgnored private let cardWindow = {
        let window = FloatingWindow()
        window.takesKey = false
        window.hidesOnDeactivate = true
        return window
    }()
    @ObservationIgnored private var panelID: UUID?
    @ObservationIgnored private var panelClosed: (@MainActor () -> Void)?
    @ObservationIgnored private var keys = KeyMonitor()
    @ObservationIgnored private var clicks: Any?
    @ObservationIgnored private var resign: (any NSObjectProtocol)?
    #endif

    private var anythingOpen: Bool {
        #if os(macOS)
        open != nil || panelID != nil
        #else
        open != nil
        #endif
    }

    /// Opens a menu at a point (a right-click) or below a rect (a button),
    /// both in the SwiftUI global coordinates of `window` (the key window
    /// when nil), unless it has nothing in it.
    func show(_ entries: [MenuEntry], at anchor: CGRect, in window: NSWindowRef = nil, source: AnyHashable? = nil,
              minWidth: CGFloat = 0, highlightChecked: Bool = false) {
        guard entries.contains(where: { $0.item != nil }) else { return }
        let checked = highlightChecked ? entries.firstIndex { $0.item?.checked == true } : nil
        hideCard()
        open = Open(entries: entries, highlighted: checked, minWidth: minWidth)
        isOpen = true
        self.source = source
        #if os(macOS)
        guard let host = window ?? hostWindow else { return dismiss() }
        menuWindow.present(environment(AnyView(MenuPanel(presenter: self))), anchor: anchor, from: host)
        startMonitoring()
        #endif
    }

    func dismiss() {
        guard open != nil else { return }
        open = nil
        isOpen = false
        source = nil
        #if os(macOS)
        menuWindow.close(restoringKey: panelID != nil ? panelWindow : nil)
        stopMonitoringIfIdle()
        #endif
    }

    /// Shows a panel (a form or a card) below `anchor`, in place of any other
    /// panel. `closed` runs when it goes away by a click elsewhere or Escape.
    func showPanel(_ content: AnyView, at anchor: CGRect, id: UUID, closed: @escaping @MainActor () -> Void) {
        #if os(macOS)
        // A trigger inside the open panel (none today) would name it; the host otherwise.
        guard let host = NSApp.keyWindow.flatMap({ $0 === panelWindow ? $0 : nil }) ?? hostWindow else { return closed() }
        hideCard()
        if panelID != id { closePanel() }
        panelID = id
        panelClosed = closed
        panelWindow.present(environment(AnyView(PanelBox(content: content))), anchor: anchor, from: host)
        startMonitoring()
        #endif
    }

    /// Takes away the panel `id` (when its trigger says so).
    func dismissPanel(id: UUID) {
        #if os(macOS)
        guard panelID == id else { return }
        panelID = nil
        panelClosed = nil
        dismiss()
        panelWindow.close(restoringKey: nil)
        stopMonitoringIfIdle()
        #endif
    }

    /// Closes the panel from here, telling its trigger.
    private func closePanel() {
        #if os(macOS)
        guard let id = panelID else { return }
        let closed = panelClosed
        dismissPanel(id: id)
        closed?()
        #endif
    }

    /// Moving to another row takes back a first click on a destructive one.
    func highlight(_ index: Int?) {
        if open?.confirming != index { open?.confirming = nil }
        open?.highlighted = index
    }

    /// Runs an item, or for one that confirms, asks first. The menu goes
    /// first, so the action lands on the window underneath.
    func choose(_ index: Int) {
        guard let open, let item = open.entries[index].item else { return }
        if item.confirm != nil, open.confirming != index {
            self.open?.confirming = index
            self.open?.highlighted = index
            return
        }
        dismiss()
        if item.action(), let done = item.done { showToast(done) }
    }

    /// Shows `text` at the bottom of the window for a moment; another one
    /// takes its place and starts the wait again.
    func showToast(_ text: String) {
        toast = Toast(text: text)
        CopyFeedback.announce(text)
    }

    func hideToast(id: UUID) {
        if toast?.id == id { toast = nil }
    }

    func cancelConfirmation() {
        open?.confirming = nil
    }

    // MARK: Hover cards

    /// What the hover card shows now, and what it is about to.
    @ObservationIgnored private var cardSource: AnyHashable?
    @ObservationIgnored private var pendingCard: AnyHashable?
    @ObservationIgnored private var cardTimer: Task<Void, Never>?

    /// The pointer came onto a card's trigger (`over`) or left it. A card
    /// shows after a moment's rest, never over an open menu or panel, and
    /// goes a moment after the pointer leaves both the trigger and the card,
    /// so it can be reached.
    func hoverCard(_ source: AnyHashable, over: Bool, at anchor: CGRect, content: @escaping @MainActor () -> AnyView) {
        cardTimer?.cancel()
        pendingCard = nil
        guard over else { return hideCardSoon() }
        guard cardSource != source else { return }
        let delay = cardSource == nil ? 500 : 150
        pendingCard = source
        cardTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, !self.anythingOpen else { return }
            self.showCard(content(), at: anchor, source: source)
        }
    }

    /// A trigger went away (scrolled off, its panel closed): only its own
    /// card goes, shown or about to show.
    func triggerGone(_ source: AnyHashable) {
        guard cardSource == source || pendingCard == source else { return }
        cardTimer?.cancel()
        pendingCard = nil
        hideCardSoon()
    }

    private func showCard(_ content: AnyView, at anchor: CGRect, source: AnyHashable) {
        #if os(macOS)
        guard let host = hostWindow else { return }
        cardSource = source
        let card = content
            .menuBoxed(cornerRadius: 10)
            .onHover { [weak self] over in
                self?.cardTimer?.cancel()
                if !over { self?.hideCardSoon() }
            }
        cardWindow.present(environment(AnyView(card)), anchor: anchor, from: host)
        #endif
    }

    private func hideCardSoon() {
        cardTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { self?.hideCard() }
        }
    }

    private func hideCard() {
        cardTimer?.cancel()
        cardSource = nil
        pendingCard = nil
        #if os(macOS)
        cardWindow.hide()
        #endif
    }

    #if os(macOS)
    private func startMonitoring() {
        keys.start { [weak self] event in self?.handle(event) ?? false }
        if clicks == nil {
            clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                event in MainActor.assumeIsolated { [weak self] in self?.click(event) ?? false } ? nil : event
            }
        }
        if resign == nil {
            resign = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss()
                    self?.closePanel()
                }
            }
        }
    }

    private func stopMonitoringIfIdle() {
        guard !anythingOpen else { return }
        keys.stop()
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
    }

    /// A click outside a menu closes it and goes no further, as native menus
    /// do; a click outside a panel closes it and goes on.
    private func click(_ event: NSEvent) -> Bool {
        if open != nil {
            guard event.window !== menuWindow else { return false }
            dismiss()
            return true
        }
        if panelID != nil, event.window !== panelWindow {
            closePanel()
        }
        return false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let open else {
            // A panel: Escape closes it; every other key is its own.
            if event.keyCode == 53, panelID != nil {
                closePanel()
                return true
            }
            return false
        }
        switch event.keyCode {
        case 53: // Escape
            if open.confirming != nil { cancelConfirmation() } else { dismiss() }
            return true
        case 36, 76: // Return, Enter
            if let index = open.confirming ?? open.highlighted { choose(index) }
            return true
        case 125: move(1); return true
        case 126: move(-1); return true
        default:
            break
        }
        guard open.confirming == nil, let typed = event.charactersIgnoringModifiers?.lowercased().first else {
            return open.confirming != nil
        }
        let command = event.modifierFlags.contains(.command), option = event.modifierFlags.contains(.option)
        if let index = open.entries.firstIndex(where: {
            guard let shortcut = $0.item?.shortcut else { return false }
            return Character(shortcut.key.lowercased()) == typed && shortcut.command == command && shortcut.option == option
        }) {
            choose(index)
            return true
        }
        // Anything else typed while a menu is open closes it and goes on.
        dismiss()
        return false
    }
    #endif

    private func move(_ step: Int) {
        cancelConfirmation()
        guard let open else { return }
        let items = open.entries.indices.filter { open.entries[$0].item != nil }
        guard !items.isEmpty else { return }
        let position = open.highlighted.flatMap(items.firstIndex(of:))
        let next = position.map { ($0 + step + items.count) % items.count } ?? (step > 0 ? 0 : items.count - 1)
        self.open?.highlighted = items[next]
    }
}

// MARK: - The menu itself

private struct MenuPanel: View {
    let presenter: MenuPresenter

    var body: some View {
        if let open = presenter.open {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(open.entries.enumerated()), id: \.offset) { index, entry in
                    switch entry {
                    case .divider:
                        Theme.divider.frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
                    case .view(let view):
                        view
                    case .header(let title):
                        Text(title)
                            .font(Theme.font(11, .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                    case .item(let item):
                        MenuRow(item: item, highlighted: open.highlighted == index, confirming: open.confirming == index)
                            .onHover { if $0 { presenter.highlight(index) } }
                            .onTapGesture { presenter.choose(index) }
                    }
                }
            }
            .padding(5)
            .frame(minWidth: max(220, open.minWidth), alignment: .leading)
            .fixedSize()
            .menuBoxed()
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

/// One item. A destructive one after its first click reads its `confirm`
/// text in bold with "Click again" beside it.
private struct MenuRow: View {
    let item: MenuItem
    let highlighted: Bool
    var confirming = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if item.checked {
                    Image(systemName: "checkmark")
                } else if let systemImage = confirming ? "trash" : item.systemImage {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: 12, weight: confirming ? .bold : .regular))
            .frame(width: 16)
            Text(confirming ? item.confirm ?? item.title : item.title)
                .font(Theme.font(13, confirming ? .bold : .regular))
                .lineLimit(1)
            Spacer(minLength: 16)
            if confirming {
                Text("Click again")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            } else if let shortcut = item.shortcut {
                Text(shortcut.label)
                    .font(Theme.font(12))
                    .foregroundStyle(highlighted ? Theme.text : Theme.secondaryText)
            }
        }
        .foregroundStyle(item.destructive ? Theme.destructive : Theme.text)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(highlighted ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
}

/// A panel in the menu box, unless it draws its own (`DrawsOwnPanelBox`).
/// The box goes behind the content, so finding out never rebuilds the panel.
private struct PanelBox: View {
    private static let radius: CGFloat = 8
    let content: AnyView
    @State private var ownBox = false

    var body: some View {
        content
            .onPreferenceChange(DrawsOwnPanelBox.self) { ownBox = $0 }
            .background { if !ownBox { Color.clear.menuBoxed(cornerRadius: Self.radius) } }
            // The border again over the content, where `content.menuBoxed()` drew it.
            .overlay {
                if !ownBox { RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Theme.divider) }
            }
    }
}
