#if os(macOS)
import AppKit
#endif
import SwiftUI

#if os(macOS)
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

    /// A menu or a panel takes the keyboard; a hover card leaves it where it is.
    var takesKey = true

    override var canBecomeKey: Bool { takesKey }

    /// `anchor` is in the SwiftUI global coordinates of `host`.
    func present(_ content: AnyView, anchor: CGRect, from host: NSWindow) {
        if let old = self.host, old !== host { old.removeChildWindow(self) }
        self.host = host
        self.anchor = Self.screenRect(anchor, in: host)
        alphaValue = 0
        let root = FloatingRoot(content: content, margin: Self.margin) { [weak self] size in self?.place(size) }
        contentView = NSHostingView(rootView: root)
        if parent == nil { host.addChildWindow(self, ordered: .above) }
        if takesKey { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
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

    /// Hides a window that never took the keyboard (a hover card), also
    /// one AppKit has already hidden with the app, so it does not come back.
    func hide() {
        host?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
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
#endif
