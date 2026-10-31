import AgentKit
import PeelAgent
import SwiftUI
import PeelCore
import PeelUI

// MARK: - Pieces

/// Peel's row at the top of Direct messages: "Set up" in link blue until the
/// agent has its own account, then AGENT ("Needs a model" beside it, quiet,
/// while none is connected); bold with a count for replies that
/// came while it was not open; "Waiting on you" in orange while a send's
/// card waits for an answer.
struct AgentLink: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession

    var body: some View {
        let unread = model.agentUnread
        SidebarLink(agent.name, to: model.agentDestination, unread: unread > 0) {
            PeelLogo(size: 18)
        } accessory: {
            if model.agentWaiting {
                Text("Waiting on you")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.attention)
            } else if unread > 0 {
                Badge(count: unread)
            } else if model.agentChat == nil && (agent.connection == nil || model.agentSetUp.action != nil) {
                Text("Set up")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.link)
            } else {
                HStack(spacing: 6) {
                    if model.agentNeedsModel {
                        Text("Needs a model")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    AgentTag()
                }
            }
        }
    }
}

// MARK: - The chat

/// The agent chat: one long conversation like a direct message. Peel's
/// first message introduces it, with a card to connect a model until one
/// is; the chat Peel's own loop kept on this Mac before strut was the agent
/// is under it, read only. With `dm`, the agent's DM (`AppModel.agentChat`)
/// follows, its messages sent to the agent contact and its replies whole;
/// without, until the agent has its own account, its set-up
/// (`AgentSetUpPanel`).
struct AgentChatView: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession
    var dm: String?
    /// Dragged on its divider; remembered on this Mac (a convenience).
    @AppStorage("memoryPanelWidth") private var memoryWidth: Double = ThreadPanel.width

    var body: some View {
        // One memory a row opened, beside the chat as a thread is.
        SidePanelSplit(item: model.memoryPanel, width: $memoryWidth, range: ConversationView.threadRange,
                       standard: ThreadPanel.width, minimumMain: ConversationView.minimumWidth) {
            AgentChatColumn(agent: agent, dm: dm)
        } panel: { panel, _ in
            MemoryPanelView(panel: panel)
        }
        // Here, not on the column: a memory in the chat's place on a narrow
        // window is still the agent chat, shown.
        .onDisappear { model.closeMemory() }
    }
}

/// The agent chat's header, conversation and composer. Its own view, so
/// resizing the window or the memory beside it does not redraw it.
private struct AgentChatColumn: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession
    let dm: String?

    private var composer: ComposerID { dm.map(ComposerID.chat) ?? .agent }

    /// While the DM's turn runs (`agentAnswering`).
    private var stop: (@MainActor () -> Void)? {
        let model = model
        return model.agentAnswering == nil ? nil : { @MainActor in model.stopAgentTurn() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = agent.notice {
                Callout(detail: notice, icon: .problem, dismiss: { agent.notice = nil })
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            // The DM's list is made once, with its rows, as a chat's is (`ConversationView`).
            if let dm, model.loadedChat != dm {
                Spacer()
            } else {
                AgentMessageList(agent: agent, dm: dm, composer: composer)
                    .id(composer)
            }
            if let conversation = model.selectedConversation, conversation.chat == dm {
                // Its bridge or Peel's memory stopped, or failed to start: said, with Try again.
                if model.agentSetUp.problem { AgentSetUpPanel() }
                if model.agentNeedsModel {
                    // The model was removed: nothing sent here could be answered.
                    AgentModelPrompt()
                } else {
                    // Text only, to the agent contact (`AppModel.takesFiles`); Stop sends it a `cancel`.
                    ChatFooter(conversation: conversation, tribe: nil, composer: composer,
                               placeholder: "Message \(agent.name)", stop: stop)
                }
            } else {
                // No DM yet: setting up the agent's own account, never the local loop.
                AgentSetUpPanel()
            }
        }
        // A reply's View opens the message; any other link goes where a
        // message's link goes (`WebPane.linkAction`).
        .environment(\.openURL, OpenURLAction { url in
            if model.openAgentLink(url) { return .handled }
            model.web.linkAction(url)
            return .handled
        })
        .onAppear {
            // After this layout pass, once the chat it replaced has let go
            // of the keyboard (Tom: back from a View, the cursor was lost).
            if !model.sidebarHasKeys { Task { model.composerFocus[composer, default: 0] += 1 } }
        }
        // Connected: the cursor goes to the field, ready for the first question.
        .onChange(of: agent.connection) { _, connection in
            if connection != nil { model.composerFocus[composer, default: 0] += 1 }
        }
        // A card took the keys while it waited; answered, they go back to the field.
        .onChange(of: model.agentWaiting) { _, waiting in
            if !waiting { model.composerFocus[composer, default: 0] += 1 }
        }
    }

    private var header: some View {
        let subtitle = agent.connection.map { "\($0.provider.modelName($0.model)) · \($0.provider.name)" }
        return DetailHeader(title: agent.name, subtitle: subtitle ?? "No model connected", showsAgentTag: true) {
            PeelLogo(size: 28)
        } trailing: {
            if agent.connection != nil {
                IconButton("gearshape", help: "Agent settings") { model.openAccount(.assistant) }
            }
        }
    }
}

/// The conversation, newest at the bottom: the shared list
/// (`ChatListController` on `MessageTableEngine`), as a chat's.
private struct AgentMessageList: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession
    /// The agent's DM, when the chat is it: the DM's rows, its read marks
    /// and older pages as any chat's (`MessageTableEngine` on its composer).
    let dm: String?
    let composer: ComposerID

    @State private var link = ListLink()
    @State private var rows = AgentRows()

    var body: some View {
        // The local turns only above the DM's first message: not while older
        // pages are to come, nor over a jump's window. With no DM yet they are
        // shown the same way, read only.
        // The workspaces' cards come whether or not the DM is the chat yet.
        let shown = AgentDMRows(rows: dm == nil ? [] : model.chatRows, answering: dm == nil ? nil : model.agentAnswering,
                                proposals: model.proposals.orgCards,
                                fromStart: dm == nil || !model.mayHaveOlder && !model.showsWindow)
        MessageTable(model: model, rows: rows.rows(of: agent, open: model.agentOpenRows, dm: shown), composer: composer,
                     focus: dm == nil ? nil : MessageList.focusTarget(of: model, in: composer, hasRows: !model.chatRows.isEmpty),
                     reachesNewest: dm == nil || model.timelineReachesNewest, hasOlder: dm != nil && model.mayHaveOlder, link: link)
            // Bottom centre, above the composer, as in a chat.
            .overlay(alignment: .bottom) {
                if let controller = link.controller {
                    JumpPill(controller: controller, composer: composer)
                }
            }
            .hiddenShortcut(KeyboardShortcut(.pageUp, modifiers: [])) { link.engine?.page(up: true) }
            .hiddenShortcut(KeyboardShortcut(.pageDown, modifiers: [])) { link.engine?.page(up: false) }
    }
}

/// A row of the agent's DM: drawn as the chat draws it (`ListRowContent`),
/// with the tools an agent's reply ran above it, under its day line.
struct AgentDMRow: View {
    let row: ChatRow
    let composer: ComposerID
    let canAnswer: Bool

    var body: some View {
        ListRowContent(row: row, composer: composer, canAnswer: canAnswer, above: above, below: artifacts)
            .environment(\.inAgentDM, true)
    }

    /// The job it is about, then the tools it ran.
    private var above: AnyView? {
        guard row.agentJob != nil || !row.agentTools.isEmpty else { return nil }
        return agentNoteLines {
            if let job = row.agentJob { AgentJobLine(job: job) }
            // By position: a reply may run one tool twice.
            ForEach(Array(row.agentTools.enumerated()), id: \.offset) { _, tool in
                AgentToolLineRow(tool: tool)
            }
        }
    }

    /// What it points to: a job's deliverables, a page, a link.
    private var artifacts: AnyView? { agentArtifactLines(row.agentArtifacts) }
}

/// What a message points to, a quiet line each under it: the agent's DM
/// replies, and in a tribe a member's (Jamie's) deliverables (`inTribe`:
/// opened only on your own Stadeum workspaces, an app after a confirm).
/// Nil for none.
@MainActor func agentArtifactLines(_ artifacts: [AgentArtifact], inTribe: Bool = false) -> AnyView? {
    guard !artifacts.isEmpty else { return nil }
    return agentNoteLines {
        // By position: a reply may name one thing twice.
        ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
            AgentArtifactLine(artifact: artifact, inTribe: inTribe)
        }
    }
}

/// Quiet lines in line with a message's text, as a tool's rows are.
@MainActor private func agentNoteLines(@ViewBuilder _ lines: () -> some View) -> AnyView {
    AnyView(VStack(alignment: .leading, spacing: 2) { lines() }.agentNoteRow())
}

/// The job an agent's message is about, one quiet line: "Job · Lisbon
/// flights · Asks you", orange while it waits on your answer (your next
/// message continues it), "Done", or "Didn't finish".
private struct AgentJobLine: View {
    let job: AgentJob

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "briefcase")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(job.title.map { "Job · \($0)" } ?? "Job")
                .lineLimit(1)
                .truncationMode(.tail)
            switch job.state {
            case .asking?:
                Text("· Asks you").foregroundStyle(Theme.attention)
            case .done?:
                Text("· Done")
            case .failed?:
                Text("· Didn't finish")
            case .working?:
                Text("· Working")
            case nil:
                EmptyView()
            }
        }
        .font(Theme.font(13))
        .foregroundStyle(Theme.secondaryText)
        .help(job.id)
    }
}

/// Something an agent's message points to: its label and title, a line of
/// what is in it, and Open: a deliverable Peel's own strut shows (its
/// handle; an org's file or app, read through to it) in the web pane beside
/// the chat, with the org it lives on, or else an https link as any link.
/// Under the agent's DM replies, Jamie's in a call's chat, and a member's
/// in a tribe (`inTribe`).
struct AgentArtifactLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    let artifact: AgentArtifact
    /// Title, then Open on a line of its own, for a narrow panel (the
    /// call's chat); the summary only on hover.
    var stacked = false
    /// Sent in a tribe, where anyone could have written it
    /// (docs/hive-tribes.md): a handle opens only on one of your own live
    /// Stadeum workspaces, and an app only after a confirm.
    var inTribe = false

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        icon
                        title.lineLimit(2)
                    }
                    .help(artifact.summary ?? "")
                    HStack(spacing: 6) { open }
                        .padding(.leading, 17)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon
                    title.lineLimit(1)
                    if let summary = artifact.summary {
                        Text("· " + summary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(summary)
                    }
                    open
                }
            }
        }
        .font(Theme.font(13))
        .foregroundStyle(Theme.secondaryText)
    }

    private var icon: some View {
        Image(systemName: "doc.text")
            .font(.system(size: 11))
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text(artifact.label.map { "\($0): \(artifact.title)" } ?? artifact.title)
            .foregroundStyle(Theme.text)
    }

    @ViewBuilder private var open: some View {
        if let handle = artifact.handle, model.memoryServer != nil, !inTribe || model.stadeum.opensFromTribe(handle) {
            // Made again on the click: strut may have started again on another port and key.
            // An app the Apps list has opens there, as from the sidebar; else
            // the page, in the web pane (`AppModel.open`). Both are the main window's: from the
            // call's chat, that window comes to the front (opened again if closed).
            let openIt = {
                guard model.open(handle, title: artifact.title) else { return }
                openWindow(id: MainWindow.id, value: MainWindow.Key.main)
            }
            if artifact.asksBeforeOpening(inTribe: inTribe) {
                InlineConfirm(trigger: "Open", prompt: artifact.tribeAppQuestion(on: model.stadeum.workspaceName(handle.peer ?? "")),
                              confirm: "Open app", confirmKind: .primary, style: .text) { openIt() }
                    .foregroundStyle(Theme.link)
                    .help(StrutPage.name(artifact.title, on: handle.peer))
            } else {
                Button("Open", action: openIt)
                    .buttonStyle(.peel(.link))
                    .help(StrutPage.name(artifact.title, on: handle.peer))
            }
            if let peer = handle.peer { Text("@\(peer)").fixedSize() }
        } else if let url = artifact.url {
            // Where it goes, beside the agent's words for it.
            Button("Open") { openURL(url) }
                .buttonStyle(.peel(.link))
                .help(url.absoluteString)
            if let host = url.host() { Text(host).fixedSize() }
        } else if inTribe, let handle = artifact.handle, let peer = handle.peer, !model.stadeum.opensFromTribe(handle) {
            // Someone else's workspace, or one not connected here: the title only.
            Text("@\(peer) isn't connected here").fixedSize()
        }
    }
}

/// A tool an agent's reply in its DM ran, one quiet line as the bridge
/// listed it: "Read unseen messages · {"chat":"Kate"}", and "failed".
private struct AgentToolLineRow: View {
    let tool: AgentToolLine

    var body: some View {
        let asked = AgentToolTitle.asked(tool.summary)
        HStack(spacing: 6) {
            Text(AgentToolTitle.of(tool.name))
                .layoutPriority(1)
            if !asked.isEmpty {
                Text("· " + asked)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(asked)
            }
            if tool.failed {
                Text("· failed")
                    .fixedSize()
            }
        }
        .font(Theme.font(13))
        .foregroundStyle(Theme.secondaryText)
    }
}

/// The agent answering your message in its DM: no streamed text, only
/// "writing…" in its header, until the reply comes whole.
struct AgentAnsweringRow: View {
    let name: String

    var body: some View {
        AgentRow(author: .agent, name: name, writing: true) {}
    }
}

/// Peel's first message: what it can do, and until a model is connected a
/// card to connect one (in the DM, the composer's place has it instead).
struct AgentIntro: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession

    var body: some View {
        AgentRow(author: .agent, name: agent.name) {
            Text("Hi, I'm \(agent.name == AgentSession.defaultName ? "Peel's agent" : agent.name). I can catch you up on chats and send messages for you.")
                .font(Theme.font(14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if agent.connection == nil && model.agentChat == nil {
                Card {
                HStack(spacing: 12) {
                    Text("Connect a model to start")
                        .font(Theme.font(14, .semibold))
                    Spacer(minLength: 8)
                    AgentConnectButton(source: .chat, title: "Connect", variant: .primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                }
                .padding(.top, 6)
            }
        }
    }
}

/// One earlier message: the person's on a faint tint with their photo, or
/// the agent's with its logo and AGENT; the tools a reply ran above it; how
/// it ended when not on its own ("Stopped").
struct AgentTurnRow: View {
    let turn: AgentTurn
    let name: String
    /// Its tool rows' open parts.
    let disclosures: AgentDisclosures

    var body: some View {
        if !turn.tools.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // By position: a provider may repeat a call id across steps.
                ForEach(Array(turn.tools.enumerated()), id: \.offset) { index, tool in
                    AgentToolRow(tool: tool, open: disclosures.open("tool\(index)"))
                }
            }
            .padding(.leading, 20 + MessageRow.avatarSize + MessageRow.gutterSpacing)
            .padding(.trailing, 20)
            .padding(.top, 6)
        }
        if turn.author == .user || !turn.text.isEmpty || turn.ending != nil {
            AgentRow(author: turn.author, name: name, date: turn.date, menuID: turn.id, menu: menu) {
                if !turn.text.isEmpty {
                    MessageText(text: turn.text, chat: nil, agentLinks: turn.author == .agent)
                        .rowMenu(turn.id, menu)
                }
                if let ending = turn.ending {
                    Text(Self.words(for: ending))
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    /// The turn's menu, as a message's: Copy text.
    private var menu: (@MainActor () -> [MenuEntry])? {
        guard !turn.text.isEmpty else { return nil }
        let text = turn.text
        return { [.copyText(text)] }
    }

    static func words(for ending: AgentTurn.Ending) -> String {
        switch ending {
        case .stopped: "Stopped"
        case .cutOff: "Reply cut off."
        case .declined: "The model declined to answer."
        case .stepLimit: "Stopped: too many steps."
        case .failed: "Didn't finish. Ask again."
        }
    }
}

/// A row of the agent chat in a message row's shape (`MessageRow`): the
/// photo or logo in the gutter, then the name, AGENT and the time, then
/// the body; yours on the faint accent tint. With a `menu`, More over its
/// top-right corner on hover, as a message row has (`HoverBar`), and the
/// same menu on a right-click of the text.
private struct AgentRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    let author: AgentTurn.Author
    let name: String
    var date: Date?
    var writing = false
    var menuID: String?
    var menu: (@MainActor () -> [MenuEntry])?
    @ViewBuilder let content: Content

    @State private var hovering = false

    var body: some View {
        let me = model.me
        HStack(alignment: .top, spacing: MessageRow.gutterSpacing) {
            Group {
                if author == .user {
                    Avatar(name: me.avatarName, url: me.photoURL, size: MessageRow.avatarSize, hue: me.hue)
                } else {
                    PeelLogo(size: MessageRow.avatarSize)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(author == .user ? me.name : name)
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(author == .user ? me.hue.name : Theme.text)
                        .lineLimit(1)
                    if author == .agent { AgentTag().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 } }
                    if writing {
                        Text("writing…")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                    } else if let date {
                        Text(Formatting.time(date))
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                            .help(date.formatted(date: .complete, time: .shortened))
                    }
                }
                VStack(alignment: .leading, spacing: 4) { content }
            }
            .frame(maxWidth: MessageRow.textWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .rowChrome(id: menu == nil ? nil : menuID, fromMe: author == .user, hovering: hovering)
        // Kept while this row's menu is open, as a message row keeps its own.
        .overlay(alignment: .topTrailing) {
            if let menu, let menuID,
               (hovering && presenter?.isOpen != true) || presenter?.source == AnyHashable(menuID) {
                MenuButton(systemImage: "ellipsis", help: "More", source: menuID, entries: menu)
                    .padding(2)
                    .menuBoxed(cornerRadius: Theme.Radius.control, shadow: false)
                    .padding(.trailing, 20)
                    .offset(y: -10)
            }
        }
        .zIndex(hovering ? 1 : 0)
        .onHover { hovering = $0 }
    }
}

/// One quiet line in the agent chat with a chevron; a click opens `detail`
/// under it on an inset card. Tool rows and request rows. Whether it is
/// open is kept beside the list (`AgentOpenRows`), so a row stays open when
/// it scrolls away; a click first tells the list, which keeps the row's top
/// where it is.
struct AgentDisclosureRow<Label: View, Detail: View>: View {
    @Environment(\.listRowExpanding) private var expanding
    let disclosure: AgentDisclosure
    let label: Label
    /// Built only while open.
    let detail: () -> Detail

    init(_ disclosure: AgentDisclosure, @ViewBuilder label: () -> Label, @ViewBuilder detail: @escaping () -> Detail) {
        self.disclosure = disclosure
        self.label = label()
        self.detail = detail
    }

    var body: some View {
        let open = Binding {
            disclosure.isOpen
        } set: { new in
            if new != disclosure.isOpen { disclosure.toggle(expanding: expanding) }
        }
        VStack(alignment: .leading, spacing: 4) {
            DisclosureButton(open: open) { label }
            if disclosure.isOpen {
                Card(.inset) {
                detail()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: MessageRow.textWidth, alignment: .leading)
                }
            }
        }
    }
}

/// A tool an earlier reply ran, one quiet line ("Read the time · 0.1 s"); a
/// click opens what it was asked and what it answered. A tool that acted
/// says what it did and how it was answered ("Send to Kate · Allowed once ·
/// 0.4 s · View").
private struct AgentToolRow: View {
    @Environment(AppModel.self) private var model
    let tool: ToolActivity
    let open: AgentDisclosure

    var body: some View {
        AgentDisclosureRow(open) {
            Text(tool.approval?.intent.action ?? AgentToolTitle.of(tool.name))
                .layoutPriority(1)
            if let approval = tool.approval, let outcome = approval.outcome {
                Text("· " + AgentToolTitle.outcome(outcome, target: approval.intent.target?.name))
                    .fixedSize()
            }
            if tool.approval?.outcome?.allows != false,
               let summary = tool.summary.map(AgentToolTitle.summary), !summary.isEmpty {
                Text("· " + summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(summary)
            }
            if let duration = tool.duration {
                Text("· " + (tool.failed ? "failed · " : "") + AgentToolTitle.duration(duration))
                    .monospacedDigit()
                    .fixedSize()
            }
            if tool.approval != nil, let url = tool.summary.flatMap(AgentMessageLink.init(summary:))?.url {
                Button("View") { _ = model.openAgentLink(url) }
                    .buttonStyle(.peel(.link))
                    .fixedSize()
            }
        } detail: {
            if let row = tool.row, MemoryResult.tools.contains(tool.name) {
                MemoryRowDetail(tool: tool.name, input: tool.input, row: row)
            } else {
                facts
            }
        }
    }

    /// What it was asked and answered, for a tool whose row keeps nothing more.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let content = tool.approval?.intent.content { FactLine(label: "Content", text: content) }
            FactLine(label: "Asked", text: tool.input == .object([:]) ? "Nothing" : tool.input.jsonString)
            if let summary = tool.summary { FactLine(label: "Answered", text: AgentToolTitle.summary(summary)) }
        }
    }

}

/// One fact under an opened agent row: its label, then what it says
/// ("Asked", "Answered", "Why"): a tool's details, a device request's.
struct FactLine: View {
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 64, alignment: .leading)
            Text(text)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.font(12))
    }
}

/// A device request that acts, waiting on you in the agent's DM
/// (`DeviceRequestLine`): what will happen in plain words, the exact
/// content, any cost, and Allow once (Return), Always allow for its
/// target, and Deny (Escape). Orange while it waits; no red, since nothing
/// is lost by declining. It never takes the keys as it appears: the agent,
/// not you, decides when it comes, so a Return meant for the composer
/// never allows it.
struct AgentApprovalCard: View {
    let intent: ToolIntent
    let answer: (ApprovalDecision) -> Void

    var body: some View {
        Callout(.attention, intent.action, detail: detail, icon: .symbol("paperplane", Theme.attention)) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if let content = intent.content {
                    Card(.inset) {
                        Text(content)
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                HStack(spacing: Theme.Space.sm) {
                    Button("Allow once") { answer(.allowOnce) }
                        .buttonStyle(.peel(.primary, size: .sm))
                        .help(intent.cost == nil ? "Return" : "Click to pay and send")
                    if intent.mayBeAlwaysAllowed {
                        Button(intent.alwaysLabel) {
                            answer(.alwaysAllow)
                        }
                        .buttonStyle(.peel(.outline, size: .sm))
                    }
                    Button("Deny") { answer(.deny) }
                        .buttonStyle(.peel(.ghost, size: .sm))
                        .help("Escape")
                }
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: MessageRow.textWidth, alignment: .leading)
        // A send that costs sats takes a click on Allow once, never a key
        // that may have been meant for something else.
        .answerKeys(returnAccepts: intent.cost == nil) { answer(.allowOnce) } reject: { answer(.deny) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting on you: \(intent.action)")
    }

    /// What else will happen, and what it costs.
    private var detail: String {
        let lines = intent.lines
        return lines.isEmpty ? "Nothing is sent until you allow it." : lines.joined(separator: "\n")
    }
}

/// The keys a card waiting on you takes, and only while the card itself
/// has them (never as it appears: the agent, not you, decides when it
/// comes, so a Return meant for the composer never allows it; and Return
/// on a button inside it, tabbed to, is the button's): Return accepts when
/// `returnAccepts`, Escape rejects. `enabled` false takes the card out of
/// the focus order (it is no longer yours to answer).
private struct AnswerKeys: ViewModifier {
    let enabled: Bool
    let returnAccepts: Bool
    let accept: () -> Void
    let reject: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(enabled)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.return) {
                guard focused, enabled, returnAccepts else { return .ignored }
                accept()
                return .handled
            }
            .onKeyPress(.escape) {
                guard focused, enabled else { return .ignored }
                reject()
                return .handled
            }
    }
}

extension View {
    /// The one owner of an approval card's keys (`AnswerKeys`): the send
    /// card's and the proposal card's.
    func answerKeys(enabled: Bool = true, returnAccepts: Bool, accept: @escaping () -> Void, reject: @escaping () -> Void) -> some View {
        modifier(AnswerKeys(enabled: enabled, returnAccepts: returnAccepts, accept: accept, reject: reject))
    }

    /// A note in the agent chat (a job, the tools a reply ran, what it
    /// points to), with the message it is about, in line with its text.
    fileprivate func agentNoteRow() -> some View {
        frame(maxWidth: MessageRow.textWidth, alignment: .leading)
            .padding(.leading, 20 + MessageRow.avatarSize + MessageRow.gutterSpacing)
            .padding(.trailing, 20)
            .padding(.vertical, 6)
    }
}

/// A button that opens the Connect panel beside itself. Each place has its
/// own `source`, so the panel opens next to the button clicked.
struct AgentConnectButton: View {
    @Environment(AppModel.self) private var model
    let source: AgentConnectSource
    let title: String
    var variant = PeelButton.Variant.outline
    var size = PeelButton.Size.md

    var body: some View {
        let open = Binding(
            get: { model.agentConnectFrom == source },
            set: { model.agentConnectFrom = $0 ? source : nil }
        )
        Button(title) { open.wrappedValue = true }
            .buttonStyle(.peel(variant, size: size))
            .peelPopover(isPresented: open) {
                if let agent = model.agent {
                    AgentConnectPanel(agent: agent) { open.wrappedValue = false }
                }
            }
    }
}
