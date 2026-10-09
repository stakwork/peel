import SwiftUI
import PeelCore

/// Who sent something, as `ChatRow.People.sender(of:inTribe:)` names them:
/// you, the contact, or a tribe member by the alias they sent.
struct Sender: Equatable {
    /// What someone who sent no name is called, everywhere.
    static let unnamed = "Someone"

    /// The name they go by; nil when they sent none.
    var alias: String?
    var photoURL: String?
    /// Their colour, on their initials and name.
    var hue: PersonHue
    var isMe = false

    /// Their name as a run header shows it: yours is your alias.
    var name: String { alias ?? (isMe ? "You" : Self.unnamed) }
    /// As quotes and lists name them: you are "You".
    var label: String { isMe ? "You" : name }
    /// What their avatar's initials come from: "?" with no name.
    var avatarName: String { alias ?? "?" }
}

/// What a reply quotes: the parent and its sender, or a note that it is not here.
enum Quote: Equatable {
    case message(Message, Sender)
    /// The parent is older than this Mac's history, or the link is broken.
    case missing
}

/// One row of a conversation, worked out once per change in a single pass:
/// a message (or a run of one sender's images, or a collapsed thread), a
/// request to join, or a note; in a thread also its original and the
/// "N replies" line. Names and photos are decoded here, once per message.
struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case message, request, note
        /// Sats sent in a direct message (type 5).
        case payment
        /// A payment request with its invoice (type 2).
        case paymentRequest
        /// A thread's original that is not stored here.
        case missingOriginal
        /// "N replies" under a thread's original.
        case replies(Int)
    }

    let id: String
    var kind: Kind
    /// What actions act on: the newest of an image run, the original of a
    /// collapsed thread.
    var message: Message
    /// In a tribe: the member's name and photo show beside their messages.
    var inTribe: Bool
    /// A run of one sender's images (two or more), oldest first.
    var images: [Message] = []
    var summary: ThreadSummary?
    /// The boosts on `message` (the original, for a collapsed thread).
    var boosts: BoostSummary?
    /// Whether to offer Boost: someone else's boostable message we have not
    /// boosted yet (Tom, 2026-10-07; the official apps offer it again). Our
    /// failed boost on it offers Retry and Discard under it instead; the
    /// engine's `quickBoost` holds the same rule.
    var canBoost: Bool { message.isBoostable && boosts?.hasOwnBoost != true }
    var quote: Quote?
    /// For a request to join: whether the owner approved, once answered.
    var approved: Bool?
    /// For a payment request: its invoice and whether it is paid.
    var paymentRequest: PaymentRequest?
    /// For a paid attachment: locked, being bought, unlocked, or ours for sale.
    var purchase: PurchaseState?
    /// A call message (or text that is only a call link) that passed the
    /// checks against the account's call server: drawn as the call card.
    var call: CallLink?
    var sender: Sender
    /// In a tribe, someone else's alias as sent; nil in a direct message.
    var member: String? { inTribe && !sender.isMe ? sender.alias : nil }
    /// The sender's zone when they wrote it, if they shared one: the
    /// message's own offset, else the run's (`AppModel.withSenderZones`).
    /// Never for yours.
    var senderZone: TimeZone?
    /// The messages the row stands for, oldest first: a run's images, a
    /// collapsed thread's newest, else its own.
    var shown: [Message] {
        if let latest { return [latest] }
        return images.isEmpty ? [message] : images
    }

    /// Where the row sits in time: a collapsed thread at its newest message.
    var date: Date
    var startsDay = false
    /// "New messages" goes above this row: the first incoming one past the
    /// read marker the chat had when it was opened.
    var startsNew = false
    /// For a collapsed thread: its newest message, which placed the row.
    var latest: Message?
    var startsRun = false
    var endsRun = true

    /// Images sent within this long of each other, by one sender, share a grid.
    static let imageRunGap: TimeInterval = 60

    /// Who the rows name: you, and in a direct message the contact (a
    /// tribe's members name themselves on their messages).
    struct People {
        var me: Sender
        var contact: Sender

        /// The one way a message's sender is named: you, in a tribe the
        /// member (decoded from the message), else the contact.
        func sender(of message: Message, inTribe: Bool) -> Sender {
            if message.fromMe { return me }
            guard inTribe else { return contact }
            let details = message.senderDetails
            return Sender(alias: details.alias, photoURL: details.photoURL,
                          hue: PersonHue(pubkey: message.chat, alias: details.alias, inTribe: true))
        }
    }

    /// The rows of a chat (`threads` collapsed), or of a thread: with
    /// `threadRoot` set, its `original` (or a note that it is missing) and
    /// "N replies" come first. `newAfter` is the read marker that places "New messages".
    static func rows(
        _ messages: [Message], threads: [String: ThreadSummary] = [:], parents: [String: Message],
        boosts: [String: BoostSummary] = [:], requests: [Int64: PaymentRequest] = [:],
        purchases: [Int64: PurchaseState] = [:], inTribe: Bool, people: People, callServer: String? = nil,
        threadRoot: String? = nil, original: Message? = nil, newAfter: Int64? = nil
    ) -> [ChatRow] {
        var answers: [String: Bool] = [:]
        for message in messages where message.type == MessageType.memberApprove || message.type == MessageType.memberReject {
            if let request = message.replyUUID { answers[request] = message.type == MessageType.memberApprove }
        }
        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count + 2)
        // A thread's rows start with its original (or, when only its replies
        // are stored, a note in its place) and the reply count.
        if let threadRoot, let anchor = original ?? messages.first {
            rows.append(row(anchor, kind: original == nil ? .missingOriginal : .message, id: "o\(threadRoot)",
                            inTribe: inTribe, people: people))
            rows.append(row(anchor, kind: .replies(messages.count), id: "r\(threadRoot)", inTribe: inTribe, people: people))
        }
        var newAfter = newAfter
        for message in messages {
            // A collapsed thread's row stands for its newest message, which this is.
            let collapsed = message.standsForThread ? message.threadUUID.flatMap { threads[$0] } : nil
            // No row that would draw nothing (blank space under the last
            // row, Tom 2026-10-08), or only "Original message not
            // available": "New messages" goes to the next.
            if message.isBlank, collapsed == nil, message.uuid.flatMap({ boosts[$0] }) == nil,
               (quote(message, parents: parents, threadRoot: threadRoot, inTribe: inTribe, people: people) ?? .missing)
                == .missing { continue }
            // What counts as unread (`Storage.readStates`): text, attachments, payments.
            let startsNew = newAfter.map { message.countsAsUnread(after: $0) } ?? false
            if startsNew { newAfter = nil }
            if let summary = collapsed {
                var row = row(summary.original, kind: .message, id: "t\(summary.uuid)", inTribe: inTribe, people: people)
                row.startsNew = startsNew
                row.latest = message
                row.summary = summary
                row.date = message.date
                rows.append(row)
                continue
            }
            let kind: Kind = message.isSaid ? .message
                : message.type == MessageType.directPayment ? .payment
                : message.type == MessageType.invoice ? .paymentRequest
                : message.type == MessageType.memberRequest && !message.fromMe ? .request : .note
            var row = row(message, kind: kind, id: "m\(message.id ?? 0)", inTribe: inTribe, people: people)
            if kind == .message, !startsNew, let last = rows.last, last.takes(message, sender: row.sender) {
                rows[rows.count - 1].images = (last.images.isEmpty ? [last.message] : last.images) + [message]
                rows[rows.count - 1].message = message
                continue
            }
            if kind == .message {
                row.quote = quote(message, parents: parents, threadRoot: threadRoot, inTribe: inTribe, people: people)
            }
            if kind == .request { row.approved = message.uuid.flatMap { answers[$0] } }
            row.startsNew = startsNew
            if kind == .paymentRequest { row.paymentRequest = message.id.flatMap { requests[$0] } }
            rows.append(row)
        }
        // Ids are unique by construction; should one ever repeat, the newest
        // row keeps it. A repeated id leaves the lazy list room for a row it
        // never draws: blank space under the newest message.
        var seen = Set<String>()
        rows = rows.reversed().filter { seen.insert($0.id).inserted }.reversed()
        // Every message row, a collapsed thread's and a thread's original included.
        for index in rows.indices where rows[index].kind == .message {
            rows[index].call = callServer.flatMap { CallLink(in: rows[index].message, server: $0) }
            rows[index].boosts = rows[index].message.uuid.flatMap { boosts[$0] }
            rows[index].purchase = rows[index].message.id.flatMap { purchases[$0] }
        }
        // Only boosts on our messages are new: above the first of those.
        if let after = newAfter, let index = rows.firstIndex(where: { row in
            row.message.fromMe && (row.boosts?.boosts.contains { !$0.fromMe && ($0.serverIndex ?? -1) > after } ?? false)
        }) {
            rows[index].startsNew = true
        }
        // Runs: one sender, a few minutes apart, on one day. The last of a run
        // shows the time under it; in a tribe the first shows the name.
        for index in rows.indices {
            guard index > 0 else {
                rows[index].startsDay = true
                rows[index].startsRun = true
                continue
            }
            let previous = rows[index - 1], row = rows[index]
            let startsDay = !Calendar.current.isDate(row.date, inSameDayAs: previous.date)
            let startsRun = startsDay || row.startsNew || row.kind != .message || previous.kind != .message
                || row.summary != nil || previous.summary != nil || previous.message.fromMe != row.message.fromMe
                || row.date.timeIntervalSince(previous.date) > 5 * 60 || row.sender.name != previous.sender.name
            rows[index - 1].endsRun = startsRun
            rows[index].startsDay = startsDay
            rows[index].startsRun = startsRun
        }
        return rows
    }

    /// A row for one message, its sender worked out once.
    private static func row(_ message: Message, kind: Kind, id: String, inTribe: Bool, people: People) -> ChatRow {
        ChatRow(id: id, kind: kind, message: message, inTribe: inTribe,
                sender: people.sender(of: message, inTribe: inTribe), date: message.date)
    }

    /// Only text and attachments are quoted, and not one with no words (it
    /// has no row to go to); a reply to the thread's own original is not,
    /// inside that thread. The parent's sender is named here, not while drawing.
    private static func quote(
        _ message: Message, parents: [String: Message], threadRoot: String?, inTribe: Bool, people: People
    ) -> Quote? {
        guard let reply = message.replyUUID, reply != threadRoot else { return nil }
        guard let parent = parents[reply] else { return .missing }
        guard parent.isContent, !parent.isBlank else { return nil }
        return .message(parent, people.sender(of: parent, inTribe: inTribe))
    }

    /// Whether `next` joins this row's run of images.
    private func takes(_ next: Message, sender: Sender) -> Bool {
        guard kind == .message, summary == nil, message.attachmentKind == .image, next.attachmentKind == .image,
              (message.content ?? "").isEmpty, message.fromMe == next.fromMe, sender.name == self.sender.name,
              message.replyUUID == next.replyUUID, message.threadUUID == next.threadUUID,
              Self.settled(message), Self.settled(next),
              // A paid image is bought on its own, never in a grid.
              message.attachmentPriceMsat == nil, next.attachmentPriceMsat == nil,
              next.date.timeIntervalSince(message.date) <= Self.imageRunGap else { return false }
        return true
    }

    /// Not still uploading, sending or failed: those keep their own row and actions.
    private static func settled(_ message: Message) -> Bool {
        guard message.fromMe else { return true }
        return message.uploadState != .pending && message.uploadState != .failed
            && (message.delivery == .delivered || message.delivery == nil)
    }
}

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
    /// A scroll back to the end is waiting for the layout pass to finish.
    @State private var repinning = false
    /// Others' messages take the list down: while it is at the bottom or on
    /// its way there, until you scroll away by hand or it opens at "New messages".
    @State private var following = true
    /// Scrolled up over a screen from the bottom: the jump button shows.
    @State private var farFromBottom = false
    /// "New messages" still marks what is unread below it: from opening at
    /// it (or its moving) until you reach the bottom or scroll away from it.
    @State private var dividerUnread = false
    /// What counted as seen when the list left the bottom; what came after
    /// it and counts as unread is the jump button's count.
    @State private var seenUpTo: Int64?

    /// The end of the list, under its padding. Scrolling to the last row
    /// stops at that padding, short of the scroll view's own bottom, where
    /// its bottom anchor no longer holds the list as the rows below grow.
    private static let bottomID = "bottom"

    /// Where the list sits against its bottom, as the scroll position or
    /// the content's height changes.
    private struct BottomDistance: Equatable {
        var height: CGFloat
        /// Exactly at the end, as far as layout goes.
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
                                .padding(.horizontal, 20)
                        }
                        // "New messages" shares its row's id, so scrolling to
                        // the row (drawn or not) shows it.
                        VStack(alignment: .leading, spacing: 0) {
                            if row.startsNew {
                                NewMessagesDivider()
                                    .padding(.horizontal, 20)
                            }
                            switch row.kind {
                            case .message:
                                MessageRow(row: row, composer: composer, flashed: flashed == row.id)
                                    .equatable()
                            case .request:
                                JoinRequestNote(message: row.message, approved: row.approved, canAnswer: canAnswer)
                                    .padding(.horizontal, 20)
                            case .note:
                                MembershipNote(message: row.message)
                                    .padding(.horizontal, 20)
                            case .payment:
                                PaymentRow(row: row, flashed: flashed == row.id)
                            case .paymentRequest:
                                PaymentRequestRow(row: row, flashed: flashed == row.id)
                            case .missingOriginal:
                                OriginalNotAvailable()
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                            case .replies(let count):
                                RepliesDivider(count: count)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .id(row.id)
                    }
                }
                .environment(\.goToMessage) { go(to: $0, proxy: proxy) }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Color.clear.frame(height: 0).id(Self.bottomID) }
            }
            // A thread reads from its original down; a chat from its newest up.
            // Either starts at the bottom once there is more than fits.
            .defaultScrollAnchor(composer.thread == nil ? .bottom : .top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // A lazy list only estimates the rows it has not drawn, so the
            // initial anchor can land short of the end; go to the newest.
            // With "New messages", open at it instead.
            .onAppear {
                if focusTarget != nil || divider != nil {
                    // A message asked for wins over "New messages". Both go
                    // after the list's initial bottom anchor, which would
                    // undo a scroll asked for now.
                    if focusTarget == nil {
                        following = false
                        dividerUnread = true
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        if focusTarget != nil { takeFocus(proxy) } else { await openAtDivider(proxy) }
                    }
                } else if composer.thread == nil {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onScrollPhaseChange { _, new in phase = new }
            .onScrollGeometryChange(for: BottomDistance.self) { geometry in
                let below = geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                return BottomDistance(height: geometry.contentSize.height, atEnd: abs(below) <= 0.5,
                                      atBottom: below <= 24, far: below > geometry.containerSize.height)
            } action: { old, new in
                // A row that changed height under a list following at its end
                // (one that does not reserve its final size, such as a video
                // sizing itself) moved the end, and the bottom anchor holds
                // only a list exactly at it: back to the end.
                if new.height != old.height, old.atBottom, !new.atEnd, following, phase == .idle {
                    return repin(proxy)
                }
                guard new.atBottom != old.atBottom || new.far != old.far else { return }
                // Scrolled back to the bottom by hand after "Mark unread":
                // reading resumes. Not when a new message scrolls it there.
                if new.atBottom, !old.atBottom, userScrolling { reachedBottom() }
                // Counted from the first time it leaves the bottom until it is
                // back there, through resizes that cross the one-screen line.
                if new.atBottom {
                    following = true
                    seenUpTo = nil
                    if composer.thread == nil, !old.atBottom { model.chatListAtBottom() }
                } else {
                    // Scrolled away by hand: no longer following, and
                    // everything there had been seen.
                    if userScrolling {
                        following = false
                        dividerUnread = false
                    }
                    if seenUpTo == nil { seenUpTo = seenWhenScrolledUp }
                }
                if new.far != old.far {
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
                if following || rows.last?.shown.last?.fromMe == true { scrollToNewest(proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                let count = newSinceScrolledUp
                if farFromBottom || count > 0 {
                    JumpToNewestButton(count: count, composer: composer) { jumpToNewest(proxy) }
                        .padding(.trailing, 20)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
        }
    }

    /// The row "New messages" sits above.
    private var divider: ChatRow? { rows.first(where: \.startsNew) }

    /// To "New messages" at the top, twice: the rows around it have only
    /// estimated heights until the first scroll draws them. Not once you
    /// have taken the list.
    private func openAtDivider(_ proxy: ScrollViewProxy) async {
        for pass in 0..<2 {
            guard let divider, !userScrolling, pass == 0 || !following else { return }
            // The initial anchor may have set it, reaching the bottom.
            following = false
            proxy.scrollTo(divider.id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// What counts as seen when the list leaves the bottom: up to "New
    /// messages" while what is below it is still unread, else everything
    /// in the list.
    private var seenWhenScrolledUp: Int64 {
        if dividerUnread, let index = divider?.shown.first?.serverIndex { return index - 1 }
        return rows.lazy.compactMap { $0.shown.last?.serverIndex }.max() ?? -1
    }

    /// Messages below that count as unread (as "New messages" does) and came
    /// after what was seen; counted from the bottom up, stopping at it.
    private var newSinceScrolledUp: Int {
        guard let seenUpTo else { return 0 }
        var count = 0
        for row in rows.reversed() {
            guard let newest = row.shown.last?.serverIndex, newest > seenUpTo else { break }
            count += row.shown.filter { $0.countsAsUnread(after: seenUpTo) }.count
        }
        return count
    }

    /// To the newest message; like scrolling there by hand, it ends a
    /// "Mark unread" hold and reads the chat.
    private func jumpToNewest(_ proxy: ScrollViewProxy) {
        scrollToNewest(proxy, duration: 0.3)
        reachedBottom()
    }

    /// To the end of the list, following what arrives on the way.
    private func scrollToNewest(_ proxy: ScrollViewProxy, duration: Double = 0.2) {
        following = true
        withAnimation(.easeInOut(duration: duration)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } completion: {
            // Rows that grew on the way moved the end it aimed at.
            repin(proxy)
        }
    }

    /// Back to the end once this layout pass is over: a scroll asked for
    /// inside it can be lost. One for a burst of changes, and none once
    /// you have taken the list.
    private func repin(_ proxy: ScrollViewProxy) {
        guard !repinning else { return }
        repinning = true
        Task {
            repinning = false
            if following, !userScrolling { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    /// Only the chat's own list releases the hold (threads share its marker
    /// but not its scroll position).
    private func reachedBottom() {
        dividerUnread = false
        if composer.thread == nil { model.reachedBottom(of: composer.chat) }
    }

    /// The model's focused message, if it belongs in this list: scrolled
    /// to and lit (or its thread opened, whose list then takes it).
    private func takeFocus(_ proxy: ScrollViewProxy) {
        guard let target = focusTarget else { return }
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
        if let row = rows.first(where: { row in
            [.message, .payment, .paymentRequest].contains(row.kind)
                && (row.message.uuid == uuid || row.images.contains { $0.uuid == uuid } || row.summary?.original.uuid == uuid)
        }) {
            following = false
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(row.id, anchor: .center) }
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
        count == 1 ? "1 new message" : "\(UnreadBadge.text(count)) new messages"
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
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Theme.button, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .contentShape(Capsule())
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36)
                    .menuBoxed(cornerRadius: 18, style: .circular)
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
            .font(Theme.font(12))
            .italic()
            .foregroundStyle(Theme.secondaryText)
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

    static let avatarSize: CGFloat = 32
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
                    Text(message.date, format: .dateTime.hour().minute())
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
                }
            }
            .frame(maxWidth: Self.textWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        // Inside a run, 5 pt between messages: more than a message's 3 pt
        // line spacing, so two read as two (design README, Flat rows).
        .padding(.top, row.startsRun ? 8 : 3)
        .padding(.bottom, row.endsRun ? 4 : 2)
        .rowChrome(row, lit: flashed || openThread, hovering: hovering)
        // At the row's top-right, overlapping its top edge as Slack's does;
        // never over the text, which stops well short of the right edge.
        .overlay(alignment: .topTrailing) {
            if hovering, !menuOpen, !retryable, !uploading, !message.deleted {
                HoverBar(row: row, composer: composer)
                    .padding(.trailing, 20)
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
    let id: String
    let fromMe: Bool
    let lit: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content.background {
            if lit || presenter?.source == AnyHashable(id) {
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
        modifier(RowChrome(id: row.id, fromMe: row.message.fromMe, lit: lit, hovering: hovering))
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
            ?? date.formatted(date: .complete, time: .shortened)
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
            Text(message.date, format: .dateTime.hour().minute())
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
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
                HoverIconButton(systemImage: "arrowshape.turn.up.left", help: "Reply (R)") {
                    withAnimation(.easeOut(duration: 0.2)) { model.startReply(to: message, from: composer) }
                }
            }
            if row.canBoost {
                // One tap boosts with the boost amount (Account sets it).
                HoverIconButton(systemImage: "bolt", help: model.quickBoostLabel) {
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
        .menuBoxed(cornerRadius: 7, shadow: false)
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
        let text = message.shownText
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
    /// Where it was said, for what a mention of you looks like there.
    let chat: String

    var body: some View {
        let blocks = MessageMarkup.blocks(text)
        let myAliases = model.mentionAliases(in: chat)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    styled(line, myAliases)
                case .item(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.secondaryText)
                        styled(line, myAliases)
                    }
                    .padding(.leading, 4)
                case .numbered(let number, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).")
                            .font(Theme.font(14))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                        styled(line, myAliases)
                    }
                    .padding(.leading, 4)
                case .heading(let level, let line):
                    styled(line, myAliases, font: Theme.font(level == 1 ? 20 : level == 2 ? 17 : 15, .semibold))
                        .padding(.top, 2)
                case .quote(let line):
                    styled(line, myAliases)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(width: 3)
                        }
                case .code(let code):
                    Text(code)
                        .font(Theme.code(13))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private func styled(_ line: String, _ myAliases: Set<String>, font: Font = Theme.font(14)) -> some View {
        Text(LinkText.attributed(line, myAliases: myAliases))
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
                .background(Theme.quote, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .message(let parent, let sender):
            Button { goTo(parent) } label: {
                HStack(spacing: 8) {
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
                .background(Theme.quote, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to message")
        }
    }
}
