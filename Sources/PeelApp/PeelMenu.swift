#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Peel's own menu, in place of every native context menu, pop-up button and
/// picker: one look, keyboard navigable (arrows, Return, Escape, and the
/// shortcuts it shows), opened beside what triggered it and flipped to stay
/// inside the window. Destructive items are red, and ones that delete or
/// leave ask once more in place before they run.
///
/// The main window hosts menus with `.peelMenuHost()`; views open one with
/// `.peelMenu { ... }` (right-click or Control-click), `MenuButton` (an icon
/// such as More) or `PeelDropdown` (a value to choose), and a panel with
/// `.peelPopover(isPresented:)`. Both show in their own windows.

// MARK: - Entries

/// A key that runs a menu item while its menu is open.
struct MenuShortcut: Equatable {
    let key: Character
    var command = false

    var label: String { (command ? "⌘" : "") + String(key).uppercased() }

    static func key(_ key: Character) -> MenuShortcut { MenuShortcut(key: key) }
    static func command(_ key: Character) -> MenuShortcut { MenuShortcut(key: key, command: true) }
}

struct MenuItem {
    var title: String
    var systemImage: String?
    var shortcut: MenuShortcut?
    var checked = false
    var destructive = false
    /// What the row says once clicked, waiting for a second click, for
    /// what deletes, discards or leaves ("Delete for everyone").
    var confirm: String?
    var action: @MainActor () -> Void
}

enum MenuEntry {
    case item(MenuItem)
    case header(String)
    /// Something to show rather than choose, such as who the menu is about.
    case view(AnyView)
    case divider

    static func button(
        _ title: String, systemImage: String? = nil, shortcut: MenuShortcut? = nil, checked: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> MenuEntry {
        .item(MenuItem(title: title, systemImage: systemImage, shortcut: shortcut, checked: checked, action: action))
    }

    /// Red, and confirmed by a second click: the first turns the row into
    /// `confirm` without closing the menu.
    static func destructive(
        _ title: String, systemImage: String? = nil, confirm: String, action: @escaping @MainActor () -> Void
    ) -> MenuEntry {
        .item(MenuItem(title: title, systemImage: systemImage, destructive: true, confirm: confirm, action: action))
    }

    /// "Copy text" (⌘C), the same wherever a message's words can be copied.
    static func copyText(_ text: String) -> MenuEntry {
        .button("Copy text", systemImage: "doc.on.doc", shortcut: .command("c")) { Clipboard.copy(text) }
    }

    var item: MenuItem? {
        if case .item(let item) = self { item } else { nil }
    }
}

extension Array where Element == MenuEntry {
    /// Groups joined by dividers, leaving out empty ones.
    static func sections(_ groups: [MenuEntry]...) -> [MenuEntry] {
        groups.filter { !$0.isEmpty }.enumerated().flatMap { index, group in index == 0 ? group : [.divider] + group }
    }
}

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

    /// Gives floating content the environment of the window it opens from.
    @ObservationIgnored var environment: (AnyView) -> AnyView = { $0 }
    #if os(macOS)
    /// The window whose root hosts this presenter, where its menus and
    /// panels open unless a trigger names another (a panel's own window).
    @ObservationIgnored weak var hostWindow: NSWindow?
    @ObservationIgnored private let menuWindow = FloatingWindow()
    @ObservationIgnored private let panelWindow = FloatingWindow()
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
        if panelID != id { closePanel() }
        panelID = id
        panelClosed = closed
        panelWindow.present(environment(AnyView(content.menuBoxed())), anchor: anchor, from: host)
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
        item.action()
    }

    func cancelConfirmation() {
        open?.confirming = nil
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
        let command = event.modifierFlags.contains(.command)
        if let index = open.entries.firstIndex(where: {
            guard let shortcut = $0.item?.shortcut else { return false }
            return Character(shortcut.key.lowercased()) == typed && shortcut.command == command
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

#if os(macOS)
typealias NSWindowRef = NSWindow?
#else
typealias NSWindowRef = Void?
#endif

extension EnvironmentValues {
    @Entry var menuPresenter: MenuPresenter?
}

extension View {
    /// Makes this window's root the place menus and panels open from, with
    /// its environment.
    func peelMenuHost() -> some View {
        modifier(MenuHost())
    }

    /// Opens a menu on right-click or Control-click. `source` marks the view
    /// while its menu is open (see `MenuPresenter.source`).
    func peelMenu(source: AnyHashable? = nil, _ entries: @escaping @MainActor () -> [MenuEntry]) -> some View {
        modifier(ContextMenuModifier(source: source, entries: entries))
    }

    /// Peel's popover: `content` in a Peel panel below this view while
    /// `isPresented` is true; a click elsewhere or Escape sets it false.
    func peelPopover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(PopoverModifier(isPresented: isPresented, content: content))
    }
}

private struct MenuHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var presenter = MenuPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.menuPresenter, presenter)
            #if os(macOS)
            .background(WindowReader { presenter.hostWindow = $0 })
            #endif
            .onAppear {
                let model = model, presenter = presenter
                presenter.environment = { view in
                    AnyView(
                        view.environment(model)
                            .environment(\.menuPresenter, presenter)
                            .tint(Theme.accent)
                            .foregroundStyle(Theme.text)
                    )
                }
            }
    }
}

private struct ContextMenuModifier: ViewModifier {
    @Environment(\.menuPresenter) private var presenter
    let source: AnyHashable?
    let entries: @MainActor () -> [MenuEntry]

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay {
            RightClickCatcher { point, window in
                presenter?.show(entries(), at: CGRect(origin: point, size: .zero), in: window, source: source)
            }
        }
        #else
        content
        #endif
    }
}

private struct PopoverModifier<Panel: View>: ViewModifier {
    @Environment(\.menuPresenter) private var presenter
    @Binding var isPresented: Bool
    let content: () -> Panel

    @State private var frame: CGRect = .zero
    @State private var id = UUID()

    func body(content view: Content) -> some View {
        view
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onChange(of: isPresented) { _, shown in
                if shown {
                    let binding = $isPresented
                    presenter?.showPanel(AnyView(content()), at: frame, id: id) { binding.wrappedValue = false }
                } else {
                    presenter?.dismissPanel(id: id)
                }
            }
            .onDisappear { presenter?.dismissPanel(id: id) }
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

// MARK: - Triggers

/// An icon button that opens a menu below it, such as a message's More.
struct MenuButton: View {
    @Environment(\.menuPresenter) private var presenter
    let systemImage: String
    let help: String
    var source: AnyHashable?
    let entries: @MainActor () -> [MenuEntry]

    @State private var frame: CGRect = .zero

    var body: some View {
        HoverIconButton(systemImage: systemImage, help: help) {
            presenter?.show(entries(), at: frame, source: source)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// A small icon button that lights up under the pointer.
struct HoverIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                .frame(width: 28, height: 26)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Peel's pop-up button: shows the chosen value and opens the menu below
/// itself, with a check by the current one.
struct PeelDropdown<Value: Hashable>: View {
    @Environment(\.menuPresenter) private var presenter
    let selection: Value
    let options: [(value: Value, label: String)]
    let choose: @MainActor (Value) -> Void

    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        Button {
            presenter?.show(
                options.map { option in
                    .button(option.label, checked: option.value == selection) { choose(option.value) }
                },
                at: frame, minWidth: frame.width, highlightChecked: true
            )
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(Theme.font(13))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering ? Theme.hover : Theme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

// MARK: - AppKit

#if os(macOS)
/// Keys while a menu or the image viewer is open, whichever view has focus.
@MainActor
final class KeyMonitor {
    private var token: Any?

    /// `handle` returns whether it took the key.
    func start(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A modal panel (Save as…) has the keys while it is up.
            guard MainActor.assumeIsolated({ NSApp.modalWindow == nil }) else { return event }
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Takes right-clicks and Control-clicks over a view and lets everything
/// else (clicks, hovers, text selection, scrolling) through to it.
private struct RightClickCatcher: NSViewRepresentable {
    let action: (CGPoint, NSWindow?) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: ((CGPoint, NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isMenuClick(event) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { report(event) }

        override func mouseDown(with event: NSEvent) {
            if Self.isMenuClick(event) { report(event) } else { super.mouseDown(with: event) }
        }

        private static func isMenuClick(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        /// The click in the window's top-left coordinates, as SwiftUI's global space.
        private func report(_ event: NSEvent) {
            guard let content = window?.contentView else { return }
            let point = content.convert(event.locationInWindow, from: nil)
            action?(CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y), window)
        }
    }
}

/// A borderless window for a menu or a panel: sized to its content, placed
/// below its anchor (above, or to the left, when that would leave the parent
/// window), a child of the window it opened from so it moves with it.
@MainActor
final class FloatingWindow: NSPanel {
    /// Room around the content for its shadow.
    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 4

    private var anchor: CGRect = .zero
    private weak var host: NSWindow?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        // The presenter closes it when Peel goes to the back.
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }

    /// `anchor` is in the SwiftUI global coordinates of `host`.
    func present(_ content: AnyView, anchor: CGRect, from host: NSWindow) {
        if let old = self.host, old !== host { old.removeChildWindow(self) }
        self.host = host
        self.anchor = Self.screenRect(anchor, in: host)
        alphaValue = 0
        let root = FloatingRoot(content: content, margin: Self.margin) { [weak self] size in self?.place(size) }
        contentView = NSHostingView(rootView: root)
        if parent == nil { host.addChildWindow(self, ordered: .above) }
        makeKeyAndOrderFront(nil)
    }

    /// Hides it and gives the keyboard back: to `restoringKey` when given,
    /// else to the window it opened from.
    func close(restoringKey: NSWindow?) {
        guard isVisible else { return }
        let back = restoringKey ?? host
        host?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
        back?.makeKey()
    }

    /// A SwiftUI global rect (top-left origin, in the window's content) on the screen.
    private static func screenRect(_ rect: CGRect, in window: NSWindow) -> CGRect {
        let height = window.contentView?.bounds.height ?? window.frame.height
        return window.convertToScreen(NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
    }

    private func place(_ size: CGSize) {
        let content = CGSize(width: size.width - Self.margin * 2, height: size.height - Self.margin * 2)
        let bounds = (host?.frame ?? screen?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 8)
        var x = anchor.minX
        if x + content.width > bounds.maxX { x = (anchor.width > 0 ? anchor.maxX : anchor.minX) - content.width }
        let gap = anchor.height > 0 ? Self.gap : 0
        // Screen coordinates grow upwards: below the anchor is under its minY.
        var bottom = anchor.minY - gap - content.height
        if bottom < bounds.minY { bottom = anchor.maxY + gap }
        x = min(max(bounds.minX, x), max(bounds.minX, bounds.maxX - content.width))
        bottom = min(max(bounds.minY, bottom), max(bounds.minY, bounds.maxY - content.height))
        setFrame(NSRect(x: x - Self.margin, y: bottom - Self.margin, width: size.width, height: size.height), display: true)
        alphaValue = 1
    }
}

/// The content of a floating window at its own size, with room for its shadow.
private struct FloatingRoot: View {
    let content: AnyView
    let margin: CGFloat
    let sized: (CGSize) -> Void

    var body: some View {
        content
            .fixedSize()
            .padding(margin)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sized($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Tells which window a view is in, once it is in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var found: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
