import SwiftUI
import PeelCore

/// A rounded field with the attach button (and in a direct message the
/// send-sats bolt) before it and the round send arrow after it. Over the field: what it is replying to, and the files
/// waiting to go. A chat and each open thread have their own
/// (`ComposerID`); its draft, what it replies to and the files it holds
/// live in the model, so the message menus can set them and a draft
/// outlives the view (a thread covering its chat, another chat opened).
struct Composer: View {
    @Environment(AppModel.self) private var model
    let composer: ComposerID
    let placeholder: String
    /// Who `@` offers, in a tribe; nil elsewhere. Asked each time an `@word`
    /// starts, so it is current without querying on every message.
    var loadMentionable: (@MainActor @Sendable () async -> [TribeMember])?
    /// In a direct message: who the bolt beside the field sends sats to.
    var paysTo: String?

    @State private var sendingSats = false
    @State private var mentionable: [TribeMember] = []
    @State private var mention: String?
    @State private var highlighted = 0
    @State private var insertion: MentionInsertion?
    @State private var dismissedMention: String?

    private var files: [URL] { model.pendingFiles[composer] ?? [] }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[composer] ?? "" }, set: { model.drafts[composer] = $0 })
    }

    private var canSend: Bool {
        !(model.drafts[composer] ?? "").trimmed.isEmpty || !files.isEmpty
    }

    private func send() {
        guard canSend else { return }
        Task { await model.sendDraft(from: composer) }
    }

    /// Aliases starting with what follows the `@`, ignoring case, as the Mac
    /// app matches them; an exact match first, so Return never swaps a
    /// finished `@ann` for `@anna`.
    private var suggestions: [TribeMember] {
        guard let mention, mention != dismissedMention else { return [] }
        let typed = mention.lowercased()
        let matches = mentionable.filter { $0.alias.lowercased().hasPrefix(typed) }
        return Array((matches.filter { $0.alias == mention } + matches.filter { $0.alias != mention }).prefix(20))
    }

    private func choose(_ member: TribeMember) {
        insertion = MentionInsertion(id: (insertion?.id ?? 0) + 1, alias: member.alias)
    }

    /// Arrow keys move through the suggestions, Return or Tab takes one, Escape closes them.
    private func handle(_ key: SuggestionKey) -> Bool {
        let shown = suggestions
        guard !shown.isEmpty else { return false }
        switch key {
        case .up: highlighted = (highlighted + shown.count - 1) % shown.count
        case .down: highlighted = (highlighted + 1) % shown.count
        case .accept: choose(shown[min(highlighted, shown.count - 1)])
        case .dismiss: dismissedMention = mention
        }
        return true
    }

    @ViewBuilder private var field: some View {
        #if os(macOS)
        ComposerField(
            text: draft, placeholder: placeholder, focusRequest: model.composerFocus[composer] ?? 0, submit: send,
            mention: $mention, insertion: insertion, suggestionKey: handle,
            escape: { withAnimation(.easeIn(duration: 0.15)) { model.escape(in: composer) } }
        )
        .onChange(of: mention) { highlighted = 0 }
        .task(id: mention != nil) {
            if mention != nil, let loadMentionable { mentionable = await loadMentionable() }
        }
        #else
        TextField(placeholder, text: draft, axis: .vertical)
            .lineLimit(1...8)
            .onSubmit(send)
        #endif
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                model.chooseFiles(for: composer)
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(Theme.divider))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Attach files")
            if let paysTo {
                Button {
                    sendingSats = true
                } label: {
                    Image(systemName: "bolt")
                        .font(.system(size: 14))
                        .foregroundStyle(sendingSats ? Theme.attention : Theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(Theme.divider))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Send or request sats")
                .peelPopover(isPresented: $sendingSats) {
                    SendSatsPanel(chat: composer.chat, name: paysTo) { sendingSats = false }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if let target = model.replyTargets[composer] {
                    ReplyBar(message: target) { model.cancelReply(in: composer) }
                }
                if !files.isEmpty {
                    PendingFilesTray(composer: composer, files: files)
                        .padding(.horizontal, 10)
                }
                field
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.divider))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Theme.accent : Theme.secondaryText.opacity(0.5))
            .disabled(!canSend)
            // No Cmd-Return here: with a thread open two composers share the
            // window, and Return in the field already sends from the right one.
            .help("Send (Return). Shift-Return for a new line.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .overlay(alignment: .topLeading) {
            let shown = suggestions
            if !shown.isEmpty {
                // Its bottom on the composer's top, at its own fixed height:
                // drawn above the composer and inside the window, never
                // squeezed into the composer's height or below it.
                MentionSuggestions(members: shown, highlighted: min(highlighted, shown.count - 1), choose: choose)
                    .padding(.leading, 62)
                    .offset(y: -MentionSuggestions.height(for: shown.count))
            }
        }
        .zIndex(1)
    }
}

/// "Replying to Name" and the start of what they said, over the field.
private struct ReplyBar: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                (Text("Replying to ") + Text(message.fromMe ? "yourself" : model.sender(of: message).name).font(Theme.font(12, .bold)))
                    .font(Theme.font(12))
                Text(message.preview)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop replying (Escape)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.quote, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }
}

/// Who an `@` can mention, just above the composer, in the menu's style;
/// scrolls past seven, keeping the highlighted one in view.
struct MentionSuggestions: View {
    let members: [TribeMember]
    let highlighted: Int
    let choose: (TribeMember) -> Void

    private static let rowHeight: CGFloat = 28
    private static let visibleRows = 7
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 4

    /// Its whole height for `count` suggestions, so it can sit just above the composer.
    static func height(for count: Int) -> CGFloat {
        CGFloat(min(count, visibleRows)) * rowHeight + padding * 2 + gap
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                        HStack(spacing: 8) {
                            Avatar(name: member.alias, url: member.photoURL, size: 20)
                            Text(member.alias)
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: Self.rowHeight)
                        .background(index == highlighted ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { choose(member) }
                        .id(index)
                    }
                }
            }
            .scrollIndicators(members.count > Self.visibleRows ? .automatic : .never)
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
        }
        .frame(height: CGFloat(min(members.count, Self.visibleRows)) * Self.rowHeight)
        .padding(Self.padding)
        .frame(width: 240)
        .menuBoxed()
        .padding(.bottom, Self.gap)
    }
}
