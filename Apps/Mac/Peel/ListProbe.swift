import AppKit
import CryptoKit
import Foundation
import PeelUI
import SwiftUI

/// What a message list reports of where its rows are, as of its last move:
/// the chat's, a thread's and the agent chat's table (`MessageTableEngine`).
/// Frames and the view are in the content, from its top.
@MainActor protocol ListGeometry: AnyObject {
    /// The rows, oldest first.
    var ids: [String] { get }
    /// The content in view.
    var view: Range<CGFloat> { get }
    /// The content's height.
    var content: CGFloat { get }
    /// Shown, no longer hidden until placed.
    var shown: Bool { get }
    /// Where the rows around the view are.
    var frames: [String: CGRect] { get }
    /// What each row's cell draws now: its content's size.
    var drawn: [String: CGSize] { get }
    /// The list has gone: its scroll view is another list's, or none.
    var gone: Bool { get }
    /// Its scroll view, when it knows it.
    var scrollView: NSScrollView? { get }
    /// The width its rows are laid out at; 0 when it does not say.
    var width: CGFloat { get }
    /// The jump button over it, if any.
    var pill: ListPill? { get }
}

/// Offscreen only: the message lists a drive's `probe` step reads each
/// frame (`OffscreenDriver`). Each list hands over the `ListGeometry` it
/// keeps anyway, and a sample reads what that already holds (where its rows
/// are, the content in view, whether it is shown), so a probe adds no
/// observer, modifier or state to the list: it runs as it does unprobed.
/// Registering does nothing outside the offscreen mode.
@MainActor enum ListProbe {
    @MainActor private final class Entry {
        weak var end: ListGeometry?
        let kind: String
        let serial: Int

        init(end: ListGeometry, kind: String, serial: Int) {
            self.end = end
            self.kind = kind
            self.serial = serial
        }
    }

    private static var entries: [Entry] = []
    private static var made = 0

    /// A list appeared: `kind` is chat, thread or agent.
    static func register(_ end: ListGeometry, kind: String) {
        guard Offscreen.isOn else { return }
        entries.removeAll { $0.end == nil }
        guard !entries.contains(where: { $0.end === end }) else { return }
        made += 1
        entries.append(Entry(end: end, kind: kind, serial: made))
    }

    /// A row as a probe writes it: its tag (`tag`, never its text or id), its index in the list, and where it sits from the top of the
    /// list's view.
    struct Row: Encodable {
        let row: String
        let index: Int
        let y: Double
        let height: Double
        /// The height its cell draws, when it drew it at the row's width.
        let drawn: Double?
    }

    /// One list in one frame.
    struct List: Encodable {
        let kind: String
        /// Which list this is: a list made again has a new number.
        let list: Int
        let rows: Int
        let width: Double
        let shown: Bool
        let atEnd: Bool
        /// The view's top in the content, and how far the content goes
        /// past its bottom.
        let offset: Double
        let below: Double
        let container: Double
        /// Rows laid out and in view.
        let inView: Int
        /// Rows to show and none seen: hidden, or none in view.
        let blank: Bool
        /// The top row wholly in view (else the one across the view's top).
        let top: Row?
        /// The rows laid out from a view's height above to one below.
        let laidOut: [Row]
        /// "New messages" and the message a jump or search went to, if laid out.
        let divider: Row?
        let target: Row?
        /// The target's index, laid out or not.
        let targetIndex: Int?
        /// Its scroll view's x in the window, and whether it is drawn: in
        /// the window, not hidden, not transparent.
        let windowX: Double?
        let visible: Bool
        /// The jump button: "count N", "arrow", "present", or none.
        let pill: String?
    }

    /// One list in one frame as read, nothing derived: a frame's work is
    /// copying what the list holds (the arrays and the frames are shared,
    /// not copied, until the list changes them). `List` is made from it
    /// once, when the probe is written.
    struct Capture {
        let kind: String
        let serial: Int
        let ids: [String]
        let view: Range<CGFloat>
        let content: CGFloat
        let width: CGFloat
        let shown: Bool
        let frames: [String: CGRect]
        let drawn: [String: CGSize]
        let windowX: CGFloat?
        let visible: Bool
        let pill: ListPill?
    }

    /// Every list now in a window.
    static func capture() -> [Capture] {
        entries.compactMap { entry in
            guard let end = entry.end, !end.gone else { return nil }
            let (windowX, visible) = placement(of: end.scrollView)
            return Capture(kind: entry.kind, serial: entry.serial, ids: end.ids, view: end.view,
                           content: end.content, width: end.width, shown: end.shown, frames: end.frames, drawn: end.drawn,
                           windowX: windowX, visible: visible && end.shown, pill: end.pill)
        }
    }

    /// What a probe writes, made after it ends. `divider` and `target` give
    /// the row id of "New messages" and of the message gone to, if any.
    static func list(_ capture: Capture, divider: String?, target: String?, index: [String: Int],
                     tag: (String) -> String) -> List {
        let view = capture.view
        let height = view.upperBound - view.lowerBound
        func row(_ id: String, _ frame: CGRect) -> Row? {
            guard let place = index[id] else { return nil }
            let drawn = capture.drawn[id].flatMap { abs($0.width - frame.width) <= 0.5 ? Double($0.height) : nil }
            return Row(row: tag(id), index: place, y: Double(frame.minY - view.lowerBound), height: Double(frame.height),
                       drawn: drawn)
        }
        let placed = capture.frames.compactMap { id, frame in index[id] != nil ? (id, frame) : nil }
        let inView = placed.filter { $0.1.maxY > view.lowerBound && $0.1.minY < view.upperBound }
        let whole = inView.filter { $0.1.minY >= view.lowerBound - 0.5 && $0.1.maxY <= view.upperBound + 0.5 }
        let top = (whole.isEmpty ? inView : whole).min { $0.1.minY < $1.1.minY }
        let near = placed.filter { $0.1.maxY > view.lowerBound - height && $0.1.minY < view.upperBound + height }
        let below = capture.content - view.upperBound
        func find(_ id: String?) -> Row? { id.flatMap { id in capture.frames[id].flatMap { row(id, $0) } } }
        return List(
            kind: capture.kind, list: capture.serial, rows: capture.ids.count, width: Double(capture.width), shown: capture.shown,
            atEnd: below <= 0.5, offset: Double(view.lowerBound), below: Double(below), container: Double(height),
            inView: inView.count, blank: !capture.ids.isEmpty && (!capture.shown || inView.isEmpty),
            top: top.flatMap { row($0.0, $0.1) },
            laidOut: near.compactMap { row($0.0, $0.1) }.sorted { $0.index < $1.index },
            divider: find(divider), target: find(target), targetIndex: target.flatMap { index[$0] },
            windowX: capture.windowX.map(Double.init), visible: capture.visible,
            pill: capture.pill.map { pill in
                switch pill {
                case .count(let count): "count \(count)"
                case .arrow: "arrow"
                case .present: "present"
                }
            }
        )
    }

    /// A key made for each run, so a probe's tags match nothing outside it.
    private static let salt = SymmetricKey(size: .bits128)

    /// A row's tag in a probe: sixteen hex characters of a keyed hash of its
    /// id, long enough that two rows never share one; the id itself (a
    /// message's uuid) is not written.
    static func tag(_ id: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: salt)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension ListProbe {
    /// The newest list of `kind` now in a window, for the driver's scrolls.
    static func geometry(kind: String) -> ListGeometry? {
        entries.last { $0.kind == kind && $0.end?.gone == false }?.end
    }

    /// The rows of the newest list of `kind` laid out and in view, by id.
    static func inView(kind: String) -> [String] {
        guard let end = geometry(kind: kind) else { return [] }
        let view = end.view
        return end.ids.filter { id in end.frames[id].map { $0.maxY > view.lowerBound && $0.minY < view.upperBound } ?? false }
    }
}

// MARK: Where a list and a side panel are drawn

extension ListProbe {
    /// A side panel's (`SidePanelSplit`) frame in the window, from its top
    /// left, as laid out; nil with none in. Set only offscreen.
    static var panel: CGRect?

    /// Drawn at the panel's top left, offscreen only: a colour nothing else
    /// in Peel draws.
    static let mark = SwiftUI.Color(red: 1, green: 0, blue: 1)

    /// Where the panel is drawn now: the x its mark is drawn at in the
    /// window's row through the mark (a drawn offset, as
    /// `.move(edge:)`'s, moves what is drawn but not the frame laid out);
    /// nil with no panel in, or none drawn in the window (slid past its
    /// edge). The whole row is read, wherever the frame says it is.
    static func drawnPanel(in window: NSWindow?) -> CGFloat? {
        guard let panel, let root = window?.contentView else { return nil }
        let y = root.isFlipped ? panel.minY : root.bounds.height - panel.minY - 1
        let strip = CGRect(x: 0, y: y, width: root.bounds.width, height: 1)
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: strip) else { return nil }
        root.cacheDisplay(in: strip, to: bitmap)
        // A pixel a point: the mark is two points wide.
        let scale = max(bitmap.pixelsWide / Int(strip.width), 1)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: scale) {
            guard let color = bitmap.colorAt(x: x, y: 0) else { continue }
            if color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent > 0.8 {
                return CGFloat(x / scale)
            }
        }
        return nil
    }

    /// The scroll view's x in its window, and whether it is drawn there.
    private static func placement(of scroll: NSScrollView?) -> (CGFloat?, Bool) {
        guard let scroll, let root = scroll.window?.contentView else { return (nil, false) }
        let frame = root.convert(scroll.bounds, from: scroll)
        var drawn = frame.intersects(root.bounds)
        var view: NSView? = scroll
        while let each = view, drawn {
            drawn = !each.isHidden && each.alphaValue > 0
            view = each.superview
        }
        return (frame.minX, drawn)
    }
}

extension View {
    /// Offscreen only: the panel's frame, and a mark drawn at its top left
    /// that a drive's probe finds in what is drawn each frame
    /// (`ListProbe.drawnPanel`). Nothing outside the offscreen mode.
    @ViewBuilder func probedPanel() -> some View {
        if Offscreen.isOn {
            overlay(alignment: .topLeading) { ListProbe.mark.frame(width: 2, height: 1) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ListProbe.panel = $0 }
                .onDisappear { ListProbe.panel = nil }
        } else {
            self
        }
    }
}
