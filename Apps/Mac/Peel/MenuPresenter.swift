#if os(macOS)
import AppKit
#endif
import SwiftUI
import PeelUI

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
        /// Inside a submenu: the menu it came from, its item and that item's title.
        var back: (entries: [MenuEntry], index: Int, title: String)?
    }

    private(set) var open: Open?
    /// Set only when a menu opens or closes, apart from `open` (which changes
    /// as the pointer moves over items), so the views that read these are
    /// not redrawn on every hover: whether a menu is open, and what opened
    /// it, so that view can show it is the menu's subject.
    private(set) var isOpen = false
    private(set) var source: AnyHashable?

    /// The open menu was opened from `source`: the button that opened it is lit.
    func isOpen(from source: AnyHashable?) -> Bool {
        source != nil && isOpen && self.source == source
    }

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

    /// A menu or a panel is up; it has the keys.
    var anythingOpen: Bool {
        #if os(macOS)
        open != nil || panelID != nil
        #else
        open != nil
        #endif
    }

    #if os(macOS)
    /// Whether a key monitor below the menus and panels may take `event`:
    /// it is for this presenter's window and no menu or panel is up
    /// (`KeyMonitor`'s Escape order).
    func takesKeys(_ event: NSEvent) -> Bool {
        event.window === hostWindow && !anythingOpen
    }
    #endif

    /// Opens a menu below a button (`anchor`), moving with it while its
    /// list moves and closing once it is out of sight, unless it has
    /// nothing in it. `edge: .trailing` lines its right edge up with the
    /// button's, for a button at the end of a row.
    func show(_ entries: [MenuEntry], at anchor: MenuAnchor, source: AnyHashable? = nil,
              minWidth: CGFloat = 0, highlightChecked: Bool = false, edge: PopoverEdge = .leading) {
        show(entries, at: anchor.screenRect, in: anchor.window, following: anchor, source: source, minWidth: minWidth,
             highlightChecked: highlightChecked, edge: edge)
    }

    /// Opens a menu at a point on the screen (a right-click) from `window`
    /// (the host window when nil).
    func show(_ entries: [MenuEntry], at point: CGPoint, in window: NSWindowRef = nil, source: AnyHashable? = nil) {
        show(entries, at: CGRect(origin: point, size: .zero), in: window, source: source)
    }

    private func show(_ entries: [MenuEntry], at rect: CGRect, in window: NSWindowRef = nil, following: MenuAnchor? = nil,
                      source: AnyHashable?, minWidth: CGFloat = 0, highlightChecked: Bool = false,
                      edge: PopoverEdge = .leading) {
        guard entries.contains(where: { $0.item != nil }) else { return }
        let checked = highlightChecked ? entries.firstIndex { $0.item?.checked == true } : nil
        hideCard()
        open = Open(entries: entries, highlighted: checked, minWidth: minWidth)
        isOpen = true
        self.source = source
        #if os(macOS)
        guard let host = window ?? hostWindow else { return dismiss() }
        menuWindow.present(environment(AnyView(MenuPanel(presenter: self))), anchor: rect, from: host,
                           following: following, lost: { [weak self] in self?.dismiss() }, edge: edge)
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

    /// Shows a panel (a `Panel`, which draws its own box) below `anchor`, in
    /// place of any other panel. `closed` runs when it goes away by a click
    /// elsewhere or Escape. It moves with its trigger and, unlike a menu or a
    /// card, stays at the list's edge while the trigger is out of sight; it
    /// goes only with the trigger's row (`PopoverModifier`).
    func showPanel(_ content: AnyView, at anchor: MenuAnchor, id: UUID, edge: PopoverEdge = .leading,
                   closed: @escaping @MainActor () -> Void) {
        #if os(macOS)
        // Always the real host window, never panelWindow itself: it is one
        // long-lived instance reused for every panel, so it is often still
        // NSApp.keyWindow (legitimately, because a panel is open, or stale,
        // because close(restoringKey:)'s makeKey() could not take while the
        // app was inactive) with no trigger inside it actually asking for
        // that. Either way, presenting with it as its own host crashes
        // (addChildWindow:ordered: cannot add self as child of itself).
        guard let host = hostWindow else { return closed() }
        hideCard()
        if panelID != id { closePanel() }
        panelID = id
        panelClosed = closed
        panelWindow.present(environment(content), anchor: anchor.screenRect, from: host,
                            following: anchor, edge: edge)
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
        if let submenu = item.submenu {
            self.open?.back = (open.entries, index, item.title)
            self.open?.entries = submenu
            self.open?.confirming = nil
            self.open?.highlighted = submenu.firstIndex { $0.item?.checked == true }
            return
        }
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

    /// From a submenu back to the menu it opened from, its item highlighted.
    func goBack() {
        guard let back = open?.back else { return }
        open?.entries = back.entries
        open?.back = nil
        open?.confirming = nil
        open?.highlighted = back.index
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
    func hoverCard(_ source: AnyHashable, over: Bool, at anchor: MenuAnchor, content: @escaping @MainActor () -> AnyView) {
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

    /// A menu's trigger went away (its row's views made anew, its bar
    /// gone): its menu goes with it.
    func menuTriggerGone(_ source: AnyHashable?) {
        guard let source, open != nil, self.source == source else { return }
        dismiss()
    }

    /// A trigger went away (scrolled off, its panel closed): only its own
    /// card goes, shown or about to show.
    func triggerGone(_ source: AnyHashable) {
        guard cardSource == source || pendingCard == source else { return }
        cardTimer?.cancel()
        pendingCard = nil
        hideCardSoon()
    }

    /// Where the trigger is now, not where it was when the pointer arrived.
    private func showCard(_ content: AnyView, at anchor: MenuAnchor, source: AnyHashable) {
        #if os(macOS)
        guard let host = hostWindow, anchor.isVisible else { return }
        cardSource = source
        let card = content
            .menuBoxed(cornerRadius: Theme.Radius.panel)
            .onHover { [weak self] over in
                self?.cardTimer?.cancel()
                if !over { self?.hideCardSoon() }
            }
        cardWindow.present(environment(AnyView(card)), anchor: anchor.screenRect, from: host, following: anchor) { [weak self] in
            self?.hideCard()
        }
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
            if event.keyCode == KeyCode.escape, panelID != nil {
                closePanel()
                return true
            }
            return false
        }
        switch event.keyCode {
        case KeyCode.escape:
            if open.confirming != nil { cancelConfirmation() } else if open.back != nil { goBack() } else { dismiss() }
            return true
        case KeyCode.left: // out of a submenu
            goBack()
            return true
        case KeyCode.right: // into one
            if let index = open.highlighted, open.entries[index].item?.submenu != nil { choose(index) }
            return true
        case KeyCode.return, KeyCode.enter:
            if let index = open.confirming ?? open.highlighted { choose(index) }
            return true
        case KeyCode.down: move(1); return true
        case KeyCode.up: move(-1); return true
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
            // One column for checks and icons when any row has one, so every title lines up.
            let leading = open.entries.contains { $0.item.map { $0.checked || $0.systemImage != nil } ?? false }
            VStack(alignment: .leading, spacing: 0) {
                if let back = open.back {
                    MenuBackRow(title: back.title) { presenter.goBack() }
                    Theme.divider.frame(height: 1).padding(.vertical, Theme.Space.xs).padding(.horizontal, 6)
                }
                ForEach(Array(open.entries.enumerated()), id: \.offset) { index, entry in
                    switch entry {
                    case .divider:
                        Theme.divider.frame(height: 1).padding(.vertical, Theme.Space.xs).padding(.horizontal, 6)
                    case .view(let view):
                        view
                    case .header(let title):
                        Text(title)
                            .font(Theme.font(11, .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, Theme.Space.xs)
                            .padding(.bottom, 2)
                    case .item(let item):
                        MenuRow(item: item, highlighted: open.highlighted == index, confirming: open.confirming == index,
                                leading: leading)
                            .onHover { if $0 { presenter.highlight(index) } }
                            .onTapGesture { presenter.choose(index) }
                    }
                }
            }
            .padding(5)
            .frame(minWidth: max(220, open.minWidth), alignment: .leading)
            .fixedSize()
            .menuBoxed(cornerRadius: Theme.Radius.panel)
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
    /// The menu has a column for checks and icons: kept empty on a row without one.
    var leading = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if item.checked {
                    Image(systemName: "checkmark")
                } else if let systemImage = confirming ? "trash" : item.systemImage {
                    Image(systemName: systemImage)
                } else if leading {
                    Color.clear.frame(height: 1)
                }
            }
            .font(.system(size: 12, weight: confirming ? .bold : .regular))
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(confirming ? item.confirm ?? item.title : item.title)
                    .font(Theme.font(13, confirming ? .bold : .regular))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    // Kept, unseen, while confirming: the row keeps its height.
                    Text(subtitle)
                        .font(Theme.font(12))
                        .foregroundStyle(highlighted ? Theme.text : Theme.secondaryText)
                        .lineLimit(1)
                        .opacity(confirming ? 0 : 1)
                }
            }
            Spacer(minLength: 16)
            if confirming {
                Text("Click again")
                    .muted()
            } else if let shortcut = item.shortcut {
                Text(shortcut.label)
                    .font(Theme.font(12))
                    .foregroundStyle(highlighted ? Theme.text : Theme.secondaryText)
            } else if item.detail != nil || item.detailSystemImage != nil || item.submenu != nil {
                HStack(spacing: Theme.Space.xs) {
                    if let detail = item.detail { Text(detail).font(Theme.font(12)) }
                    if let image = item.detailSystemImage ?? (item.submenu != nil ? "chevron.right" : nil) {
                        Image(systemName: image).font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(highlighted ? Theme.text : Theme.secondaryText)
            }
        }
        .foregroundStyle(item.destructive ? Theme.destructive : Theme.text)
        .padding(.horizontal, Theme.Space.sm)
        // One line fits the 28 pt; a second takes the row past it, with room above and below.
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(highlighted ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
}

/// The top of a submenu: its parent item's title, back to the menu.
private struct MenuBackRow: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16)
            Text(title)
                .font(Theme.font(13, .medium))
            Spacer(minLength: 16)
        }
        .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 28)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Back to the menu")
        .accessibilityAddTraits(.isButton)
    }
}
