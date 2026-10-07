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
    var quote: Quote?
    /// For a request to join: whether the owner approved, once answered.
    var approved: Bool?
    var alias: String?
    var photoURL: String?
    /// Where the row sits in time: a collapsed thread at its newest message.
    var date: Date
    var startsDay = false
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
    /// "N replies" come first.
    static func rows(
        _ messages: [Message], threads: [String: ThreadSummary] = [:], parents: [String: Message],
        boosts: [String: BoostSummary] = [:], inTribe: Bool, people: People, threadRoot: String? = nil, original: Message? = nil
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
        for message in messages {
            if let thread = message.threadUUID, let summary = threads[thread] {
                var row = row(summary.original, kind: .message, id: "t\(summary.uuid)", inTribe: inTribe, people: people)
                row.summary = summary
                row.date = message.date
                rows.append(row)
                continue
            }
            let kind: Kind = message.isContent ? .message
                : message.type == MessageType.directPayment ? .payment
                : message.type == MessageType.memberRequest && !message.fromMe ? .request : .note
            var row = row(message, kind: kind, id: "m\(message.id ?? 0)", inTribe: inTribe, people: people)
            if kind == .message, let last = rows.last, last.takes(message, alias: row.alias) {
                rows[rows.count - 1].images = (last.images.isEmpty ? [last.message] : last.images) + [message]
                rows[rows.count - 1].message = message
                continue
            }
            if kind == .message { row.quote = quote(message, parents: parents, threadRoot: threadRoot) }
            if kind == .request { row.approved = message.uuid.flatMap { answers[$0] } }
            rows.append(row)
        }
        for index in rows.indices where rows[index].kind == .message {
            rows[index].boosts = rows[index].message.uuid.flatMap { boosts[$0] }
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
            let startsRun = startsDay || row.kind != .message || previous.kind != .message
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
                        Group {
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
            }
            // A thread reads from its original down; a chat from its newest up.
            // Either starts at the bottom once there is more than fits.
            .defaultScrollAnchor(composer.thread == nil ? .bottom : .top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // A lazy list only estimates the rows it has not drawn, so the
            // initial anchor can land short of the end; go to the newest.
            .onAppear {
                if composer.thread == nil, let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: rows.last?.id) { _, last in
                if let last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    /// From a quote to the message it quotes: scrolled to and lit if it is
    /// here, its thread opened if a thread has folded it away.
    private func go(to parent: Message, proxy: ScrollViewProxy) {
        let uuid = parent.uuid
        if let row = rows.first(where: { row in
            row.kind == .message
                && (row.message.uuid == uuid || row.images.contains { $0.uuid == uuid } || row.summary?.original.uuid == uuid)
        }) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(row.id, anchor: .center) }
            flashed = row.id
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if flashed == row.id { flashed = nil }
            }
        } else if composer.thread == nil, parent.threadUUID != nil {
            withAnimation(.easeOut(duration: 0.2)) { model.openThread(of: parent) }
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
    /// The boost panel, opened from the hover bar's bolt or "Boost…".
    @State private var boosting = false

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
                    menu: { MessageMenu.entries(for: row, composer: composer, model: model, boost: boost) },
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
            if hovering, !menuOpen, !boosting, !retryable, !uploading, !message.deleted {
                HoverBar(row: row, composer: composer, boost: boost)
                    .padding(.trailing, 20)
                    .offset(y: -10)
            }
        }
        // The boost panel opens under where the hover bar sits, and stays
        // while the bar goes.
        .overlay(alignment: .topTrailing) {
            if message.isBoostable {
                Color.clear
                    .frame(width: 96, height: 16)
                    .padding(.trailing, 20)
                    .allowsHitTesting(false)
                    .peelPopover(isPresented: $boosting) {
                        BoostPanel(message: message) { boosting = false }
                    }
            }
        }
        .zIndex(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Opens the boost panel, where this message can be boosted.
    private var boost: (@MainActor () -> Void)? {
        guard message.isBoostable else { return nil }
        let boosting = $boosting
        return { boosting.wrappedValue = true }
    }
}

/// A run's header: the sender's name, the time and, for yours, the green
/// bolt once the server has it.
private struct RunHeader: View {
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
    let boost: (@MainActor () -> Void)?

    var body: some View {
        let message = row.message
        HStack(spacing: 0) {
            if message.isLinkable(inTribe: row.inTribe) {
                HoverIconButton(systemImage: "arrowshape.turn.up.left", help: "Reply (R)") {
                    withAnimation(.easeOut(duration: 0.2)) { model.startReply(to: message, from: composer) }
                }
            }
            if let boost {
                HoverIconButton(systemImage: "bolt", help: "Boost", action: boost)
            }
            if !message.deleted {
                MenuButton(systemImage: "ellipsis", help: "More", source: row.id) {
                    MessageMenu.entries(for: row, composer: composer, model: model, boost: boost)
                }
            }
        }
        .padding(2)
        .menuBoxed(cornerRadius: 7, shadow: false)
    }
}

/// What a message's menu offers. Undelivered: Retry and Discard. Otherwise
/// Reply, Boost (where `boost` is given: someone else's message), copying,
/// saving an attachment, and for a tribe's owner, pinning (the Mac app lets
/// only the owner pin).
@MainActor
enum MessageMenu {
    static func entries(
        for row: ChatRow, composer: ComposerID, model: AppModel, boost: (@MainActor () -> Void)? = nil
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
                file.append(.button("Copy image", systemImage: "photo") { model.copyImage(message) })
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
        if let boost {
            reply.append(.button("Boost…", systemImage: "bolt", action: boost))
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
        var delete: [MenuEntry] = []
        if oneMessage, model.canDelete(message, inTribe: row.inTribe) {
            delete.append(.destructive("Delete", systemImage: "trash", confirm: "Delete for everyone") {
                Task { await model.delete(message) }
            })
        }
        return .sections(reply, copy + file, pin, delete)
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

/// Message text: links and mentions marked, and lines starting with "-" or
/// "•" set as a list with a hanging indent. Its own view, so hovering the
/// row does not redo the parsing.
struct MessageText: View {
    let text: String

    var body: some View {
        let blocks = MessageBlocks.split(text)
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

/// A message split into paragraphs and list items.
enum MessageBlocks: Equatable {
    case paragraph(String)
    case item(String)

    static func split(_ text: String) -> [MessageBlocks] {
        var blocks: [MessageBlocks] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = ["- ", "• ", "* "].first(where: { trimmed.hasPrefix($0) }) {
                flush()
                blocks.append(.item(String(trimmed.dropFirst(marker.count))))
            } else {
                paragraph.append(String(line))
            }
        }
        flush()
        return blocks
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
