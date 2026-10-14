import PeelCore
import PeelUI
import SwiftUI

/// A conversation's or a thread's rows, newest at the bottom, as the
/// Mac's `MessageList` places them: a chat opens at "New messages" when it
/// has one, else at its newest; others' messages take it down only while
/// it is at the bottom (yours always do); scrolled up, what arrives below
/// is counted on the "N new messages" pill (`ListBottom`). Near the top a
/// chat asks the model for an older page (`loadOlder`). The keyboard goes
/// down with a drag down the list.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    let rows: [ChatRow]
    let composer: ComposerID

    @State private var position = ScrollPosition(idType: String.self)
    @State private var phase = ScrollPhase.idle
    /// Others' messages take the list down while it is at the bottom or on
    /// its way there, until you scroll away or it opens at "New messages".
    @State private var following = true
    @State private var farFromBottom = false
    /// "New messages" still marks what is unread below it.
    @State private var dividerUnread = false
    @State private var bottom = ListBottom()
    @State private var opening = true
    /// A row just gone to from a quote or a jump, lit for a moment.
    @State private var flashed: String?

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
                    .id(row.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, Theme.Space.sm)
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
        .onChange(of: model.focus?.message.id) { _, _ in takeFocus() }
        .onChange(of: divider?.id) { _, id in if id != nil { dividerUnread = true } }
        // Yours always take you to the newest; others' only while following.
        .onChange(of: rows.last?.id) { _, _ in
            guard reachesNewest, !opening else { return }
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
    }

    // MARK: Placing it

    /// At "New messages" (a chat with something unread), at a message
    /// asked for, else at the newest (the initial anchor's job).
    private func open() {
        Task {
            // The lazy stack lays out its estimate first; place it after.
            try? await Task.sleep(for: .milliseconds(80))
            if focusTarget != nil {
                takeFocus()
            } else if let divider {
                following = false
                dividerUnread = true
                position.scrollTo(id: divider.id, anchor: .top)
            } else if !isThread {
                keepLastRowInView()
            }
            try? await Task.sleep(for: .milliseconds(120))
            opening = false
            settled()
        }
    }

    private func moved(_ edges: Edges) {
        if edges.nearTop, !isThread, !opening { model.loadOlder() }
        var bottom = self.bottom
        if reachesNewest {
            bottom.report(atBottom: edges.atBottom, settled: !opening && phase == .idle, newest: newestIndex)
        }
        switch bottom.cross(atBottom: edges.atBottom) {
        case .reached:
            if userScrolling, reachesNewest { reachedBottom() }
            if reachesNewest { following = true }
            if !isThread, reachesNewest || userScrolling { model.chatListAtBottom() }
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

    /// Still at the bottom after opening or a scroll: all of it was seen.
    private func settled() {
        guard !opening, bottom.atBottom, phase == .idle else { return }
        var bottom = self.bottom
        bottom.report(atBottom: true, settled: true, newest: newestIndex)
        if bottom != self.bottom { self.bottom = bottom }
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
        withAnimation(.easeOut(duration: 0.25)) { keepLastRowInView() }
    }

    private func jumpToNewest() {
        if reachesNewest { scrollToNewest() } else { model.showNewest() }
        reachedBottom()
    }

    private func reachedBottom() {
        dividerUnread = false
        if !isThread, let chat = composer.chat { model.reachedBottom(of: chat) }
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
        guard let target = model.focus, target.message.chat == composer.chat,
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
            flashed = row.id
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                if flashed == row.id { withAnimation(.easeOut(duration: 1.2)) { flashed = nil } }
            }
            return true
        } else if !isThread, message.threadUUID != nil {
            model.focus(on: message, inThread: true)
        }
        return false
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
