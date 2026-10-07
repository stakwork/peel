import SwiftUI
import PeelCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            MessageList(messages: model.messages)
            Composer(draft: $draft, focused: $composing, send: send)
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
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if startsNewDay(at: index) {
                            DayHeading(date: message.date)
                        }
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
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

struct DayHeading: View {
    let date: Date

    var body: some View {
        Text(Formatting.dayHeading(date))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromMe { Spacer(minLength: 80) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                Text(message.content ?? "")
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(message.fromMe ? Color.white : Color.primary)
                    .opacity(message.delivery == .pending ? 0.6 : 1)
                HStack(spacing: 6) {
                    if message.delivery == .failed {
                        Text("Not delivered")
                    }
                    Text(message.date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            if !message.fromMe { Spacer(minLength: 80) }
        }
    }

    private var bubble: AnyShapeStyle {
        message.fromMe ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary)
    }
}

struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused(focused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
