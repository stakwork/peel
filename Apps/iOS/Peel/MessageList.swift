import PeelCore
import PeelUI
import SwiftUI

/// A conversation's or a thread's rows, newest at the bottom, as the
/// Mac's `MessageList` places them: a list opens at a message asked for,
/// else at "New messages" when it has one, else where it last stood
/// (`AppModel.anchor(of:)`), else at its newest, and is shown only once
/// it is there. Others' messages take it down only while it is at the
/// bottom (yours always do); scrolled up, what arrives below is counted on
/// the "N new messages" pill (`ListBottom`). Near the top a chat asks the
/// model for an older page (`loadOlder`). The keyboard goes down with a
/// drag down the list.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    let rows: [ChatRow]
    let composer: ComposerID
    /// False while its screen goes (popped, or under another tab) or waits
    /// for a reload, showing the rows it last had: it keeps its place and
    /// tells the model nothing.
    let live: Bool

    @State private var position: ScrollPosition
    /// Where it opens, until it is there; it is hidden until then.
    @State private var start: Start?
    @State private var phase = ScrollPhase.idle
    /// Others' messages take the list down while it is at the bottom or on
    /// its way there, until you scroll away or it opens at "New messages".
    @State private var following = true
    @State private var farFromBottom = false
    /// "New messages" still marks what is unread below it.
    @State private var dividerUnread = false
    @State private var bottom = ListBottom()
    @State private var opening = true
    /// The chat was left (another tab) since the list was placed: coming
    /// back, "New messages" that came meanwhile wins over where it stood.
    @State private var left = false
    /// The jump button asked for the newest past a jump's window: the list
    /// goes there once the newest page has loaded.
    @State private var wantsNewest = false
    /// A row just gone to from a quote or a jump, lit for a moment.
    @State private var flashed: String?
    @State private var layout = Layout()

    /// Where a list opens.
    enum Start: Equatable {
        case newest
        /// A row with its top `offset` points below the list's top: "New
        /// messages" (at 0), or where the list last stood.
        case row(id: String, offset: CGFloat)
        /// A message asked for, centred and lit.
        case focus(id: String)
    }

    init(rows: [ChatRow], composer: ComposerID, live: Bool = true, start: Start) {
        self.rows = rows
        self.composer = composer
        self.live = live
        // Asked for before the list is first laid out, so its first frame
        // is at the row, not at the bottom and then the row.
        switch start {
        case .newest:
            _position = State(initialValue: ScrollPosition(idType: String.self))
            // The initial anchor places it, but before the composer has
            // taken its room below: shown once the last row is above it.
            _start = State(initialValue: rows.isEmpty ? nil : start)
        case .row(let id, _):
            _position = State(initialValue: ScrollPosition(id: id, anchor: .top))
            _start = State(initialValue: start)
        case .focus(let id):
            _position = State(initialValue: ScrollPosition(id: id, anchor: .center))
            _start = State(initialValue: start)
        }
    }

    /// Where a list of `rows` made now opens: a message asked for wins over
    /// "New messages" (`AppModel.opensAtNewMessages`), and both over where
    /// it last stood, kept as a row it still has.
    static func start(of composer: ComposerID, rows: [ChatRow], in model: AppModel) -> Start {
        if let target = focusTarget(model.focus, of: composer, rows: rows) {
            // One folded into a thread opens the thread (`go(to:)`).
            return rows.first(where: { $0.holds(target.message.uuid) }).map { .focus(id: $0.id) } ?? .newest
        }
        if model.opensAtNewMessages(in: composer), let divider = rows.first(where: \.startsNew) {
            return .row(id: divider.id, offset: 0)
        }
        if case .row(let id, let offset) = model.anchor(of: composer), rows.contains(where: { $0.id == id }) {
            return .row(id: id, offset: offset)
        }
        return .newest
    }

    private var userScrolling: Bool { phase == .interacting || phase == .decelerating }
    private var isThread: Bool { composer.thread != nil }
    /// A thread's list always ends at its newest; the chat's unless a
    /// jump's window stops short of it.
    private var reachesNewest: Bool { isThread || model.timelineReachesNewest }
    private var divider: ChatRow? { rows.first(where: \.startsNew) }

    private struct Edges: Equatable {
        /// The list's own height: the keyboard or the composer growing takes room from it.
        var container: CGFloat
        var atBottom: Bool
        var far: Bool
        var nearTop: Bool
    }

    var body: some View {
        let newCount = newSinceScrolledUp
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Kept while the page loads, so nothing moves under the finger.
                if !isThread, model.mayHaveOlder || model.loadingOlder, !rows.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.md)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        if row.startsDay { DayDividerLine(date: row.date) }
                        if row.startsNew { NewMessagesLine() }
                        ConversationRow(row: row, composer: composer, flashed: flashed == row.id)
                            .equatable()
                    }
                    // Where each made row is in the content, to place the list
                    // and keep its place: reported as rows lay out, not as
                    // the list scrolls, and not state, so nothing is drawn again.
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Layout.space)).minY } action: { [layout] top in
                        layout.tops[row.id] = top
                    }
                    .onDisappear { [layout] in layout.tops[row.id] = nil }
                    .id(row.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, Theme.Space.sm)
            .coordinateSpace(.named(Layout.space))
            .environment(\.goToMessage) { go(to: $0) }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(isThread ? .top : .bottom, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdges()
        .onScrollPhaseChange { _, new in
            phase = new
            if new == .idle { settled() }
        }
        .onScrollGeometryChange(for: Layout.Viewport.self) { geometry in
            Layout.Viewport(inset: geometry.contentInsets.top, offset: geometry.contentOffset.y,
                            end: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
        } action: { [layout] _, new in
            layout.viewport = new
        }
        .onScrollGeometryChange(for: Edges.self) { geometry in
            let below = geometry.contentSize.height + geometry.contentInsets.bottom
                - (geometry.contentOffset.y + geometry.containerSize.height)
            return Edges(container: geometry.containerSize.height - geometry.contentInsets.bottom, atBottom: below <= 24, far: below > geometry.containerSize.height,
                         nearTop: geometry.contentOffset.y + geometry.contentInsets.top < geometry.containerSize.height)
        } action: { old, new in
            // The keyboard came up (or the composer grew) under a list
            // following at its bottom: it stays at the bottom.
            // Judged by the last crossing taken, not `old`, which a
            // coalesced report can have moved past (`ListBottom`).
            if new.container != old.container, following, bottom.atBottom, reachesNewest, !userScrolling {
                keepLastRowInView()
            }
            moved(new)
        }
        .onAppear(perform: open)
        .onChange(of: model.focus?.message.id) { _, _ in if live { takeFocus() } }
        .onChange(of: divider?.id) { _, id in if id != nil { dividerUnread = true } }
        .onChange(of: model.selectedChat == composer.chat) { _, selected in if !selected { left = true } }
        .onChange(of: live) { _, live in if live { resume() } }
        // Yours always take you to the newest; others' only while following.
        .onChange(of: rows.last?.id) { _, _ in
            guard live, reachesNewest, !opening else { return }
            if following || rows.last?.shown.last?.fromMe == true { scrollToNewest() }
        }
        .overlay(alignment: .bottom) {
            if newCount > 0 || farFromBottom || !reachesNewest {
                JumpToNewest(count: newCount, action: jumpToNewest)
                    .padding(.bottom, Theme.Space.sm)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: newCount > 0 || farFromBottom || !reachesNewest)
        .opacity(start == nil ? 1 : 0)
    }

    // MARK: Placing it

    /// The initial anchor (the newest) or position (a row) has asked for
    /// it; it is shown once that row is laid out where it belongs.
    private func open() {
        guard let start else {
            opening = false
            settled()
            return
        }
        Task {
            await place(start)
            // A message folded into a thread: its thread opens.
            if start == .newest { takeFocus() }
        }
    }

    /// Live again after a reload or another tab, the same list with the
    /// rows it kept: to a message asked for, to the newest the jump button
    /// asked for, to "New messages" that came while away, or, left at the
    /// newest, to the newest, past what came meanwhile; else it stays.
    private func resume() {
        let returned = left
        left = false
        if focusTarget != nil {
            takeFocus()
        } else if wantsNewest {
            wantsNewest = false
            scrollToNewest()
        } else if returned, model.opensAtNewMessages(in: composer), let divider {
            let start = Start.row(id: divider.id, offset: 0)
            self.start = start
            opening = true
            Task { await place(start) }
        } else if model.anchor(of: composer) == .newest, reachesNewest {
            following = true
            keepLastRowInView()
        }
    }

    /// To the row by where it is laid out, a frame at a time until it is
    /// where it belongs or goes no further (the end of the list), then
    /// shown. Not once you take the list; at most a dozen frames.
    ///
    /// Interim: a timed retry against the lazy stack's estimates, which the
    /// shared list engine (the review's PR 6) deletes.
    private func place(_ start: Start) async {
        let id: String, anchor: UnitPoint, offset: CGFloat?
        switch start {
        case .newest:
            (id, anchor, offset) = (rows.last?.id ?? "", .bottom, nil)
        case .row(let row, let rowOffset): (id, anchor, offset) = (row, .top, rowOffset)
        case .focus(let row): (id, anchor, offset) = (row, .center, nil)
        }
        if case .row = start {
            following = false
            dividerUnread = divider?.id == id
        }
        var last: CGFloat?
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(16))
            guard !userScrolling, rows.contains(where: { $0.id == id }) else { break }
            guard let top = layout.top(of: id) else {
                position.scrollTo(id: id, anchor: anchor)
                last = nil
                continue
            }
            if let offset, abs(top - offset) <= 0.5 { break }
            if top == last { break }
            last = top
            guard let offset else {
                // The newest: again by the last row, as the composer's room comes.
                if start == .newest { keepLastRowInView() }
                continue
            }
            let y = layout.viewport.offset + top - offset
            // Past the end the row cannot go; the end then, by the last
            // row, which counts the composer's room below it (an offset
            // stops short of that room).
            if y >= layout.viewport.end { keepLastRowInView() } else { position.scrollTo(y: y) }
        }
        self.start = nil
        if case .focus(let id) = start {
            following = false
            model.focus = nil
            flash(id)
        }
        opening = false
        settled()
    }

    private func moved(_ edges: Edges) {
        if edges.nearTop, !isThread, !opening, live { model.loadOlder() }
        var bottom = self.bottom
        if reachesNewest {
            bottom.report(atBottom: edges.atBottom, settled: !opening && phase == .idle, newest: newestIndex)
        }
        switch bottom.cross(atBottom: edges.atBottom) {
        case .reached:
            if userScrolling, reachesNewest { reachedBottom() }
            if reachesNewest { following = true }
            if !isThread, live, reachesNewest || userScrolling { model.chatListAtBottom() }
        case .left:
            if userScrolling {
                following = false
                dividerUnread = false
            }
            bottom.left(byItself: !userScrolling && !following, otherwiseSeen: seenWhenScrolledUp)
        case nil:
            break
        }
        if bottom != self.bottom { self.bottom = bottom }
        if edges.far != farFromBottom { farFromBottom = edges.far }
    }

    /// Still after opening or a scroll: where it stands is kept, and at the
    /// bottom all of it was seen.
    private func settled() {
        keepPlace()
        guard !opening, bottom.atBottom, phase == .idle else { return }
        var bottom = self.bottom
        bottom.report(atBottom: true, settled: true, newest: newestIndex)
        if bottom != self.bottom { self.bottom = bottom }
    }

    /// Where the list stands, kept in the model for a list of these rows
    /// made again (`AppModel.keep`): the newest at the bottom, else the
    /// row at the top, never "New messages"' row or a thread's lines.
    private func keepPlace() {
        guard live, !opening, phase == .idle, !rows.isEmpty else { return }
        if reachesNewest, bottom.atBottom { return model.keep(.newest, of: composer) }
        let anchors = Set(rows.lazy.filter { row in
            switch row.kind {
            case .replies, .missingOriginal: false
            default: !row.startsNew
            }
        }.map(\.id))
        // The lowest made row whose top is at or above the list's top.
        let top = layout.viewport.offset + layout.viewport.inset
        if let reading = layout.tops.filter({ anchors.contains($0.key) && $0.value <= top + 0.5 }).max(by: { $0.value < $1.value }) {
            model.keep(.row(id: reading.key, offset: Double(reading.value - top)), of: composer)
        }
    }

    /// To the last row, not the edge: a scroll to the edge while the lazy
    /// stack resizes can leave it with no row made there, a blank list
    /// (the Mac's `repin` by its last row).
    private func keepLastRowInView() {
        guard let last = rows.last?.id else { return }
        position.scrollTo(id: last, anchor: .bottom)
    }

    private func scrollToNewest() {
        following = true
        withAnimation(.easeOut(duration: 0.25)) { keepLastRowInView() } completion: { settled() }
    }

    private func jumpToNewest() {
        if reachesNewest {
            scrollToNewest()
        } else {
            // The newest page replaces the window, kept rows on screen until
            // it has loaded (`resume`).
            wantsNewest = true
            model.showNewest()
        }
        reachedBottom()
    }

    private func reachedBottom() {
        dividerUnread = false
        if !isThread, live, let chat = composer.chat { model.reachedBottom(of: chat) }
    }

    // MARK: Counting what came below

    private var newestIndex: Int64? {
        rows.lazy.compactMap { $0.shown.last?.serverIndex }.max()
    }

    private var seenWhenScrolledUp: Int64 {
        if dividerUnread, let index = divider?.shown.first?.serverIndex { return index - 1 }
        return newestIndex ?? -1
    }

    private var newSinceScrolledUp: Int {
        bottom.newBelow(newestFirst: rows.reversed().lazy.map(\.shown))
    }

    // MARK: Going to a message

    /// The model's focused message, when it belongs in this list.
    private var focusTarget: FocusTarget? {
        Self.focusTarget(model.focus, of: composer, rows: rows)
    }

    private static func focusTarget(_ target: FocusTarget?, of composer: ComposerID, rows: [ChatRow]) -> FocusTarget? {
        guard let target, target.message.chat == composer.chat,
              composer.thread.map({ $0 == target.message.threadRoot }) ?? !target.inThread,
              !rows.isEmpty else { return nil }
        return target
    }

    private func takeFocus() {
        guard let target = focusTarget else { return }
        if go(to: target.message) { model.focus = nil }
    }

    /// To a message, lit for a moment; one folded into a thread opens it.
    @discardableResult
    private func go(to message: Message) -> Bool {
        if let row = rows.first(where: { $0.holds(message.uuid) }) {
            following = false
            withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(id: row.id, anchor: .center) }
            flash(row.id)
            return true
        } else if !isThread, message.threadUUID != nil {
            model.focus(on: message, inThread: true)
        }
        return false
    }

    private func flash(_ id: String) {
        flashed = id
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            if flashed == id { withAnimation(.easeOut(duration: 1.2)) { flashed = nil } }
        }
    }
}

/// Where a list's rows are: each made row's top in the content, and the
/// content's top inset and offset as it scrolls. Not observed: the list
/// reads it only to place itself and to keep its place.
private final class Layout {
    static let space = "MessageList.content"

    struct Viewport: Equatable {
        /// The content's top inset (under the header) and offset.
        var inset: CGFloat = 0
        var offset: CGFloat = 0
        /// The offset at the end of the content, the composer's room below it included.
        var end: CGFloat = 0
    }

    var tops: [String: CGFloat] = [:]
    var viewport = Viewport()

    /// A made row's top below the list's top (under its inset), as on screen now.
    func top(of id: String) -> CGFloat? {
        tops[id].map { $0 - viewport.offset - viewport.inset }
    }
}

/// Over the composer: once messages have come in below, a blue "3 new
/// messages" pill; scrolled up with nothing new, a round glass arrow.
private struct JumpToNewest: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        if count > 0 {
            let words = Formatting.count(count, "new message", shown: Badge.text(count))
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold))
                    Text(words).phoneFont(PhoneFont.secondary.weight(.semibold)).monospacedDigit()
                }
                .foregroundStyle(Theme.buttonText)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Theme.button, in: Capsule())
                .shadow(color: Theme.menuShadow, radius: 10, y: 4)
                .frame(minHeight: Theme.touchTarget)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to newest, \(words)")
        } else {
            GlassButton("arrow.down", label: "Jump to newest", action: action)
        }
    }
}
