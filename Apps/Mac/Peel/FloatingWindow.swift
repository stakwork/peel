#if os(macOS)
import AppKit
#endif
import SwiftUI

#if os(macOS)
/// A borderless window for a menu or a panel: sized to its content, placed
/// below its anchor (above, or to the left, when that would leave the parent
/// window), a child of the window it opened from so it moves with it. A
/// panel may instead grow leftward from the anchor's right edge (`PopoverEdge`).
@MainActor
final class FloatingWindow: NSPanel {
    /// Room around the content for its shadow.
    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 4

    /// On the screen.
    private var anchor: CGRect = .zero
    private var size: CGSize = .zero
    /// Reset on each `present`, so menus and cards keep the default.
    private var edge = PopoverEdge.leading
    private weak var host: NSWindow?
    /// The trigger it moves with as its list moves, and what to do once the
    /// trigger is out of sight (nil: stay, at the list's edge).
    private var following: (anchor: MenuAnchor, lost: (@MainActor () -> Void)?)?
    private var watches: [any NSObjectProtocol] = []

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

    /// A menu or a panel takes the keyboard; a hover card leaves it where it is.
    var takesKey = true

    override var canBecomeKey: Bool { takesKey }

    isolated deinit {
        follow(nil)
    }

    /// `anchor` is on the screen. With `following`, the window keeps beside
    /// that trigger as the list it sits in moves; once the trigger is out of
    /// sight `lost` runs, or with none the window stays at the list's edge.
    func present(_ content: AnyView, anchor: CGRect, from host: NSWindow, following: MenuAnchor? = nil,
                 lost: (@MainActor () -> Void)? = nil, edge: PopoverEdge = .leading) {
        if let old = self.host, old !== host { old.removeChildWindow(self) }
        self.host = host
        self.anchor = anchor
        self.edge = edge
        // Unplaced until the new content reports its size.
        size = .zero
        follow(following.map { ($0, lost) })
        alphaValue = 0
        let root = FloatingRoot(content: content, margin: Self.margin) { [weak self] size in self?.place(size) }
        contentView = NSHostingView(rootView: root)
        // AppKit throws (does not just refuse) adding a window as a child of
        // itself. Never this window's own caller's mistake to make fatal:
        // shown unparented instead, which only means it does not move with
        // a host it was never really told.
        if parent == nil, host !== self { host.addChildWindow(self, ordered: .above) }
        if takesKey { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
    }

    /// Hides it and gives the keyboard back: to `restoringKey` when given,
    /// else to the window it opened from.
    func close(restoringKey: NSWindow?) {
        follow(nil)
        guard isVisible else { return }
        let back = restoringKey ?? host
        host?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
        back?.makeKey()
    }

    /// Hides a window that never took the keyboard (a hover card), also
    /// one AppKit has already hidden with the app, so it does not come back.
    func hide() {
        follow(nil)
        host?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
    }

    /// Watches the trigger's list: its scrolling (the clip view's bounds),
    /// its height (the clip view's frame, when the composer grows) and its
    /// content (the document's frame, when a row above grows or the lazy
    /// stack measures rows again).
    private func follow(_ trigger: (anchor: MenuAnchor, lost: (@MainActor () -> Void)?)?) {
        watches.forEach(NotificationCenter.default.removeObserver)
        watches = []
        following = trigger
        guard let clip = trigger?.anchor.scrollView?.contentView else { return }
        let watched: [(NSView?, Notification.Name)] = [
            (clip, NSView.boundsDidChangeNotification), (clip, NSView.frameDidChangeNotification),
            (clip.documentView, NSView.frameDidChangeNotification),
        ]
        watches = watched.compactMap { view, name in
            view.map { view in
                NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.triggerMoved() }
                }
            }
        }
    }

    private func triggerMoved() {
        guard let following, size != .zero else { return }
        if following.anchor.isVisible {
            anchor = following.anchor.screenRect
        } else if let lost = following.lost {
            return lost()
        } else if let list = following.anchor.scrollView?.contentView, let window = list.window,
                  following.anchor.screenRect != .zero {
            // Out of sight but still there: pinned to the list's edge it left by.
            let visible = window.convertToScreen(list.convert(list.bounds, to: nil))
            var pinned = following.anchor.screenRect
            pinned.origin.y = min(max(pinned.minY, visible.minY), visible.maxY - pinned.height)
            anchor = pinned
        } else {
            return
        }
        place(size)
    }

    private func place(_ size: CGSize) {
        self.size = size
        let content = CGSize(width: size.width - Self.margin * 2, height: size.height - Self.margin * 2)
        let bounds = (host?.frame ?? screen?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 8)
        var x = anchor.minX
        switch edge {
        case .leading:
            if x + content.width > bounds.maxX { x = (anchor.width > 0 ? anchor.maxX : anchor.minX) - content.width }
        case .trailing:
            x = anchor.maxX - content.width
        }
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
#endif
