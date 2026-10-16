import SwiftUI
import PeelCore
import PeelUI

/// A conversation's rows, newest at the bottom. `composer` is where a reply
/// from here goes: the chat's, or the thread panel's. Where it goes is
/// `ChatListController`'s; the table under it is `MessageTable`.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    let rows: [ChatRow]
    let composer: ComposerID
    var canAnswer = false

    @State private var link = ListLink()

    var body: some View {
        MessageTable(
            model: model, rows: rows, composer: composer, canAnswer: canAnswer, focus: focusTarget,
            // A thread's list always ends at its newest; the chat's unless a
            // jump's window stops short of it.
            reachesNewest: composer.thread != nil || model.timelineReachesNewest,
            hasOlder: composer.thread == nil && model.mayHaveOlder, link: link
        )
        // Bottom centre, above the composer, as Slack's "Jump to recent":
        // clear of the newest row's hover bar at the right.
        .overlay(alignment: .bottom) {
            if let controller = link.controller {
                JumpPill(controller: controller, composer: composer)
            }
        }
        // The chat's list only: a thread's composer beside it keeps its own keys.
        .hiddenShortcut(KeyboardShortcut(.pageUp, modifiers: []), enabled: composer.thread == nil) {
            link.engine?.page(up: true)
        }
        .hiddenShortcut(KeyboardShortcut(.pageDown, modifiers: []), enabled: composer.thread == nil) {
            link.engine?.page(up: false)
        }
    }

    /// The model's focused message, when it belongs in this list.
    private var focusTarget: FocusTarget? {
        guard let target = model.focus, target.message.chat == composer.chat,
              composer.thread.map({ $0 == target.message.threadRoot }) ?? !target.inThread,
              !rows.isEmpty else { return nil }
        return target
    }
}

/// One row as the list draws it, its day line and "New messages" inside it.
/// Message rows reach the edges (their hover and tint do); everything else
/// keeps the usual margin.
struct ListRowContent: View {
    @Environment(ListFlash.self) private var flash
    let row: ChatRow
    let composer: ComposerID
    let canAnswer: Bool

    var body: some View {
        let flashed = flash.id == row.id
        VStack(alignment: .leading, spacing: 0) {
            if row.startsDay {
                DayDivider(date: row.date)
                    .padding(.horizontal, Theme.Space.xl)
            }
            if row.startsNew {
                NewMessagesDivider()
                    .padding(.horizontal, Theme.Space.xl)
            }
            switch row.kind {
            case .message:
                MessageRow(row: row, composer: composer, flashed: flashed)
                    .equatable()
            case .request:
                JoinRequestNote(message: row.message, sender: row.sender, approved: row.approved, canAnswer: canAnswer)
                    .padding(.horizontal, Theme.Space.xl)
            case .note:
                NoteLine(text: row.message.membershipNote(by: row.sender))
                    .padding(.horizontal, Theme.Space.xl)
            case .control(let line):
                NoteLine(text: line)
                    .padding(.horizontal, Theme.Space.xl)
            case .payment:
                PaymentRow(row: row, flashed: flashed)
            case .paymentRequest:
                PaymentRequestRow(row: row, flashed: flashed)
            case .missingOriginal:
                OriginalNotAvailable()
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.sm)
            case .replies(let count):
                RepliesDivider(count: count)
                    .padding(.horizontal, Theme.Space.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The controller's pill over the list: an arrow, "N new messages", or the
/// way back to the newest from a jump's window.
struct JumpPill: View {
    let controller: ChatListController
    let composer: ComposerID

    var body: some View {
        let pill = controller.pill
        ZStack {
            if let pill {
                JumpToNewestButton(count: pill.count, composer: composer) { controller.jumpToPresent() }
                    .padding(.bottom, Theme.Space.md)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: pill == nil)
    }
}

private extension ListPill {
    /// The messages below it counts, 0 for none.
    var count: Int {
        if case .count(let count) = self { count } else { 0 }
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
    let row: ChatRow
    let composer: ComposerID
    var flashed = false

    /// The list's row under the pointer; none when measured.
    @Environment(ListHover.self) private var hover: ListHover?

    private var hovering: Bool { hover?.id == row.id }

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

/// Reply, Boost and More, over the hovered row's top-right corner
/// (`MessageTableEngine` places it), as in Slack.
struct HoverBar: View {
    /// How far it reaches above its row's top edge.
    static let overhang: CGFloat = 10

    /// A message's row has one, unless deleted, waiting to be retried, or uploading.
    static func shows(_ row: ChatRow) -> Bool {
        let message = row.message
        return row.kind == .message && !message.deleted && !message.isRetryable()
            && !(message.fromMe && message.uploadState == .pending)
    }

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

extension View {
    /// The row's menu on a right-click, when it has one.
    @ViewBuilder func rowMenu(_ source: String, _ entries: (@MainActor () -> [MenuEntry])?) -> some View {
        if let entries { peelMenu(source: source, entries) } else { self }
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
