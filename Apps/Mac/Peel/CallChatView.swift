import SwiftUI
import PeelCore
import PeelUI

/// The call's chat panel (beside the stage in the call window): the
/// messages of this call, a "Jamie is thinking…" line while Jamie works,
/// and a composer. Jamie's hints (the placeholder, the suggestion, the
/// mention highlight) show only while a Jamie is in the call; between
/// people it is plain chat.
struct CallChatView: View {
    static let width: CGFloat = 300

    let call: CallSession
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.callDivider.frame(height: 1)
            list
            composer
        }
        .frame(width: Self.width)
        .background(Theme.callBackground)
    }

    private var header: some View {
        HStack {
            Text("Chat").font(Theme.font(13, .semibold))
            Spacer()
            IconButton("xmark", help: "Close chat") { call.setChatOpen(false) }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 38)
    }

    // MARK: The list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(call.chatRows) { row in
                        ChatRowView(call: call, row: row)
                            .id(row.id)
                    }
                    if call.jamieThinking {
                        Text("Jamie is thinking…")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                            .id(Self.thinkingID)
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: call.chatRows.last?.id) { scrollToNewest(proxy) }
            .onChange(of: call.jamieThinking) { scrollToNewest(proxy) }
            .onAppear { scrollToNewest(proxy, animated: false) }
        }
    }

    private static let thinkingID = "jamie-thinking"

    private func scrollToNewest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target = call.jamieThinking ? Self.thinkingID : call.chatRows.last?.id
        guard let target else { return }
        if animated { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .bottom) } } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    // MARK: The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let notice = call.chatNotice {
                Text(notice).font(Theme.font(12)).foregroundStyle(Theme.secondaryText)
            }
            if call.jamieInCall, Self.mentionPrefix(in: draft) != nil {
                Button { draft = CallChatWire.completingJamie(draft) ?? draft } label: {
                    Text("Jamie").font(Theme.font(12, .medium)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.Space.sm).padding(.vertical, 2)
                        .background(Theme.mentionFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mention Jamie")
            }
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                TextField("", text: $draft, prompt: Text(call.jamieInCall ? "Message, @Jamie to ask" : "Message"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                    // Tab completes a started @mention of Jamie; with nothing to
                    // complete it is left alone and moves focus as usual.
                    .onKeyPress(.tab) {
                        guard call.jamieInCall, let completed = CallChatWire.completingJamie(draft) else { return .ignored }
                        draft = completed
                        return .handled
                    }
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 6)
                    .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(focused ? Theme.accent : Theme.inputBorder) }
                    .accessibilityLabel("Message")
                IconButton("arrow.up", help: "Send", variant: .outline, action: send)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Space.md)
        .overlay(alignment: .top) { Theme.callDivider.frame(height: 1) }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        draft = ""
        Task { await call.sendChat(text) }
    }

    /// The last word of `text` when it is `@` or the start of `@jamie`
    /// (but not all of it), which the suggestion would complete.
    static func mentionPrefix(in text: String) -> String? {
        guard let word = text.split(whereSeparator: \.isWhitespace).last.map(String.init),
              text.last?.isWhitespace == false, word.hasPrefix("@")
        else { return nil }
        let typed = word.dropFirst().lowercased()
        return typed.count < "jamie".count && "jamie".hasPrefix(typed) ? word : nil
    }
}

/// One message: who (and when), then its text.
private struct ChatRowView: View {
    let call: CallSession
    let row: CallChatLog.Row

    var body: some View {
        let message = row.message
        let jamie = row.message.isFromJamie
        VStack(alignment: row.isMine ? .trailing : .leading, spacing: 2) {
            HStack(spacing: Theme.Space.xs) {
                Text(row.isMine ? "You" : jamie ? "Jamie" : message.sender ?? "")
                    .font(Theme.font(12, .bold))
                    .foregroundStyle(jamie ? Theme.accent : Theme.secondaryText)
                if message.isVoice {
                    Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                        .accessibilityLabel("Spoken")
                }
                Text(Formatting.time(message.timestamp))
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(Self.body(message.text, highlightingJamie: call.jamieInCall))
                .font(Theme.font(13))
                .textSelection(.enabled)
                .multilineTextAlignment(row.isMine ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: row.isMine ? .trailing : .leading)
            if !message.artifacts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    // By position: two entries may share an id.
                    ForEach(Array(message.artifacts.enumerated()), id: \.offset) { _, artifact in
                        AgentArtifactLine(artifact: artifact)
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
            if row.failed {
                HStack(spacing: Theme.Space.xs) {
                    Text("Not sent").foregroundStyle(Theme.attention)
                    Button("Retry") { Task { await call.retryChat(row.id) } }
                        .buttonStyle(.peel(.link, size: .sm))
                        .accessibilityLabel("Retry sending")
                }
                .font(Theme.font(11))
            }
        }
        .frame(maxWidth: .infinity, alignment: row.isMine ? .trailing : .leading)
    }

    /// The text as markdown, line by line so a `- [Title](https://…)` list
    /// reads as bullets with a live link; plain text when it does not parse.
    /// `@Jamie` takes the accent colour while a Jamie is on the call.
    static func body(_ text: String, highlightingJamie: Bool) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = AttributedString()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            var source = String(line)
            if let bullet = source.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) {
                source.replaceSubrange(bullet, with: "• ")
            }
            result += (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        }
        if highlightingJamie {
            var from = result.startIndex
            while let found = result[from...].range(of: "@jamie", options: .caseInsensitive) {
                result[found].foregroundColor = Theme.accent
                from = found.upperBound
            }
        }
        return result
    }
}
