import SwiftUI
import PeelCore

/// One rounded field that holds everything: what it is replying to and the
/// files waiting to go over the text, then a row under it with attach (and
/// in a direct message the send-sats bolt) at the left and send at the
/// right (shadcn's `InputGroup` with its addon at the block end). A chat
/// and each open thread have their own (`ComposerID`); its draft, what it replies to and the files it holds
/// live in the model, so the message menus can set them and a draft
/// outlives the view (a thread covering its chat, another chat opened).
struct Composer: View {
    @Environment(AppModel.self) private var model
    let composer: ComposerID
    let placeholder: String
    /// Who `@` offers, in a tribe; nil elsewhere. Asked each time an `@word`
    /// starts, so it is current without querying on every message.
    var loadMentionable: (@MainActor @Sendable () async -> [TribeMember])?
    /// In a direct message: who the bolt in the field sends sats to.
    var paysTo: String?

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
            text: draft, placeholder: placeholder, focusRequest: model.composerFocus[composer] ?? 0,
            // A chat opened from the sidebar's keys leaves them there.
            focusesOnAppear: !(model.sidebarHasKeys && composer.thread == nil), submit: send,
            mention: $mention, insertion: insertion, suggestionKey: handle,
            escape: { withAnimation(.easeIn(duration: 0.15)) { model.escape(in: composer) } },
            attach: { model.attach($0, to: composer) },
            dropTargeted: { model.dropTargeted($0, composer: composer) }
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

    /// The composer's distance from the window's sides; the mention
    /// suggestions line up with the field's edge at it.
    private static let inset: CGFloat = 20
    /// The buttons row's distance from the field's edge.
    fileprivate static let buttonsInset: CGFloat = 6
    /// The field's corners, concentric with the buttons' (`Theme.Radius.control`)
    /// at `buttonsInset` in from them.
    fileprivate static let radius = Theme.Radius.control + buttonsInset

    var body: some View {
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
                .padding(.top, 5)
            buttons
                .padding(.horizontal, Self.buttonsInset)
                .padding(.bottom, Self.buttonsInset)
        }
        .background {
            // A click anywhere in the field that no button or the text takes
            // puts the cursor in the text.
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Theme.input)
                .onTapGesture { model.composerFocus[composer, default: 0] += 1 }
                .accessibilityHidden(true)
        }
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Theme.divider))
        .padding(.horizontal, Self.inset)
        .padding(.top, 6)
        .padding(.bottom, Theme.Space.lg)
        .overlay(alignment: .topLeading) {
            let shown = suggestions
            if !shown.isEmpty {
                // Its bottom on the composer's top, at its own fixed height:
                // drawn above the composer and inside the window, never
                // squeezed into the composer's height or below it.
                MentionSuggestions(members: shown, highlighted: min(highlighted, shown.count - 1), choose: choose)
                    .padding(.leading, Self.inset)
                    .offset(y: -MentionSuggestions.height(for: shown.count))
            }
        }
        .zIndex(1)
    }

    /// The field's last row: attach (and in a direct message the bolt) at
    /// the left, send at the right, under the text so its left edge stays.
    private var buttons: some View {
        HStack(spacing: 2) {
            IconButton("paperclip", help: "Attach files") {
                model.chooseFiles(for: composer)
            }
            if let paysTo {
                let sendingSats = Binding(
                    get: { model.sendingSats == composer },
                    set: { model.sendingSats = $0 ? composer : nil }
                )
                IconButton("bolt", help: "Send or request sats", lit: sendingSats.wrappedValue) {
                    sendingSats.wrappedValue = true
                }
                .accessibilityAddTraits(sendingSats.wrappedValue ? .isSelected : [])
                .peelPopover(isPresented: sendingSats) {
                    SendSatsPanel(chat: composer.chat, name: paysTo) { sendingSats.wrappedValue = false }
                }
                // The view stays when another chat opens in its place: the
                // panel left behind is closed, not opened again on coming back.
                .onChange(of: composer) { old, _ in if model.sendingSats == old { model.sendingSats = nil } }
            }
            Spacer(minLength: 8)
            Button(action: send) {
                // As wide as `.sm` is tall, less its padding: a square.
                // `IconButton` has no primary variant.
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: PeelButton.Size.sm.height - 2 * PeelButton.Size.sm.padding)
            }
            // Filled when there is something to send, a muted arrow otherwise.
            .buttonStyle(.peel(canSend ? .primary : .ghost, size: .sm))
            .disabled(!canSend)
            // No Cmd-Return here: with a thread open two composers share the
            // window, and Return in the field already sends from the right one.
            .help("Send (Return). Shift-Return for a new line.")
            .accessibilityLabel("Send")
        }
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
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                let sender = model.sender(of: message)
                (Text("Replying to ") + Text(message.fromMe ? "yourself" : sender.name).font(Theme.font(12, .bold))
                    .foregroundColor(sender.hue.name))
                    .font(Theme.font(12))
                Text(message.preview)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            // Its icon, words and fill pass a click to the field below,
            // which puts the cursor in the text; only the ✕ takes one.
            .allowsHitTesting(false)
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
        .padding(.vertical, Theme.Space.sm)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Composer.radius, topTrailingRadius: Composer.radius, style: .continuous)
                .fill(Theme.quote)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1).allowsHitTesting(false) }
    }
}

/// Who an `@` can mention, just above the composer, in the menu's style;
/// scrolls past seven, keeping the highlighted one in view.
struct MentionSuggestions: View {
    @Environment(AppModel.self) private var model
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
                        HStack(spacing: Theme.Space.sm) {
                            Avatar(name: member.alias, url: member.photoURL, size: Theme.AvatarSize.sm,
                                   hue: model.hue(of: member))
                            Text(member.alias)
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.sm)
                        .frame(height: Self.rowHeight)
                        .background(index == highlighted ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
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
