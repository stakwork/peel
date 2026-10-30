import AppKit
import SwiftUI
import PeelCore
import PeelUI

/// A row a `MessageTableEngine` shows: a chat's or a thread's (`ChatRow`),
/// or one of the agent chat's (`AgentListRow`). Two rows equal draw alike:
/// a row unequal to the one measured is measured again, so equality is its
/// version for the height cache.
@MainActor protocol TableRow: Equatable {
    var id: String { get }
    /// Cells are reused among rows of one kind.
    var reuse: NSUserInterfaceItemIdentifier { get }
    /// Its height until it is measured.
    var estimatedHeight: CGFloat { get }
    /// The cell's SwiftUI content.
    func content(in list: ComposerID, canAnswer: Bool) -> AnyView
    /// The bar over it while the pointer is (Reply, Boost, More); nil for none.
    func hoverBar(in list: ComposerID) -> AnyView?
    /// The rows as the list's controller sees them.
    static func listContent(_ rows: [Self], in list: ComposerID, reachesNewest: Bool, hasOlder: Bool) -> ListContent
}

/// What the views around a `MessageTableEngine` reach it by, whatever its rows.
@MainActor protocol MessageTableHost: AnyObject {
    var adjusting: Int { get set }
    func layoutPass()
    func willResize(to size: NSSize) -> ListPlacement?
    func didResize(holding held: ListPlacement?)
    func page(up: Bool)
    func pointer(at point: NSPoint?)
}

/// A message list on the Mac (`ChatListEngine`): the chat's, a thread's or
/// the agent chat's. An
/// `NSTableView` whose document is not flipped, so its origin is the
/// newest message and older rows above change nothing below them; each
/// row a SwiftUI cell in a reused hosting controller; each row's height
/// measured once per width and per version of the row (`stale` until then), the rows in view
/// before they are drawn and the rest in idle time. Every change applies
/// the controller's placement in the same pass, so a row never moves on
/// screen unless the list means it to (`docs/reviews/2026-10-14-message-lists.md`).
@MainActor
final class MessageTableEngine<Row: TableRow>: NSObject, ChatListEngine, ListGeometry, MessageTableHost,
    NSTableViewDataSource, NSTableViewDelegate
{
    let composer: ComposerID
    let controller: ChatListController
    let table = BottomTable()
    let scroll = ListScrollView()
    /// The row lit after a jump, read by every cell.
    private let flashed = ListFlash()
    /// The row under the pointer, read by every cell.
    private let hover = ListHover()
    /// Reply, Boost and More: one bar over the hovered row's top-right, as
    /// in Slack, floating over the rows (in a cell, the row above drew
    /// over it), and inside the view at its top.
    private let hoverBar = NSHostingView(rootView: AnyView(EmptyView()))
    /// The row the bar shows, and its size.
    private var barRow: Row?
    private var barSize = NSSize.zero
    /// The pointer, in the window, while it is over the list.
    private var pointer: NSPoint?
    private var watchingMenu = false

    private weak var model: AppModel?
    private var environment = EnvironmentValues()
    /// What of the environment the cells draw by and the table does not
    /// follow by itself: a change shows the cells in view again.
    private struct Look: Equatable {
        var colorScheme: ColorScheme
        var contrast: ColorSchemeContrast
        var dynamicType: DynamicTypeSize
        var enabled: Bool
        var reduceMotion: Bool
        var direction: LayoutDirection

        init(_ environment: EnvironmentValues) {
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            dynamicType = environment.dynamicTypeSize
            enabled = environment.isEnabled
            reduceMotion = environment.accessibilityReduceMotion
            direction = environment.layoutDirection
        }
    }
    private var look: Look?
    private var canAnswer = false
    private var reachesNewest = true
    private var hasOlder = false
    private(set) var rows: [Row] = []
    private var position: [String: Int] = [:]

    // What the probe and the driver read (`ListGeometry`): the rows, the
    // content in view (from the content's top), and where the rows around
    // it are, as of the last move.
    private(set) var ids: [String] = []
    private(set) var view: Range<CGFloat> = 0..<0
    private(set) var content: CGFloat = 0
    private(set) var frames: [String: CGRect] = [:]
    private(set) var shown = false
    private(set) var gone = false
    var scrollView: NSScrollView? { scroll }
    var pill: ListPill? { controller.pill }

    private var appeared = false
    private var placed = false
    /// Where it opens, until its view has a size.
    private var pendingOpen: ListMove?
    private var openStarted: ContinuousClock.Instant?
    /// Our own moves of the clip and the table, which are not scrolls.
    var adjusting = 0
    /// A scroll by hand that announced itself (a trackpad, the scroller).
    private var liveScrolling = false
    /// One that did not (a mouse wheel, keys, AppKit's own): ends once still.
    private var quietScrollEnd: DispatchWorkItem?
    /// A scroll by hand that ended past an end: its rubber band easing
    /// back, still that scroll, which ends once back in range (or still).
    private var settleEnd: DispatchWorkItem?
    /// A placement asked for while a rubber band ran, which moves nothing
    /// then: the controller's is put in place once it is back (`settled`).
    private var deferred = false
    /// The animated move running, by number; 0 for none.
    private var animation = 0
    /// The message asked for last, by uuid, so a request is taken once.
    private var handledFocus: String?
    private var jumpedTo: String?

    /// Each row's height, as last measured or reported.
    private var heights: [String: CGFloat] = [:]
    /// Rows to measure: new, changed since measured, or all at a new width.
    private var stale: Set<String> = []
    /// Every row's height (measured or estimated) and the padding, for a thread's fill.
    private var rowsHeight: CGFloat = 0
    /// Hosting controllers that measure rows with no cell, one per kind.
    private var sizers: [String: NSHostingController<AnyView>] = [:]
    private(set) var width: CGFloat = 0
    /// Cells laid out at another height than their row's (an image's size came).
    private var corrections: [String: CGFloat] = [:]
    private var idleGeneration = 0
    /// Under a thread's rows while they are shorter than the view, so they start at its top.
    private var fill: CGFloat = 0

    /// Above the oldest row and below the newest.
    static var padding: CGFloat { Theme.Space.md }

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

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.setAccessibilityLabel(composer == .agent ? "Agent chat" : composer.thread == nil ? "Messages" : "Thread")
        table.dataSource = self
        table.delegate = self
        scroll.engine = self
        // The driver's stand-in for a trackpad's rubber band, only offscreen.
        if Offscreen.isOn { scroll.contentView = ListClipView() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // Shown once placed (`reveal`).
        scroll.alphaValue = 0
        scroll.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                           object: scroll.contentView)
        center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification,
                           object: scroll)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification,
                           object: scroll)
        hoverBar.safeAreaRegions = []
        hoverBar.isHidden = true
        scroll.addSubview(hoverBar)
        scroll.addTrackingArea(scroll.pointerArea)
    }

    private var kind: String { composer == .agent ? "agent" : composer.thread == nil ? "chat" : "thread" }

    /// To the model past the update that asked (the model is not written
    /// during one), and only while this list is still its chat's: a call
    /// left over from a list since gone, or a chat since left, is dropped.
    private func later(_ body: @escaping @MainActor (AppModel) -> Void) {
        let chat = composer.chat
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.gone, let model = self.model, model.selectedChat == chat else { return }
            body(model)
        }
    }
    private var clip: NSClipView { scroll.contentView }
    /// The clip's origin at the top of the content.
    private var maxOrigin: CGFloat { max(table.frame.height - clip.bounds.height, 0) }

    // MARK: Updates

    func update(model: AppModel, rows new: [Row], canAnswer: Bool, focus: FocusTarget?, reachesNewest: Bool,
                hasOlder: Bool, environment: EnvironmentValues) {
        self.model = model
        self.environment = environment
        let look = Look(environment)
        let restyled = self.look != nil && look != self.look
        let resized = self.look.map { $0.dynamicType != look.dynamicType || $0.direction != look.direction } ?? false
        self.look = look
        if restyled { barRow = nil }
        let redraw = canAnswer != self.canAnswer || restyled
        self.canAnswer = canAnswer
        // The same rows in the same order (a reply growing, a row opened):
        // those that changed, found in one pass; nil when the rows differ.
        let inPlace = Self.changedInPlace(rows, new)
        let changed = inPlace.map { !$0.isEmpty } ?? true || reachesNewest != self.reachesNewest
            || hasOlder != self.hasOlder
        self.reachesNewest = reachesNewest
        self.hasOlder = hasOlder
        if !appeared {
            appeared = true
            openStarted = .now
            setRows(new)
            stale = Set(ids)
            adjust { table.reloadData() }
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
        if changed {
            let old = rows
            let visual = captureVisual()
            let oldIDs = ids
            setRows(new, sameIDs: inPlace != nil)
            let changedIDs = inPlace ?? Self.changed(old, rows)
            // Newest first, as the table's rows run; none in place.
            let difference = inPlace != nil
                ? CollectionDifference<String>([])!
                : ids.reversed().difference(from: oldIDs.reversed()).inferringMoves()
            let diff = ListDiff(difference)
            stale.formUnion(diff.inserted)
            stale.formUnion(changedIDs)
            let move = controller.contentWillChange(to: listContent, diff: diff)
            applyRows(difference, oldCount: oldIDs.count, changed: changedIDs)
            log("rows \(old.count)->\(rows.count) move \(move.to)\(move.animated ? " animated" : "")")
            if placed {
                apply(move, from: visual)
            } else if move.to != .keep {
                pendingOpen = move
            }
        } else if redraw {
            refreshVisibleCells()
            if resized, placed {
                // Every height measured in the old size is wrong now.
                let hold = holdNow()
                heights = [:]
                stale = Set(ids)
                updateRowsHeight()
                adjust { table.reloadData() }
                place(hold)
                report()
                queueIdle()
            }
        }
        takeFocus(focus)
    }

    func dismantle() {
        controller.disappear()
        stopAnimation()
        gone = true
        idleGeneration += 1
        quietScrollEnd?.cancel()
        settleEnd?.cancel()
        NotificationCenter.default.removeObserver(self)
        log("dismantle")
    }

    private var listContent: ListContent {
        Row.listContent(rows, in: composer, reachesNewest: reachesNewest, hasOlder: hasOlder)
    }

    private func setRows(_ new: [Row], sameIDs: Bool = false) {
        rows = new
        if !sameIDs {
            ids = new.map(\.id)
            position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }
        updateRowsHeight()
    }

    /// With the same rows in the same order, the ids of those drawn
    /// differently now; nil when the rows are not the same.
    private static func changedInPlace(_ old: [Row], _ new: [Row]) -> [String]? {
        guard old.count == new.count else { return nil }
        var changed: [String] = []
        for (was, row) in zip(old, new) {
            guard was.id == row.id else { return nil }
            if was != row { changed.append(row.id) }
        }
        return changed
    }

    /// Kept rows drawn differently now.
    private static func changed(_ old: [Row], _ new: [Row]) -> [String] {
        let was = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { row in was[row.id].map { $0 == row ? nil : row.id } ?? nil }
    }

    /// The table made to match the rows: rows that went removed, rows that
    /// came inserted, the cells of kept rows that changed shown again. Cells
    /// of rows that did not change stay as they are (a selection in one survives).
    private func applyRows(_ difference: CollectionDifference<String>, oldCount: Int, changed: [String]) {
        if difference.removals.count == oldCount {
            // Nothing kept: made again.
            adjust { table.reloadData() }
            return
        }
        if !difference.isEmpty {
            var removed = IndexSet(), inserted = IndexSet()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset + 1)
                case .insert(let offset, _, _): inserted.insert(offset + 1)
                }
            }
            adjust {
                table.beginUpdates()
                if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
                if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
                table.endUpdates()
            }
        }
        var resized = IndexSet()
        for id in changed {
            guard let index = position[id] else { continue }
            let t = tableRow(index)
            resized.insert(t)
            if let cell = table.view(atColumn: 0, row: t, makeIfNecessary: false) as? HostCell { show(rows[index], in: cell) }
        }
        if !resized.isEmpty { noteHeights(resized) }
    }

    // MARK: Placing

    /// The first placement, once the view has a size: in the pass that
    /// gives it one, before anything is drawn.
    private func openIfSized() {
        guard let open = pendingOpen, !gone, clip.bounds.height >= 1, clip.bounds.width >= 1 else { return }
        pendingOpen = nil
        setWidth(clip.bounds.width)
        place(open.to)
        placed = true
        ListProbe.register(self, kind: kind)
        report()
        queueIdle()
        if Offscreen.isOn, let openStarted {
            Offscreen.log("list: open \(kind) rows=\(rows.count) placed in \(Self.ms(.now - openStarted)) ms, "
                + "content=\(Int(table.frame.height)) view=\(Int(clip.bounds.height)) w=\(Int(width))")
        }
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
        guard target != .keep else { return }
        // A rubber band is AppKit's to run to its end.
        guard !banding else { return deferred = true }
        if case .center(let id) = target, let index = position[id], stale.contains(id) {
            measure(index)
            noteHeights([tableRow(index)])
        }
        for _ in 0..<8 {
            setOrigin(for: target)
            let bounds = clip.bounds
            let changed = measureRows(in: bounds.insetBy(dx: 0, dy: -(margin ?? bounds.height)))
            if changed.isEmpty { break }
            noteHeights(changed)
        }
        updateFill()
        setOrigin(for: target)
    }

    /// The clip's origin for `target`, clamped to the content; nil for a row not here.
    private func origin(for target: ListPlacement) -> CGFloat? {
        let height = clip.bounds.height
        var y: CGFloat
        switch target {
        case .keep:
            return nil
        case .newest:
            y = 0
        case .row(let id, let offset):
            guard let index = position[id] else { return nil }
            y = table.rect(ofRow: tableRow(index)).maxY + offset - height
        case .center(let id):
            guard let index = position[id] else { return nil }
            y = table.rect(ofRow: tableRow(index)).midY - height / 2
        }
        return min(max(y, 0), maxOrigin)
    }

    private func setOrigin(for target: ListPlacement) {
        guard let y = origin(for: target) else { return }
        setOrigin(y)
    }

    private func setOrigin(_ y: CGFloat) {
        let bounds = clip.bounds
        guard abs(bounds.origin.y - y) > 0.01 else { return }
        adjust {
            clip.setBoundsOrigin(NSPoint(x: bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Where the rows on the screen are: the top row whose top is in view
    /// (else the one across the top) and its top below the view's.
    private func captureVisual() -> ListPlacement? {
        guard placed, !rows.isEmpty else { return nil }
        let bounds = clip.bounds
        var best: (Int, NSRect)?, across: (Int, NSRect)?
        forEachRow(in: bounds) { t, rect in
            if rect.maxY <= bounds.maxY + 0.5, best.map({ rect.maxY > $0.1.maxY }) ?? true { best = (t, rect) }
            if across.map({ rect.maxY > $0.1.maxY }) ?? true { across = (t, rect) }
        }
        guard let (t, rect) = best ?? across, let index = index(ofTableRow: t) else { return nil }
        return .row(id: rows[index].id, offset: bounds.maxY - rect.maxY)
    }

    /// What a change the list makes by itself holds: what the controller
    /// holds (the newest, the reading row, a row jumped to), else, while a
    /// scroll by hand moves it, the rows on the screen.
    private func holdNow() -> ListPlacement {
        resolved(controller.placement) ?? .keep
    }

    /// `.keep` as the rows on the screen are now.
    private func resolved(_ placement: ListPlacement) -> ListPlacement? {
        placement == .keep ? captureVisual() : placement
    }

    // MARK: Animated moves

    /// A follow, a jump or the pill: the rows on the way and around the
    /// target measured first, so the move runs over exact heights; from
    /// over two views away, to a view and a half short of it at once.
    private func animate(to target: ListPlacement) {
        stopAnimation()
        guard !banding else { return deferred = true }
        // Off the screens (the offscreen check) there is no frame to animate on.
        guard scroll.window?.screen != nil else { return place(target) }
        let height = clip.bounds.height
        prepare(target)
        guard var to = origin(for: target) else { return place(target) }
        let from = clip.bounds.origin.y
        if abs(to - from) > 2 * height {
            setOrigin(to + (from > to ? 1.5 : -1.5) * height)
            if let visual = captureVisual() { place(visual) }
            prepare(target)
            to = origin(for: target) ?? to
        }
        guard abs(to - clip.bounds.origin.y) > 0.5 else { return place(target) }
        animation += 1
        let number = animation
        controller.phase(.animating)
        let clip = clip
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: to))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animation == number, !self.gone else { return }
                self.animation = 0
                // Exactly there, should a row have changed on the way.
                self.place(target)
                self.report()
                self.controller.phase(.idle)
                self.queueIdle()
            }
        }
    }

    /// Measures the rows between the view and `target` (within two views)
    /// and around it, holding what is on the screen.
    private func prepare(_ target: ListPlacement) {
        let height = clip.bounds.height
        for _ in 0..<8 {
            guard let to = origin(for: target) else { return }
            let hold = captureVisual()
            let from = clip.bounds.origin.y
            var low = min(from, to) - height / 2, high = max(from, to) + height * 1.5
            if high - low > 4 * height {
                low = to - height
                high = to + 2 * height
            }
            let changed = measureRows(in: NSRect(x: 0, y: low, width: clip.bounds.width, height: high - low))
            if changed.isEmpty { return }
            noteHeights(changed)
            if let hold { setOrigin(for: hold) }
        }
    }

    private func stopAnimation() {
        guard animation != 0 else { return }
        animation = 0
        let clip = clip
        adjust {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(clip.bounds.origin)
            }
        }
        controller.phase(.idle)
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
            try? await Task.sleep(for: .seconds(0.4))
            if flashed.id == id { withAnimation(.easeOut(duration: 1.5)) { flashed.id = nil } }
        }
    }

    func reveal() {
        shown = true
        scroll.alphaValue = 1
    }

    /// The row's top below the view's, measured; nil when it is not in the table.
    func top(of id: String) -> Double? {
        guard placed, let index = position[id] else { return nil }
        return Double(clip.bounds.maxY - table.rect(ofRow: tableRow(index)).maxY)
    }

    /// A row the user is about to open or close (a tool's details): it
    /// keeps its top where it is, and the list stops following.
    func expanding(_ id: String) {
        guard placed, !gone else { return }
        stopAnimation()
        controller.userExpanded(id)
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

    /// A message asked for that is not among the rows: the model decides.
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

    // MARK: Keys

    /// Page Up and Page Down: a view less a line, as a scroll by hand.
    func page(up: Bool) {
        guard placed else { return }
        stopAnimation()
        controller.userScrollBegan()
        let height = clip.bounds.height
        let y = clip.bounds.origin.y + (up ? 1 : -1) * max(height - 40, height / 2)
        setOrigin(min(max(y, 0), maxOrigin))
        if let visual = captureVisual() { place(visual) }
        controller.userScrollEnded(report())
        queueIdle()
    }

    // MARK: Scrolling

    @objc private func liveScrollStarted() {
        guard placed, !gone else { return }
        liveScrolling = true
        quietScrollEnd?.cancel()
        quietScrollEnd = nil
        // A new gesture during a rubber band's ease back: the same scroll goes on.
        settleEnd?.cancel()
        settleEnd = nil
        stopAnimation()
        controller.userScrollBegan()
    }

    @objc private func liveScrollEnded() {
        guard liveScrolling, !gone else { return }
        liveScrolling = false
        settle()
    }

    /// Past the content's range at either end: a rubber band, pulled by
    /// the gesture or easing back.
    private var overscrolled: Bool {
        let bounds = clip.bounds
        return bounds.origin.y < -0.01 || bounds.origin.y > maxOrigin + 0.01
    }

    /// A rubber band pulled or easing back: the list places nothing.
    private var banding: Bool { overscrolled || settleEnd != nil }

    /// The scroll that ended past an end goes on while its rubber band
    /// eases back: over once back in range, or once nothing has moved.
    private func settle() {
        settleEnd?.cancel()
        guard overscrolled else { return settled() }
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settled() }
        }
        settleEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: end)
    }

    private func settled() {
        settleEnd = nil
        guard !gone else { return }
        controller.userScrollEnded(report())
        if deferred {
            deferred = false
            place(controller.placement)
            report()
        }
        queueIdle()
    }

    @objc private func boundsChanged() {
        guard adjusting == 0, placed, !gone else { return }
        if animation != 0 {
            // A frame of an animated move: what shows, reported.
            scroll.reflectScrolledClipView(clip)
            report()
            return
        }
        if banding {
            // Past an end, or easing back: the origin is the gesture's (or
            // AppKit's) alone, and the ease back the same scroll.
            if settleEnd != nil { settle() } else if !liveScrolling, quietScrollEnd != nil { quietScroll() }
            report()
            return
        }
        if !liveScrolling { quietScroll() }
        // The rows coming into view measured before they are drawn,
        // holding what is there.
        if let visual = captureVisual() { place(visual) }
        report()
    }

    /// A scroll no gesture announced (a mouse wheel, Page keys, the
    /// scroller's track, a text selection dragged past the edge): by hand,
    /// over once nothing has moved for a moment.
    private func quietScroll() {
        if quietScrollEnd == nil {
            stopAnimation()
            controller.userScrollBegan()
        }
        quietScrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.gone else { return }
                self.quietScrollEnd = nil
                self.controller.userScrollEnded(self.report())
                self.queueIdle()
            }
        }
        quietScrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: end)
    }

    // MARK: Resizing

    /// The view is about to change size: what it holds across it.
    func willResize(to size: NSSize) -> ListPlacement? {
        guard placed, !gone else { return nil }
        let held = controller.placement
        stopAnimation()
        return resolved(held)
    }

    /// The view changed size: the held placement put back in the same
    /// pass, the rows in view measured at the new width first.
    func didResize(holding held: ListPlacement?) {
        if pendingOpen != nil { return openIfSized() }
        guard placed, !gone, let held else { return }
        let start = ContinuousClock.now
        let widthChanged = setWidth(clip.bounds.width)
        place(held, margin: 0)
        report()
        queueIdle(after: widthChanged ? 0.15 : 0)
        if Offscreen.isOn, widthChanged {
            Offscreen.log("list: resize \(kind) w=\(Int(width)) in \(Self.ms(.now - start)) ms")
        }
    }

    @discardableResult
    private func setWidth(_ new: CGFloat) -> Bool {
        guard new > 0, abs(new - width) > 0.5 else { return false }
        width = new
        stale = Set(ids)
        table.tableColumns.first?.width = new
        return true
    }

    // MARK: Heights

    private func height(of row: Row) -> CGFloat {
        heights[row.id] ?? row.estimatedHeight
    }

    /// Records a row's height, keeping the total.
    private func setHeight(_ height: CGFloat, of index: Int) {
        let row = rows[index]
        rowsHeight += height - self.height(of: row)
        heights[row.id] = height
        stale.remove(row.id)
    }

    private func updateRowsHeight() {
        guard composer.thread != nil else { return }
        rowsHeight = rows.reduce(0) { $0 + height(of: $1) } + 2 * Self.padding
    }

    /// Measures the row, by its own cell when it has one showing it (whose
    /// layout at this width then reuses the work), else by a sizer.
    @discardableResult
    private func measure(_ index: Int) -> CGFloat {
        let row = rows[index]
        let proposal = CGSize(width: width, height: 100_000)
        let size: CGSize
        if let cell = table.view(atColumn: 0, row: tableRow(index), makeIfNecessary: false) as? HostCell, cell.row as? Row == row {
            size = cell.controller.sizeThatFits(in: proposal)
        } else {
            let key = row.reuse.rawValue
            let sizer = sizers[key] ?? {
                let sizer = NSHostingController(rootView: AnyView(EmptyView()))
                sizer.sizingOptions = []
                sizers[key] = sizer
                return sizer
            }()
            sizer.rootView = content(row)
            size = sizer.sizeThatFits(in: proposal)
        }
        let height = max(ceil(size.height), 1)
        setHeight(height, of: index)
        return height
    }

    /// Measures a stale row; returns whether its height changed.
    private func remeasure(_ index: Int) -> Bool {
        let was = height(of: rows[index])
        return abs(measure(index) - was) > 0.25
    }

    /// Measures the stale rows in `rect`; returns the table rows whose height changed.
    private func measureRows(in rect: NSRect) -> IndexSet {
        var changed = IndexSet()
        guard !stale.isEmpty else { return changed }
        forEachRow(in: rect) { t, _ in
            guard let index = index(ofTableRow: t), stale.contains(rows[index].id) else { return }
            if remeasure(index) { changed.insert(t) }
        }
        return changed
    }

    private func noteHeights(_ changed: IndexSet) {
        guard !changed.isEmpty else { return }
        adjust {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
        }
    }

    /// A thread shorter than the view starts at its top: the space goes
    /// under its newest row.
    private func updateFill() {
        guard composer.thread != nil else { return }
        let new = max(0, clip.bounds.height - rowsHeight)
        guard abs(new - fill) > 0.25 else { return }
        fill = new
        noteHeights([0])
    }

    /// The rows not in view, in idle time: a few milliseconds a turn of
    /// the run loop, nearest the view first, holding what is on the screen.
    /// Not while scrolling or moving; done once every row is exact, so an
    /// idle list does nothing.
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
        guard !gone, placed, !stale.isEmpty else { return }
        guard animation == 0, !liveScrolling, quietScrollEnd == nil, !banding else {
            return queueIdle(after: 0.2)
        }
        let deadline = ContinuousClock.now + .milliseconds(8)
        let hold = holdNow()
        let count = rows.count
        let middle = index(ofTableRow: table.rows(in: clip.bounds).location) ?? count - 1
        var changed = IndexSet()
        var left = false
        var step = 0
        outward: while step <= count {
            for index in [middle - step, middle + step + 1] where rows.indices.contains(index) && stale.contains(rows[index].id) {
                if ContinuousClock.now >= deadline {
                    left = true
                    break outward
                }
                if remeasure(index) { changed.insert(tableRow(index)) }
            }
            step += 1
        }
        if !changed.isEmpty {
            noteHeights(changed)
            updateFill()
            setOrigin(for: hold)
            report()
        }
        if left { queueIdle() }
    }

    /// A cell laid out at another height than its row's: its content
    /// changed without the row changing (an image's size arriving, a send
    /// that can be retried). Corrected in the layout pass that follows,
    /// before anything is drawn, holding the list.
    private func cellReported(_ id: String, _ reported: CGFloat) {
        guard !gone, let index = position[id] else { return }
        let height = max(ceil(reported), 1)
        guard abs(height - self.height(of: rows[index])) > 0.5 else { return }
        corrections[id] = height
        scroll.needsLayout = true
    }

    /// The scroll view's layout pass (`ListScrollView.layout`).
    func layoutPass() {
        guard !corrections.isEmpty, adjusting == 0 else { return }
        applyCorrections()
    }

    private func applyCorrections() {
        guard !gone, placed else { return }
        // An animated move lands exactly where it aims once it ends.
        let hold = animation != 0 ? .keep : holdNow()
        var changed = IndexSet()
        for (id, height) in corrections {
            guard let index = position[id] else { continue }
            setHeight(height, of: index)
            changed.insert(tableRow(index))
        }
        corrections = [:]
        guard !changed.isEmpty else { return }
        noteHeights(changed)
        updateFill()
        setOrigin(for: hold)
        report()
    }

    // MARK: Reports

    /// What the list shows now, to the controller and the probe.
    @discardableResult
    private func report() -> ListViewport {
        let bounds = clip.bounds
        let height = table.frame.height
        // Row 0 at the bottom: reversed, top down. The probe's frames, a
        // view either side, only in the offscreen check.
        let inView = table.rows(in: bounds)
        var visibleIDs: [String] = [], visibleTops: [Double] = []
        var frames: [String: CGRect] = [:]
        forEachRow(in: Offscreen.isOn ? bounds.insetBy(dx: 0, dy: -bounds.height) : bounds) { t, rect in
            guard let index = index(ofTableRow: t) else { return }
            let id = rows[index].id
            if NSLocationInRange(t, inView) {
                visibleIDs.append(id)
                visibleTops.append(Double(bounds.maxY - rect.maxY))
            }
            if Offscreen.isOn { frames[id] = CGRect(x: 0, y: height - rect.maxY, width: rect.width, height: rect.height) }
        }
        let viewport = ListViewport(
            visibleIDs: visibleIDs.reversed(), visibleTops: visibleTops.reversed(),
            atBottom: bounds.origin.y <= ChatListController.bottomZone,
            nearTop: height - bounds.maxY < bounds.height, far: bounds.origin.y > bounds.height
        )
        // As a lazy list's frames were: from the content's top down.
        view = (height - bounds.maxY)..<(height - bounds.minY)
        content = height
        self.frames = frames
        controller.scrolled(viewport)
        placeHoverBar()
        return viewport
    }

    // MARK: Hover

    /// The pointer moved over the list, or left it (nil).
    func pointer(at point: NSPoint?) {
        pointer = point
        placeHoverBar()
    }

    /// The row under the pointer: the bar's while it is over the bar.
    private func row(under point: NSPoint) -> Row? {
        if !hoverBar.isHidden, hoverBar.frame.contains(scroll.convert(point, from: nil)) { return barRow }
        guard clip.bounds.contains(clip.convert(point, from: nil)),
              let index = index(ofTableRow: table.row(at: table.convert(point, from: nil))) else { return nil }
        return rows[index]
    }

    /// The bar over the row under the pointer, across its top edge, or
    /// inside the view where that is above it; kept on the row whose menu
    /// it opened while that menu is open (following it as the list moves),
    /// hidden while another is.
    private func placeHoverBar() {
        let presenter = environment.menuPresenter
        watchMenu(presenter)
        // None while the list moves, as in Slack: back once it is still.
        let moving = liveScrolling || quietScrollEnd != nil || banding || animation != 0
        let hovered = moving ? nil : pointer.flatMap(row(under:))
        if hover.id != hovered?.id { hover.id = hovered?.id }
        let current = barRow.flatMap { position[$0.id].map { rows[$0] } }
        let row = presenter?.isOpen == true
            ? current.flatMap { presenter?.isOpen(from: $0.id) == true ? $0 : nil }
            : hovered
        guard let row, let index = position[row.id], let bar = row.hoverBar(in: composer) else {
            return hoverBar.isHidden = true
        }
        if row != barRow {
            barRow = row
            hoverBar.rootView = AnyView(bar.environment(\.self, environment))
            barSize = hoverBar.fittingSize
        }
        let rect = table.rect(ofRow: tableRow(index))
        let top = min(rect.maxY + HoverBar.overhang, clip.bounds.maxY)
        let frame = NSRect(x: rect.maxX - Theme.Space.xl - barSize.width, y: top - barSize.height,
                           width: barSize.width, height: barSize.height)
        hoverBar.frame = scroll.convert(clip.convert(frame, from: table), from: clip)
        hoverBar.isHidden = false
    }

    /// Places the bar again when a menu opens or closes.
    private func watchMenu(_ presenter: MenuPresenter?) {
        guard let presenter, !watchingMenu else { return }
        watchingMenu = true
        withObservationTracking {
            _ = presenter.isOpen
            _ = presenter.source
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchingMenu = false
                self?.placeHoverBar()
            }
        }
    }

    // MARK: Cells

    /// Table row 0 is the space under the newest row, then the newest
    /// first, then the space above the oldest.
    private func tableRow(_ index: Int) -> Int { rows.count - index }

    private func index(ofTableRow t: Int) -> Int? {
        let index = rows.count - t
        return rows.indices.contains(index) ? index : nil
    }

    private func forEachRow(in rect: NSRect, _ body: (Int, NSRect) -> Void) {
        let range = table.rows(in: rect)
        guard range.length > 0 else { return }
        for t in range.location..<(range.location + range.length) { body(t, table.rect(ofRow: t)) }
    }

    private func content(_ row: Row) -> AnyView {
        AnyView(
            row.content(in: composer, canAnswer: canAnswer)
                .environment(\.goToMessage) { [weak self] message in self?.go(to: message) }
                .environment(\.listRowExpanding) { [weak self] id in self?.expanding(id) }
                .environment(flashed)
                .environment(hover)
                // The list's own environment, under what the rows add to it.
                .environment(\.self, environment)
        )
    }

    /// A cell reused for another row makes that row's views anew (`.id`):
    /// whatever the old row's views opened (a menu, a card, a panel) goes
    /// with them, as when they scroll away.
    private func show(_ row: Row, in cell: HostCell) {
        cell.row = row
        let id = row.id
        cell.controller.rootView = AnyView(
            content(row)
                .id(id)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                    self?.cellReported(id, height)
                }
        )
    }

    private func refreshVisibleCells() {
        forEachRow(in: clip.bounds.insetBy(dx: 0, dy: -clip.bounds.height)) { t, _ in
            guard let index = index(ofTableRow: t),
                  let cell = table.view(atColumn: 0, row: t, makeIfNecessary: false) as? HostCell else { return }
            show(rows[index], in: cell)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 2 }

    func tableView(_ tableView: NSTableView, heightOfRow t: Int) -> CGFloat {
        guard let index = index(ofTableRow: t) else { return t == 0 ? Self.padding + fill : Self.padding }
        return height(of: rows[index])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row t: Int) -> NSView? {
        guard let index = index(ofTableRow: t) else {
            return tableView.makeView(withIdentifier: Self.edge, owner: nil) ?? {
                let view = NSView()
                view.identifier = Self.edge
                return view
            }()
        }
        let row = rows[index]
        let kind = row.reuse
        let cell = tableView.makeView(withIdentifier: kind, owner: nil) as? HostCell ?? HostCell(kind: kind)
        show(row, in: cell)
        return cell
    }

    private static var edge: NSUserInterfaceItemIdentifier { .init("edge") }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Helpers

    private func adjust(_ body: () -> Void) {
        adjusting += 1
        body()
        adjusting -= 1
    }

    private func log(_ event: @autoclosure () -> String) {
        TimelineLog.log("\(TimelineLog.tag(composer)) \(event())")
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}

/// The table: its document not flipped, so row 0 (under the newest) sits
/// at the bottom and its origin is the list's end.
final class BottomTable: NSTableView {
    override var isFlipped: Bool { false }
    /// The keyboard stays with the composer; text in a row can still take it.
    override var acceptsFirstResponder: Bool { false }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }

    // Rows run newest first from the bottom: VoiceOver reads them top down,
    // oldest first, as they are on the screen.
    override func accessibilityChildren() -> [Any]? { super.accessibilityChildren()?.reversed() }
}

/// Holds the list's placement across its own size changes: captured before
/// the frame changes, put back in the same layout pass.
final class ListScrollView: NSScrollView {
    weak var engine: MessageTableHost?
    /// The pointer over the rows, for the engine's hover.
    private(set) lazy var pointerArea = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self
    )

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === pointerArea else { return super.mouseEntered(with: event) }
        engine?.pointer(at: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) { engine?.pointer(at: event.locationInWindow) }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === pointerArea else { return super.mouseExited(with: event) }
        engine?.pointer(at: nil)
    }

    override func layout() {
        engine?.layoutPass()
        super.layout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard let engine, newSize != frame.size else { return super.setFrameSize(newSize) }
        let held = engine.willResize(to: newSize)
        engine.adjusting += 1
        super.setFrameSize(newSize)
        engine.adjusting -= 1
        engine.didResize(holding: held)
    }
}

/// The list's clip view. `elastic` is the offscreen driver's stand-in for
/// AppKit's rubber band, which lets the clip past the content only during
/// a trackpad's gesture, one the driver cannot make off the screens.
final class ListClipView: NSClipView {
    var elastic = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        elastic ? proposedBounds : super.constrainBoundsRect(proposedBounds)
    }
}

/// A row's cell: one hosting controller, reused for rows of its kind. A
/// controller rather than a bare view, so a row in view is measured by its
/// own SwiftUI graph, which its layout at that width then reuses.
final class HostCell: NSView {
    let controller = NSHostingController(rootView: AnyView(EmptyView()))
    /// The row it shows now.
    var row: Any?

    init(kind: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = kind
        controller.sizingOptions = []
        controller.safeAreaRegions = []
        controller.view.autoresizingMask = [.width, .height]
        controller.view.frame = bounds
        addSubview(controller.view)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The row under the pointer, from the list's tracking area.
@MainActor @Observable final class ListHover {
    var id: String?
}

/// The row lit after a jump.
@MainActor @Observable final class ListFlash {
    var id: String?
}

/// The SwiftUI side's way to the list: the controller, for the pill, and
/// the engine, for the keys.
@MainActor @Observable final class ListLink {
    var controller: ChatListController?
    @ObservationIgnored weak var engine: MessageTableHost?
}

/// A message list's table: `MessageList`'s, or the agent chat's.
struct MessageTable<Row: TableRow>: NSViewRepresentable {
    let model: AppModel
    let rows: [Row]
    let composer: ComposerID
    var canAnswer = false
    var focus: FocusTarget?
    var reachesNewest = true
    var hasOlder = false
    let link: ListLink

    func makeCoordinator() -> MessageTableEngine<Row> {
        let engine = MessageTableEngine<Row>(composer: composer, model: model)
        link.engine = engine
        link.controller = engine.controller
        return engine
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(model: model, rows: rows, canAnswer: canAnswer, focus: focus, reachesNewest: reachesNewest,
                                   hasOlder: hasOlder, environment: context.environment)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: MessageTableEngine<Row>) {
        coordinator.dismantle()
    }
}

extension ChatRow: TableRow {
    var reuse: NSUserInterfaceItemIdentifier {
        switch kind {
        case .message: .init("message")
        case .payment, .paymentRequest: .init("payment")
        default: .init("note")
        }
    }

    /// For a row never measured: by kind and length.
    var estimatedHeight: CGFloat {
        var height: CGFloat = startsDay ? 40 : 0
        if startsNew { height += 28 }
        switch kind {
        case .message:
            let lines = max(1, (message.shownText.count + 69) / 70)
            height += CGFloat(lines) * 18 + (startsRun ? 30 : 6)
            if message.attachmentKind != nil { height += 220 }
            if summary != nil { height += 28 }
            height += CGFloat(agentArtifacts.count) * 24
        default:
            height += 28
        }
        return height
    }

    func content(in list: ComposerID, canAnswer: Bool) -> AnyView {
        // A tribe member's deliverables (Jamie's), under the message.
        AnyView(ListRowContent(row: self, composer: list, canAnswer: canAnswer,
                               below: inTribe ? agentArtifactLines(agentArtifacts, inTribe: true) : nil))
    }

    func hoverBar(in list: ComposerID) -> AnyView? {
        HoverBar.shows(self) ? AnyView(HoverBar(row: self, composer: list)) : nil
    }

    static func listContent(_ rows: [ChatRow], in list: ComposerID, reachesNewest: Bool, hasOlder: Bool) -> ListContent {
        ListContent(rows, in: list, reachesNewest: reachesNewest, hasOlder: hasOlder)
    }
}

extension EnvironmentValues {
    /// A row in a message list about to open or close part of itself, by
    /// its id: the list holds that row's top (`ChatListController.userExpanded`).
    @Entry var listRowExpanding: @MainActor (String) -> Void = { _ in }
    /// The row is in the agent's DM, drawn as the agent chat: the agent's
    /// messages with Peel's logo and AGENT, their links to messages opening
    /// them (`MessageText`'s `agentLinks`).
    @Entry var inAgentDM = false
}
