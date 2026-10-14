import PeelCore
import PeelUI
import SwiftUI

/// The open chat's newest messages, read only: the model's rows
/// (`AppModel.chatRows`), flat as on the Mac, newest at the bottom. No
/// composer, attachments, threads or older pages yet (F2b).
struct ConversationScreen: View {
    @Environment(AppModel.self) private var model
    let chat: String

    var body: some View {
        let rows = model.selectedChat == chat ? model.chatRows : []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if row.startsDay { DayLine(date: row.date) }
                    if row.startsNew { NewMessagesLine() }
                    PhoneRow(row: row)
                }
                Text("Read only on iPhone for now.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.lg)
            }
            .padding(.vertical, Theme.Space.md)
        }
        .defaultScrollAnchor(.bottom)
        .background(Theme.background)
        .overlay {
            if let notice = model.conversationNotices[chat] {
                ProblemText(notice).padding(20)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }

    private var title: String {
        model.conversations.first { $0.chat == chat }?.title ?? ""
    }
}

/// One row: a message with its run's header, a payment, a request to pay,
/// or a tribe's note.
private struct PhoneRow: View {
    let row: ChatRow

    private var message: Message { row.message }

    var body: some View {
        switch row.kind {
        case .message:
            run { MessageBody(row: row) }
        case .payment:
            run { PaymentBody(row: row) }
        case .paymentRequest:
            run { RequestBody(row: row) }
        case .request:
            note("\(row.sender.name) wants to join" + (row.approved.map { $0 ? " · Approved" : " · Declined" } ?? ""))
        case .note:
            note(message.membershipNote(by: row.sender))
        case .missingOriginal:
            note("The original message isn't on this iPhone.")
        case .replies(let count):
            note(Formatting.replies(count))
        }
    }

    /// The run's photo, name and time on its first row; the rest sit under it.
    private func run(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if row.startsRun {
                Avatar(name: row.sender.avatarName, url: row.sender.photoURL, size: 32, hue: row.sender.hue)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if row.startsRun {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.sender.name)
                            .font(Theme.font(14, .semibold))
                            .foregroundStyle(row.sender.hue.name)
                            .lineLimit(1)
                        Text(Formatting.time(row.date))
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, row.startsRun ? 10 : 2)
        .padding(.bottom, row.endsRun ? 2 : 0)
        .background(message.fromMe ? Theme.accent.opacity(0.06) : .clear)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(13))
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, 6)
    }
}

/// A message's words through the Mac's renderer (`MessageText`: links,
/// mentions, emphasis, lists, code). Attachments say what they are.
private struct MessageBody: View {
    let row: ChatRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(row.shown.enumerated()), id: \.offset) { _, message in
                if message.deleted {
                    Text("Message deleted").italic().foregroundStyle(Theme.secondaryText)
                } else {
                    if message.attachmentKind != nil || message.giphy != nil {
                        Label(attachment(message), systemImage: "paperclip")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    let text = message.shownText
                    if !text.isEmpty { MessageText(text: text, chat: message.chat, size: PhoneFont.message.size) }
                }
            }
            if let summary = row.summary {
                Text(Formatting.replies(summary.count))
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.link)
            }
            if row.message.notSent {
                Text("Not sent")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(Theme.font(16))
    }

    /// "Image", "File: notes.pdf", "GIF", as a list names it.
    private func attachment(_ message: Message) -> String {
        let what = message.giphy != nil ? "GIF" : message.preview
        return "\(what), shown on the Mac for now"
    }
}

/// Sats sent in a direct message, and the note with them.
private struct PaymentBody: View {
    let row: ChatRow

    var body: some View {
        let message = row.message
        VStack(alignment: .leading, spacing: 4) {
            if message.deleted {
                Text("This payment has been deleted").italic().foregroundStyle(Theme.secondaryText)
            } else {
                Label {
                    if let msat = message.amountMsat, msat > 0 {
                        let amount = Text(Sats.format(msat: msat)).fontWeight(.semibold)
                        Text(message.fromMe ? "You sent \(amount)" : "\(row.sender.name) sent you \(amount)")
                    } else {
                        Text(message.fromMe ? "You sent a payment" : "\(row.sender.name) sent a payment with no sats")
                    }
                } icon: {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.attention)
                }
                .monospacedDigit()
                if let note = message.content?.trimmed.nilIfEmpty {
                    MessageText(text: note, chat: message.chat, size: PhoneFont.message.size)
                }
            }
        }
        .font(Theme.font(16))
    }
}

/// A request to be paid: who asks, how much, its memo, and whether it is
/// paid. Paying comes with I4.
private struct RequestBody: View {
    let row: ChatRow

    var body: some View {
        let invoice = row.paymentRequest?.invoice
        VStack(alignment: .leading, spacing: 4) {
            Label {
                if let invoice {
                    Text("\(row.sender.label) requested \(Text(Sats.format(msat: invoice.amountMsat)).fontWeight(.semibold))")
                } else {
                    Text("\(row.sender.label) requested a payment")
                }
            } icon: {
                Image(systemName: "bolt").foregroundStyle(Theme.attention)
            }
            .monospacedDigit()
            if let memo = invoice?.memo, !memo.isEmpty { Text(memo) }
            if case .paid = row.paymentRequest?.state {
                Label("Paid", systemImage: "checkmark")
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(Theme.font(16))
    }
}

/// "Today", "Yesterday", "Monday 5 October" between days.
private struct DayLine: View {
    let date: Date

    var body: some View {
        Text(Formatting.dayHeading(date))
            .font(Theme.font(13, .semibold))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xs)
    }
}

/// Where the chat's unread messages start, as it was opened.
private struct NewMessagesLine: View {
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Rectangle().fill(Theme.accent).frame(height: 1)
            Text("New messages")
                .font(Theme.font(12, .semibold))
                .foregroundStyle(Theme.accent)
                .fixedSize()
            Rectangle().fill(Theme.accent).frame(height: 1)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
    }
}
