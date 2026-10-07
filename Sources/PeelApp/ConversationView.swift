import SwiftUI
import PeelCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                title: conversation.name,
                avatar: Avatar(name: conversation.name, url: conversation.photoURL, size: 32)
            )
            MessageList(messages: model.messages)
            Composer(draft: $draft, placeholder: "Message \(conversation.name)", focused: $composing, send: send)
        }
        .onAppear { composing = true }
        .onChange(of: conversation.chat) { composing = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }
}

struct MessageList: View {
    let messages: [Message]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if startsNewDay(at: index) {
                            DayDivider(date: message.date)
                        }
                        MessageRow(message: message)
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

/// One message: theirs on the left, yours on the right.
struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromMe { Spacer(minLength: 80) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                Text(message.content ?? "")
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
                    .opacity(message.delivery == .pending ? 0.6 : 1)
                HStack(spacing: 6) {
                    if message.delivery == .failed {
                        Text("Not delivered")
                    }
                    Text(message.date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                }
                .font(Theme.font(11))
                .foregroundStyle(Theme.secondaryText)
            }
            if !message.fromMe { Spacer(minLength: 80) }
        }
    }
}

struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.font(14))
                .lineLimit(1...8)
                .focused(focused)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }
}
