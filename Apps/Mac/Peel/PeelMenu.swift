#if os(macOS)
import AppKit
#endif
import SwiftUI
import PeelUI

/// Peel's own menu, in place of every native context menu, pop-up button and
/// picker: one look, keyboard navigable (arrows, Return, Escape, and the
/// shortcuts it shows), opened beside what triggered it and flipped to stay
/// inside the window. Destructive items are red, and ones that delete or
/// leave ask once more in place before they run.
///
/// The main window hosts menus with `.peelMenuHost()`; views open one with
/// `.peelMenu { ... }` (right-click or Control-click), `MenuButton` (an icon
/// such as More) or `PeelDropdown` (a value to choose), and a panel with
/// `.peelPopover(isPresented:)`, and a hover card with `.peelHoverCard`. All
/// show in their own windows.

// MARK: - Entries

/// A key that runs a menu item while its menu is open.
struct MenuShortcut: Equatable {
    let key: Character
    var command = false
    var option = false

    var label: String { (option ? "⌥" : "") + (command ? "⌘" : "") + String(key).uppercased() }

    static func key(_ key: Character) -> MenuShortcut { MenuShortcut(key: key) }
    static func command(_ key: Character) -> MenuShortcut { MenuShortcut(key: key, command: true) }
    static func optionCommand(_ key: Character) -> MenuShortcut { MenuShortcut(key: key, command: true, option: true) }
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
    /// Shown at the bottom of the window when `action` says it did its job
    /// ("Copied"), since the menu has gone by then.
    var done: String?
    /// Shown on the right, after the title: the current choice behind a
    /// submenu ("All"), or an icon for where the item opens.
    var detail: String?
    var detailSystemImage: String?
    /// Entries that take the menu's place when this item is chosen, with a
    /// way back (a submenu, opened in place).
    var submenu: [MenuEntry]?
    /// Returns whether it did its job; only `done` cares.
    var action: @MainActor () -> Bool
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
        .item(MenuItem(title: title, systemImage: systemImage, shortcut: shortcut, checked: checked) {
            action()
            return true
        })
    }

    /// Red, and confirmed by a second click: the first turns the row into
    /// `confirm` without closing the menu.
    static func destructive(
        _ title: String, systemImage: String? = nil, confirm: String, action: @escaping @MainActor () -> Void
    ) -> MenuEntry {
        .item(MenuItem(title: title, systemImage: systemImage, destructive: true, confirm: confirm) {
            action()
            return true
        })
    }

    /// Opens `entries` in the menu's place; `detail` names the current choice.
    static func submenu(
        _ title: String, systemImage: String? = nil, detail: String? = nil, _ entries: [MenuEntry]
    ) -> MenuEntry {
        .item(MenuItem(title: title, systemImage: systemImage, detail: detail, submenu: entries) { false })
    }

    /// A copy item: `copy` returns whether it copied, and "Copied" shows at
    /// the bottom of the window when it did.
    static func copy(
        _ title: String, systemImage: String = "doc.on.doc", shortcut: MenuShortcut? = nil,
        copy: @escaping @MainActor () -> Bool
    ) -> MenuEntry {
        .item(MenuItem(title: title, systemImage: systemImage, shortcut: shortcut, done: "Copied", action: copy))
    }

    static func copy(
        _ title: String, text: String, systemImage: String = "doc.on.doc", shortcut: MenuShortcut? = nil
    ) -> MenuEntry {
        .copy(title, systemImage: systemImage, shortcut: shortcut) { Clipboard.copy(text) }
    }

    /// "Copy text" (⌘C), the same wherever a message's words can be copied.
    static func copyText(_ text: String) -> MenuEntry {
        .copy("Copy text", text: text, shortcut: .command("c"))
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
    /// its environment; `main` for the main window, whose presenter the
    /// menu commands check (`AppModel.takesCommands`).
    func peelMenuHost(main: Bool = false) -> some View {
        modifier(MenuHost(main: main))
    }

    /// Opens a menu on right-click or Control-click. `source` marks the view
    /// while its menu is open (see `MenuPresenter.source`).
    func peelMenu(source: AnyHashable? = nil, _ entries: @escaping @MainActor () -> [MenuEntry]) -> some View {
        modifier(ContextMenuModifier(source: source, entries: entries))
    }

    /// A hover card: `card` in a floating window below this view while the
    /// pointer rests on it (`MenuPresenter.hoverCard`). `source` names what
    /// it is about, so moving between two triggers for the same person keeps it.
    func peelHoverCard<Card: View>(_ source: AnyHashable, @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(HoverCardModifier(source: source, card: card))
    }

    /// Peel's popover: `content`, a `Panel`, below this view while
    /// `isPresented` is true; a click elsewhere or Escape sets it false.
    func peelPopover<Content: View>(isPresented: Binding<Bool>, edge: PopoverEdge = .leading,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(PopoverModifier(isPresented: isPresented, edge: edge, content: content))
    }

    /// Marks this view as where the menu, panel or card it opens belongs.
    func menuAnchor(_ anchor: MenuAnchor) -> some View {
        #if os(macOS)
        background(AnchorView(anchor: anchor))
        #else
        self
        #endif
    }
}

/// Where a view that opens a menu, panel or card is: an AppKit view behind
/// it, asked for its frame when the menu opens and as its list scrolls
/// while it is open, never a frame kept from an earlier layout. Not state,
/// so following it redraws nothing. Hold one in `@State` and pass it to
/// `.menuAnchor`, one per trigger: two triggers on screen at once must not
/// share one.
@MainActor
final class MenuAnchor {
    #if os(macOS)
    fileprivate weak var view: NSView?

    var window: NSWindow? { view?.window }

    /// The view's frame now, on the screen.
    var screenRect: CGRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Some of it shows: in a window, and not scrolled out of its list.
    var isVisible: Bool {
        guard let view, view.window != nil else { return false }
        return !view.visibleRect.isEmpty
    }

    /// The scroll view it moves in, if any.
    var scrollView: NSScrollView? { view?.enclosingScrollView }
    #else
    var window: NSWindowRef { nil }
    var screenRect: CGRect { .zero }
    #endif
}

private struct MenuHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var presenter = MenuPresenter()
    let main: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                ToastView(presenter: presenter)
                    .padding(.bottom, 72)
            }
            .environment(\.menuPresenter, presenter)
            #if os(macOS)
            .background(WindowReader { presenter.hostWindow = $0 })
            #endif
            .onAppear {
                let model = model, presenter = presenter
                if main { model.mainPresenter = presenter }
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
                presenter?.show(entries(), at: point, in: window, source: source)
            }
        }
        .onDisappear { [source] in presenter?.menuTriggerGone(source) }
        #else
        content
        #endif
    }
}

private struct HoverCardModifier<Card: View>: ViewModifier {
    @Environment(\.menuPresenter) private var presenter
    let source: AnyHashable
    let card: () -> Card

    @State private var anchor = MenuAnchor()

    func body(content view: Content) -> some View {
        view
            .menuAnchor(anchor)
            .onHover { over in
                let card = card
                presenter?.hoverCard(source, over: over, at: anchor) { AnyView(card()) }
            }
            .onDisappear { presenter?.triggerGone(source) }
    }
}

private struct PopoverModifier<Panel: View>: ViewModifier {
    @Environment(\.menuPresenter) private var presenter
    @Binding var isPresented: Bool
    let edge: PopoverEdge
    let content: () -> Panel

    @State private var anchor = MenuAnchor()
    @State private var id = UUID()

    func body(content view: Content) -> some View {
        view
            .menuAnchor(anchor)
            .onChange(of: isPresented) { _, shown in
                if shown {
                    let binding = $isPresented
                    presenter?.showPanel(AnyView(content()), at: anchor, id: id, edge: edge) { binding.wrappedValue = false }
                } else {
                    presenter?.dismissPanel(id: id)
                }
            }
            // The trigger is told, so state kept outside the view (the
            // model's `sendingSats`) does not stay open with no panel.
            .onDisappear {
                presenter?.dismissPanel(id: id)
                if isPresented { isPresented = false }
            }
    }
}

// MARK: - AppKit

#if os(macOS)
/// The key codes the monitors read: a key's place on the keyboard, the
/// same whatever the layout.
enum KeyCode {
    static let `return`: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let enter: UInt16 = 76
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

/// Keys before any view sees them, whichever view has focus: a menu, a
/// panel, the image viewer, the search field and the sidebar each run
/// one while they are up.
///
/// Escape goes to the first of these that is open, and to no other:
///
/// 1. A menu (`MenuPresenter`): out of an armed confirm, else back out of
///    a submenu, else the menu closes.
/// 2. A panel (`MenuPresenter`): it closes.
/// 3. The image viewer, in the main window: it closes.
/// 4. The search bar, while its field has the cursor: the search closes.
/// 5. The sidebar, while it has focus: the arrow keys' highlight clears.
/// 6. No monitor: the view with the keyboard. The composer closes its
///    mention list, else (the agent's) closes the memory beside it, else
///    stops its reply, else stops replying, else closes its thread
///    (`AppModel.escape(in:)`); the web pane's
///    address field puts the address back; the Payments pane closes; the
///    call window, its own window, goes back to the grid.
///
/// Monitors run in the order they started, not this one, so each defers
/// to those above it itself: one below 2 takes only its own window's keys
/// with no menu or panel up (`MenuPresenter.takesKeys`), one below 3 none
/// while `AppModel.viewer` is set. The arrows and Return follow the same
/// order.
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

        /// The click on the screen.
        private func report(_ event: NSEvent) {
            guard let window else { return }
            action?(window.convertPoint(toScreen: event.locationInWindow), window)
        }
    }
}

/// The view behind a `.menuAnchor`, which its `MenuAnchor` asks where it is.
private struct AnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> PassThroughView {
        PassThroughView()
    }

    func updateNSView(_ view: PassThroughView, context: Context) {
        view.anchor = anchor
        // A view on its way out (the other side of an `if`) is still
        // updated after the one that replaced it, and must not take the
        // anchor back: only a view joining a window takes it from another
        // that is in one.
        if view.window != nil, anchor.view?.window == nil { anchor.view = view }
    }
}

/// Draws nothing and takes no clicks. Takes its anchor when it joins a
/// window (the newest wins) and lets go when it leaves, unless another has
/// taken it.
private final class PassThroughView: NSView {
    weak var anchor: MenuAnchor?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { anchor?.view = self } else if anchor?.view === self { anchor?.view = nil }
    }
}

/// Tells which window a view is in, once it is in one.
struct WindowReader: NSViewRepresentable {
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

/// Where a popover sits across its trigger. `.leading` starts at the
/// trigger's left edge (and flips left only to stay in the window).
/// `.trailing` grows leftward, its right edge in line with the trigger's.
enum PopoverEdge {
    case leading
    case trailing
}
