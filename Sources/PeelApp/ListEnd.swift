import SwiftUI

/// Where a lazy list's rows are laid out, for holding it at its end by
/// them, kept outside SwiftUI's observation so writing it redraws nothing.
///
/// A lazy stack only estimates the rows it has not laid out. Measuring rows
/// far from its estimate, it can move them and change its height without
/// moving the scroll offset: the list's end, or the place a row not laid
/// out is scrolled to, can then be blank space past the rows, or older
/// rows than the newest (`03-chat.md`, "Blank past the rows the stack
/// placed"). A re-pin by these places goes where the rows really are.
@MainActor class ListEnd {
    /// Where each row laid out sits in the content, from its first layout
    /// until it disappears.
    var frames: [String: CGRect] = [:]
    /// Where each row was last laid out, kept once it is not: once the
    /// list is past the rows, the stack drops them, and a re-pin steps
    /// back down from where they were (`towardsNewest`).
    var placed: [String: CGRect] = [:]
    /// The list's rows by id, oldest first, as they are now: a re-pin's
    /// task holds the rows of when it was asked for.
    var ids: [String] = []
    /// The list has disappeared: its scroll view is another list's now.
    var gone = false
    /// Steps down from the newest row laid out towards the newest row
    /// since one ended in view, a new one came or you took the list; past
    /// `stepLimit` a re-pin jumps to the end instead.
    var steps = 0
    static let stepLimit = 12

    /// Scrolls a re-pin has made: shown once none has come for a while.
    var moves = 0

    /// The content in view at the last scroll geometry, and the content's
    /// height then (read by a drive's `probe`, `ListProbe`).
    private(set) var view: Range<CGFloat> = 0..<0
    private(set) var content: CGFloat = 0
    /// The list is shown (no longer hidden until placed); for `ListProbe`.
    var shown = false

    /// The latest re-pin asked for, and when the oldest still waiting was.
    private(set) var request = 0
    private var waitingSince: ContinuousClock.Instant?

    /// A row laid out, or laid out again, at `frame`.
    func laidOut(_ id: String, at frame: CGRect) {
        frames[id] = frame
        placed[id] = frame
    }

    /// Whether the row with `id` is laid out and in view down to `padding`
    /// below it.
    func endsInView(_ id: String, padding: CGFloat) -> Bool {
        guard let frame = frames[id] else { return false }
        return frame.maxY > view.lowerBound && frame.maxY + padding <= view.upperBound + 0.5
    }

    /// With rows laid out, none of them in view. Called with every scroll
    /// geometry, it keeps the content in view for the rest.
    func noneInView(offset: CGFloat, container: CGFloat, content: CGFloat) -> Bool {
        view = offset..<(offset + container)
        self.content = content
        return !frames.isEmpty && !frames.values.contains { $0.maxY > offset && $0.minY < view.upperBound }
    }

    /// The row nearest the top of the view, of those laid out and not in
    /// `skipping`, and how far its top is below the view's (negative: cut
    /// off above).
    func topRow(skipping: Set<String>) -> (id: String, offset: CGFloat)? {
        frames.lazy.filter { id, frame in frame.maxY > self.view.lowerBound + 1 && frame.minY < self.view.upperBound && !skipping.contains(id) }
            .min { $0.value.minY < $1.value.minY }
            .map { ($0.key, $0.value.minY - view.lowerBound) }
    }

    /// Where a re-pin scrolls by the rows laid out, nil with none: the
    /// newest row's bottom (plus `padding`) at the list's bottom while it
    /// is laid out; else the bottom of the newest row laid out or last
    /// placed (`from`) near the top of the list, so the rows after it are
    /// laid out in view, a list's height of them a step. A place kept from
    /// an earlier layout is only stepped from, and only with none laid out.
    func towardsNewest(padding: CGFloat) -> (y: CGFloat, from: String?)? {
        let height = view.upperBound - view.lowerBound
        guard height > 0 else { return nil }
        if let last = ids.last, let frame = frames[last] { return (frame.maxY + padding - height, nil) }
        // The rows laid out now first: a place kept goes stale as the
        // estimate swings (a step to it can lie past the content, and
        // move nothing).
        let from = ids.last(where: { frames[$0] != nil }) ?? ids.last(where: { placed[$0] != nil })
        guard let newest = from, let frame = frames[newest] ?? placed[newest] else { return nil }
        return (frame.maxY - height * 0.1, newest)
    }

    /// A re-pin asked for; returns its number.
    func ask() -> Int {
        request &+= 1
        if waitingSince == nil { waitingSince = .now }
        return request
    }

    /// Whether `request` runs now: the latest one, or any once requests
    /// have kept coming for 100 ms (a reply streaming, a height swinging).
    func due(_ request: Int) -> Bool {
        guard let since = waitingSince,
              request == self.request || ContinuousClock.now - since >= .milliseconds(100) else { return false }
        waitingSince = nil
        return true
    }
}

extension View {
    /// Reports to `end` where this row is laid out in the content (the
    /// named coordinate space `space`), and that it is not once it
    /// disappears. Only a layout moves it, not a scroll.
    func laidOut(_ id: String, in end: ListEnd, space: String) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(space)) }) { end.laidOut(id, at: $0) }
            .onDisappear { end.frames[id] = nil }
    }
}
