import PeelCore
import PeelUI
import SwiftUI

// A conversation's rows on the phone (docs/design/iphone.md, screen 2): the
// Mac's flat rows (`MessageRow`, `PaymentRow`, `PaymentRequestRow` in
// `MessageViews` and `PaymentChatRows`) over the same `ChatRow`s, at the
// phone's sizes and with touch in place of hover. What a row offers is
// `MessageActions`; its menu and VoiceOver's actions both read it.

/// The photo column and its gap, as on the Mac.
enum RowMetrics {
    static let avatar: CGFloat = 32
    static let gutter: CGFloat = 10
}

/// One row of a conversation or a thread, by its kind.
struct ConversationRow: View, Equatable {
    let row: ChatRow
    let composer: ComposerID
    var flashed = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.composer == b.composer && a.flashed == b.flashed
    }

    var body: some View {
        switch row.kind {
        case .message:
            MessageRowView(row: row, composer: composer, flashed: flashed)
        case .payment:
            PaymentRowView(row: row, composer: composer, flashed: flashed)
        case .paymentRequest:
            RequestRowView(row: row, composer: composer, flashed: flashed)
        case .request:
            RowNote(text: row.sender.name + " wants to join"
                + (row.approved.map { $0 ? " · Approved" : " · Declined" } ?? ""))
        case .note:
            RowNote(text: row.message.membershipNote(by: row.sender))
        case .control(let line):
            RowNote(text: line)
        case .missingOriginal:
            RowNote(text: "Original message not available", italic: true)
        case .replies(let count):
            RepliesLine(count: count)
        }
    }
}

// MARK: - A message

/// A message as a flat row: on a run's first row the photo, the name in
/// the sender's colour and the time; the rest of the run under it. Yours
/// on a faint accent tint. Long press for its menu, swipe right to reply in
/// its thread; for VoiceOver, one element with the menu as its actions.
struct MessageRowView: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    let composer: ComposerID
    var flashed = false

    private var message: Message { row.message }

    var body: some View {
        // A pending send becomes retryable after a timeout with no change
        // to the row, so it redraws once when that passes.
        let retryableAt = message.delivery == .pending
            ? message.date.addingTimeInterval(Message.confirmationTimeout + 0.5) : nil
        TimelineView(.redrawing(at: retryableAt)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let retryable = message.isRetryable(now: now)
        let actions = MessageActions(row: row, composer: composer, model: model, now: now)
        return RowFrame(row: row, flashed: flashed) {
            if row.startsRun {
                Avatar(name: row.sender.avatarName, url: row.sender.photoURL, size: RowMetrics.avatar, hue: row.sender.hue)
            }
        } content: {
            if row.startsRun { RunHeaderLine(row: row) }
            MessageBodyView(row: row)
                .opacity(message.isSending(now: now) ? 0.6 : 1)
            if let boosts = row.boosts {
                BoostLineView(boosts: boosts, chat: message.chat, inTribe: row.inTribe, showsChip: !message.deleted)
            }
            if let summary = row.summary {
                ThreadSummaryButton(summary: summary, inTribe: row.inTribe)
            }
            if retryable {
                UndeliveredLine(message: message)
            } else if message.delivery == .pending, message.mayHavePaid {
                WaitingLine(since: message.date, what: message.type == MessageType.call ? "Call" : "Message")
            }
        }
        .messageActions(actions, spoken: spoken)
    }

    /// One VoiceOver element: who, when, what, then boosts and replies.
    private var spoken: String {
        var parts = [row.sender.label, Formatting.time(row.date)]
        if let quote = row.quote, case .message(let parent, let sender) = quote {
            parts.append("replying to \(sender.label): \(parent.preview)")
        }
        parts.append(row.images.count > 1 ? "\(row.images.count) images" : message.preview)
        if let boosts = row.boosts, boosts.count > 0, !message.deleted {
            parts.append("boosted \(Sats.format(msat: boosts.totalMsat))")
        }
        if let summary = row.summary { parts.append(Formatting.replies(summary.count)) }
        if message.isRetryable() { parts.append("not delivered") }
        return parts.joined(separator: ", ")
    }
}

/// The row's shape: the photo column, then the body, the tint behind
/// yours, lit for a moment when jumped to.
struct RowFrame<Leading: View, Content: View>: View {
    let row: ChatRow
    var flashed = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: RowMetrics.gutter) {
            // The column keeps its width under a run's later rows, which have no photo.
            ZStack(alignment: .top) {
                Color.clear.frame(height: 1)
                leading
            }
            .frame(width: RowMetrics.avatar)
            VStack(alignment: .leading, spacing: 3) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.phoneGutter)
        .padding(.top, row.startsRun ? 8 : 3)
        .padding(.bottom, row.endsRun ? 5 : 2)
        .background {
            if flashed {
                Theme.selection.opacity(0.45)
            } else if row.message.fromMe {
                Theme.accent.opacity(0.07)
            }
        }
        // Times and greys on the tint are `secondaryText` (iphone.md).
        .environment(\.surface, row.message.fromMe ? .raised : .background)
        .contentShape(Rectangle())
    }
}

/// The name in the sender's colour and the time, once per run. A payment
/// puts its headline in the name's place.
struct RunHeaderLine: View {
    @Environment(\.surface) private var surface
    let row: ChatRow
    var headline: Text?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let headline {
                headline
            } else {
                Text(row.sender.name)
                    .phoneFont(.name)
                    .foregroundStyle(row.sender.hue.name)
                    .lineLimit(1)
            }
            Text(Formatting.time(row.message.date))
                .phoneFont(.time)
                .monospacedDigit()
                .foregroundStyle(Theme.quietText(on: surface))
                .fixedSize()
        }
    }
}

/// A message's body: the quote, a GIF or the attachment, the call, then the
/// text through the shared renderer.
struct MessageBodyView: View {
    let row: ChatRow

    var body: some View {
        let message = row.message
        if message.deleted {
            Label("This message has been deleted", systemImage: "trash")
                .phoneFont(.secondary)
                .italic()
                .foregroundStyle(Theme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let quote = row.quote { QuoteBox(quote: quote) }
                if let giphy = row.giphy { GiphyPicture(giphy: giphy) }
                if message.attachmentKind != nil { AttachmentBlock(row: row) }
                if let call = row.call {
                    CallBlock(link: call, chat: message.chat)
                } else if !message.shownText.isEmpty {
                    // Link cards are the Mac's for now: the link stays in the text.
                    MessageText(text: message.shownText, chat: message.chat, size: PhoneFont.message.size)
                }
            }
        }
    }
}

/// The message a reply answers: who and what, one line, on `quote`. Tap
/// to go to it.
struct QuoteBox: View {
    @Environment(\.goToMessage) private var goTo
    let quote: Quote

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        switch quote {
        case .missing:
            Text("Original message not available")
                .phoneFont(.secondary)
                .italic()
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.quote, in: shape)
        case .message(let parent, let sender):
            Button { goTo(parent) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sender.label)
                        .phoneFont(PhoneFont.secondary.weight(.semibold))
                        .foregroundStyle(sender.hue.name)
                    Text(parent.preview)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.quote, in: shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Goes to the message")
        }
    }
}

/// A call message: the call card's words, and Join through the model,
/// which says calls are not on the phone yet (`CallProvider.unavailable`).
private struct CallBlock: View {
    @Environment(AppModel.self) private var model
    let link: CallLink
    let chat: String

    var body: some View {
        PhoneCard {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: link.audioOnly ? "phone.fill" : "video.fill")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text(link.audioOnly ? "Audio call" : "Video call")
                    .phoneFont(.row)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: Theme.Space.sm)
                Button("Join") { Task { _ = await model.calls.join(link, in: chat, failureInChat: true) } }
                    .buttonStyle(.peel(.outline, size: .touch))
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
    }
}

// MARK: - Payments and requests

/// Sats sent in a direct message: the bolt in the photo's place, "You sent
/// 1,000 sats" as the header, the note, and for yours the wait or Retry.
struct PaymentRowView: View {
    let row: ChatRow
    let composer: ComposerID
    var flashed = false

    private var message: Message { row.message }

    var body: some View {
        RowFrame(row: row, flashed: flashed) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13))
                .foregroundStyle(message.deleted ? Theme.secondaryText : Theme.attention)
                .frame(width: 28, height: 28)
                .background(Theme.attention.opacity(message.deleted ? 0.06 : 0.14), in: Circle())
        } content: {
            RunHeaderLine(row: row, headline: headline)
            if !message.deleted, let note = message.content?.trimmed.nilIfEmpty {
                MessageText(text: note, chat: message.chat, size: PhoneFont.message.size)
            }
            if message.fromMe, !message.deleted {
                switch message.delivery {
                case .pending: WaitingLine(since: message.date, what: "Payment", person: message.chat)
                case .unsettled: QuietLine(text: "Payment not settled")
                case .failed: UndeliveredLine(message: message)
                case .delivered, nil: EmptyView()
                }
            } else if !message.deleted, message.arrived == false {
                QuietLine(text: "Not received")
            }
        }
        .opacity(message.isSending() ? 0.6 : 1)
        .messageActions(MessageActions(row: row, composer: composer, model: nil))
    }

    private var who: String { row.sender.name }

    private var headline: Text {
        if message.deleted {
            return Text("This payment has been deleted").italic().foregroundColor(Theme.secondaryText)
        } else if let msat = message.amountMsat, msat > 0 {
            let amount = Text(Sats.format(msat: msat)).fontWeight(.semibold)
            return Text(message.fromMe ? "You sent \(amount)" : "\(who) sent you \(amount)")
                .foregroundColor(Theme.text)
        } else {
            return Text(message.fromMe ? "You sent a payment" : "\(who) sent a payment with no sats")
                .foregroundColor(Theme.secondaryText)
        }
    }
}

/// A request to be paid: who asked, how much (the invoice's, never the
/// message's words), its memo and whether it is paid. Paying it comes with
/// the phone's payment flows (F2c); the Mac pays it today.
struct RequestRowView: View {
    let row: ChatRow
    let composer: ComposerID
    var flashed = false

    var body: some View {
        let message = row.message
        let invoice = row.paymentRequest?.invoice
        RowFrame(row: row, flashed: flashed) {
            Avatar(name: row.sender.avatarName, url: row.sender.photoURL, size: RowMetrics.avatar, hue: row.sender.hue)
        } content: {
            RunHeaderLine(row: row)
            PhoneCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt").accessibilityHidden(true)
                        Text("\(row.sender.label) requested")
                        Spacer(minLength: Theme.Space.sm)
                        if case .paid = row.paymentRequest?.state {
                            Label("Paid", systemImage: "checkmark")
                                .phoneFont(PhoneFont.secondary.weight(.semibold))
                                .foregroundStyle(Theme.text)
                        }
                    }
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    if let invoice {
                        Text(Sats.format(msat: invoice.amountMsat))
                            .phoneFont(.title)
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                        if !invoice.memo.isEmpty {
                            Text(invoice.memo).phoneFont(.message).foregroundStyle(Theme.text)
                        }
                        if !message.fromMe, row.paymentRequest?.paysRequester == false {
                            Text("This invoice pays \(Formatting.shortKey(invoice.payee)), not \(row.sender.name).")
                                .phoneFont(.secondary)
                                .foregroundStyle(Theme.attention)
                        }
                        Text(status(invoice))
                            .phoneFont(.secondary)
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Text("Can't read this invoice, so it can't be paid.")
                            .phoneFont(.secondary)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, Theme.Space.md)
                .frame(maxWidth: 320, alignment: .leading)
            }
            if message.fromMe, message.delivery == .failed { UndeliveredLine(message: message) }
        }
        .messageActions(MessageActions(row: row, composer: composer, model: nil))
    }

    /// Where it stands, as the Mac's footer words it (paying it waits for F2c).
    private func status(_ invoice: Invoice) -> String {
        switch row.paymentRequest?.state ?? .open {
        case .underpaid: return "Partly paid. This invoice can't take the rest."
        case .paid(let at): return (row.message.fromMe ? "Paid" : "You paid") + (at.map { " · \(Formatting.when($0))" } ?? "")
        case .paying: return "Paying…"
        case .open, .failed:
            if invoice.isExpired() { return "Expired at \(invoice.expiresAt.map(Formatting.expiry) ?? "")" }
            if row.message.fromMe { return "Waiting to be paid · expires \(invoice.expiresAt.map(Formatting.expiry) ?? "never")" }
            return "Pay it from the Mac for now"
        }
    }
}

// MARK: - Under a message

/// The boosts as a chip (the orange bolt and the total, on `quote`, yours
/// on `boostMineFill`), then your boosts still on their way or failed.
struct BoostLineView: View {
    let boosts: BoostSummary
    let chat: String
    let inTribe: Bool
    var showsChip = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if showsChip, boosts.count > 0 { BoostChipView(boosts: boosts) }
            if let since = boosts.pendingSince {
                WaitingLine(since: since, what: "Boost", person: inTribe ? nil : chat)
            }
            ForEach(Array(boosts.unsettled.enumerated()), id: \.offset) { _, boost in
                QuietLine(text: "Boost of \(Sats.format(msat: boost.amountMsat)) not settled")
            }
            ForEach(boosts.failed, id: \.id) { boost in
                UndeliveredLine(message: boost)
            }
        }
    }
}

private struct BoostChipView: View {
    let boosts: BoostSummary

    var body: some View {
        let pending = boosts.pendingSince != nil
        let mine = boosts.boostedByMe && !pending
        Chip(.inset, lit: mine) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.attention.opacity(pending ? 0.5 : 1))
                Text(Sats.number(msat: boosts.totalMsat))
                    .fontWeight(.semibold)
                    .foregroundStyle(mine ? Theme.boostMineText : Theme.text)
                + Text(" sats").foregroundStyle(Theme.secondaryText)
            }
            .phoneFont(.time)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        // The row reads the total ("boosted 1,200 sats").
        .accessibilityHidden(true)
    }
}

/// Under a collapsed thread: who replied, "4 replies" in `link` blue and
/// the last reply's time. Opens the thread sheet.
struct ThreadSummaryButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.surface) private var surface
    let summary: ThreadSummary
    let inTribe: Bool

    var body: some View {
        Button {
            model.openThread(ThreadRef(chat: summary.chat, uuid: summary.uuid))
        } label: {
            HStack(spacing: Theme.Space.sm) {
                HStack(spacing: -5) {
                    ForEach(Array(summary.participants.prefix(3).enumerated()), id: \.offset) { _, person in
                        let avatar = model.avatar(fromMe: person.fromMe, alias: person.alias, photoURL: person.photoURL,
                                                  chat: summary.chat, inTribe: inTribe)
                        Avatar(name: avatar.avatarName, url: avatar.photoURL, size: Theme.AvatarSize.sm, hue: avatar.hue)
                            .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                    }
                }
                Text(Formatting.replies(summary.count))
                    .phoneFont(PhoneFont.secondary.weight(summary.unread > 0 ? .bold : .semibold))
                    .foregroundStyle(Theme.link)
                if summary.unread > 0 {
                    Text("\(summary.unread) new")
                        .phoneFont(PhoneFont.time.weight(.bold))
                        .foregroundStyle(Theme.text)
                }
                if let last = summary.lastDate {
                    Text("Last reply \(Formatting.time(last))")
                        .phoneFont(.time)
                        .monospacedDigit()
                        .foregroundStyle(Theme.quietText(on: surface))
                        .lineLimit(1)
                }
            }
            .frame(minHeight: Theme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Not delivered" (or "Not uploaded", "Boost of 21 sats not sent") with
/// Retry and Discard, the Mac's `UndeliveredActions`: a payment's Retry
/// goes through `PaymentAttempt`, over the threshold first asking to tap
/// "Send 1,000 sats" again; Discard asks once, in place.
struct UndeliveredLine: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var confirmingDiscard = false
    @State private var attempt = PaymentAttempt()

    private var isPayment: Bool { MessageType.payments.contains(message.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.md) {
                if let armed = attempt.armed {
                    Button("\(message.type == MessageType.boost ? "Boost" : "Send") \(Sats.format(msat: armed))") {
                        Task { await retry() }
                    }
                    .foregroundStyle(Theme.attention)
                    Button("Cancel") { attempt.armed = nil }
                        .foregroundStyle(Theme.secondaryText)
                } else if confirmingDiscard {
                    Text("Discard, never sent?").foregroundStyle(Theme.secondaryText)
                    Button("Discard") { Task { await model.discard(message) } }
                        .foregroundStyle(Theme.text)
                    Button("Cancel") { confirmingDiscard = false }
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text(message.undeliveredLabel).foregroundStyle(Theme.secondaryText)
                    // Ours from history or another device is never paid again from here.
                    if message.isRetryable() {
                        Button("Retry") { Task { await retry() } }
                            .foregroundStyle(Theme.link)
                            .disabled(attempt.working)
                    }
                    if message.isDiscardable {
                        Button("Discard") { confirmingDiscard = true }
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .buttonStyle(.plain)
            .phoneFont(PhoneFont.secondary.weight(.medium))
            .monospacedDigit()
            .frame(minHeight: Theme.touchTarget)
            if let problem = attempt.problem { ProblemText(problem) }
        }
    }

    private func retry() async {
        guard isPayment else { return await model.resend(message) }
        _ = await attempt.run { await model.retryPayment(message, confirmedMsat: $0) }
    }
}

/// "Message waiting for the server…" once a send that may have paid has
/// gone unconfirmed past the usual wait; for a payment to a person, waiting
/// for them to come online. No Retry: it may have paid (the Mac's
/// `WaitingForServer`).
struct WaitingLine: View {
    @Environment(AppModel.self) private var model
    let since: Date
    let what: String
    var person: String?

    var body: some View {
        TimelineView(.redrawing(at: since.addingTimeInterval(Message.confirmationTimeout))) { context in
            if context.date.timeIntervalSince(since) >= Message.confirmationTimeout {
                QuietLine(text: person.map {
                    "\(what) waiting for \(model.contactName($0) ?? "them") to come online · can't be cancelled"
                } ?? "\(what) waiting for the server…")
            }
        }
    }
}

/// A short state under a row, in the quiet grey.
struct QuietLine: View {
    let text: String

    var body: some View {
        Text(text)
            .phoneFont(PhoneFont.time.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
    }
}

// MARK: - Between rows

/// A tribe's note ("Ann joined"), a request to join, or a missing original.
struct RowNote: View {
    let text: String
    var italic = false

    var body: some View {
        Text(text)
            .phoneFont(.secondary)
            .italic(italic)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.phoneGutter)
            .padding(.vertical, 6)
    }
}

/// "Today" as an outline badge on a hairline.
struct DayDividerLine: View {
    let date: Date

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Theme.divider.frame(height: 1)
            Text(Formatting.dayHeading(date))
                .phoneFont(PhoneFont.time.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(Theme.divider))
                .fixedSize()
            Theme.divider.frame(height: 1)
        }
        .padding(.horizontal, Theme.phoneGutter)
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The Mac's blue "New messages" line: blue, because blue is unread.
struct NewMessagesLine: View {
    var body: some View {
        HStack(spacing: 10) {
            Theme.accent.frame(height: 1)
            Text("New messages")
                .phoneFont(PhoneFont.time.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
        .padding(.horizontal, Theme.phoneGutter)
        .padding(.vertical, 6)
    }
}

/// "4 replies" on a hairline, between a thread's original and its replies.
struct RepliesLine: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(count == 0 ? "No replies yet" : Formatting.replies(count))
                .phoneFont(.time)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize()
            Theme.divider.frame(height: 1)
        }
        .padding(.horizontal, Theme.phoneGutter)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
