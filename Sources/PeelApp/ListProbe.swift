import Foundation
import PeelUI

/// Offscreen only: the message lists a drive's `probe` step reads each
/// frame (`OffscreenDriver`). Each list hands over the `ListEnd` it keeps
/// anyway, and a sample reads what that already holds (where its rows are
/// laid out, the content in view, whether it is shown), so a probe adds no
/// observer, modifier or state to the list: it runs as it does unprobed.
/// Registering does nothing outside the offscreen mode.
@MainActor enum ListProbe {
    private final class Entry {
        weak var end: ListEnd?
        let kind: String
        let serial: Int
        let ignored: String?

        init(end: ListEnd, kind: String, serial: Int, ignored: String?) {
            self.end = end
            self.kind = kind
            self.serial = serial
            self.ignored = ignored
        }
    }

    private static var entries: [Entry] = []
    private static var made = 0

    /// A list appeared: `kind` is chat, thread or agent; `ignoring`, a row
    /// id that is not a row (the agent list's end marker).
    static func register(_ end: ListEnd, kind: String, ignoring: String? = nil) {
        guard Offscreen.isOn else { return }
        entries.removeAll { $0.end == nil }
        guard !entries.contains(where: { $0.end === end }) else { return }
        made += 1
        entries.append(Entry(end: end, kind: kind, serial: made, ignored: ignoring))
    }

    /// A row as a sample shows it: a keyed hash of its id (never its text
    /// or id), its index in the list, and where it sits from the top of the
    /// list's view.
    struct Row: Encodable {
        let row: String
        let index: Int
        let y: Double
        let height: Double
    }

    /// One list in one frame.
    struct List: Encodable {
        let kind: String
        /// Which list this is: a list made again has a new number.
        let list: Int
        let rows: Int
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
    }

    /// Every list now in a window. `divider` and `target` give, by list
    /// kind, the row id of "New messages" and of the message gone to.
    static func sample(divider: (String) -> String?, target: (String) -> String?) -> [List] {
        entries.compactMap { entry in
            guard let end = entry.end, !end.gone else { return nil }
            let ids = end.ids.filter { $0 != entry.ignored }
            let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let view = end.view
            let height = view.upperBound - view.lowerBound
            func row(_ id: String, _ frame: CGRect) -> Row? {
                guard let place = index[id] else { return nil }
                return Row(row: TimelineLog.tag(id), index: place, y: Double(frame.minY - view.lowerBound),
                           height: Double(frame.height))
            }
            let placed = end.frames.compactMap { id, frame in index[id] != nil ? (id, frame) : nil }
            let inView = placed.filter { $0.1.maxY > view.lowerBound && $0.1.minY < view.upperBound }
            let whole = inView.filter { $0.1.minY >= view.lowerBound - 0.5 && $0.1.maxY <= view.upperBound + 0.5 }
            let top = (whole.isEmpty ? inView : whole).min { $0.1.minY < $1.1.minY }
            let near = placed.filter { $0.1.maxY > view.lowerBound - height && $0.1.minY < view.upperBound + height }
            let below = end.content - view.upperBound
            let frames = end.frames
            func find(_ id: String?) -> Row? { id.flatMap { id in frames[id].flatMap { row(id, $0) } } }
            return List(
                kind: entry.kind, list: entry.serial, rows: ids.count, shown: end.shown,
                atEnd: below <= 0.5, offset: Double(view.lowerBound), below: Double(below), container: Double(height), inView: inView.count,
                blank: !ids.isEmpty && (!end.shown || inView.isEmpty),
                top: top.flatMap { row($0.0, $0.1) },
                laidOut: near.compactMap { row($0.0, $0.1) }.sorted { $0.index < $1.index },
                divider: find(divider(entry.kind)), target: find(target(entry.kind)),
                targetIndex: target(entry.kind).flatMap { index[$0] }
            )
        }
    }
}

extension ListProbe {
    /// The newest list of `kind` now in a window, for the driver's scrolls.
    static func end(kind: String) -> ListEnd? {
        entries.last { $0.kind == kind && $0.end?.gone == false }?.end
    }

    /// The rows of the newest list of `kind` laid out and in view, by id.
    static func inView(kind: String) -> [String] {
        guard let end = end(kind: kind) else { return [] }
        let view = end.view
        return end.ids.filter { id in end.frames[id].map { $0.maxY > view.lowerBound && $0.minY < view.upperBound } ?? false }
    }
}
