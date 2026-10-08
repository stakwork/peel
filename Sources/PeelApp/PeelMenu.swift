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
    /// its environment.
    func peelMenuHost() -> some View {
        modifier(MenuHost())
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

private struct HoverCardModifier<Card: View>: ViewModifier {
    @Environment(\.menuPresenter) private var presenter
    let source: AnyHashable
    let card: () -> Card

    /// Not state: it moves with every scroll, and only a hover reads it.
    final class Frame { var rect: CGRect = .zero }
    @State private var frame = Frame()

    func body(content view: Content) -> some View {
        view
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
            .onHover { over in
                let card = card
                presenter?.hoverCard(source, over: over, at: frame.rect) { AnyView(card()) }
            }
            .onDisappear { presenter?.triggerGone(source) }
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
