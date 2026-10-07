import SwiftUI
import PeelCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    @State private var draft = ""
    @State private var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                title: conversation.name,
                avatar: Avatar(name: conversation.name, url: conversation.photoURL, size: 32)
            )
            MessageList(messages: model.messages)
            if let notice = model.conversationNotices[conversation.chat] {
                ConversationNotice(text: notice) { model.dismissNotice(in: conversation.chat) }
            }
            Composer(draft: $draft, placeholder: "Message \(conversation.name)", focusRequest: focusRequest, send: send)
        }
        .onAppear { focusRequest += 1 }
        .onChange(of: conversation.chat) { focusRequest += 1 }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }
}

/// An error that belongs to this conversation, such as a send the server
/// refused. Quiet, not red: nothing was destroyed.
struct ConversationNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.attention)
            Text(text)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.divider))
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }
}

struct MessageList: View {
    let messages: [Message]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if startsNewDay(at: index) {
                            DayDivider(date: message.date)
                        }
                        MessageRow(message: message, endsRun: endsRun(at: index))
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, last in
                if let last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func startsNewDay(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(messages[index].date, inSameDayAs: messages[index - 1].date)
    }

    /// The last of a run of messages from one side, a few minutes apart, shows
    /// the time under it; the others show it on hover.
    private func endsRun(at index: Int) -> Bool {
        guard index + 1 < messages.count else { return true }
        let message = messages[index], next = messages[index + 1]
        return next.fromMe != message.fromMe
            || next.date.timeIntervalSince(message.date) > 5 * 60
            || startsNewDay(at: index + 1)
    }
}

struct DayDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            Theme.divider.frame(height: 1)
            Text(Formatting.dayHeading(date))
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(Theme.divider))
                .fixedSize()
            Theme.divider.frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

/// One message: theirs on the left, yours on the right. The time sits under
/// the last message of a run and appears beside any bubble on hover, without
/// moving anything.
struct MessageRow: View {
    let message: Message
    let endsRun: Bool

    @State private var hovering = false

    var body: some View {
        // A pending send becomes retryable after a timeout, with no change to
        // the row itself, so those rows redraw once when it passes.
        if message.delivery == .pending {
            TimelineView(.explicit([message.date.addingTimeInterval(Message.confirmationTimeout + 0.5)])) { context in
                row(now: context.date)
            }
        } else {
            row(now: .now)
        }
    }

    private func row(now: Date) -> some View {
        let retryable = message.isRetryable(now: now)
        return HStack(alignment: .center, spacing: 8) {
            if message.fromMe {
                Spacer(minLength: 80)
                hoverTime
            }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                MessageBubble(message: message)
                    .opacity(message.delivery == .pending && !retryable ? 0.6 : 1)
                if retryable {
                    UndeliveredActions(message: message)
                } else if endsRun {
                    MessageMeta(message: message)
                }
            }
            if !message.fromMe {
                hoverTime
                Spacer(minLength: 80)
            }
        }
        .padding(.bottom, endsRun ? 6 : 0)
        .onHover { hovering = $0 }
    }

    /// Always laid out, so hovering never shifts the row; only its opacity changes.
    private var hoverTime: some View {
        MessageMeta(message: message)
            .opacity(hovering && !endsRun ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// Its own view, so hovering the row does not redo link detection.
struct MessageBubble: View {
    let message: Message

    var body: some View {
        Text(LinkText.attributed(message.content ?? "", onSentBubble: message.fromMe))
            .font(Theme.font(14))
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.fromMe ? Theme.sentBubble : Theme.receivedBubble,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .foregroundStyle(message.fromMe ? Theme.sentText : Theme.text)
            .help(message.date.formatted(date: .complete, time: .shortened))
    }
}

/// The time, and for a message of ours the server's confirmation: a green
/// bolt, as in the official apps.
struct MessageMeta: View {
    let message: Message

    var body: some View {
        HStack(spacing: 4) {
            if message.fromMe, message.delivery == .delivered {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.confirmed)
                    .help("Delivered")
            }
            Text(message.date, format: .dateTime.hour().minute())
                .monospacedDigit()
        }
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .fixedSize()
    }
}

/// "Not delivered" with Retry and Discard. Discard asks once, in place.
struct UndeliveredActions: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 10) {
            if confirmingDiscard {
                Text("Discard this message?")
                    .foregroundStyle(Theme.secondaryText)
                Button("Discard") { Task { await model.discard(message) } }
                    .foregroundStyle(Theme.destructive)
                Button("Keep") { confirmingDiscard = false }
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Not delivered")
                    .foregroundStyle(Theme.secondaryText)
                Button("Retry") { Task { await model.resend(message) } }
                    .foregroundStyle(Theme.accent)
                Button("Discard") { confirmingDiscard = true }
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .font(Theme.font(11, .medium))
    }
}

/// Makes web links in message text clickable. Only https links: anything
/// else stays plain text.
enum LinkText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String, onSentBubble: Bool) -> AttributedString {
        var result = AttributedString(text)
        guard let detector else { return result }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, url.scheme?.lowercased() == "https",
                  let textRange = Range(match.range, in: text),
                  let start = AttributedString.Index(textRange.lowerBound, within: result),
                  let end = AttributedString.Index(textRange.upperBound, within: result) else { continue }
            result[start..<end].link = url
            result[start..<end].underlineStyle = .single
            // The accent blue is too faint on the sent bubble; keep the text colour there.
            result[start..<end].foregroundColor = onSentBubble ? Theme.sentText : Theme.accent
        }
        return result
    }
}

struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    let focusRequest: Int
    let send: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var field: some View {
        #if os(macOS)
        ComposerField(text: $draft, placeholder: placeholder, focusRequest: focusRequest, submit: send)
        #else
        TextField(placeholder, text: $draft, axis: .vertical)
            .lineLimit(1...8)
            .onSubmit(send)
        #endif
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            field
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.input, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.divider))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Theme.accent : Theme.secondaryText.opacity(0.5))
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (Return). Shift-Return for a new line.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }
}
