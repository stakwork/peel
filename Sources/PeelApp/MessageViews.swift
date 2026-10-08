import SwiftUI
import PeelCore

/// What a reply quotes: the parent, or a note that it is not here.
enum Quote: Equatable {
    case message(Message)
    /// The parent is older than this Mac's history, or the link is broken.
    case missing
}

/// One row of a conversation, worked out once per change in a single pass:
/// a message (or a run of one sender's images, or a collapsed thread), a
/// request to join, or a note; in a thread also its original and the
/// "N replies" line. Names and photos are decoded here, once per message.
struct ChatRow: Identifiable {
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
    var alias: String?
    var photoURL: String?
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
        var me: (name: String, photoURL: String?)
        var contact: (name: String, photoURL: String?)
    }

    /// The rows of a chat (`threads` collapsed), or of a thread: with
    /// `threadRoot` set, its `original` (or a note that it is missing) and
    /// "N replies" come first. `newAfter` is the read marker that places "New messages".
    static func rows(
        _ messages: [Message], threads: [String: ThreadSummary] = [:], parents: [String: Message],
        boosts: [String: BoostSummary] = [:], requests: [Int64: PaymentRequest] = [:],
        purchases: [Int64: PurchaseState] = [:], inTribe: Bool, people: People,
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
            // What counts as unread (`Storage.readStates`): text, attachments, payments.
            let startsNew = newAfter.map { message.countsAsUnread(after: $0) } ?? false
            if startsNew { newAfter = nil }
            if let thread = message.threadUUID, let summary = threads[thread] {
                var row = row(summary.original, kind: .message, id: "t\(summary.uuid)", inTribe: inTribe, people: people)
                row.startsNew = startsNew
                row.latest = message
                row.summary = summary
                row.date = message.date
                rows.append(row)
                continue
            }
            let kind: Kind = message.isContent ? .message
                : message.type == MessageType.directPayment ? .payment
                : message.type == MessageType.invoice ? .paymentRequest
                : message.type == MessageType.memberRequest && !message.fromMe ? .request : .note
            var row = row(message, kind: kind, id: "m\(message.id ?? 0)", inTribe: inTribe, people: people)
            if kind == .message, !startsNew, let last = rows.last, last.takes(message, alias: row.alias) {
                rows[rows.count - 1].images = (last.images.isEmpty ? [last.message] : last.images) + [message]
                rows[rows.count - 1].message = message
                continue
            }
            if kind == .message {
                row.quote = quote(message, parents: parents, threadRoot: threadRoot)
            }
            if kind == .request { row.approved = message.uuid.flatMap { answers[$0] } }
            row.startsNew = startsNew
            if kind == .paymentRequest { row.paymentRequest = message.id.flatMap { requests[$0] } }
            rows.append(row)
        }
        // Every message row, a collapsed thread's and a thread's original included.
        for index in rows.indices where rows[index].kind == .message {
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
                || row.date.timeIntervalSince(previous.date) > 5 * 60 || row.alias != previous.alias
            rows[index - 1].endsRun = startsRun
            rows[index].startsDay = startsDay
            rows[index].startsRun = startsRun
        }
        return rows
    }

    /// A row for one message, its sender's name and photo worked out once:
    /// you, the contact, or in a tribe the member (decoded from the message).
    private static func row(_ message: Message, kind: Kind, id: String, inTribe: Bool, people: People) -> ChatRow {
        let sender: (alias: String?, photoURL: String?)
        if message.fromMe {
            sender = (people.me.name, people.me.photoURL)
        } else if inTribe {
            let details = message.senderDetails
            sender = (details.alias ?? "Unknown", details.photoURL)
        } else {
            sender = (people.contact.name, people.contact.photoURL)
        }
        return ChatRow(id: id, kind: kind, message: message, inTribe: inTribe, alias: sender.alias,
                       photoURL: sender.photoURL, date: message.date)
    }

    /// Only text and attachments are quoted; a reply to the thread's own
    /// original is not, inside that thread.
    private static func quote(_ message: Message, parents: [String: Message], threadRoot: String?) -> Quote? {
        guard let reply = message.replyUUID, reply != threadRoot else { return nil }
        guard let parent = parents[reply] else { return .missing }
        return parent.isContent ? .message(parent) : nil
    }

    /// Whether `next` joins this row's run of images.
    private func takes(_ next: Message, alias: String?) -> Bool {
        guard kind == .message, summary == nil, message.attachmentKind == .image, next.attachmentKind == .image,
              (message.content ?? "").isEmpty, message.fromMe == next.fromMe, alias == self.alias,
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

/// A conversation's rows, newest at the bottom. `composer` is where a reply
/// from here goes: the chat's, or the thread panel's.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    let rows: [ChatRow]
    let composer: ComposerID
    var canAnswer = false

    /// A row just jumped to from a quote, lit for a moment.
    @State private var flashed: String?
    @State private var userScrolling = false
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

    /// Where the list sits against its bottom, as the scroll position changes.
    private struct BottomDistance: Equatable {
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
                                MessageRow(row: row, composer: composer, flashed: flashed == row.id) {
                                    go(to: $0, proxy: proxy)
                                }
                            case .request:
                                JoinRequestNote(message: row.message, approved: row.approved, canAnswer: canAnswer)
                                    .padding(.horizontal, 20)
                            case .note:
                                MembershipNote(message: row.message)
                                    .padding(.horizontal, 20)
                            case .payment:
                                PaymentRow(row: row)
                                    .background(flashed == row.id ? Theme.selection.opacity(0.45) : .clear)
                            case .paymentRequest:
                                PaymentRequestRow(row: row)
                                    .background(flashed == row.id ? Theme.selection.opacity(0.45) : .clear)
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
                if focusTarget != nil {
                    // A message asked for wins over "New messages". After the
                    // list's initial bottom anchor, which would undo it.
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        takeFocus(proxy)
                    }
                } else if let divider {
                    proxy.scrollTo(divider.id, anchor: .top)
                    following = false
                    dividerUnread = true
                } else if composer.thread == nil {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: BottomDistance.self) { geometry in
                let below = geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                return BottomDistance(atBottom: below <= 24, far: below > geometry.containerSize.height)
            } action: { old, new in
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
        withAnimation(.easeInOut(duration: duration)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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
            (row.kind == .message || row.kind == .payment)
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
            withAnimation(.easeOut(duration: 0.2)) { model.openThread(of: parent) }
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
                    .menuBoxed(cornerRadius: 18)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help("Jump to newest (End)")
        .accessibilityLabel(count > 0 ? "Jump to newest, \(newMessages)" : "Jump to newest")
        .background {
            // Shortcuts, only while the button shows.
            if shortcuts {
                ForEach([KeyboardShortcut(.end, modifiers: []), KeyboardShortcut(.downArrow, modifiers: .command)],
                        id: \.key) { shortcut in
                    Button("", action: action).keyboardShortcut(shortcut).opacity(0).frame(width: 0, height: 0)
                }
            }
        }
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
/// same menu as More.
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    let row: ChatRow
    let composer: ComposerID
    var flashed = false
    let goTo: (Message) -> Void

    @State private var hovering = false

    static let avatarSize: CGFloat = 32
    static let gutterSpacing: CGFloat = 10
    /// About 68 characters of 14 pt text: lines short enough to read.
    static let textWidth: CGFloat = 560

    private var message: Message { row.message }

    var body: some View {
        // A pending send becomes retryable after a timeout, with no change to
        // the row itself, so those rows redraw once when it passes.
        if message.delivery == .pending {
            TimelineView(.explicit([message.date.addingTimeInterval(Message.confirmationTimeout + 0.5)])) { context in
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
        let isSubject = presenter?.source == AnyHashable(row.id)
        let openThread = row.summary.map { model.openThread == ThreadRef(chat: $0.chat, uuid: $0.uuid) } ?? false
        return HStack(alignment: .top, spacing: Self.gutterSpacing) {
            // The gutter: the photo on a run's first row, the time on hover after it.
            Group {
                if row.startsRun {
                    Avatar(name: row.alias ?? "?", url: row.photoURL, size: Self.avatarSize)
                } else {
                    Text(message.date, format: .dateTime.hour().minute())
                        .font(Theme.font(11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .opacity(hovering ? 1 : 0)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Self.avatarSize, alignment: row.startsRun ? .center : .trailing)
            VStack(alignment: .leading, spacing: 3) {
                if row.startsRun {
                    RunHeader(row: row)
                }
                MessageContent(
                    row: row, goTo: goTo,
                    menu: { MessageMenu.entries(for: row, composer: composer, model: model, offersBoost: row.canBoost) },
                    tileMenu: { image in
                        var single = row
                        single.message = image
                        single.images = []
                        return MessageMenu.entries(for: single, composer: composer, model: model)
                    }
                )
                .opacity(message.delivery == .pending && !retryable && !uploading ? 0.6 : 1)
                if let boosts = row.boosts {
                    BoostLine(boosts: boosts, showsChip: !message.deleted)
                }
                if let summary = row.summary {
                    ThreadSummaryLine(summary: summary)
                }
                if retryable {
                    UndeliveredActions(message: message)
                }
            }
            .frame(maxWidth: Self.textWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, row.startsRun ? 8 : 1)
        .padding(.bottom, row.endsRun ? 4 : 1)
        .background {
            if isSubject || flashed || openThread {
                Theme.selection.opacity(0.45)
            } else if hovering {
                Theme.hover.opacity(0.55)
            } else if message.fromMe {
                Theme.accent.opacity(0.06)
            }
        }
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

/// A run's header: the sender's name, the time and, for yours, the green
/// bolt once the server has it.
struct RunHeader: View {
    let row: ChatRow

    var body: some View {
        let message = row.message
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.alias ?? "Unknown")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.name)
                .lineLimit(1)
            Text(message.date, format: .dateTime.hour().minute())
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .help(message.date.formatted(date: .complete, time: .shortened))
            if message.fromMe, message.delivery == .delivered {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.confirmed)
                    .help("Delivered")
            }
        }
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
        if let text = message.content?.trimmed.nilIfEmpty {
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
        if let tribe = model.selectedTribe, tribe.pubkey == message.chat, tribe.canManage, message.isPinnable {
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
        if !message.fromMe, message.isContent, !message.deleted, message.serverIndex != nil {
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
    let goTo: (Message) -> Void

    /// The row's menu, on everything but a run's image tiles, which each
    /// have their own (`tileMenu`), so an image is saved or deleted by itself.
    var menu: (@MainActor () -> [MenuEntry])?
    var tileMenu: (@MainActor (Message) -> [MenuEntry])?

    var body: some View {
        let message = row.message
        let text = message.content?.trimmed ?? ""
        if message.deleted {
            Label("This message has been deleted", systemImage: "trash")
                .font(Theme.font(13))
                .italic()
                .foregroundStyle(Theme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let quote = row.quote {
                    QuoteView(quote: quote, goTo: goTo)
                        .rowMenu(row.id, menu)
                }
                if message.attachmentKind != nil {
                    if row.images.count > 1 {
                        AttachmentView(row: row, tileMenu: tileMenu)
                    } else {
                        AttachmentView(row: row).rowMenu(row.id, menu)
                    }
                }
                if !text.isEmpty {
                    MessageText(text: text)
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

/// Message text as `MessageMarkup` reads it: links, mentions and inline
/// code marked, list items with a hanging indent, ``` blocks as code. Its
/// own view, so hovering the row does not redo the parsing.
struct MessageText: View {
    let text: String

    var body: some View {
        let blocks = MessageMarkup.blocks(text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    styled(line)
                case .item(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.secondaryText)
                        styled(line)
                    }
                    .padding(.leading, 4)
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

    private func styled(_ line: String) -> some View {
        Text(LinkText.attributed(line))
            .font(Theme.font(14))
            .lineSpacing(3)
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The message a reply answers: who and what, one line, with a small image
/// or file mark for an attachment. Click to go to it.
struct QuoteView: View {
    @Environment(AppModel.self) private var model
    let quote: Quote
    let goTo: (Message) -> Void

    var body: some View {
        switch quote {
        case .missing:
            OriginalNotAvailable()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.quote, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .message(let parent):
            Button { goTo(parent) } label: {
                HStack(spacing: 8) {
                    if parent.attachmentKind != nil {
                        AttachmentMark(message: parent, size: 32)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.sender(of: parent).name)
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(Theme.link)
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
