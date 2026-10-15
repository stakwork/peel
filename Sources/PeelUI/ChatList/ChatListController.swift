import Foundation
import Observation
import PeelCore

/// Where a message list goes, for any engine: the anchor, the following
/// latch, "New messages", the jump pill, jumps and where it opens
/// (`docs/reviews/2026-10-14-message-lists.md`, "Layer 2"). The engine
/// reports what it shows (`scrolled`) and the user's scrolls; every change
/// that comes with a layout returns the placement the engine applies in
/// that same pass, so nothing waits on a timer.
///
/// The list is in one of four modes: opening (until it first shows),
/// following the newest, reading a row (the anchor: the top row in view
/// that can hold the list, and its top below the view's), or holding a
/// row jumped to in the middle. Following is a latch: only your own
/// message arriving, your scroll reaching the bottom and the pill set it;
/// any scroll by hand clears it. Geometry alone never sets it.
@MainActor @Observable
public final class ChatListController {
    /// At most this far above the content's end is "at the bottom".
    public static let bottomZone: Double = 24

    public let list: ComposerID
    @ObservationIgnored public weak var engine: ChatListEngine?
    @ObservationIgnored private let store: ListAnchorStore

    // To the model. Called synchronously; the engine defers them past its update.
    /// The chat's list reached its bottom (a jump's window grows from there).
    @ObservationIgnored public var onListAtBottom: (() -> Void)?
    /// The list reached the newest by hand or the pill: a chat kept unread is read.
    @ObservationIgnored public var onReachedBottom: (() -> Void)?
    /// Near the top with older messages to load.
    @ObservationIgnored public var onLoadOlder: (() -> Void)?
    /// The pill outside a jump's window: the newest page replaces it.
    @ObservationIgnored public var onShowNewest: (() -> Void)?
    /// A jump landed on the message asked for: the model's request is done.
    @ObservationIgnored public var onJumped: (() -> Void)?

    /// The jump button: nil when the list is at (or near) its newest.
    public private(set) var pill: ListPill?

    private enum Mode: Equatable {
        case opening, following, reading, jumping(String)
    }

    @ObservationIgnored private var mode = Mode.opening
    @ObservationIgnored private var content = ListContent.empty {
        didSet {
            ids = Set(content.rows.lazy.map(\.id))
            anchorable = Set(content.rows.lazy.filter(\.canAnchor).map(\.id))
            contentVersion &+= 1
        }
    }
    /// Made once per content, not per scroll report.
    @ObservationIgnored private var ids: Set<String> = []
    @ObservationIgnored private var anchorable: Set<String> = []
    @ObservationIgnored private var contentVersion = 0
    /// What the pill was last worked out from: it changes only with them.
    private struct PillInputs: Equatable {
        var content: Int
        var bottom: ListBottom
        var far: Bool
        var mode: Mode
    }
    @ObservationIgnored private var pillInputs: PillInputs?
    /// The reading row and its top below the view's, from the last report.
    @ObservationIgnored private var anchor: (id: String, offset: Double)?
    @ObservationIgnored private var viewport: ListViewport?
    @ObservationIgnored public private(set) var phase = ListScrollPhase.idle
    @ObservationIgnored private var bottom = ListBottom()
    /// "New messages" still marks what is unread below it.
    @ObservationIgnored public private(set) var dividerUnread = false
    @ObservationIgnored private var revealed = false
    /// A message asked for that is not among the rows yet, by uuid.
    @ObservationIgnored public private(set) var pendingJump: String?
    /// Older messages asked for and not here yet.
    @ObservationIgnored private var olderAsked = false

    public init(list: ComposerID, store: ListAnchorStore) {
        self.list = list
        self.store = store
    }

    public var isFollowing: Bool { mode == .following }
    private var userScrolling: Bool { phase == .tracking || phase == .decelerating }

    /// Where the list holds now, for a change the engine makes by itself
    /// (rows measured, a cell that grew, T16 a resize): the newest while
    /// following, the reading row, the row jumped to; while a scroll by
    /// hand moves it, where it is.
    public var placement: ListPlacement {
        if userScrolling { return .keep }
        return switch mode {
        case .opening: .keep
        case .following: .newest
        case .reading: anchor.map { .row(id: $0.id, offset: $0.offset) } ?? .keep
        case .jumping(let id): .center(id: id)
        }
    }

    // MARK: Opening

    /// The list's first content: at the message asked for (`focus`, a
    /// uuid), else "New messages", else where it last stood, else the newest.
    public func appear(_ content: ListContent, focus: String? = nil) -> ListMove {
        self.content = content
        let move: ListMove
        if let focus, let id = row(holding: focus) {
            // T1
            move = land(on: id)
        } else if store.opensAtNewMessages(in: list), let divider = content.divider, has(divider) {
            // T2
            mode = .reading
            dividerUnread = true
            move = ListMove(to: .row(id: divider, offset: 0))
        } else if case .row(let id, let offset)? = store.anchor(of: list), has(id) {
            // T3
            mode = .reading
            anchor = (id, offset)
            move = ListMove(to: .row(id: id, offset: offset))
        } else {
            // T4
            mode = .following
            move = ListMove(to: .newest)
        }
        if let focus, row(holding: focus) == nil { pendingJump = focus }
        updatePill()
        return move
    }

    // MARK: Changes

    /// The rows are about to change to `content`; returns where the list
    /// goes in the same pass.
    public func contentWillChange(to content: ListContent, diff: ListDiff) -> ListMove {
        guard mode != .opening else { return appear(content) }
        let old = self.content
        self.content = content
        // T15: "Mark unread" placed the line again.
        if let divider = content.divider, divider != old.divider { dividerUnread = true }
        defer { updatePill() }

        let newIDs = content.rows.map(\.id)
        let inserted = Set(diff.inserted)
        let kept = newIDs.indices.filter { !inserted.contains(newIDs[$0]) }
        // T13, T14: a window swapped for another.
        if kept.isEmpty, !old.rows.isEmpty, !content.rows.isEmpty {
            return replaced()
        }
        let lastKept = kept.last ?? -1
        let arrivals = content.rows.indices.filter { $0 > lastKept && inserted.contains(newIDs[$0]) }
        // The page asked for came, or there is no more to ask for; a page
        // that brought nothing new leaves the rows as they were.
        if olderAsked, content.hasOlder != old.hasOlder || content.rows.count != old.rows.count {
            olderAsked = false
        }
        // T6: yours follows, whatever you were doing.
        if arrivals.contains(where: { content.rows[$0].isOwn }) {
            mode = .following
            pendingJump = nil
            return ListMove(to: .newest, animated: true)
        }
        switch mode {
        case .opening:
            return .keep  // Taken by `appear` above.
        case .following:
            // T7 animated once; T9 (a row grew, a re-sort) in place.
            return ListMove(to: .newest, animated: !arrivals.isEmpty && content.reachesNewest)
        case .jumping(let id):
            if has(id) { return ListMove(to: .center(id: id)) }
            mode = .reading
            return holdReading(old: old)
        case .reading:
            // T8, T10, T11, T12
            return holdReading(old: old)
        }
    }

    /// Reading: the anchor held, or (T12) its nearest surviving neighbour,
    /// below first, where it stood on the screen.
    private func holdReading(old: ListContent) -> ListMove {
        guard let current = anchor else { return .keep }
        if has(current.id) { return ListMove(to: .row(id: current.id, offset: current.offset)) }
        guard let index = old.rows.firstIndex(where: { $0.id == current.id }) else { return .keep }
        let below = old.rows[(index + 1)...].first { anchorable.contains($0.id) }
        let above = old.rows[..<index].last { anchorable.contains($0.id) }
        guard let neighbour = below ?? above else { return .keep }
        let offset = viewport.flatMap { view in
            view.visibleIDs.firstIndex(of: neighbour.id).map { view.visibleTops[$0] }
        } ?? current.offset
        anchor = (neighbour.id, offset)
        return ListMove(to: .row(id: neighbour.id, offset: offset))
    }

    /// T13: the jump waiting for this window; T14: where it stood, else the newest.
    private func replaced() -> ListMove {
        if let uuid = pendingJump, let id = row(holding: uuid) {
            pendingJump = nil
            return land(on: id)
        }
        if mode != .following, case .row(let id, let offset)? = store.anchor(of: list), has(id) {
            mode = .reading
            anchor = (id, offset)
            return ListMove(to: .row(id: id, offset: offset))
        }
        mode = .following
        return ListMove(to: .newest)
    }

    // MARK: Reports

    public func phase(_ new: ListScrollPhase) {
        let old = phase
        phase = new
        // T21, after an animated move.
        if old == .animating, new == .idle { settle() }
    }

    /// What the list shows now, after any move: by hand, by the engine, by
    /// a change.
    public func scrolled(_ view: ListViewport) {
        viewport = view
        if mode != .opening, !revealed {
            // T5
            revealed = true
            engine?.reveal()
            if phase == .idle { settle() }
        }
        if mode != .opening, let top = topAnchor(in: view) { anchor = top }
        if content.reachesNewest {
            bottom.report(atBottom: view.atBottom, settled: phase == .idle && mode != .opening, newest: newestIndex)
        }
        switch bottom.cross(atBottom: view.atBottom) {
        case .reached:
            // T18, T19.
            if userScrolling, content.reachesNewest { reachedNewest() }
            if content.reachesNewest || userScrolling { onListAtBottom?() }
        case .left:
            // Moved off by itself (a message that did not take it down, a
            // row that grew): only what was in view at the bottom is seen.
            if userScrolling { dividerUnread = false }
            bottom.left(byItself: !userScrolling && mode != .following, otherwiseSeen: seenWhenScrolledUp)
        case nil:
            break
        }
        // T20, once per page.
        if view.nearTop, content.hasOlder, !olderAsked, mode != .opening {
            olderAsked = true
            onLoadOlder?()
        }
        updatePill()
    }

    /// T17: a scroll by hand began; it stops following, even at the bottom.
    public func userScrollBegan() {
        phase = .tracking
        pendingJump = nil
        guard mode != .opening else { return }
        mode = .reading
        if let view = viewport, let top = topAnchor(in: view) { anchor = top }
    }

    /// T21: a scroll by hand ended. Ended at the newest, it follows again.
    public func userScrollEnded(_ view: ListViewport) {
        scrolled(view)
        phase = .idle
        if view.atBottom, content.reachesNewest, mode == .reading {
            reachedNewest()
        }
        settle()
    }

    // MARK: Jumps

    /// To the message with this uuid (from `date`), centred and lit (T22),
    /// or once a window with it comes (T23, then T13).
    @discardableResult
    public func jump(to uuid: String, at date: Date? = nil) -> JumpOutcome {
        pendingJump = nil
        guard let id = row(holding: uuid) else {
            pendingJump = uuid
            return outcome(of: uuid, at: date)
        }
        engine?.move(ListMove(to: land(on: id).to, animated: true))
        return .here
    }

    /// Where a jump to the message with this uuid, from `date`, stands.
    public func outcome(of uuid: String, at date: Date?) -> JumpOutcome {
        if row(holding: uuid) != nil { return .here }
        guard let date, let first = content.rows.first?.date, date < first else { return .notLoaded }
        return .waitingForWindow
    }

    /// Holding the row jumped to, lit; the model's request is done.
    private func land(on id: String) -> ListMove {
        mode = .jumping(id)
        engine?.flash(id)
        onJumped?()
        return ListMove(to: .center(id: id))
    }

    /// The pill, End or Command-Down: the newest, following (T24), or the
    /// newest page in place of a jump's window (T25).
    public func jumpToPresent() {
        pendingJump = nil
        mode = .following
        if content.reachesNewest {
            engine?.move(ListMove(to: .newest, animated: true))
            reachedNewest()
        } else {
            store.keep(.newest, of: list)
            onShowNewest?()
        }
        updatePill()
    }

    /// T27: kept for a list of these rows made again.
    public func disappear() {
        guard mode != .opening, !content.rows.isEmpty else { return }
        keep()
    }

    // MARK: State

    /// At rest: where it stands is kept, and at the newest everything there
    /// counts as seen.
    private func settle() {
        guard mode != .opening, !userScrolling else { return }
        keep()
        if content.reachesNewest, viewport?.atBottom == true {
            bottom.report(atBottom: true, settled: true, newest: newestIndex)
        }
        updatePill()
    }

    private func keep() {
        guard !content.rows.isEmpty else { return }
        if content.reachesNewest, mode == .following || viewport?.atBottom == true {
            store.keep(.newest, of: list)
        } else if let top = viewport.flatMap(topAnchor) ?? anchor {
            store.keep(.row(id: top.id, offset: top.offset), of: list)
        }
    }

    private func reachedNewest() {
        mode = .following
        dividerUnread = false
        onReachedBottom?()
    }

    /// The top row in view that can hold the list: the first whose top is
    /// in view, else the first cut off above.
    private func topAnchor(in view: ListViewport) -> (id: String, offset: Double)? {
        let rows = zip(view.visibleIDs, view.visibleTops).filter { anchorable.contains($0.0) }
        guard let top = rows.first(where: { $0.1 >= -0.5 }) ?? rows.first else { return nil }
        return (top.0, top.1)
    }

    private func updatePill() {
        let inputs = PillInputs(content: contentVersion, bottom: bottom, far: viewport?.far == true, mode: mode)
        guard inputs != pillInputs else { return }
        pillInputs = inputs
        let pill: ListPill?
        if mode == .opening {
            pill = nil
        } else if !content.reachesNewest {
            pill = .present
        } else {
            let count = bottom.newBelow(newestFirst: content.rows.reversed().lazy.map(\.shown))
            pill = count > 0 ? .count(count) : viewport?.far == true ? .arrow : nil
        }
        if pill != self.pill { self.pill = pill }
    }

    /// What counts as seen when the list leaves the bottom: up to "New
    /// messages" while what is below it is still unread, else everything.
    private var seenWhenScrolledUp: Int64 {
        if dividerUnread, let divider = content.divider,
           let index = content.rows.first(where: { $0.id == divider })?.shown.first?.serverIndex {
            return index - 1
        }
        return newestIndex ?? -1
    }

    /// The newest message in the list that the server has numbered.
    private var newestIndex: Int64? {
        content.rows.lazy.compactMap { $0.shown.last?.serverIndex }.max()
    }

    private func has(_ id: String) -> Bool {
        ids.contains(id)
    }

    private func row(holding uuid: String) -> String? {
        content.rows.first { $0.holds.contains(uuid) }?.id
    }
}
