import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// A message list on the iPhone (`ChatListEngine`): the chat's or a
/// thread's. The Mac's `MessageTableEngine` on UIKit
/// (`docs/reviews/2026-10-14-message-lists.md`, PR 6): a `UITableView`
/// whose rows have exact heights, each row's SwiftUI content measured once
/// per width and per version of the row (`stale` until then), the rows in
/// view before they are drawn and the rest in idle time. Every change
/// applies the controller's placement in the same pass, and every offset it
/// sets is clamped to the content, so the list never stands in estimated
/// space where no row is (the lazy stack's blank list).
@MainActor
final class MessageTableEngine: NSObject, ChatListEngine, UITableViewDataSource, UITableViewDelegate {
    let composer: ComposerID
    let controller: ChatListController
    let table = MessageTableView(frame: .zero, style: .plain)
    /// The row lit after a jump, read by every cell.
    private let flashed = PhoneListFlash()

    private weak var model: AppModel?
    private var environment = EnvironmentValues()
    /// What of the environment the cells draw by and the table does not
    /// follow by itself: a change shows the cells in view again.
    private struct Look: Equatable {
        var colorScheme: ColorScheme
        var contrast: ColorSchemeContrast
        var dynamicType: DynamicTypeSize
        var direction: LayoutDirection

        init(_ environment: EnvironmentValues) {
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            dynamicType = environment.dynamicTypeSize
            direction = environment.layoutDirection
        }
    }
    private var look: Look?
    /// False while its screen goes or waits for a reload (`ConversationScreen`):
    /// it shows the rows it last had and tells the model nothing.
    private var live = true
    private var reachesNewest = true
    private var hasOlder = false
    private(set) var rows: [ChatRow] = []
    private var ids: [String] = []
    private var position: [String: Int] = [:]
    /// The bars' room (header, composer, keyboard), the content's insets.
    private var insets = UIEdgeInsets.zero

    private var appeared = false
    private var placed = false
    private var gone = false
    /// Where it opens, until its view has a size.
    private var pendingOpen: ListMove?
    /// Our own moves of the content, which are not scrolls.
    private var adjusting = 0
    /// A scroll by hand: dragged, or decelerating after it.
    private var userScrolling = false
    /// The animated move running and where it goes.
    private var animatingTo: ListPlacement?
    /// A placement asked for while a rubber band ran: put in place once it is back.
    private var deferred = false
    /// Where the rows on the screen were at the last report, for a change
    /// that comes after the geometry moved (the insets).
    private var lastVisual: ListPlacement?
    /// The message asked for last, by uuid, so a request is taken once.
    private var handledFocus: String?
    private var jumpedTo: String?

    /// Each row's height, as last measured or reported.
    private var heights: [String: CGFloat] = [:]
    /// Rows to measure: new, changed since measured, or all at a new width.
    private var stale: Set<String> = []
    /// Every row's height (measured or estimated), for a short chat's fill.
    private var rowsHeight: CGFloat = 0
    /// Hosting controllers that measure rows, one per kind.
    private var sizers: [String: UIHostingController<AnyView>] = [:]
    private(set) var width: CGFloat = 0
    /// Cells laid out at another height than their row's (an image's size came).
    private var corrections: [String: CGFloat] = [:]
    private var correctionsQueued = false
    private var idleGeneration = 0
    /// Heights `idle` measured that the table has not taken yet: rows away
    /// from the view, taken in batches rather than after every slice.
    private var idleUnapplied = 0
    /// The offset at the last scroll report, for the direction a scroll moves.
    private var lastOffset: CGFloat = 0
    /// Rows measured, for the hitch log.
    private var measuredCount = 0
    /// Above a chat's rows while they are shorter than the view, so they sit at its bottom.
    private var fill: CGFloat = 0

    private let header = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let footer = UIView()

    /// Above the oldest row and below the newest.
    static var padding: CGFloat { Theme.Space.sm }
    /// The room the "older messages" spinner takes above the oldest row.
    static var spinnerRoom: CGFloat { 20 + 2 * Theme.Space.md }

    init(composer: ComposerID, model: AppModel) {
        self.composer = composer
        self.model = model
        controller = ChatListController(list: composer, store: model)
        super.init()
        controller.engine = self
        if let chat = composer.chat, composer.thread == nil {
            controller.onListAtBottom = { [weak self] in self?.later { $0.chatListAtBottom() } }
            controller.onReachedBottom = { [weak self] in self?.later { $0.reachedBottom(of: chat) } }
            controller.onLoadOlder = { [weak self] in self?.later { $0.loadOlder() } }
            controller.onShowNewest = { [weak self] in self?.later { $0.showNewest() } }
        }
        controller.onJumped = { [weak self] in self?.focusTaken() }

        table.engine = self
        table.dataSource = self
        table.delegate = self
        // Heights are ours, exact: nothing self-sizes or estimates.
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.allowsSelection = false
        table.keyboardDismissMode = .interactive
        table.contentInsetAdjustmentBehavior = .never
        table.topEdgeEffect.style = .soft
        table.bottomEdgeEffect.style = .soft
        table.accessibilityLabel = composer.thread == nil ? String(localized: "Messages") : String(localized: "Thread")
        for kind in Self.kinds { table.register(HostRowCell.self, forCellReuseIdentifier: kind) }
        spinner.hidesWhenStopped = true
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        header.addSubview(spinner)
        header.frame = CGRect(x: 0, y: 0, width: 1, height: Self.padding)
        footer.frame = CGRect(x: 0, y: 0, width: 1, height: Self.padding)
        table.tableHeaderView = header
        table.tableFooterView = footer
        // Shown once placed (`reveal`).
        table.alpha = 0
    }

    private var isThread: Bool { composer.thread != nil }

    /// To the model past the update that asked (the model is not written
    /// during one), and only while this list is live and still its chat's.
    private func later(_ body: @escaping @MainActor (AppModel) -> Void) {
        let chat = composer.chat
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.gone, self.live, let model = self.model, model.selectedChat == chat else { return }
            body(model)
        }
    }

    // MARK: Geometry

    private var offset: CGFloat { table.contentOffset.y }
    /// The room between the bars.
    private var viewHeight: CGFloat { max(table.bounds.height - insets.top - insets.bottom, 0) }
    private var minOffset: CGFloat { -insets.top }
    private var maxOffset: CGFloat { max(minOffset, table.contentSize.height + insets.bottom - table.bounds.height) }
    /// The content between the bars, in the content's coordinates.
    private var viewRect: CGRect {
        CGRect(x: 0, y: offset + insets.top, width: table.bounds.width, height: viewHeight)
    }

    // MARK: Updates

    func update(model: AppModel, rows new: [ChatRow], live: Bool, focus: FocusTarget?, reachesNewest: Bool,
                hasOlder: Bool, insets newInsets: UIEdgeInsets, environment: EnvironmentValues) {
        self.model = model
        self.environment = environment
        self.live = live
        let look = Look(environment)
        let restyled = self.look != nil && look != self.look
        let resized = self.look.map { $0.dynamicType != look.dynamicType || $0.direction != look.direction } ?? false
        self.look = look
        setInsets(newInsets)
        if !appeared {
            appeared = true
            self.reachesNewest = reachesNewest
            self.hasOlder = hasOlder
            updateHeader()
            setRows(new)
            stale = Set(ids)
            adjust {
                table.reloadData()
                table.layoutIfNeeded()
            }
            let uuid = focus?.message.uuid
            handledFocus = uuid
            jumpedTo = uuid
            pendingOpen = controller.appear(listContent, focus: uuid)
            if let focus, let uuid, controller.pendingJump != nil {
                notHere(focus.message, controller.outcome(of: uuid, at: focus.message.date))
            }
            log("appear rows=\(rows.count) open=\(pendingOpen.map { "\($0.to)" } ?? "-")")
            openIfSized()
            return
        }
        let differs = new != rows || reachesNewest != self.reachesNewest || hasOlder != self.hasOlder
        if differs, placed, userScrolling {
            // Under the finger nothing moves by itself: what changed is
            // applied the moment the scroll ends (`userScrollEnded`).
            waiting = Waiting(rows: new, reachesNewest: reachesNewest, hasOlder: hasOlder)
        } else if differs {
            waiting = nil
            timed("rows") { change(to: new, reachesNewest: reachesNewest, hasOlder: hasOlder) }
        } else if restyled {
            refreshVisibleCells()
            if resized, placed {
                // Every height measured in the old size is wrong now.
                let hold = holdNow()
                heights = [:]
                stale = Set(ids)
                updateRowsHeight()
                adjust {
                    table.reloadData()
                    table.layoutIfNeeded()
                }
                place(hold)
                report()
                queueIdle()
            }
        }
        takeFocus(focus)
        // Not yet open: in case the size came without a layout pass telling it.
        if pendingOpen != nil { openIfSized() }
    }

    /// Rows (or what the model says about them) held back during a scroll by hand.
    private struct Waiting {
        var rows: [ChatRow]
        var reachesNewest: Bool
        var hasOlder: Bool
    }
    private var waiting: Waiting?

    /// The rows change: the controller says where the list goes, and the
    /// table takes them in the same pass, from where the rows were on the screen.
    private func change(to new: [ChatRow], reachesNewest: Bool, hasOlder: Bool) {
        // Where the rows are, before anything (the header too) moves them.
        let visual = captureVisual()
        // The same rows in the same order (a reply growing, a reaction):
        // those that changed, found in one pass; nil when the rows differ.
        let inPlace = Self.changedInPlace(rows, new)
        self.reachesNewest = reachesNewest
        if hasOlder != self.hasOlder {
            self.hasOlder = hasOlder
            updateHeader()
        }
        let old = rows
        let oldIDs = ids
        setRows(new, sameIDs: inPlace != nil)
        let changedIDs = inPlace ?? Self.changed(old, rows)
        let difference = inPlace != nil
            ? CollectionDifference<String>([])!
            : ids.difference(from: oldIDs).inferringMoves()
        let diff = ListDiff(difference)
        stale.formUnion(diff.inserted)
        stale.formUnion(changedIDs)
        let move = controller.contentWillChange(to: listContent, diff: diff)
        applyRows(difference, oldCount: oldIDs.count, changed: changedIDs)
        log("rows \(old.count)->\(rows.count) move \(move.to)\(move.animated ? " animated" : "")")
        if placed {
            apply(move, from: visual)
            // After the move, so the fade starts as the list brings the row up.
            arrive(difference.insertions)
        } else if move.to != .keep {
            pendingOpen = move
        }
    }

    func dismantle() {
        controller.disappear()
        stopAnimation()
        gone = true
        idleGeneration += 1
        log("dismantle")
    }

    private var listContent: ListContent {
        ListContent(rows, in: composer, reachesNewest: reachesNewest, hasOlder: hasOlder)
    }

    private func setRows(_ new: [ChatRow], sameIDs: Bool = false) {
        rows = new
        if !sameIDs {
            ids = new.map(\.id)
            position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }
        updateRowsHeight()
    }

    /// With the same rows in the same order, the ids of those drawn
    /// differently now; nil when the rows are not the same.
    private static func changedInPlace(_ old: [ChatRow], _ new: [ChatRow]) -> [String]? {
        guard old.count == new.count else { return nil }
        var changed: [String] = []
        for (was, row) in zip(old, new) {
            guard was.id == row.id else { return nil }
            if was != row { changed.append(row.id) }
        }
        return changed
    }

    /// Kept rows drawn differently now.
    private static func changed(_ old: [ChatRow], _ new: [ChatRow]) -> [String] {
        let was = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { row in was[row.id].map { $0 == row ? nil : row.id } ?? nil }
    }

    /// The table made to match the rows: rows that went removed, rows that
    /// came inserted, the cells of kept rows that changed shown again.
    private func applyRows(_ difference: CollectionDifference<String>, oldCount: Int, changed: [String]) {
        if difference.removals.count == oldCount {
            // Nothing kept: made again.
            adjust {
                table.reloadData()
                table.layoutIfNeeded()
            }
            return
        }
        adjust {
            UIView.performWithoutAnimation {
                if !difference.isEmpty {
                    var removed: [IndexPath] = [], inserted: [IndexPath] = []
                    for change in difference {
                        switch change {
                        case .remove(let offset, _, _): removed.append(IndexPath(row: offset, section: 0))
                        case .insert(let offset, _, _): inserted.append(IndexPath(row: offset, section: 0))
                        }
                    }
                    table.performBatchUpdates {
                        if !removed.isEmpty { table.deleteRows(at: removed, with: .none) }
                        if !inserted.isEmpty { table.insertRows(at: inserted, with: .none) }
                    }
                }
                let reconfigured = changed.compactMap { position[$0].map { IndexPath(row: $0, section: 0) } }
                if !reconfigured.isEmpty { table.reconfigureRows(at: reconfigured) }
                table.layoutIfNeeded()
            }
        }
    }

    /// A message you just sent (ours, still pending, seconds old) fades up
    /// 4 pt into its row over 150 ms; under Reduce Motion it only fades.
    /// History, others' messages and rows scrolling into view never move.
    private func arrive(_ insertions: [CollectionDifference<String>.Change]) {
        // A move (`inferringMoves`) is an existing row, not a new one.
        for case .insert(let offset, _, nil) in insertions {
            guard rows.indices.contains(offset) else { continue }
            let message = rows[offset].message
            guard rows[offset].kind == .message, message.fromMe, message.delivery == .pending,
                  Date.now.timeIntervalSince(message.date) < 10,
                  let cell = table.cellForRow(at: IndexPath(row: offset, section: 0)) else { continue }
            let view = cell.contentView
            view.alpha = 0
            if !UIAccessibility.isReduceMotionEnabled { view.transform = CGAffineTransform(translationX: 0, y: 4) }
            UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    /// The bars' room changed (the keyboard, the composer growing): the
    /// list holds what it held, in the same animation as the change.
    private func setInsets(_ new: UIEdgeInsets) {
        guard new != insets else { return }
        let hold = placed ? holdNow() : nil
        insets = new
        adjust {
            table.contentInset = UIEdgeInsets(top: new.top, left: 0, bottom: new.bottom, right: 0)
            table.verticalScrollIndicatorInsets = table.contentInset
        }
        guard placed else { return openIfSized() }
        // A drag (the keyboard pulled down with the list) is the user's.
        if userScrolling {
            report()
            return
        }
        if let hold { place(hold, margin: 0) }
        report()
    }

    /// The view changed size (`MessageTableView`): the held placement put
    /// back, the rows in view measured at the new width first.
    func sizeChanged() {
        log("size \(Int(table.bounds.width))x\(Int(table.bounds.height)) placed=\(placed)")
        if pendingOpen != nil { return openIfSized() }
        guard placed, !gone else { return }
        let hold = lastVisual.map { controller.placement == .keep ? $0 : controller.placement } ?? controller.placement
        setWidth(table.bounds.width)
        updateHeader()
        updateFill()
        if !userScrolling { timed("resize") { place(hold, margin: 0) } }
        report()
        queueIdle(after: 0.15)
    }

    // MARK: Placing

    /// The first placement, once the view has a size, before anything is drawn.
    private func openIfSized() {
        guard let open = pendingOpen, !gone, table.bounds.height >= 1, table.bounds.width >= 1 else { return }
        pendingOpen = nil
        setWidth(table.bounds.width)
        // The content's size from the rows' heights, before the first offset is worked out from it.
        adjust { table.layoutIfNeeded() }
        updateHeader()
        timed("open") { place(open.to) }
        placed = true
        report()
        log("open \(open.to) rows=\(rows.count) content=\(Int(table.contentSize.height)) offset=\(Int(offset)) "
            + "range=\(Int(minOffset))...\(Int(maxOffset)) insets=\(Int(insets.top))/\(Int(insets.bottom))")
        queueIdle()
    }

    /// A placement for a change: animated from where the rows were on the
    /// screen, else at once.
    private func apply(_ move: ListMove, from visual: ListPlacement?) {
        switch move.to {
        case .keep:
            if let visual { place(visual) }
        default:
            if move.animated, let visual {
                place(visual)
                animate(to: move.to)
            } else {
                place(move.to)
            }
        }
        report()
        queueIdle()
    }

    /// Puts the list at `target`, the rows in view and a view's height
    /// either side measured first, until nothing there changes.
    private func place(_ target: ListPlacement, margin: CGFloat? = nil) {
        stopAnimation()
        guard target != .keep else { return clampOffset() }
        // A rubber band is UIKit's to run to its end.
        guard !banding else { return deferred = true }
        if case .center(let id) = target, let index = position[id], stale.contains(id) {
            measure(index)
            noteHeights()
        }
        for _ in 0..<8 {
            setOffset(for: target)
            let view = viewRect
            if !measureRows(in: view.insetBy(dx: 0, dy: -(margin ?? view.height))) { break }
            noteHeights()
        }
        updateFill()
        setOffset(for: target)
    }

    /// The content offset for `target`, clamped to the content; nil for a row not here.
    private func offset(for target: ListPlacement) -> CGFloat? {
        let y: CGFloat
        switch target {
        case .keep:
            return nil
        case .newest:
            y = maxOffset
        case .row(let id, let rowOffset):
            guard let index = position[id] else { return nil }
            y = table.rectForRow(at: IndexPath(row: index, section: 0)).minY - CGFloat(rowOffset) - insets.top
        case .center(let id):
            guard let index = position[id] else { return nil }
            y = table.rectForRow(at: IndexPath(row: index, section: 0)).midY - viewHeight / 2 - insets.top
        }
        return min(max(y, minOffset), maxOffset)
    }

    private func setOffset(for target: ListPlacement) {
        guard let y = offset(for: target) else { return }
        setOffset(y)
    }

    private func setOffset(_ y: CGFloat) {
        guard abs(offset - y) > 0.01 else { return }
        adjust { table.contentOffset = CGPoint(x: table.contentOffset.x, y: y) }
    }

    /// Back within the content: the content shrank under an offset no one
    /// moved since (the lazy stack's blank list). Never during a scroll by
    /// hand or a rubber band, which are UIKit's.
    private func clampOffset() {
        guard !userScrolling, animatingTo == nil else { return }
        setOffset(min(max(offset, minOffset), maxOffset))
    }

    /// Where the rows on the screen are: the top row whose top is in view
    /// (else the one across the top) and its top below the view's.
    private func captureVisual() -> ListPlacement? {
        guard placed, !rows.isEmpty else { return nil }
        let view = viewRect
        var best: (Int, CGRect)?, across: (Int, CGRect)?
        forEachRow(in: view) { index, rect in
            if rect.minY >= view.minY - 0.5, best.map({ rect.minY < $0.1.minY }) ?? true { best = (index, rect) }
            if across.map({ rect.minY < $0.1.minY }) ?? true { across = (index, rect) }
        }
        guard let (index, rect) = best ?? across else { return nil }
        return .row(id: rows[index].id, offset: Double(rect.minY - view.minY))
    }

    /// What a change the list makes by itself holds: what the controller
    /// holds (the newest, the reading row, a row jumped to), else, while a
    /// scroll by hand moves it, the rows on the screen.
    private func holdNow() -> ListPlacement {
        let held = controller.placement
        return held == .keep ? captureVisual() ?? lastVisual ?? .keep : held
    }

    // MARK: Animated moves

    /// A follow, a jump or the pill: the rows on the way and around the
    /// target measured first, so the move runs over exact heights; from
    /// over two views away, to a view and a half short of it at once.
    private func animate(to target: ListPlacement) {
        stopAnimation()
        guard !banding else { return deferred = true }
        guard table.window != nil else { return place(target) }
        let height = viewHeight
        prepare(target)
        guard var to = offset(for: target) else { return place(target) }
        let from = offset
        if abs(to - from) > 2 * height {
            setOffset(to + (from > to ? 1.5 : -1.5) * height)
            if let visual = captureVisual() { place(visual) }
            prepare(target)
            to = offset(for: target) ?? to
        }
        guard abs(to - offset) > 0.5 else { return place(target) }
        animatingTo = target
        controller.phase(.animating)
        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: to), animated: true)
    }

    /// Measures the rows between the view and `target` (within two views)
    /// and around it, holding what is on the screen.
    private func prepare(_ target: ListPlacement) {
        let height = viewHeight
        for _ in 0..<8 {
            guard let to = offset(for: target) else { return }
            let hold = captureVisual()
            let from = offset
            var low = min(from, to) + insets.top - height / 2, high = max(from, to) + insets.top + height * 1.5
            if high - low > 4 * height {
                low = to + insets.top - height
                high = to + insets.top + 2 * height
            }
            guard measureRows(in: CGRect(x: 0, y: low, width: table.bounds.width, height: high - low)) else { return }
            noteHeights()
            if let hold { setOffset(for: hold) }
        }
    }

    private func stopAnimation() {
        guard animatingTo != nil else { return }
        animatingTo = nil
        adjust { table.setContentOffset(table.contentOffset, animated: false) }
        controller.phase(.idle)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let target = animatingTo, !gone else { return }
        animatingTo = nil
        // Exactly there, should a row have changed on the way.
        place(target)
        report()
        controller.phase(.idle)
        queueIdle()
    }

    // MARK: ChatListEngine

    func move(_ move: ListMove) {
        guard placed else { return pendingOpen = move }
        log("move \(move.to)\(move.animated ? " animated" : "")")
        if move.animated { animate(to: move.to) } else { place(move.to) }
        report()
        queueIdle()
    }

    func flash(_ id: String) {
        flashed.id = id
        Task { [flashed] in
            // Lit, then fading out as it settles.
            try? await Task.sleep(for: .seconds(0.5))
            if flashed.id == id { withAnimation(.easeOut(duration: 1.2)) { flashed.id = nil } }
        }
    }

    func reveal() {
        log("reveal")
        table.alpha = 1
    }

    /// The row's top below the view's, measured; nil when it is not in the table.
    func top(of id: String) -> Double? {
        guard placed, let index = position[id] else { return nil }
        return Double(table.rectForRow(at: IndexPath(row: index, section: 0)).minY - viewRect.minY)
    }

    // MARK: Jumps

    private func takeFocus(_ focus: FocusTarget?) {
        guard let focus, let uuid = focus.message.uuid else {
            if focus == nil { handledFocus = nil }
            return
        }
        guard uuid != handledFocus, placed else { return }
        handledFocus = uuid
        jumpedTo = uuid
        let outcome = controller.jump(to: uuid, at: focus.message.date)
        if outcome != .here { notHere(focus.message, outcome) }
    }

    /// A message asked for that is not among the rows: the model decides
    /// (one folded into a thread opens its thread).
    private func notHere(_ message: Message, _ outcome: JumpOutcome) {
        let composer = composer
        later { $0.jumpMissed(message, in: composer, outcome) }
    }

    /// The model's request was this list's jump: done.
    private func focusTaken() {
        guard let uuid = jumpedTo else { return }
        later { model in
            if model.focus?.message.uuid == uuid { model.focus = nil }
        }
    }

    /// From a quote: to its message here, or in its thread's list.
    private func go(to message: Message) {
        guard let uuid = message.uuid else { return }
        jumpedTo = nil
        let outcome = controller.jump(to: uuid, at: message.date)
        if outcome != .here { notHere(message, outcome) }
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard placed, !gone else { return }
        // A new drag during a rubber band's ease back: the same scroll goes on.
        stopAnimation()
        userScrolling = true
        controller.userScrollBegan()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard userScrolling, !gone else { return }
        if decelerate { controller.phase(.decelerating) } else { userScrollEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard userScrolling, !gone else { return }
        userScrollEnded()
    }

    /// The status bar's tap to the top: a scroll by hand.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard placed, !gone else { return false }
        stopAnimation()
        userScrolling = true
        controller.userScrollBegan()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        guard userScrolling, !gone else { return }
        userScrollEnded()
    }

    private func userScrollEnded() {
        userScrolling = false
        controller.userScrollEnded(report())
        if deferred {
            deferred = false
            place(controller.placement)
            report()
        }
        if let waiting {
            self.waiting = nil
            timed("rows after scroll") {
                change(to: waiting.rows, reachesNewest: waiting.reachesNewest, hasOlder: waiting.hasOlder)
            }
        }
        queueIdle()
    }

    /// Past the content's range during a scroll by hand: a rubber band,
    /// pulled by the finger or easing back, which the list leaves alone.
    private var banding: Bool {
        userScrolling && (offset < minOffset - 0.5 || offset > maxOffset + 0.5)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard adjusting == 0, placed, !gone else { return }
        if animatingTo != nil || banding {
            report()
            return
        }
        if userScrolling { timed("scroll") { measureAhead() } }
        lastOffset = offset
        report()
    }

    /// During a scroll by hand, only what it needs: the stale rows in view
    /// (drawn now, so always) and, within a few milliseconds, those half a
    /// view ahead in the direction it moves. The table takes their heights
    /// once, holding what is on the screen; the rest waits for `idle`.
    private func measureAhead() {
        guard !stale.isEmpty || idleUnapplied > 0 else { return }
        let view = viewRect
        let lead = view.height / 2
        let ahead = offset >= lastOffset
            ? CGRect(x: 0, y: view.maxY, width: view.width, height: lead)
            : CGRect(x: 0, y: view.minY - lead, width: view.width, height: lead)
        // Before any height moves the rows.
        let hold = captureVisual()
        // Heights `idle` measured and the table has not taken: taken now, before they scroll into view.
        var changed = measureRows(in: view) || idleUnapplied > 0
        let deadline = ContinuousClock.now + .milliseconds(4)
        forEachRow(in: ahead) { index, _ in
            guard ContinuousClock.now < deadline, stale.contains(rows[index].id) else { return }
            if remeasure(index) { changed = true }
        }
        guard changed else { return }
        noteHeights()
        if let hold { setOffset(for: hold) }
    }

    // MARK: Heights

    private func height(of row: ChatRow) -> CGFloat {
        heights[row.id] ?? row.estimatedPhoneHeight
    }

    /// Records a row's height, keeping the total.
    private func setHeight(_ height: CGFloat, of index: Int) {
        let row = rows[index]
        rowsHeight += height - self.height(of: row)
        heights[row.id] = height
        stale.remove(row.id)
    }

    private func updateRowsHeight() {
        rowsHeight = rows.reduce(0) { $0 + height(of: $1) }
    }

    @discardableResult
    private func setWidth(_ new: CGFloat) -> Bool {
        guard new > 0, abs(new - width) > 0.5 else { return false }
        width = new
        stale = Set(ids)
        return true
    }

    /// Measures the row by a sizer of its kind at the table's width.
    @discardableResult
    private func measure(_ index: Int) -> CGFloat {
        let row = rows[index]
        let key = row.reuseKind
        let sizer = sizers[key] ?? {
            let sizer = UIHostingController(rootView: AnyView(EmptyView()))
            sizer.sizingOptions = []
            sizer.safeAreaRegions = []
            sizers[key] = sizer
            return sizer
        }()
        // As its cell lays it out: its ideal height at the table's width.
        sizer.rootView = AnyView(content(row).fixedSize(horizontal: false, vertical: true))
        let size = sizer.sizeThatFits(in: CGSize(width: width, height: 100_000))
        let height = max(ceil(size.height), 1)
        setHeight(height, of: index)
        measuredCount += 1
        return height
    }

    /// Measures a stale row; returns whether its height changed.
    private func remeasure(_ index: Int) -> Bool {
        let was = height(of: rows[index])
        return abs(measure(index) - was) > 0.25
    }

    /// Measures the stale rows in `rect`; returns whether any height changed.
    private func measureRows(in rect: CGRect) -> Bool {
        guard !stale.isEmpty, rect.height > 0 else { return false }
        var changed = false
        forEachRow(in: rect) { index, _ in
            guard stale.contains(rows[index].id) else { return }
            if remeasure(index) { changed = true }
        }
        return changed
    }

    /// The table takes the heights again, in place, without animating.
    private func noteHeights() {
        // Whatever `idle` measured goes with it.
        idleUnapplied = 0
        adjust {
            UIView.performWithoutAnimation {
                table.beginUpdates()
                table.endUpdates()
                table.layoutIfNeeded()
            }
        }
    }

    /// The space above the oldest row: the padding, the spinner while
    /// older messages can load, and a short chat's fill, which puts its
    /// rows at the bottom of the view (a thread's start at its top).
    private func updateHeader() {
        let base = Self.padding + (hasOlder ? Self.spinnerRoom : 0)
        let height = base + fill
        if hasOlder { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.center = CGPoint(x: table.bounds.width / 2, y: fill + Self.padding + Self.spinnerRoom / 2)
        guard abs(header.frame.height - height) > 0.25 || abs(header.frame.width - table.bounds.width) > 0.5 else { return }
        header.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: height)
        adjust {
            table.tableHeaderView = header
            table.layoutIfNeeded()
        }
    }

    private func updateFill() {
        var new: CGFloat = 0
        if !isThread {
            let used = rowsHeight + 2 * Self.padding + (hasOlder ? Self.spinnerRoom : 0)
            new = max(0, viewHeight - used)
        }
        guard abs(new - fill) > 0.25 else { return }
        fill = new
        updateHeader()
    }

    /// The rows not in view, in idle time: a few milliseconds a turn of
    /// the run loop, nearest the view first, holding what is on the screen.
    /// Not while scrolling or moving; done once every row is exact.
    private func queueIdle(after delay: TimeInterval = 0) {
        guard !gone else { return }
        idleGeneration += 1
        let generation = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.idleGeneration == generation else { return }
                self.idle()
            }
        }
    }

    private func idle() {
        guard !gone, placed, !stale.isEmpty || idleUnapplied > 0 else { return }
        guard animatingTo == nil, !userScrolling else { return queueIdle(after: 0.2) }
        let started = ContinuousClock.now
        measuredCount = 0
        let deadline = started + .milliseconds(4)
        let hold = holdNow()
        let count = rows.count
        let visible = table.indexPathsForRows(in: viewRect)?.map(\.row) ?? []
        let middle = visible.first ?? count - 1
        // Rows within a view's height of it: their height shows soon, so it is taken at once.
        let near = visible.isEmpty ? 0..<0 : (visible[0] - visible.count)..<(visible[visible.count - 1] + visible.count + 1)
        var nearChanged = false
        var left = false
        var step = 0
        outward: while step <= count {
            for index in [middle - step, middle + step + 1] where rows.indices.contains(index) && stale.contains(rows[index].id) {
                if ContinuousClock.now >= deadline {
                    left = true
                    break outward
                }
                if remeasure(index) {
                    if near.contains(index) { nearChanged = true } else { idleUnapplied += 1 }
                }
            }
            step += 1
        }
        // Far rows' heights go to the table every few dozen, and once all are measured.
        if nearChanged || idleUnapplied >= 40 || (!left && idleUnapplied > 0) {
            noteHeights()
            updateFill()
            setOffset(for: hold)
            report()
        }
        slow("idle", since: started)
        if left { queueIdle() }
    }

    /// A cell laid out at another height than its row's: its content
    /// changed without the row changing (an image's size arriving, a send
    /// that can be retried). Corrected right after this layout, holding the list.
    private func cellReported(_ id: String, _ reported: CGFloat) {
        guard !gone, let index = position[id] else { return }
        let height = max(ceil(reported), 1)
        guard abs(height - self.height(of: rows[index])) > 0.5 else { return }
        corrections[id] = height
        guard !correctionsQueued else { return }
        correctionsQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.timed("corrections") { self?.applyCorrections() } }
        }
    }

    private func applyCorrections() {
        correctionsQueued = false
        guard !gone, placed, !corrections.isEmpty else { return }
        // An animated move lands exactly where it aims once it ends.
        let hold = animatingTo != nil ? ListPlacement.keep : holdNow()
        var changed = false
        for (id, height) in corrections {
            guard let index = position[id] else { continue }
            setHeight(height, of: index)
            changed = true
        }
        corrections = [:]
        guard changed else { return }
        noteHeights()
        updateFill()
        if hold == .keep { clampOffset() } else { setOffset(for: hold) }
        report()
    }

    /// The table laid out (`MessageTableView`): an offset left past the
    /// content by anything is put back within it.
    func laidOut() {
        guard placed, !gone, adjusting == 0 else { return }
        if offset > maxOffset + 0.5 || offset < minOffset - 0.5 { clampOffset() }
    }

    // MARK: Reports

    /// What the list shows now, to the controller.
    @discardableResult
    private func report() -> ListViewport {
        let view = viewRect
        var visibleIDs: [String] = [], visibleTops: [Double] = []
        forEachRow(in: view) { index, rect in
            visibleIDs.append(rows[index].id)
            visibleTops.append(Double(rect.minY - view.minY))
        }
        let below = maxOffset - offset
        let viewport = ListViewport(
            visibleIDs: visibleIDs, visibleTops: visibleTops,
            atBottom: below <= ChatListController.bottomZone,
            nearTop: view.minY < view.height, far: below > view.height
        )
        if !userScrolling, animatingTo == nil { lastVisual = captureVisual() }
        controller.scrolled(viewport)
        return viewport
    }

    // MARK: Cells

    private static let kinds = ["message", "payment", "note"]

    private func forEachRow(in rect: CGRect, _ body: (Int, CGRect) -> Void) {
        guard rect.height > 0, let paths = table.indexPathsForRows(in: rect) else { return }
        for path in paths where rows.indices.contains(path.row) {
            body(path.row, table.rectForRow(at: path))
        }
    }

    private func content(_ row: ChatRow) -> AnyView {
        AnyView(
            PhoneListRow(row: row, composer: composer)
                .environment(\.goToMessage) { [weak self] message in self?.go(to: message) }
                .environment(flashed)
                // The list's own environment, under what the rows add to it.
                .environment(\.self, environment)
        )
    }

    /// A cell reused for another row makes that row's views anew (`.id`).
    private func show(_ row: ChatRow, in cell: HostRowCell) {
        cell.rowID = row.id
        let id = row.id
        let content = content(row)
        cell.contentConfiguration = UIHostingConfiguration {
            content
                .id(id)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                    self?.cellReported(id, height)
                }
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
    }

    private func refreshVisibleCells() {
        guard let paths = table.indexPathsForVisibleRows, !paths.isEmpty else { return }
        adjust { UIView.performWithoutAnimation { table.reconfigureRows(at: paths) } }
    }

    // MARK: UITableViewDataSource, UITableViewDelegate

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard rows.indices.contains(indexPath.row) else { return 0 }
        return height(of: rows[indexPath.row])
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: row.reuseKind, for: indexPath) as? HostRowCell ?? HostRowCell()
        show(row, in: cell)
        return cell
    }

    // MARK: Helpers

    private func adjust(_ body: () -> Void) {
        adjusting += 1
        body()
        adjusting -= 1
    }

    private func log(_ event: @autoclosure () -> String) {
        TimelineLog.log("\(TimelineLog.tag(composer)) \(event())")
    }

    /// The list's own work, timed: a frame's worth or more is logged.
    private func timed(_ what: String, _ body: () -> Void) {
        let started = ContinuousClock.now
        measuredCount = 0
        body()
        slow(what, since: started)
    }

    /// Logs work that took over a frame (16 ms) on the main thread, where it
    /// holds up scrolling: what it was, how long, and the rows it measured.
    private func slow(_ what: String, since started: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - started
        defer { measuredCount = 0 }
        guard elapsed > .milliseconds(16) else { return }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        log("slow \(what) \(String(format: "%.0f", ms)) ms, measured \(measuredCount), stale \(stale.count), rows \(rows.count)")
    }
}

/// The list's table: tells its engine when its size changes and when it
/// has laid out.
final class MessageTableView: UITableView {
    weak var engine: MessageTableEngine?

    /// The size last told to the engine. Read in the layout pass, which
    /// every resize brings: SwiftUI sizes the view by its frame, which
    /// never goes through `bounds`' setter.
    private var toldSize = CGSize.zero
    private var telling = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != toldSize, !telling {
            toldSize = bounds.size
            // Past this pass: the engine updates the table's rows and offset.
            telling = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.telling = false
                    self.toldSize = self.bounds.size
                    self.engine?.sizeChanged()
                }
            }
        }
        engine?.laidOut()
    }
}

/// A row's cell: its SwiftUI content in a hosting configuration, reused
/// among rows of its kind.
final class HostRowCell: UITableViewCell {
    /// The row it shows now.
    var rowID: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        backgroundColor = .clear
        selectionStyle = .none
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The row lit after a jump.
@MainActor @Observable final class PhoneListFlash {
    var id: String?
}

/// One row as the list draws it, its day line and "New messages" inside it.
private struct PhoneListRow: View {
    @Environment(PhoneListFlash.self) private var flash
    let row: ChatRow
    let composer: ComposerID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.startsDay { DayDividerLine(date: row.date) }
            if row.startsNew { NewMessagesLine() }
            ConversationRow(row: row, composer: composer, flashed: flash.id == row.id)
                .equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The SwiftUI side's way to the list: the controller, for the pill.
@MainActor @Observable final class PhoneListLink {
    var controller: ChatListController?
}

/// A message list's table, under `MessageList`.
struct MessageTable: UIViewRepresentable {
    let model: AppModel
    let rows: [ChatRow]
    let composer: ComposerID
    var live = true
    var focus: FocusTarget?
    var reachesNewest = true
    var hasOlder = false
    /// The bars' room: the header, the composer, the keyboard.
    var insets: EdgeInsets
    let link: PhoneListLink

    func makeCoordinator() -> MessageTableEngine {
        let engine = MessageTableEngine(composer: composer, model: model)
        link.controller = engine.controller
        return engine
    }

    func makeUIView(context: Context) -> MessageTableView {
        context.coordinator.table
    }

    func updateUIView(_ view: MessageTableView, context: Context) {
        let insets = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        let update = {
            context.coordinator.update(model: model, rows: rows, live: live, focus: focus, reachesNewest: reachesNewest,
                                       hasOlder: hasOlder, insets: insets, environment: context.environment)
        }
        // The keyboard and the composer move their room with an animation: the list moves with it.
        if context.transaction.animation != nil, !context.transaction.disablesAnimations {
            context.animate(changes: update)
        } else {
            update()
        }
    }

    static func dismantleUIView(_ view: MessageTableView, coordinator: MessageTableEngine) {
        coordinator.dismantle()
    }
}

private extension ChatRow {
    /// Cells are reused among rows of one kind.
    var reuseKind: String {
        switch kind {
        case .message: "message"
        case .payment, .paymentRequest: "payment"
        default: "note"
        }
    }

    /// For a row never measured: by kind and length. Only ever stands for
    /// rows away from the view, which are measured before they come into it.
    var estimatedPhoneHeight: CGFloat {
        var height: CGFloat = startsDay ? 40 : 0
        if startsNew { height += 28 }
        switch kind {
        case .message:
            let lines = max(1, (message.shownText.count + 39) / 40)
            height += CGFloat(lines) * 21 + (startsRun ? 34 : 6)
            if message.attachmentKind != nil { height += 220 }
            if summary != nil { height += 28 }
            height += CGFloat(agentArtifacts.count) * 24
        default:
            height += 32
        }
        return height
    }
}
