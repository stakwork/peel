import SwiftUI
import PeelAgent
import PeelCore
import PeelUI

/// One rounded field that holds everything: what it is replying to and the
/// files waiting to go over a single row of attach (and in a direct message
/// the send-sats bolt), the text, and send. The text grows upward from one
/// line; the buttons stay level with its last. A chat
/// and each open thread have their own (`ComposerID`); its draft, what it replies to and the files it holds
/// live in the model, so the message menus can set them and a draft
/// outlives the view (a thread covering its chat, another chat opened).
/// The agent's DM's takes text alone; while its reply runs, `stop` turns
/// send into Stop.
struct Composer: View {
    @Environment(AppModel.self) private var model
    let composer: ComposerID
    let placeholder: String
    /// Who `@` offers, in a tribe; nil elsewhere. Asked each time an `@word`
    /// starts, so it is current without querying on every message.
    var loadMentionable: (@MainActor @Sendable () async -> [TribeMember])?
    /// In a direct message: who the bolt in the field sends sats to.
    var paysTo: String?
    /// While a reply runs: send is Stop, and Escape stops it too.
    var stop: (@MainActor () -> Void)?

    @State private var mentionable: [TribeMember] = []
    @State private var mention: String?
    @State private var highlighted = 0
    @State private var insertion: MentionInsertion?
    @State private var dismissedMention: String?

    private var files: [URL] { model.pendingFiles[composer] ?? [] }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[composer] ?? "" }, set: { model.drafts[composer] = $0 })
    }

    /// A restore that settled with no name to recover leaves this empty
    /// until it is set (onboarding asks for one then; this is the backstop).
    private var hasName: Bool { model.myAlias?.nilIfEmpty != nil }

    private var canSend: Bool {
        stop == nil && hasName && (!(model.drafts[composer] ?? "").trimmed.isEmpty || !files.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        Task { await model.sendDraft(from: composer) }
    }

    /// What the word being typed can become (`MentionQuery`), an exact
    /// match first, so Return never swaps a finished `@ann` for `@anna`: in
    /// a tribe, its people; in the agent's DM, the Stadeum workspaces it can
    /// ask (by id or label) and, for a `/` opening the message, its commands.
    private var suggestions: [ComposerSuggestion] {
        guard let mention, mention != dismissedMention, let trigger = mention.first else { return [] }
        let typed = String(mention.dropFirst())
        let agent = model.isAgentChat(composer)
        if trigger == "/" { return agent ? MentionQuery.suggestions(ComposerSuggestion.commands, names: \.names, typed: typed) : [] }
        if agent { return MentionQuery.suggestions(model.stadeum.live.map(ComposerSuggestion.init(workspace:)), names: \.names, typed: typed) }
        return MentionQuery.suggestions(mentionable, typed: typed).map(ComposerSuggestion.init(member:))
    }

    private func choose(_ suggestion: ComposerSuggestion) {
        insertion = MentionInsertion(id: (insertion?.id ?? 0) + 1, text: suggestion.insert)
    }

    /// Arrow keys move through the suggestions, Return or Tab takes one, Escape closes them.
    private func handle(_ key: SuggestionKey) -> Bool {
        let shown = suggestions
        guard !shown.isEmpty else { return false }
        switch key {
        case .up: highlighted = (highlighted + shown.count - 1) % shown.count
        case .down: highlighted = (highlighted + 1) % shown.count
        case .accept:
            let suggestion = shown[min(highlighted, shown.count - 1)]
            // A command typed in full sends on Return, as it would with no menu.
            if suggestion.kind == .command, suggestion.insert == mention { return false }
            choose(suggestion)
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
            mention: $mention, commands: model.isAgentChat(composer), insertion: insertion, suggestionKey: handle,
            escape: {
                // The memory beside the agent chat first: the least to lose.
                if model.isAgentChat(composer), model.memoryPanel != nil {
                    return model.escape(in: composer)
                }
                if let stop {
                    stop()
                    return true
                }
                // A reply cancelled, else the thread closed, with its slide.
                return ThreadPanel.closing { model.escape(in: composer) }
            },
            attach: { if acceptsFiles { model.attach($0, to: composer) } },
            dropTargeted: { if acceptsFiles { model.dropTargeted($0, composer: composer) } }
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
            // One line: the text between the buttons, which keep to its
            // last line as Shift-Return grows it upward.
            HStack(alignment: .bottom, spacing: 2) {
                leadingButtons
                field
                    // As tall as the buttons on one line, its text level with them.
                    .frame(minHeight: PeelButton.Size.sm.height)
                    .padding(.leading, hasLeadingButtons ? 2 : 4)
                trailingButton
            }
            .padding(Self.buttonsInset)
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
                MentionSuggestions(suggestions: shown, highlighted: min(highlighted, shown.count - 1), choose: choose)
                    .padding(.leading, Self.inset)
                    .offset(y: -MentionSuggestions.height(for: shown.count))
            }
        }
        .zIndex(1)
    }

    private var acceptsFiles: Bool { model.takesFiles(composer) }

    private var hasLeadingButtons: Bool { acceptsFiles || (paysTo != nil && composer.chat != nil) }

    /// Attach (and in a direct message the bolt), left of the text.
    @ViewBuilder private var leadingButtons: some View {
        if hasLeadingButtons {
            HStack(spacing: 2) {
                if acceptsFiles {
                    IconButton("paperclip", help: "Attach files") {
                        model.chooseFiles(for: composer)
                    }
                }
                if let paysTo, let chat = composer.chat {
                    let sendingSats = Binding(
                        get: { model.sendingSats == composer },
                        set: { model.sendingSats = $0 ? composer : nil }
                    )
                    IconButton("bolt", help: "Send or request sats", lit: sendingSats.wrappedValue) {
                        sendingSats.wrappedValue = true
                    }
                    .accessibilityAddTraits(sendingSats.wrappedValue ? .isSelected : [])
                    .peelPopover(isPresented: sendingSats) {
                        SendSatsPanel(chat: chat, name: paysTo) { sendingSats.wrappedValue = false }
                    }
                    // The view stays when another chat opens in its place: the
                    // panel left behind is closed, not opened again on coming back.
                    .onChange(of: composer) { old, _ in if model.sendingSats == old { model.sendingSats = nil } }
                }
            }
        }
    }

    /// Send, or Stop while a reply runs, right of the text.
    @ViewBuilder private var trailingButton: some View {
        if let stop {
            Button(action: stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: PeelButton.Size.sm.height - 2 * PeelButton.Size.sm.padding)
            }
            .buttonStyle(.peel(.outline, size: .sm))
            .help("Stop the reply (Escape)")
            .accessibilityLabel("Stop")
        } else {
            sendButton
        }
    }

    private var sendButton: some View {
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
        .help(hasName ? "Send (Return). Shift-Return for a new line." : "Set your name in Profile first")
        .accessibilityLabel("Send")
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

/// One thing the word being typed can become: a tribe's member, a Stadeum
/// workspace the agent can ask, or one of the agent DM's commands.
struct ComposerSuggestion: Identifiable, Equatable {
    enum Kind: Equatable { case member(TribeMember), workspace, command }
    let id: String
    /// What replaces the word, its trigger included.
    let insert: String
    let title: String
    var detail: String?
    /// What the typed word is matched against, without the trigger.
    let names: [String]
    let kind: Kind

    init(member: TribeMember) {
        self.init(id: member.id, insert: "@" + member.alias, title: member.alias, names: [member.alias], kind: .member(member))
    }

    /// By its label, with its `@id` beside it; matched by either.
    init(workspace: HivePeer) {
        self.init(id: "@" + workspace.id, insert: "@" + workspace.id, title: workspace.name, detail: "@" + workspace.id,
                  names: [workspace.id] + (workspace.label.map { [$0] } ?? []), kind: .workspace)
    }

    private init(id: String, insert: String, title: String, detail: String? = nil, names: [String], kind: Kind) {
        (self.id, self.insert, self.title, self.detail, self.names, self.kind) = (id, insert, title, detail, names, kind)
    }

    /// The commands the agent's bridge takes in its DM.
    static let commands = [
        ComposerSuggestion(id: "/new", insert: "/new", title: "/new", detail: "Start a fresh conversation", names: ["new"], kind: .command),
    ]
}

/// What an `@` (or in the agent's DM a `/`) can become, just above the
/// composer, in the menu's style; scrolls past seven, keeping the
/// highlighted one in view.
struct MentionSuggestions: View {
    @Environment(AppModel.self) private var model
    let suggestions: [ComposerSuggestion]
    let highlighted: Int
    let choose: (ComposerSuggestion) -> Void

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
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        HStack(spacing: Theme.Space.sm) {
                            switch suggestion.kind {
                            case .member(let member):
                                Avatar(name: member.alias, url: member.photoURL, size: Theme.AvatarSize.sm,
                                       hue: model.hue(of: member))
                            case .workspace, .command:
                                Image(systemName: suggestion.kind == .workspace ? "building.2" : "plus.bubble")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(width: Theme.AvatarSize.sm, height: Theme.AvatarSize.sm)
                            }
                            Text(suggestion.title)
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if let detail = suggestion.detail {
                                Text(detail)
                                    .font(Theme.font(12))
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.sm)
                        .frame(height: Self.rowHeight)
                        .background(index == highlighted ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .contentShape(Rectangle())
                        .onTapGesture { choose(suggestion) }
                        .id(index)
                    }
                }
            }
            .scrollIndicators(suggestions.count > Self.visibleRows ? .automatic : .never)
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
        }
        .frame(height: CGFloat(min(suggestions.count, Self.visibleRows)) * Self.rowHeight)
        .padding(Self.padding)
        .frame(width: 240)
        .menuBoxed()
        .padding(.bottom, Self.gap)
    }
}
