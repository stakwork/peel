import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// The list controller's state machine (`ChatListController`, T1–T27 in
/// `docs/reviews/2026-10-14-message-lists.md`): where a list opens, what
/// follows, what holds, the pill and jumps, against a fake engine and store.
@MainActor
struct ChatListControllerTests {
    private final class FakeEngine: ChatListEngine {
        var moves: [ListMove] = []
        var flashed: [String] = []
        var reveals = 0
        /// Each row's top below the view's, as measured.
        var tops: [String: Double] = [:]

        func move(_ move: ListMove) { moves.append(move) }
        func flash(_ id: String) { flashed.append(id) }
        func reveal() { reveals += 1 }
        func top(of id: String) -> Double? { tops[id] }
    }

    /// As `AppModel` keeps them: per list, and "New messages" opening the
    /// chat's list until it has stood at its newest.
    private final class FakeStore: ListAnchorStore {
        var anchors: [ComposerID: ListAnchor] = [:]
        var newMessages = false

        func anchor(of list: ComposerID) -> ListAnchor? { anchors[list] }
        func keep(_ anchor: ListAnchor, of list: ComposerID) {
            anchors[list] = anchor
            if anchor == .newest, list.thread == nil { newMessages = false }
        }
        func opensAtNewMessages(in list: ComposerID) -> Bool { list.thread == nil && newMessages }
    }

    private static let chat = ComposerID.chat(dm)
    private static let thread = ComposerID.thread(ThreadRef(chat: dm, uuid: uuid(900)))

    private let engine = FakeEngine()
    private let store = FakeStore()

    private func controller(_ list: ComposerID = chat) -> ChatListController {
        let controller = ChatListController(list: list, store: store)
        controller.engine = engine
        return controller
    }

    private func message(_ n: Int, fromMe: Bool = false, thread: String? = nil) -> Message {
        var message = Message.fixture(uuid: uuid(n), serverIndex: Int64(n), fromMe: fromMe, content: "m\(n)",
                                      timestamp: Int64(n) * 1_000, threadUUID: thread)
        message.id = Int64(n) + 1
        return message
    }

    private func row(_ n: Int, own: Bool = false, anchors: Bool = true) -> ChatListRow {
        let shown = message(n, fromMe: own)
        return ChatListRow(id: "m\(n)", canAnchor: anchors, isOwn: own, shown: [shown], holds: [uuid(n)], date: shown.date)
    }

    private func content(_ range: ClosedRange<Int>, divider: Int? = nil, reachesNewest: Bool = true,
                         hasOlder: Bool = false, extra: [ChatListRow] = []) -> ListContent {
        ListContent(rows: range.map { row($0) } + extra, divider: divider.map { "m\($0)" },
                    reachesNewest: reachesNewest, hasOlder: hasOlder)
    }

    /// Rows `range` in view from the top, 40 pt apart, the first `first` below the top.
    private func view(_ range: ClosedRange<Int>, first: Double = 0, atBottom: Bool = false,
                      nearTop: Bool = false, far: Bool = false) -> ListViewport {
        ListViewport(visibleIDs: range.map { "m\($0)" }, visibleTops: range.map { first + Double($0 - range.lowerBound) * 40 },
                     atBottom: atBottom, nearTop: nearTop, far: far)
    }

    private func change(_ list: ChatListController, from old: ListContent, to new: ListContent) -> ListMove {
        let ids = new.rows.map(\.id).difference(from: old.rows.map(\.id)).inferringMoves()
        return list.contentWillChange(to: new, diff: ListDiff(ids))
    }

    /// Opened at the newest, then scrolled up by hand to its fourth row,
    /// 5 pt below the view's top.
    private func reading(_ list: ChatListController, _ rows: ListContent) {
        let first = Int(rows.rows[0].id.dropFirst())!
        _ = list.appear(rows)
        list.scrolled(view((first + 6)...(first + 9), atBottom: true))
        list.userScrollBegan()
        list.scrolled(view((first + 3)...(first + 6), first: 5, far: true))
        list.userScrollEnded(view((first + 3)...(first + 6), first: 5, far: true))
    }

    // 1
    @Test func opensAtFocusThenSavedRowThenDividerThenNewest() {
        store.newMessages = true
        store.anchors[Self.chat] = .row(id: "m3", offset: 12)
        let rows = content(0...9, divider: 8)
        var jumped = false
        let focused = controller()
        focused.onJumped = { jumped = true }
        #expect(focused.appear(rows, focus: uuid(5)) == ListMove(to: .center(id: "m5")))
        #expect(engine.flashed == ["m5"] && jumped)
        #expect(controller().appear(rows) == ListMove(to: .row(id: "m3", offset: 12)))
        store.anchors[Self.chat] = .newest
        #expect(controller().appear(rows) == ListMove(to: .row(id: "m8", offset: 0)))
        store.newMessages = false
        #expect(controller().appear(rows) == ListMove(to: .newest))
        store.anchors = [:]
        #expect(controller().appear(rows) == ListMove(to: .newest))
    }

    /// Back to a chat left scrolled up while messages came: at the row you
    /// were reading, the pill counting what came below "New messages".
    @Test func returningScrolledUpWithNewMessagesOpensAtTheReadingRow() {
        store.newMessages = true
        store.anchors[Self.chat] = .row(id: "m3", offset: 12)
        let list = controller()
        #expect(list.appear(content(0...9, divider: 8)) == ListMove(to: .row(id: "m3", offset: 12)))
        list.scrolled(view(3...6, first: 12, far: true))
        #expect(list.pill == .count(2))
        #expect(!list.isFollowing)
    }

    /// Back to a chat left at its newest while messages came: at "New messages".
    @Test func returningAtTheNewestWithNewMessagesOpensAtTheDivider() {
        store.newMessages = true
        store.anchors[Self.chat] = .newest
        #expect(controller().appear(content(0...9, divider: 8)) == ListMove(to: .row(id: "m8", offset: 0)))
    }

    /// A chat not opened before, with messages unread: at "New messages".
    @Test func aFirstVisitWithNewMessagesOpensAtTheDivider() {
        store.newMessages = true
        #expect(controller().appear(content(0...9, divider: 8)) == ListMove(to: .row(id: "m8", offset: 0)))
    }

    // 2
    @Test func aSavedRowNoLongerLoadedOpensAtTheNewest() {
        store.anchors[Self.chat] = .row(id: "m500", offset: 12)
        let list = controller()
        #expect(list.appear(content(0...9)) == ListMove(to: .newest))
        #expect(list.isFollowing)
    }

    // 3
    @Test func newMessagesRetiresOnceTheNewestIsKept() {
        store.newMessages = true
        let rows = content(0...9, divider: 7)
        let first = controller()
        #expect(first.appear(rows) == ListMove(to: .row(id: "m7", offset: 0)))
        first.scrolled(view(7...9))
        first.userScrollBegan()
        first.userScrollEnded(view(6...9, first: -10, atBottom: true))
        #expect(store.anchors[Self.chat] == .newest)
        #expect(controller().appear(rows) == ListMove(to: .newest))
    }

    // 4
    @Test func aThreadKeepsItsOwnPlaceAndNeverOpensAtTheChatsDivider() {
        store.newMessages = true
        store.anchors[Self.chat] = .row(id: "m3", offset: 0)
        let thread = controller(Self.thread)
        #expect(thread.appear(content(0...9, divider: 7)) == ListMove(to: .newest))
        thread.userScrollBegan()
        thread.userScrollEnded(view(2...5, first: 8, far: true))
        #expect(store.anchors[Self.thread] == .row(id: "m2", offset: 8))
        #expect(store.anchors[Self.chat] == .row(id: "m3", offset: 0))
    }

    // 5
    @Test func revealsExactlyOnce() {
        let list = controller()
        _ = list.appear(content(0...9))
        #expect(engine.reveals == 0)
        list.scrolled(view(6...9, atBottom: true))
        list.scrolled(view(5...9, atBottom: true))
        _ = change(list, from: content(0...9), to: content(0...10))
        list.scrolled(view(7...10, atBottom: true))
        #expect(engine.reveals == 1)
    }

    // 6
    @Test func othersArrivalFollowsWhileFollowingAndHoldsWhileReading() {
        let following = controller()
        _ = following.appear(content(0...9))
        following.scrolled(view(6...9, atBottom: true))
        #expect(change(following, from: content(0...9), to: content(0...10)) == ListMove(to: .newest, animated: true))

        let list = controller()
        reading(list, content(0...9))
        #expect(change(list, from: content(0...9), to: content(0...10)) == ListMove(to: .row(id: "m3", offset: 5)))
        list.scrolled(view(3...6, first: 5, far: true))
        #expect(list.pill == .count(1))
    }

    // 7
    @Test func yourArrivalInTheChatFollowsEvenWhileReading() {
        let list = controller()
        reading(list, content(0...9))
        let sent = ListContent(rows: content(0...9).rows + [row(10, own: true)])
        #expect(change(list, from: content(0...9), to: sent) == ListMove(to: .newest, animated: true))
        #expect(list.isFollowing)
    }

    /// A direct message's rows with a reply of yours in the thread `m0` started.
    private func replyRows() -> (chat: [ChatRow], thread: [ChatRow]) {
        let me = Sender(alias: "me", hue: PersonHue(pubkey: "me", alias: "me", inTribe: false), isMe: true)
        let people = ChatRow.People(me: me, contact: Sender(alias: "them", hue: PersonHue(pubkey: dm, alias: "them", inTribe: false)))
        let root = message(0)
        let reply = message(1, fromMe: true, thread: uuid(0))
        return (ChatRow.rows([root, reply], parents: [:], inTribe: false, people: people),
                ChatRow.rows([reply], parents: [:], inTribe: false, people: people, threadRoot: uuid(0), original: root))
    }

    // 8
    @Test func yourThreadReplyIsNotTheChatsArrival() {
        let rows = replyRows()
        #expect(rows.chat.last?.listRow(in: Self.chat).isOwn == false)
        let list = controller()
        let before = ListContent(Array(rows.chat.dropLast()), in: Self.chat, reachesNewest: true, hasOlder: false)
        let after = ListContent(rows.chat, in: Self.chat, reachesNewest: true, hasOlder: false)
        _ = list.appear(before)
        list.userScrollBegan()
        list.userScrollEnded(ListViewport(visibleIDs: [before.rows[0].id], visibleTops: [-10], atBottom: false))
        #expect(change(list, from: before, to: after) == ListMove(to: .row(id: before.rows[0].id, offset: -10)))
        #expect(!list.isFollowing)
    }

    // 9
    @Test func yourReplyInAThreadFollowsInTheThreadOnly() {
        let rows = replyRows()
        #expect(rows.thread.last?.listRow(in: Self.thread).isOwn == true)
        let thread = controller(Self.thread)
        let before = ListContent(Array(rows.thread.dropLast()), in: Self.thread, reachesNewest: true, hasOlder: false)
        let after = ListContent(rows.thread, in: Self.thread, reachesNewest: true, hasOlder: false)
        _ = thread.appear(before)
        thread.userScrollBegan()
        thread.userScrollEnded(ListViewport(visibleIDs: [before.rows[0].id], visibleTops: [-10], atBottom: false))
        #expect(change(thread, from: before, to: after) == ListMove(to: .newest, animated: true))
    }

    // 10
    @Test func aRowResortedToTheBottomWhileReadingMovesNothing() {
        let list = controller()
        reading(list, content(0...9))
        let resorted = ListContent(rows: (0...9).filter { $0 != 1 }.map { row($0) } + [row(1)])
        #expect(change(list, from: content(0...9), to: resorted) == ListMove(to: .row(id: "m3", offset: 5)))
    }

    /// A tribe's thread row you are reading, re-sorted to its newest reply
    /// by a reply: the list stays, the row below in its place.
    @Test func aReadingRowResortedToTheBottomHandsItsPlaceToTheRowBelow() {
        let list = controller()
        reading(list, content(0...9))
        let resorted = ListContent(rows: (0...9).filter { $0 != 3 }.map { row($0) } + [row(3)])
        #expect(change(list, from: content(0...9), to: resorted) == ListMove(to: .row(id: "m4", offset: 5)))
        #expect(list.placement == .row(id: "m4", offset: 5))
    }

    // 11
    @Test func aRowGrowingKeepsTheNewestUnanimatedOrTheReadingRow() {
        let following = controller()
        _ = following.appear(content(0...9))
        following.scrolled(view(6...9, atBottom: true))
        #expect(change(following, from: content(0...9), to: content(0...9)) == ListMove(to: .newest))
        let list = controller()
        reading(list, content(0...9))
        #expect(change(list, from: content(0...9), to: content(0...9)) == ListMove(to: .row(id: "m3", offset: 5)))
    }

    // 12
    @Test func aScrollByHandStopsFollowingEvenAtTheBottom() {
        let list = controller()
        _ = list.appear(content(0...9))
        list.scrolled(view(6...9, atBottom: true))
        #expect(list.isFollowing)
        list.userScrollBegan()
        #expect(!list.isFollowing)
    }

    // 13
    @Test func reachingTheBottomWithoutAHandDoesNotFollow() {
        let list = controller()
        var reached = 0
        list.onReachedBottom = { reached += 1 }
        reading(list, content(0...9))
        list.scrolled(view(6...9, atBottom: true))
        #expect(!list.isFollowing && reached == 0)
    }

    // 14
    @Test func aWindowsBottomGrowsTheWindowAndShowsPresent() {
        let list = controller()
        var grown = 0
        list.onListAtBottom = { grown += 1 }
        _ = list.appear(content(0...9, reachesNewest: false), focus: uuid(3))
        list.scrolled(view(2...5))
        #expect(list.pill == .present)
        list.userScrollBegan()
        list.scrolled(view(6...9, atBottom: true))
        list.userScrollEnded(view(6...9, atBottom: true))
        #expect(grown == 1 && !list.isFollowing && list.pill == .present)
    }

    // 15
    @Test func olderRowsAboveHoldTheReadingRow() {
        let list = controller()
        reading(list, content(100...109, hasOlder: true))
        let older = ListContent(rows: (0...109).map { row($0) }, hasOlder: true)
        #expect(change(list, from: content(100...109), to: older) == ListMove(to: .row(id: "m103", offset: 5)))
    }

    // 16
    @Test func aResizeHoldsWhatEachModeHolds() {
        let following = controller()
        _ = following.appear(content(0...9))
        following.scrolled(view(6...9, atBottom: true))
        #expect(following.placement == .newest)
        let list = controller()
        reading(list, content(0...9))
        #expect(list.placement == .row(id: "m3", offset: 5))
        list.jump(to: uuid(1))
        #expect(list.placement == .center(id: "m1"))
    }

    @Test func aScrollByHandHoldsWhereTheRowsAre() {
        let list = controller()
        _ = list.appear(content(0...9))
        list.scrolled(view(6...9, atBottom: true))
        #expect(list.placement == .newest)
        list.userScrollBegan()
        #expect(list.placement == .keep)
        list.phase(.decelerating)
        #expect(list.placement == .keep)
        list.userScrollEnded(view(3...6, first: 5, far: true))
        #expect(list.placement == .row(id: "m3", offset: 5))
    }

    // 17
    @Test func aDeletedReadingRowsPlaceGoesToItsNeighbourBelow() {
        let list = controller()
        reading(list, content(0...9))
        let deleted = ListContent(rows: (0...9).filter { $0 != 3 }.map { row($0) })
        #expect(change(list, from: content(0...9), to: deleted) == ListMove(to: .row(id: "m4", offset: 5)))
        // The last row that can hold the list: the one above stays where it is.
        let last = controller()
        reading(last, content(0...9))
        let rows = ListContent(rows: (0...3).map { row($0) } + (4...9).map { row($0, anchors: false) })
        _ = change(last, from: content(0...9), to: rows)
        last.scrolled(view(2...5, first: -35))
        let gone = ListContent(rows: (0...2).map { row($0) } + (4...9).map { row($0, anchors: false) })
        #expect(change(last, from: rows, to: gone) == ListMove(to: .row(id: "m2", offset: -35)))
    }

    /// In a tribe, the message you open a thread on folds into the thread's
    /// row at the newest once the thread has two replies. Reading at it,
    /// the row below takes its place: nothing above it moves.
    @Test func aReadingRowFoldedIntoItsThreadHandsItsPlaceToTheRowBelow() {
        let me = Sender(alias: "me", hue: PersonHue(pubkey: "me", alias: "me", inTribe: true), isMe: true)
        let people = ChatRow.People(me: me, contact: me)
        let posts = (0...5).map { message($0) }
        let first = message(6, fromMe: true, thread: uuid(3))
        let second = message(7, fromMe: true, thread: uuid(3))
        let summary = ThreadSummary(original: posts[3], count: 2, lastTimestamp: second.timestamp, unread: 0, latest: second)
        let before = ChatRow.rows(posts + [first], parents: [:], inTribe: true, people: people)
        let after = ChatRow.rows(posts.filter { $0.uuid != uuid(3) } + [second], threads: [uuid(3): summary],
                                 parents: [:], inTribe: true, people: people)
        #expect(after.last?.summary != nil)
        let old = ListContent(before, in: Self.chat, reachesNewest: true, hasOlder: false)
        let new = ListContent(after, in: Self.chat, reachesNewest: true, hasOlder: false)
        let list = controller()
        _ = list.appear(old)
        list.userScrollBegan()
        list.userScrollEnded(ListViewport(visibleIDs: before[2...5].map(\.id), visibleTops: [-30, 12, 54, 96], atBottom: false))
        #expect(change(list, from: old, to: new) == ListMove(to: .row(id: before[4].id, offset: 12)))
        #expect(!list.isFollowing)
    }

    // 18
    @Test func rowsThatCannotHoldTheListAreSkipped() {
        let rows = ListContent(rows: [row(0), row(1, anchors: false), row(2, anchors: false), row(3), row(4)])
        let list = controller()
        _ = list.appear(rows)
        list.userScrollBegan()
        list.userScrollEnded(view(1...4, first: 0, far: true))
        #expect(list.placement == .row(id: "m3", offset: 80))
        #expect(store.anchors[Self.chat] == .row(id: "m3", offset: 80))
    }

    // 19
    @Test func aJumpToARowHereCentresAndLightsIt() {
        let list = controller()
        reading(list, content(0...9))
        #expect(list.jump(to: uuid(1)) == .here)
        #expect(engine.moves.last == ListMove(to: .center(id: "m1"), animated: true))
        #expect(engine.flashed == ["m1"])
        #expect(list.placement == .center(id: "m1"))
    }

    // 20
    @Test func aJumpToARowNotHereWaitsForItsWindow() {
        let list = controller()
        _ = list.appear(content(100...109))
        list.scrolled(view(106...109, atBottom: true))
        #expect(list.jump(to: uuid(5), at: message(5).date) == .waitingForWindow)
        #expect(engine.moves.isEmpty && list.pendingJump == uuid(5))
        #expect(change(list, from: content(100...109), to: content(0...9, reachesNewest: false)) == ListMove(to: .center(id: "m5")))
        #expect(engine.flashed == ["m5"] && list.pendingJump == nil)
    }

    // 21
    @Test func jumpToPresentScrollsInsideTheNewestAndReloadsOutsideIt() {
        let inside = controller()
        var reloads = 0
        inside.onShowNewest = { reloads += 1 }
        reading(inside, content(0...9))
        inside.jumpToPresent()
        #expect(engine.moves.last == ListMove(to: .newest, animated: true) && reloads == 0 && inside.isFollowing)

        let outside = controller()
        outside.onShowNewest = { reloads += 1 }
        _ = outside.appear(content(0...9, reachesNewest: false))
        let moves = engine.moves.count
        outside.jumpToPresent()
        #expect(reloads == 1 && engine.moves.count == moves)
    }

    // 22
    @Test func markUnreadMarksWhatIsBelowTheLineUnread() {
        let list = controller()
        _ = list.appear(content(0...9))
        list.scrolled(view(6...9, atBottom: true))
        #expect(!list.dividerUnread)
        _ = change(list, from: content(0...9), to: content(0...9, divider: 4))
        #expect(list.dividerUnread)
    }

    // 23
    @Test func nearTheTopLoadsOlderOncePerPage() {
        let list = controller()
        var asked = 0
        list.onLoadOlder = { asked += 1 }
        reading(list, content(100...109, hasOlder: true))
        list.scrolled(view(100...103, nearTop: true, far: true))
        list.scrolled(view(100...103, first: 2, nearTop: true, far: true))
        #expect(asked == 1)
        let older = ListContent(rows: (50...109).map { row($0) }, hasOlder: true)
        _ = change(list, from: content(100...109, hasOlder: true), to: older)
        list.scrolled(view(50...53, nearTop: true, far: true))
        #expect(asked == 2)
        // A page that brought nothing and said there is no more; then more.
        let none = ListContent(rows: older.rows, hasOlder: false)
        _ = change(list, from: older, to: none)
        list.scrolled(view(50...53, nearTop: true, far: true))
        _ = change(list, from: none, to: older)
        list.scrolled(view(50...53, first: 1, nearTop: true, far: true))
        #expect(asked == 3)
    }

    @Test func aJumpToARowWhereTheRowsAreIsNotLoaded() {
        let list = controller()
        _ = list.appear(content(0...9))
        #expect(list.jump(to: uuid(500), at: message(5).date) == .notLoaded)
        #expect(list.jump(to: uuid(500)) == .notLoaded)
        #expect(list.outcome(of: uuid(5), at: nil) == .here)
    }

    @Test func aJumpFindsARowByTheUUIDsItHolds() {
        let rows = replyRows()
        let root = rows.chat.first { $0.kind == .message && $0.message.uuid == uuid(0) }
        #expect(root?.heldUUIDs.contains(uuid(0)) == true)
        #expect(root?.holds(uuid(0)) == true && root?.holds(nil) == false && root?.holds(uuid(77)) == false)
        for row in rows.chat + rows.thread {
            #expect(row.listRow(in: Self.chat).holds == row.heldUUIDs)
            if ![.message, .payment, .paymentRequest].contains(row.kind) { #expect(row.heldUUIDs.isEmpty) }
        }
    }

    // 25
    @Test func aListMadeAgainOpensWhereTheLastOneWasLeft() {
        let list = controller()
        reading(list, content(0...9))
        list.disappear()
        #expect(store.anchors[Self.chat] == .row(id: "m3", offset: 5))
        #expect(controller().appear(content(0...9)) == ListMove(to: .row(id: "m3", offset: 5)))
    }

    // MARK: The agent chat (section 7 of the design)

    /// The agent chat's rows as `AgentListRow` makes them: the intro, turns
    /// `range` (yours where `own` says), and the reply streaming, none of
    /// them but the turns holding the list, none counted by the pill.
    private func agent(_ range: ClosedRange<Int>, own: Set<Int> = [], reply: Bool = false) -> ListContent {
        ListContent(rows: [ChatListRow(id: "intro", canAnchor: false)]
            + range.map { ChatListRow(id: "m\($0)", isOwn: own.contains($0)) }
            + (reply ? [ChatListRow(id: "reply", canAnchor: false)] : []))
    }

    /// The agent list open at the newest, the reply in view at the bottom.
    private func agentFollowing(_ rows: ListContent) -> ChatListController {
        let list = controller(.agent)
        _ = list.appear(rows)
        list.scrolled(ListViewport(visibleIDs: ["m8", "m9", "reply"], visibleTops: [0, 40, 80], atBottom: true))
        return list
    }

    @Test func aStreamingReplyHoldsTheNewestUnanimatedWhileFollowing() {
        let streaming = agent(0...9, reply: true)
        let list = agentFollowing(streaming)
        for _ in 0..<5 {
            #expect(change(list, from: streaming, to: streaming) == ListMove(to: .newest, animated: false))
        }
        #expect(list.isFollowing)
    }

    @Test func oneWheelTickStopsFollowingAndTheReplyThenMovesNothing() {
        let streaming = agent(0...9, reply: true)
        let list = agentFollowing(streaming)
        list.userScrollBegan()
        let away = ListViewport(visibleIDs: ["m8", "m9", "reply"], visibleTops: [12, 52, 92], atBottom: false)
        list.userScrollEnded(away)
        #expect(!list.isFollowing)
        // The reply is never the reading row: the turn above it holds.
        for _ in 0..<5 {
            #expect(change(list, from: streaming, to: streaming) == ListMove(to: .row(id: "m8", offset: 12)))
        }
        // The reply ends as a turn of its own: an arrival, which holds too.
        #expect(change(list, from: streaming, to: agent(0...10)) == ListMove(to: .row(id: "m8", offset: 12)))
        #expect(!list.isFollowing)
    }

    @Test func theAgentFollowsAgainAtTheBottomByHandOrThePill() {
        let streaming = agent(0...9, reply: true)
        let byHand = agentFollowing(streaming)
        byHand.userScrollBegan()
        byHand.scrolled(ListViewport(visibleIDs: ["m8", "m9"], visibleTops: [12, 52], atBottom: false))
        byHand.userScrollEnded(ListViewport(visibleIDs: ["m9", "reply"], visibleTops: [0, 40], atBottom: true))
        #expect(byHand.isFollowing)
        #expect(change(byHand, from: streaming, to: streaming) == ListMove(to: .newest))

        let pill = agentFollowing(streaming)
        pill.userScrollBegan()
        pill.userScrollEnded(ListViewport(visibleIDs: ["m3", "m4"], visibleTops: [0, 40], atBottom: false, far: true))
        #expect(pill.pill == .arrow)
        pill.jumpToPresent()
        #expect(pill.isFollowing && engine.moves.last == ListMove(to: .newest, animated: true))
    }

    /// Saved, the reply keeps its row: a change in place, not an arrival,
    /// so it never asks for an animated move.
    @Test func aReplySavedInItsOwnRowIsNoArrival() {
        let streaming = agent(0...9, reply: true)
        let list = agentFollowing(streaming)
        var saved = streaming
        saved.rows[saved.rows.count - 1].canAnchor = true
        #expect(change(list, from: streaming, to: saved) == ListMove(to: .newest, animated: false))
    }

    @Test func yourMessageToTheAgentFollowsWhileReading() {
        let list = agentFollowing(agent(0...9))
        list.userScrollBegan()
        list.userScrollEnded(ListViewport(visibleIDs: ["m3", "m4"], visibleTops: [5, 45], atBottom: false, far: true))
        #expect(change(list, from: agent(0...9), to: agent(0...10, own: [10])) == ListMove(to: .newest, animated: true))
        #expect(list.isFollowing)
    }

    @Test func theAgentsPillIsAnArrowWithNoCount() {
        let list = agentFollowing(agent(0...9))
        list.userScrollBegan()
        list.userScrollEnded(ListViewport(visibleIDs: ["m3", "m4"], visibleTops: [5, 45], atBottom: false, far: true))
        _ = change(list, from: agent(0...9), to: agent(0...12))
        #expect(list.pill == .arrow)
    }

    // 24
    @Test func openingARowHoldsItsTopAndStopsFollowing() {
        let streaming = agent(0...9, reply: true)
        let list = agentFollowing(streaming)
        engine.tops["m9"] = 40
        list.userExpanded("m9")
        #expect(!list.isFollowing)
        // The row grows: its top stays, whatever else streams below.
        #expect(change(list, from: streaming, to: streaming) == ListMove(to: .row(id: "m9", offset: 40)))
        // A row not measured, or not here, changes nothing.
        let other = agentFollowing(streaming)
        other.userExpanded("m42")
        #expect(other.isFollowing)
    }

    @Test func anApprovalCardInPlaceOfAToolRowIsAResize() {
        let streaming = agent(0...9, reply: true)
        let following = agentFollowing(streaming)
        #expect(change(following, from: streaming, to: streaming) == ListMove(to: .newest))
        let reading = agentFollowing(streaming)
        reading.userScrollBegan()
        reading.userScrollEnded(ListViewport(visibleIDs: ["m4", "m5"], visibleTops: [-3, 37], atBottom: false))
        #expect(change(reading, from: streaming, to: streaming) == ListMove(to: .row(id: "m5", offset: 37)))
    }
}
