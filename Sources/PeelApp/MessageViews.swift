import SwiftUI
import PeelCore
import PeelUI

extension EnvironmentValues {
    /// From a quote to the message it quotes, in the list it sits in. Set
    /// by `MessageList` on every redraw, so it looks in the rows of now
    /// while the rows themselves (`MessageRow`, `Equatable`) stay as drawn.
    @Entry var goToMessage: @MainActor @Sendable (Message) -> Void = { _ in }
}

/// A conversation's rows, newest at the bottom. `composer` is where a reply
/// from here goes: the chat's, or the thread panel's.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    let rows: [ChatRow]
    let composer: ComposerID
    var canAnswer = false

    /// A row just jumped to from a quote, lit for a moment.
    @State private var flashed: String?
    @State private var phase = ScrollPhase.idle
    private var userScrolling: Bool { phase == .interacting || phase == .decelerating }
    /// The rows made and the re-pin's requests, kept where writing them
    /// redraws nothing.
    @State private var tracking = ListTracking()
    /// A re-pin scrolled and the list has not reached its end since: the
    /// lazy stack's estimates can leave that scroll short, so it goes again.
    @State private var pinning = false
    /// Whether the list last reported itself at its end, so a re-pin with
    /// nothing to move does not start `pinning`. Not read by `body`.
    @State private var atEnd = true
    /// Others' messages take the list down: while it is at the bottom or on
    /// its way there, until you scroll away by hand or it opens at "New messages".
    @State private var following = true
    /// Scrolled up over a screen from the bottom: the jump button shows.
    @State private var farFromBottom = false
    /// "New messages" still marks what is unread below it: from opening at
    /// it (or its moving) until you reach the bottom or scroll away from it.
    @State private var dividerUnread = false
    /// Where the list stands against its bottom, and what counted as seen
    /// when it left: what came after and counts as unread is the jump
    /// button's count.
    @State private var bottom = ListBottom()
    /// Until the list has gone where it opens (the newest, "New messages"
    /// or a message asked for), it has shown nothing yet.
    @State private var opening = true

    /// The end of the list, under its padding. Scrolling to the last row
    /// stops at that padding, short of the scroll view's own bottom.
    private static let bottomID = "bottom"

    /// Where the list sits against its bottom, as the scroll position, the
    /// content's height or the list's own height changes.
    private struct BottomDistance: Equatable {
        var height: CGFloat
        /// The list's own height: the composer growing a line, or the
        /// search bar opening, takes room from it.
        var container: CGFloat
        /// At the end, as far as layout goes, or short of filling the list.
        var atEnd: Bool
        var atBottom: Bool
        var far: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Message rows reach the edges (their hover and tint do);
                // everything else keeps the usual margin.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if row.startsDay {
                            DayDivider(date: row.date)
                                .padding(.horizontal, Theme.Space.xl)
                        }
                        // "New messages" shares its row's id, so scrolling to
                        // the row (drawn or not) shows it.
                        VStack(alignment: .leading, spacing: 0) {
                            if row.startsNew {
                                NewMessagesDivider()
                                    .padding(.horizontal, Theme.Space.xl)
                            }
                            switch row.kind {
                            case .message:
                                MessageRow(row: row, composer: composer, flashed: flashed == row.id)
                                    .equatable()
                            case .request:
                                JoinRequestNote(message: row.message, sender: row.sender, approved: row.approved, canAnswer: canAnswer)
                                    .padding(.horizontal, Theme.Space.xl)
                            case .note:
                                MembershipNote(message: row.message, sender: row.sender)
                                    .padding(.horizontal, Theme.Space.xl)
                            case .payment:
                                PaymentRow(row: row, flashed: flashed == row.id)
                            case .paymentRequest:
                                PaymentRequestRow(row: row, flashed: flashed == row.id)
                            case .missingOriginal:
                                OriginalNotAvailable()
                                    .padding(.horizontal, Theme.Space.xl)
                                    .padding(.vertical, Theme.Space.sm)
                            case .replies(let count):
                                RepliesDivider(count: count)
                                    .padding(.horizontal, Theme.Space.xl)
                            }
                        }
                        .id(row.id)
                        // A day divider alone in view counts as none made:
                        // one re-pin more, no harm.
                        .onAppear { tracking.appeared(row.id) }
                        .onDisappear { tracking.made.remove(row.id) }
                    }
                }
                // Only for the timeline log's visible rows.
                .scrollTargetLayout(isEnabled: TimelineLog.enabled)
                .environment(\.goToMessage) { go(to: $0, proxy: proxy) }
                .padding(.vertical, Theme.Space.md)
                .overlay(alignment: .bottom) { Color.clear.frame(height: 0).id(Self.bottomID) }
            }
            // A thread reads from its original down; a chat from its newest up.
            // Either starts at the bottom once there is more than fits.
            .defaultScrollAnchor(composer.thread == nil ? .bottom : .top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // No bottom anchor for size changes. When the list's own height
            // changed at the end, the anchor moved it to the lazy stack's
            // estimated end, and once the rows were measured the stack could
            // draw nothing there: a blank list until something scrolled it.
            // Holding the end is the re-pin's job (below).
            // A lazy list only estimates the rows it has not drawn, so the
            // initial anchor can land short of the end; go to the newest.
            // With "New messages", open at it instead.
            .onAppear {
                log("appear focus=\(focusTarget.map { index(of: $0.message) } ?? "none") divider=\(divider.map { index(of: $0.id) } ?? "none")")
                // The newest first, also before "New messages": left at the
                // initial anchor, a list opening at it sat for those 100 ms
                // at the lazy stack's estimated end, past every row it had
                // drawn (logged blank on every such open), and the scroll to
                // a divider near the end could not leave it. Not before a
                // message asked for: reaching the bottom would drop the
                // longer timeline loaded to reach it (`chatListAtBottom`).
                if composer.thread == nil, focusTarget == nil {
                    log("place: appear scrollTo bottom")
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    // Then by the last row once the estimate has settled: at
                    // the end already, the scroll above can move nothing,
                    // and the stack can be left with no row made there.
                    repin(proxy, byLastRow: true)
                }
                if focusTarget != nil || divider != nil {
                    // A message asked for wins over "New messages". Both
                    // wait for the list's initial bottom anchor, which would
                    // undo a scroll to them asked for now.
                    if focusTarget == nil {
                        following = false
                        dividerUnread = true
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        if focusTarget != nil {
                            // Settled once the scroll to it is over (`go(to:)`).
                            opening = false
                            takeFocus(proxy)
                        } else {
                            await openAtDivider(proxy)
                            opened()
                        }
                    }
                } else {
                    opened()
                }
            }
            .onDisappear { log("disappear") }
            .timelineProbe(geometry: logGeometry, visible: logVisible)
            .onScrollPhaseChange { _, new in
                log("phase \(phase) -> \(new)")
                phase = new
                if new == .interacting {
                    pinning = false
                    tracking.lastRowTries = 0
                }
                // A scroll that ended at the bottom sends no report once still.
                if new == .idle { settled() }
            }
            .onScrollGeometryChange(for: BottomDistance.self) { geometry in
                let below = geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                return BottomDistance(height: geometry.contentSize.height, container: geometry.containerSize.height,
                                      atEnd: below <= 0.5, atBottom: below <= 24,
                                      far: below > geometry.containerSize.height)
            } action: { old, new in
                if atEnd != new.atEnd { atEnd = new.atEnd }
                if pinning, new.atEnd { pinning = false }
                var bottom = self.bottom
                defer { update { $0 = bottom } }
                // At the bottom the jump button goes and nothing below counts
                // as new, whatever the last report said: a re-pin's early
                // return below skips the crossing, and reports can be
                // coalesced, so a return here can arrive with `old` already
                // at the bottom. Not a jump's window's bottom, short of the
                // newest.
                if reachesNewest {
                    bottom.report(atBottom: new.atBottom, settled: !opening && phase == .idle, newest: newestIndex)
                }
                if new.atBottom, farFromBottom { farFromBottom = false }
                // A row that changed height under a list following at its end
                // (one that does not reserve its final size, such as a video
                // sizing itself), or the list's own height changing there,
                // moved the end; or a re-pin fell short: back to the end.
                let resized = new.height != old.height || new.container != old.container
                if (resized && bottom.atBottom) || pinning, !new.atEnd, following, phase == .idle {
                    log("repin: \(resized ? "resized" : "pinning") height=\(TimelineLog.points(new.height)) container=\(TimelineLog.points(new.container))")
                    return repin(proxy)
                }
                // At its end with no row made: placed right but blank. The
                // offset only clamped as the stack's estimate shrank (on
                // opening), or followed a transient estimate thousands of
                // points taller when the list's own height changed, and the
                // stack draws for neither. A thread reads from its top and
                // is left where it is; a list opening at a message asked
                // for waits for it. Not again once the scroll to the last
                // row has failed `ListTracking.lastRowLimit` times.
                if resized, new.atEnd, following, phase == .idle, composer.thread == nil, focusTarget == nil,
                   !rows.isEmpty, tracking.made.isEmpty, tracking.lastRowTries < ListTracking.lastRowLimit {
                    log("repin: none made at the end height=\(TimelineLog.points(new.height)) container=\(TimelineLog.points(new.container))")
                    repin(proxy)
                }
                // Judged against the last crossing taken, not `old`, which a
                // coalesced report can have moved past.
                switch bottom.cross(atBottom: new.atBottom) {
                case .reached:
                    // Scrolled back to the bottom by hand after "Mark unread":
                    // reading resumes. Not when a new message scrolls it there,
                    // nor at the bottom of a jump's window, short of the newest.
                    if userScrolling, reachesNewest { reachedBottom() }
                    // A window's bottom is not the chat's: what it takes in
                    // below comes in under you, not followed to its end.
                    if reachesNewest { following = true }
                    if composer.thread == nil, reachesNewest || userScrolling { model.chatListAtBottom() }
                case .left:
                    // Scrolled away by hand: no longer following, and
                    // everything there had been seen.
                    if userScrolling {
                        following = false
                        dividerUnread = false
                    }
                    // Counted from here until it is back at the bottom; moved
                    // off it by itself (not by hand, not on its way back
                    // down), only what came after the bottom last in view.
                    bottom.left(byItself: !userScrolling && !following, otherwiseSeen: seenWhenScrolledUp)
                case nil:
                    break
                }
                if new.far != farFromBottom {
                    withAnimation(.easeOut(duration: 0.2)) { farFromBottom = new.far }
                }
            }
            .onChange(of: model.focus?.message.id) { _, _ in takeFocus(proxy) }
            // "Mark unread" moved the divider: what is below it is unread again.
            .onChange(of: divider?.id) { _, id in
                if id != nil { dividerUnread = true }
            }
            // Your own messages always take you to the newest; others' only
            // while following. Scrolled up, you stay where you are and the
            // jump button counts them.
            .onChange(of: rows.last?.id) { _, _ in
                guard reachesNewest else { return }
                let scrolls = following || rows.last?.shown.last?.fromMe == true
                log("newest row changed, scrolls=\(scrolls)")
                if scrolls { scrollToNewest(proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                let count = newSinceScrolledUp
                if farFromBottom || count > 0 || !reachesNewest {
                    JumpToNewestButton(count: count, composer: composer) { jumpToNewest(proxy) }
                        .padding(.trailing, Theme.Space.xl)
                        .padding(.bottom, Theme.Space.md)
                        .transition(.opacity)
                }
            }
        }
    }

    /// The row "New messages" sits above.
    private var divider: ChatRow? { rows.first(where: \.startsNew) }

    /// Whether this list ends at the newest message: a thread's always, the
    /// chat's unless a jump's window stops short of it.
    private var reachesNewest: Bool { composer.thread != nil || model.timelineReachesNewest }

    /// To "New messages" at the top, twice: the rows around it have only
    /// estimated heights until the first scroll draws them. Not once you
    /// have taken the list.
    private func openAtDivider(_ proxy: ScrollViewProxy) async {
        for pass in 0..<2 {
            guard let divider, !userScrolling, pass == 0 || !following else { return }
            // The initial anchor may have set it, reaching the bottom.
            following = false
            log("place: divider pass \(pass) scrollTo row \(index(of: divider.id))")
            proxy.scrollTo(divider.id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// What counts as seen when the list leaves the bottom: up to "New
    /// messages" while what is below it is still unread, else everything
    /// in the list.
    private var seenWhenScrolledUp: Int64 {
        if dividerUnread, let index = divider?.shown.first?.serverIndex { return index - 1 }
        return newestIndex ?? -1
    }

    /// The newest message in the list that the server has numbered.
    private var newestIndex: Int64? {
        rows.lazy.compactMap { $0.shown.last?.serverIndex }.max()
    }

    /// Messages below that count as unread (as "New messages" does) and came
    /// after what was seen; counted from the bottom up, stopping at it.
    private var newSinceScrolledUp: Int {
        bottom.newBelow(newestFirst: rows.reversed().lazy.map(\.shown))
    }

    /// The list has gone where it opens.
    private func opened() {
        opening = false
        settled()
    }

    /// Still at the bottom after opening or a scroll: everything there is in
    /// view. A report would say so, but none comes while nothing moves.
    private func settled() {
        guard !opening, bottom.atBottom, phase == .idle else { return }
        update { $0.report(atBottom: true, settled: true, newest: newestIndex) }
    }

    /// Written back only when it changed, so what moves nothing redraws nothing.
    private func update(_ change: (inout ListBottom) -> Void) {
        var bottom = self.bottom
        change(&bottom)
        guard bottom != self.bottom else { return }
        // A write here redraws the list's body (the jump button reads it).
        log("bottom state written, crossing \(self.bottom.atBottom) -> \(bottom.atBottom)")
        self.bottom = bottom
    }

    /// To the newest message; like scrolling there by hand, it ends a
    /// "Mark unread" hold and reads the chat.
    private func jumpToNewest(_ proxy: ScrollViewProxy) {
        // A jump's window ends short of the newest: the newest replace it,
        // and the list opens again at its bottom.
        if reachesNewest { scrollToNewest(proxy, duration: 0.3) } else { model.showNewest() }
        reachedBottom()
    }

    /// To the end of the list, following what arrives on the way.
    private func scrollToNewest(_ proxy: ScrollViewProxy, duration: Double = 0.2) {
        following = true
        log("place: scrollToNewest scrollTo bottom")
        withAnimation(.easeInOut(duration: duration)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } completion: {
            // Rows that grew on the way moved the end it aimed at.
            repin(proxy)
        }
    }

    /// Back to the end once no further request has come for 20 ms: a
    /// scroll asked for inside a layout pass can be lost, and a height
    /// change can swing the lazy stack's estimate thousands of points and
    /// back within one. One for a burst of changes, at most 100 ms late
    /// while they keep coming, and none once you have taken the list.
    ///
    /// With no row made (or `byLastRow`, on opening): to the last row
    /// first, then the end marker. The marker sits outside the lazy rows,
    /// so a scroll to it, or an offset clamped to the end as the estimate
    /// shrinks, can leave the stack with no row made at the end: a blank
    /// list until a scroll by hand. A scroll to a row makes the stack make it.
    private func repin(_ proxy: ScrollViewProxy, byLastRow: Bool = false) {
        let request = tracking.ask(byLastRow: byLastRow)
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard let byLastRow = tracking.take(request) else { return }
            let latest = tracking.request
            guard following, !userScrolling else { return log("repin skipped") }
            if byLastRow, let last = rows.last?.id, tracking.lastRowTries < ListTracking.lastRowLimit {
                if tracking.made.isEmpty { tracking.lastRowTries += 1 }
                log("place: repin scrollTo last row")
                proxy.scrollTo(last, anchor: .bottom)
                // A frame for it to land before the marker below it; a
                // request since (its own resize, a new message) goes instead.
                try? await Task.sleep(for: .milliseconds(20))
                guard tracking.request == latest, rows.last?.id == last, following, !userScrolling else {
                    return log("repin skipped")
                }
            }
            if !atEnd { pinning = true }
            log("place: repin scrollTo bottom atEnd=\(atEnd)")
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    /// Only the chat's own list releases the hold (threads share its marker
    /// but not its scroll position).
    private func reachedBottom() {
        dividerUnread = false
        if composer.thread == nil, let chat = composer.chat { model.reachedBottom(of: chat) }
    }

    /// The model's focused message, if it belongs in this list: scrolled
    /// to and lit (or its thread opened, whose list then takes it).
    private func takeFocus(_ proxy: ScrollViewProxy) {
        guard let target = focusTarget else { return }
        log("focus target \(index(of: target.message))")
        if go(to: target.message, proxy: proxy) {
            model.focus = nil
            return
        }
        // Not here though within what is loaded, and no thread to look in:
        // give up rather than hold it. Older: the longer timeline is coming.
        let loadedFrom = rows.first?.date ?? .distantPast
        if target.message.date >= loadedFrom, composer.thread != nil || target.message.threadUUID == nil {
            model.focus = nil
        }
    }

    /// The model's focused message, when it belongs in this list.
    private var focusTarget: FocusTarget? {
        guard let target = model.focus, target.message.chat == composer.chat,
              composer.thread.map({ $0 == target.message.threadRoot }) ?? !target.inThread,
              !rows.isEmpty else { return nil }
        return target
    }

    /// From a quote (or `takeFocus`) to a message: scrolled to and lit if it
    /// is here, its thread opened if a thread has folded it away. Returns
    /// whether it was here.
    @discardableResult
    private func go(to parent: Message, proxy: ScrollViewProxy) -> Bool {
        let uuid = parent.uuid
        if let row = rows.first(where: { $0.holds(uuid) }) {
            following = false
            log("place: go(to:) scrollTo row \(index(of: row.id))")
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(row.id, anchor: .center)
            } completion: {
                // It may not have moved (a row already at the bottom), so no
                // phase change says it is still.
                settled()
            }
            flashed = row.id
            Task {
                // Lit, then fading out as it settles.
                try? await Task.sleep(for: .seconds(0.4))
                if flashed == row.id { withAnimation(.easeOut(duration: 1.5)) { flashed = nil } }
            }
            return true
        } else if composer.thread == nil, parent.threadUUID != nil {
            // The thread's list scrolls to it and lights it.
            withAnimation(.easeOut(duration: 0.2)) { model.focus(on: parent, inThread: true) }
        }
        return false
    }

    // MARK: Timeline log (`TimelineLog`; nothing is built while it is off)

    /// One line: the event, then the list's own state.
    private func log(_ event: @autoclosure () -> String) {
        TimelineLog.log("\(TimelineLog.tag(composer)) \(event()) | rows=\(rows.count) atBottom=\(bottom.atBottom) "
            + "atEnd=\(atEnd) following=\(following) opening=\(opening) pinning=\(pinning) phase=\(phase) "
            + "realised=\(tracking.made.count)")
    }

    /// A row's place in the list, never its id (a message's uuid).
    private func index(of id: String) -> String {
        rows.firstIndex { $0.id == id }.map { "\($0)" } ?? "absent"
    }

    private func index(of message: Message) -> String {
        rows.firstIndex { $0.holds(message.uuid) }.map { "\($0)" } ?? "absent"
    }

    /// Not while scrolled by hand, which would be a line a frame.
    private func logGeometry(_ geometry: ScrollGeometry) {
        guard !userScrolling else { return }
        let below = geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
        log("geometry offset=\(TimelineLog.points(geometry.contentOffset.y)) "
            + "content=\(TimelineLog.points(geometry.contentSize.height)) "
            + "container=\(TimelineLog.points(geometry.containerSize.height)) below=\(TimelineLog.points(below)) "
            + "insets=\(TimelineLog.points(geometry.contentInsets.top))/\(TimelineLog.points(geometry.contentInsets.bottom))")
    }

    /// The first and last rows in view, by index; none in view with rows
    /// to show is the blank list.
    private func logVisible(_ ids: [String]) {
        let positions = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A day divider shares its row's id.
        let shown = Set(ids.compactMap { positions[$0] })
        if let first = shown.min(), let last = shown.max() {
            log("visible rows \(first)...\(last) (\(shown.count))")
        } else {
            log(rows.isEmpty ? "visible none, no rows" : "visible NONE with rows: blank")
        }
    }
}

/// What a `MessageList` keeps outside SwiftUI's observation, so writing
/// it redraws nothing: the rows made and the re-pin's requests.
@MainActor private final class ListTracking {
    /// The rows the lazy stack has made (appeared, not yet gone), by id, so
    /// an appear or disappear twice cannot skew it: none with rows to show
    /// is the blank list.
    var made: Set<String> = []
    /// Scrolls to the last row with none made since a row was made or you
    /// took the list; a stack that never makes one is left after
    /// `lastRowLimit`, not scrolled every few frames.
    var lastRowTries = 0
    static let lastRowLimit = 3
    /// The latest re-pin asked for, when the oldest still waiting was asked
    /// for, and whether any of them goes by the last row.
    private(set) var request = 0
    private var waitingSince: ContinuousClock.Instant?
    private var byLastRow = false

    func appeared(_ id: String) {
        made.insert(id)
        lastRowTries = 0
    }

    /// A re-pin asked for; returns its number.
    func ask(byLastRow: Bool) -> Int {
        request &+= 1
        if byLastRow { self.byLastRow = true }
        if waitingSince == nil { waitingSince = .now }
        return request
    }

    /// Whether `request` runs now, and if so whether by the last row: the
    /// latest one, or any once requests have kept coming for 100 ms.
    func take(_ request: Int) -> Bool? {
        guard let since = waitingSince,
              request == self.request || ContinuousClock.now - since >= .milliseconds(100) else { return nil }
        defer {
            waitingSince = nil
            byLastRow = false
        }
        return byLastRow || made.isEmpty
    }
}

/// "To the newest" over a list scrolled up: a round arrow, or once messages
/// have come in below, a blue "3 new messages" pill. End or Command-Down
/// does the same.
private struct JumpToNewestButton: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let composer: ComposerID
    let action: () -> Void

    /// On the chat's own list only, and not over a draft, where End and
    /// Command-Down move the cursor. Read here so typing redraws only this.
    private var shortcuts: Bool {
        composer.thread == nil && (model.drafts[composer] ?? "").isEmpty
    }

    private var newMessages: String {
        Formatting.count(count, "new message", shown: Badge.text(count))
    }

    var body: some View {
        Button(action: action) {
            if count > 0 {
                // Blue, because blue is unread.
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(newMessages)
                        .font(Theme.font(12, .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.buttonText)
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 32)
                .background(Theme.button, in: Capsule())
                .shadow(color: Theme.menuShadow, radius: 10, y: 4)
                .contentShape(Capsule())
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36)
                    .menuBoxed(in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help("Jump to newest (End)")
        .accessibilityLabel(count > 0 ? "Jump to newest, \(newMessages)" : "Jump to newest")
        // Shortcuts, only while the button shows.
        .hiddenShortcut(KeyboardShortcut(.end, modifiers: []), enabled: shortcuts, action: action)
        .hiddenShortcut(KeyboardShortcut(.downArrow, modifiers: .command), enabled: shortcuts, action: action)
    }
}

/// In place of a quote or a thread's original that is not stored here.
struct OriginalNotAvailable: View {

    var body: some View {
        Text("Original message not available")
            .muted()
            .italic()
    }
}

/// "5 replies" with a line, between a thread's original and its replies.
struct RepliesDivider: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(count == 0 ? "No replies yet" : Formatting.replies(count))
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
            Theme.divider.frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}


/// One message as a flat row (Tom, 2026-10-07: "try it out"): no bubbles.
/// The first of a run shows the sender's photo, name and time once; the
/// rest of the run sits under it, with its time in the left gutter on
/// hover. Yours are left-aligned too, on a faint accent tint. Hovering shows
/// Reply and More at the row's top-right, as in Slack; right-click opens the
/// same menu as More. `Equatable`, so a row whose `ChatRow` did not change
/// is not drawn again when the list is.
struct MessageRow: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    let row: ChatRow
    let composer: ComposerID
    var flashed = false

    @State private var hovering = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.composer == b.composer && a.flashed == b.flashed
    }

    static let avatarSize = Theme.AvatarSize.lg
    static let gutterSpacing: CGFloat = 10
    /// About 68 characters of 14 pt text: lines short enough to read.
    static let textWidth: CGFloat = 560

    private var message: Message { row.message }

    var body: some View {
        // A pending send becomes retryable after a timeout, with no change to
        // the row itself, so those rows redraw once when it passes.
        if message.delivery == .pending {
            TimelineView(.redrawing(at: message.date.addingTimeInterval(Message.confirmationTimeout + 0.5))) { context in
                content(now: context.date)
            }
        } else {
            content(now: .now)
        }
    }

    private func content(now: Date) -> some View {
        let retryable = message.isRetryable(now: now)
        let uploading = message.fromMe && message.uploadState == .pending
        let menuOpen = presenter?.isOpen == true
        let openThread = row.summary.map { model.openThread == ThreadRef(chat: $0.chat, uuid: $0.uuid) } ?? false
        return HStack(alignment: .top, spacing: Self.gutterSpacing) {
            // The gutter: the photo on a run's first row, the time on hover after it.
            Group {
                if row.startsRun {
                    Avatar(name: row.sender.avatarName, url: row.sender.photoURL, size: Self.avatarSize,
                           hue: row.sender.hue)
                        .personCard(PersonRef(row))
                } else {
                    Text(Formatting.time(message.date))
                        .font(Theme.font(11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .opacity(hovering ? 1 : 0)
                        .padding(.top, 3)
                        .help(model.timeTooltip(message.date, zone: row.senderZone, name: row.sender.name) ?? "")
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Self.avatarSize, alignment: row.startsRun ? .center : .trailing)
            VStack(alignment: .leading, spacing: 3) {
                if row.startsRun {
                    RunHeader(row: row)
                }
                MessageContent(
                    row: row,
                    menu: { MessageMenu.entries(for: row, composer: composer, model: model, offersBoost: row.canBoost) },
                    tileMenu: { image in
                        var single = row
                        single.message = image
                        single.images = []
                        return MessageMenu.entries(for: single, composer: composer, model: model)
                    }
                )
                .opacity(message.isSending(now: now) ? 0.6 : 1)
                if let boosts = row.boosts {
                    BoostLine(boosts: boosts, chat: message.chat, inTribe: row.inTribe, showsChip: !message.deleted)
                }
                if let summary = row.summary {
                    ThreadSummaryLine(summary: summary, inTribe: row.inTribe)
                }
                if retryable {
                    UndeliveredActions(message: message)
                } else if message.delivery == .pending, message.mayHavePaid {
                    WaitingForServer(since: message.date, what: message.type == MessageType.call ? "Call" : "Message")
                }
            }
            .frame(maxWidth: Self.textWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xl)
        // Inside a run, 5 pt between messages: more than a message's 3 pt
        // line spacing, so two read as two (design README, Flat rows).
        .padding(.top, row.startsRun ? 8 : 3)
        .padding(.bottom, row.endsRun ? 4 : 2)
        .rowChrome(row, lit: flashed || openThread, hovering: hovering)
        // At the row's top-right, overlapping its top edge as Slack's does;
        // never over the text, which stops well short of the right edge.
        // Kept while this row's menu is open: its More is what the menu
        // follows as the list moves.
        .overlay(alignment: .topTrailing) {
            if (hovering && !menuOpen) || presenter?.source == AnyHashable(row.id), !retryable, !uploading, !message.deleted {
                HoverBar(row: row, composer: composer)
                    .padding(.trailing, Theme.Space.xl)
                    .offset(y: -10)
            }
        }
        .zIndex(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension Message {
    /// Ours on its way: faint until the server has it, unless it may be
    /// sent again or is still uploading (those show why instead).
    func isSending(now: Date = .now) -> Bool {
        delivery == .pending && !isRetryable(now: now) && !(fromMe && uploadState == .pending)
    }
}

/// What every chat row (messages, payments, payment requests) draws behind
/// itself: lit while `lit` or while its menu is open, else the hover, else
/// yours on a faint accent tint.
private struct RowChrome: ViewModifier {
    @Environment(\.menuPresenter) private var presenter
    /// The row's menu source; nil for a row with no menu (the agent chat's).
    let id: String?
    let fromMe: Bool
    let lit: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content.background {
            if lit || id.map({ presenter?.source == AnyHashable($0) }) == true {
                Theme.selection.opacity(0.45)
            } else if hovering {
                Theme.hover.opacity(0.55)
            } else if fromMe {
                Theme.accent.opacity(0.06)
            }
        }
    }
}

extension View {
    /// The row's chrome (`RowChrome`): `lit` while flashed, or for its open thread.
    func rowChrome(_ row: ChatRow, lit: Bool, hovering: Bool) -> some View {
        rowChrome(id: row.id, fromMe: row.message.fromMe, lit: lit, hovering: hovering)
    }

    func rowChrome(id: String?, fromMe: Bool, lit: Bool = false, hovering: Bool) -> some View {
        modifier(RowChrome(id: id, fromMe: fromMe, lit: lit, hovering: hovering))
    }
}

/// A run's header: the sender's name (or a payment's `headline` in its
/// place), the time and, for yours, the green bolt once the server has it.
/// Someone whose offset was not yours gets their local time after yours
/// ("20:05 · 14:05 local"), dropped rather than wrapped when the header
/// would not fit on one line.
struct RunHeader: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    var headline: Text?

    var body: some View {
        // The time the header shows (an image run's newest), in their zone.
        let date = row.message.date
        let name = row.sender.name
        let person = PersonRef(row)
        let tooltip = model.timeTooltip(date, zone: row.senderZone, name: name)
            ?? Formatting.moment(date)
        if let zone = row.senderZone, model.difference(zone, at: date) != 0 {
            ViewThatFits(in: .horizontal) {
                line(name, person, tooltip) { RunLocalTime(date: date, zone: zone, name: name) }
                line(name, person, tooltip) { EmptyView() }
            }
        } else {
            line(name, person, tooltip) { EmptyView() }
        }
    }

    private func line(
        _ name: String, _ person: PersonRef?, _ tooltip: String, @ViewBuilder local: () -> some View
    ) -> some View {
        let message = row.message
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let headline {
                headline
            } else {
                Text(name)
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(row.sender.hue.name)
                    .lineLimit(1)
                    .personCard(person)
            }
            Text(Formatting.time(message.date))
                .monospacedDigit()
                .muted()
                .help(tooltip)
            local()
            if message.fromMe, message.delivery == .delivered {
                DeliveredBolt()
            }
        }
    }
}

/// The green bolt after the time on a delivered message of ours, in a
/// `.firstTextBaseline` row. A symbol sits on the baseline like text of its
/// own (smaller) size, so it would ride low; its centre goes to the middle
/// of the time's capitals and digits instead, from that font's own metrics.
struct DeliveredBolt: View {
    /// The time's font beside it, `Theme.font(12)`.
    private static let timeCapHeight = NSFont.systemFont(ofSize: 12).capHeight

    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 9))
            .foregroundStyle(Theme.confirmed)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.timeCapHeight / 2 }
            .help("Delivered")
    }
}

/// Reply, Boost and More, over a hovered row's top-right corner.
private struct HoverBar: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    let composer: ComposerID

    var body: some View {
        let message = row.message
        HStack(spacing: 0) {
            if message.isLinkable(inTribe: row.inTribe) {
                IconButton("arrowshape.turn.up.left", help: "Reply (R)") {
                    withAnimation(.easeOut(duration: 0.2)) { model.startReply(to: message, from: composer) }
                }
            }
            if row.canBoost {
                // One tap boosts with the boost amount (Account sets it).
                IconButton("bolt", help: model.quickBoostLabel) {
                    Task { await model.quickBoost(message) }
                }
            }
            if !message.deleted {
                MenuButton(systemImage: "ellipsis", help: "More", source: row.id) {
                    MessageMenu.entries(for: row, composer: composer, model: model, offersBoost: row.canBoost)
                }
            }
        }
        .padding(2)
        .menuBoxed(cornerRadius: Theme.Radius.control, shadow: false)
    }
}

/// What a message's menu offers. Undelivered: Retry and Discard. Otherwise
/// Reply, Boost (`offersBoost`: someone else's message not yet boosted), copying,
/// saving an attachment, and for a tribe's owner, pinning (the Mac app lets
/// only the owner pin).
@MainActor
enum MessageMenu {
    static func entries(
        for row: ChatRow, composer: ComposerID, model: AppModel, offersBoost: Bool = false
    ) -> [MenuEntry] {
        let message = row.message
        var copy: [MenuEntry] = []
        if let call = row.call {
            copy = CallCard.menuEntries(call)
        } else if let text = message.shownText.nilIfEmpty {
            copy.append(.copyText(text))
        }
        // A run of images: what acts on one image is on that tile's own menu.
        let oneMessage = row.images.count < 2
        var file: [MenuEntry] = []
        if oneMessage, message.attachmentKind != nil, message.uploadState != .pending {
            if message.attachmentKind == .image, let id = message.id, model.attachment(id).file != nil {
                file.append(.copy("Copy image", systemImage: "photo") { model.copyImage(message) })
            }
            file.append(.button("Save as…", systemImage: "square.and.arrow.down") { Task { await model.save(message) } })
        }
        if message.isRetryable() {
            return .sections(
                [
                    .button(message.uploadState == .failed ? "Retry upload" : "Retry sending",
                            systemImage: "arrow.clockwise") { Task { await model.resend(message) } },
                    .destructive("Discard", systemImage: "xmark", confirm: "Discard, never sent") {
                        Task { await model.discard(message) }
                    },
                ],
                copy
            )
        }
        var reply: [MenuEntry] = []
        if message.isLinkable(inTribe: row.inTribe) {
            reply.append(.button("Reply", systemImage: "arrowshape.turn.up.left", shortcut: .key("r")) {
                withAnimation(.easeOut(duration: 0.2)) { model.startReply(to: message, from: composer) }
            })
        }
        if offersBoost {
            reply.append(.button(model.quickBoostLabel, systemImage: "bolt.fill",
                                 shortcut: .key("b")) { Task { await model.quickBoost(message) } })
        }
        var pin: [MenuEntry] = []
        if let tribe = model.tribes[message.chat], tribe.canManage, message.isPinnable {
            if tribe.pin == message.uuid {
                pin.append(.button("Unpin from top of tribe", systemImage: "pin.slash") {
                    Task { await model.pin(nil, in: tribe.pubkey) }
                })
            } else {
                pin.append(.button("Pin to top of tribe", systemImage: "pin") {
                    Task { await model.pin(message.uuid, in: tribe.pubkey) }
                })
            }
        }
        var unread: [MenuEntry] = []
        if !message.fromMe, message.isSaid, !message.deleted, message.serverIndex != nil {
            // A run of images: from its first.
            let first = row.images.first ?? message
            unread.append(.button("Mark unread from here", systemImage: "envelope.badge") {
                Task { await model.markUnread(first.chat, from: first) }
            })
        }
        var delete: [MenuEntry] = []
        if oneMessage, model.canDelete(message, inTribe: row.inTribe) {
            delete.append(.destructive("Delete", systemImage: "trash", confirm: "Delete for everyone") {
                Task { await model.delete(message) }
            })
        }
        return .sections(reply, copy + file, unread, pin, delete)
    }
}

/// A message's body on the row: the quote, the attachment, then the text.
struct MessageContent: View {
    let row: ChatRow

    /// The row's menu, on everything but a run's image tiles, which each
    /// have their own (`tileMenu`), so an image is saved or deleted by itself.
    var menu: (@MainActor () -> [MenuEntry])?
    var tileMenu: (@MainActor (Message) -> [MenuEntry])?

    var body: some View {
        let message = row.message
        let text = row.card?.text ?? message.shownText
        if message.deleted {
            Label("This message has been deleted", systemImage: "trash")
                .font(Theme.font(13))
                .italic()
                .foregroundStyle(Theme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let quote = row.quote {
                    QuoteView(quote: quote)
                        .rowMenu(row.id, menu)
                }
                if let giphy = row.giphy {
                    GiphyTile(giphy: giphy).rowMenu(row.id, menu)
                }
                if message.attachmentKind != nil {
                    if row.images.count > 1 {
                        AttachmentView(row: row, tileMenu: tileMenu)
                    } else {
                        AttachmentView(row: row).rowMenu(row.id, menu)
                    }
                }
                if let call = row.call {
                    CallCard(row: row, link: call)
                        .rowMenu(row.id, menu)
                } else if !text.isEmpty {
                    MessageText(text: text, chat: message.chat)
                        .rowMenu(row.id, menu)
                }
                // The card's menu copies the link it took from the text.
                switch row.card?.link {
                case .tribe(let link): TribeLinkCard(link: link).rowMenu(row.id, menu)
                case .contact(let info): ContactLinkCard(info: info).rowMenu(row.id, menu)
                case nil: EmptyView()
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder func rowMenu(_ source: String, _ entries: (@MainActor () -> [MenuEntry])?) -> some View {
        if let entries { peelMenu(source: source, entries) } else { self }
    }
}

/// Message text as `MessageMarkup` reads it: links, mentions, inline code
/// and emphasis marked, list items with a hanging indent, headings larger,
/// quotes behind a bar, ``` blocks as code. Its own view, so hovering the
/// row does not redo the parsing.
struct MessageText: View {
    @Environment(AppModel.self) private var model
    let text: String
    /// Where it was said, for what a mention of you looks like there; nil
    /// in the agent chat.
    let chat: String?
    /// The agent's reply: its links to messages open them (`LinkText`).
    var agentLinks = false

    var body: some View {
        let blocks = MessageMarkup.blocks(text)
        let myAliases = chat.map(model.mentionAliases(in:)) ?? []
        let found = model.search.flatMap { chat != nil && $0.chat == chat ? $0.query?.terms : nil } ?? []
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    styled(line, myAliases, found)
                case .item(let line):
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text("•").foregroundStyle(Theme.secondaryText)
                        styled(line, myAliases, found)
                    }
                    .padding(.leading, Theme.Space.xs)
                case .numbered(let number, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).")
                            .font(Theme.font(14))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                        styled(line, myAliases, found)
                    }
                    .padding(.leading, Theme.Space.xs)
                case .heading(let level, let line):
                    styled(line, myAliases, found, font: Theme.font(level == 1 ? 20 : level == 2 ? 17 : 15, .semibold))
                        .padding(.top, 2)
                case .quote(let line):
                    styled(line, myAliases, found)
                        .padding(.leading, Theme.Space.md)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(width: 3)
                        }
                case .code(let code):
                    Text(AttributedString(code).highlighting(found))
                        .font(Theme.code(13))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
        }
    }

    /// A line of text, with what the chat's search `found` lit.
    private func styled(_ line: String, _ myAliases: Set<String>, _ found: [String],
                        font: Font = Theme.font(14)) -> some View {
        Text(LinkText.attributed(line, myAliases: myAliases, agentLinks: agentLinks).highlighting(found))
            .font(font)
            .lineSpacing(3)
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The message a reply answers: who and what, one line, with a small image
/// or file mark for an attachment. Click to go to it.
struct QuoteView: View {
    @Environment(\.goToMessage) private var goTo
    let quote: Quote

    var body: some View {
        switch quote {
        case .missing:
            OriginalNotAvailable()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.quote, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        case .message(let parent, let sender):
            Button { goTo(parent) } label: {
                HStack(spacing: Theme.Space.sm) {
                    if parent.attachmentKind != nil {
                        AttachmentMark(message: parent, size: 32)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sender.label)
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(sender.hue.name)
                        Text(parent.preview)
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.quote, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to message")
        }
    }
}
