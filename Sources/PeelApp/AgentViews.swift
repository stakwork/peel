import AgentKit
import PeelAgent
import SwiftUI
import PeelCore
import PeelUI

// MARK: - Pieces

/// Peel's logo as the agent's avatar: the app's icon, its tile filling a
/// rounded square (agents are rounded squares, people circles).
struct PeelLogo: View {
    let size: CGFloat

    var body: some View {
        // The icon's tile is 824 of its 1024 points; the rest is margin.
        AppIcon(size: size * 1024 / 824)
            .frame(width: size, height: size)
            .clipShape(Avatar.outline(.roundedSquare, size: size))
            .accessibilityHidden(true)
    }
}

/// Peel's row at the top of Direct messages: "Set up" in link blue until a
/// model is connected, then AGENT; bold with a count for replies that
/// came while it was not open; "Waiting on you" in orange while a send's
/// card waits for an answer.
struct AgentLink: View {
    let agent: AgentSession

    var body: some View {
        let unread = agent.unread
        SidebarLink(agent.name, to: .agent, unread: unread > 0) {
            PeelLogo(size: 18)
        } accessory: {
            if agent.waiting != nil {
                Text("Waiting on you")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.attention)
            } else if unread > 0 {
                Badge(count: unread)
            } else if agent.connection == nil {
                Text("Set up")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.link)
            } else {
                AgentTag()
            }
        }
    }
}

// MARK: - The chat

/// The agent chat: one long conversation like a direct message. Peel's
/// first message introduces it, with a card to connect a model until one
/// is; replies stream in as Markdown, tools run as quiet rows, a failure
/// is a row with Retry. Everything it does is an `AgentSession` action.
struct AgentChatView: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession
    /// Dragged on its divider; remembered on this Mac (a convenience).
    @AppStorage("memoryPanelWidth") private var memoryWidth: Double = ThreadPanel.width

    var body: some View {
        // One memory a row opened, beside the chat as a thread is.
        SidePanelSplit(isOpen: model.memoryPanel != nil, width: $memoryWidth, range: ConversationView.threadRange,
                       standard: ThreadPanel.width, minimumMain: ConversationView.minimumWidth) {
            AgentChatColumn(agent: agent)
        } panel: { _ in
            if let panel = model.memoryPanel { MemoryPanelView(panel: panel) }
        }
        // A card waiting on the person must be in view: on a narrow window
        // the memory would hide it.
        .onChange(of: agent.waiting != nil) { _, waiting in
            if waiting { model.closeMemory() }
        }
        // Here, not on the column: a memory in the chat's place on a narrow
        // window is still the agent chat, shown.
        .onAppear { agent.isShown = true }
        .onDisappear {
            agent.isShown = false
            model.closeMemory()
        }
    }
}

/// The agent chat's header, conversation and composer. Its own view, so
/// resizing the window or the memory beside it does not redraw it.
private struct AgentChatColumn: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = agent.notice {
                Callout(detail: notice, icon: .problem, dismiss: { agent.notice = nil })
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            AgentMessageList(agent: agent)
            Composer(composer: .agent, placeholder: "Message \(agent.name)",
                     stop: agent.isRunning ? { agent.stop() } : nil)
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
            if !model.sidebarHasKeys { Task { model.composerFocus[.agent, default: 0] += 1 } }
        }
        // Connected: the cursor goes to the field, ready for the first question.
        .onChange(of: agent.connection) { _, connection in
            if connection != nil { model.composerFocus[.agent, default: 0] += 1 }
        }
        // A card took the keys while it waited; answered, they go back to the field.
        .onChange(of: agent.waiting == nil) { _, answered in
            if answered { model.composerFocus[.agent, default: 0] += 1 }
        }
    }

    private var header: some View {
        let subtitle = agent.connection.map { "\($0.provider.modelName($0.model)) · \($0.provider.name)" }
        return DetailHeader(title: agent.name, subtitle: subtitle ?? "No model connected", showsAgentTag: true) {
            PeelLogo(size: 28)
        } trailing: {
            if agent.connection != nil {
                IconButton("gearshape", help: "Agent settings") { model.openAgentSettings() }
            }
        }
    }
}

/// The conversation, newest at the bottom, following the reply as it
/// streams while the list is at the bottom.
private struct AgentMessageList: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession

    /// Taken down with the reply: until scrolled away by hand, and again
    /// once back at the bottom.
    @State private var following = true
    @State private var phase = ScrollPhase.idle
    /// Where the turns are laid out, to hold the list at its end by them.
    @State private var end = ListEnd()
    /// Only for a scroll to a point (`repin`).
    @State private var position = ScrollPosition()
    /// Shown once at the end and still, as the chat's list is
    /// (`MessageList.revealed`); never later than `revealLimit`.
    @State private var revealed = false
    private static let revealLimit: Duration = .milliseconds(400)
    /// The end marker, under the padding, for a jump with nothing laid out.
    private static let bottom = "bottom"
    /// The last row in the lazy stack, under the reply and any note: where
    /// it is laid out is where the conversation really ends.
    private static let lastRow = "end"
    private static let contentSpace = "agentListContent"
    private static let padding: CGFloat = 12

    var body: some View {
        let turns = agent.turns
        let problem = agent.problem
        let summary = agent.summary
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    AgentIntro(agent: agent)
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        if index == 0 || !Calendar.current.isDate(turn.date, inSameDayAs: turns[index - 1].date) {
                            DayDivider(date: turn.date)
                                .padding(.horizontal, 20)
                        }
                        // A turn is two rows (its tool calls, then its text): kept
                        // as the lazy stack placed them, at the leading edge, in
                        // one view the id and its place can be given to.
                        VStack(alignment: .leading, spacing: 0) {
                            AgentTurnRow(turn: turn, name: agent.name)
                        }
                        .id(turn.id)
                        .laidOut(turn.id, in: end, space: Self.contentSpace)
                        if let summary, summary.through == turn.id { AgentSummaryRow(summary: summary) }
                        if let problem, problem.turnID == turn.id {
                            AgentProblemRow(agent: agent, failure: problem.failure)
                        }
                    }
                    // Its own view: the reply growing redraws it alone.
                    AgentReplyRow(agent: agent) { repin(proxy, "reply grew") }
                    Color.clear.frame(height: 1)
                        .laidOut(Self.lastRow, in: end, space: Self.contentSpace)
                }
                // Only for the timeline log's visible rows.
                .scrollTargetLayout(isEnabled: TimelineLog.enabled)
                .padding(.vertical, Self.padding)
                .overlay(alignment: .bottom) { Color.clear.frame(height: 0).id(Self.bottom) }
                .coordinateSpace(.named(Self.contentSpace))
            }
            .scrollPosition($position)
            .opacity(revealed ? 1 : 0)
            .timelineProbe(geometry: logGeometry, visible: logVisible)
            // Short, it sits on the composer, as a chat does.
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, new in
                log("phase \(phase) -> \(new)")
                phase = new
                if new == .interacting { end.steps = 0 }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) <= 24
            } action: { _, bottom in
                if bottom {
                    following = true
                } else if phase == .interacting || phase == .decelerating {
                    following = false
                }
            }
            // The turns measured taller than estimated move down, the
            // offset stays, and the list is left on older turns (or past
            // them, blank); the composer growing takes room from it: back
            // to the end, by where it is.
            .onScrollGeometryChange(for: CGSize.self) { geometry in
                CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
            } action: { _, _ in
                if phase == .idle { repin(proxy, "resized") }
            }
            // Turns laid out, none in view: past them, blank. Keyed by the
            // offset, so landing there again asks again.
            .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                end.noneInView(offset: geometry.contentOffset.y, container: geometry.containerSize.height,
                               content: geometry.contentSize.height)
                    ? geometry.contentOffset.y : nil
            } action: { _, out in
                if out != nil, phase == .idle { repin(proxy, "turns laid out, none in view") }
            }
            .onChange(of: turns.map(\.id), initial: true) { _, ids in
                end.ids = ids + [Self.lastRow]
                end.steps = 0
            }
            .onAppear {
                end.gone = false
                ListProbe.register(end, kind: "agent", ignoring: Self.lastRow)
                log("appear")
                if turns.isEmpty {
                    reveal("nothing to place")
                } else {
                    Task {
                        try? await Task.sleep(for: Self.revealLimit)
                        reveal("at the limit")
                    }
                }
                // Nothing laid out yet: the end as the stack estimates it,
                // then by the turns once they are.
                proxy.scrollTo(Self.bottom, anchor: .bottom)
                repin(proxy, "appear")
            }
            .onDisappear {
                log("disappear")
                end.gone = true
            }
            // A message sent always goes to the newest; a reply growing
            // only while the list is at the bottom.
            .onChange(of: turns.count) {
                if turns.last?.author == .user { following = true }
                repin(proxy, "turns \(turns.count)")
            }
            .onChange(of: problem) { repin(proxy, "problem") }
        }
    }

    /// To the end while following, by where the turns are laid out
    /// (`ListEnd`): the conversation's last row to the bottom once it is;
    /// short of it, a step down from the newest turn laid out, then again;
    /// with none, the end marker. One for a burst of requests (a reply
    /// streaming), at most 100 ms late while they keep coming.
    private func repin(_ proxy: ScrollViewProxy, _ why: String) {
        guard following else { return }
        let request = end.ask()
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard end.due(request) else { return }
            guard !end.gone, following, phase == .idle else { return log("repin \(why) skipped") }
            if end.endsInView(Self.lastRow, padding: Self.padding) {
                end.steps = 0
                log("repin \(why): the end in view")
                // Shown once nothing has moved it for a while.
                let moves = end.moves
                try? await Task.sleep(for: .milliseconds(60))
                if end.moves == moves { reveal("settled at the end") }
                return
            }
            if let step = end.towardsNewest(padding: Self.padding), end.steps < ListEnd.stepLimit {
                end.steps += 1
                log("place: \(why), to y=\(TimelineLog.points(step.y))\(step.from == nil ? "" : " (a step)")")
                end.moves += 1
                position.scrollTo(y: max(step.y, 0))
                repin(proxy, why)
                return
            }
            end.steps = 0
            log("place: \(why), scrollTo bottom")
            end.moves += 1
            proxy.scrollTo(Self.bottom, anchor: .bottom)
        }
    }

    /// Shows the list, once.
    private func reveal(_ why: String) {
        guard !revealed, !end.gone else { return }
        revealed = true
        end.shown = true
        log("revealed: \(why)")
    }

    // MARK: Timeline log (`TimelineLog`; nothing is built while it is off)

    private func log(_ event: @autoclosure () -> String) {
        TimelineLog.log("agent \(event()) | turns=\(agent.turns.count) reply=\(agent.reply != nil) "
            + "following=\(following) phase=\(phase) \(laidOut)")
    }

    /// The turns laid out, by index, and where they sit in the content.
    private var laidOut: String {
        let positions = Dictionary(agent.turns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = end.frames.compactMap { id, frame in positions[id].map { (index: $0, frame: frame) } }
        let last = end.frames[Self.lastRow].map { " end at \(TimelineLog.points($0.maxY))" } ?? ""
        guard let first = placed.map(\.index).min(), let newest = placed.map(\.index).max() else { return "laid out none" + last }
        let top = placed.map(\.frame.minY).min() ?? 0, bottom = placed.map(\.frame.maxY).max() ?? 0
        return "laid out \(first)...\(newest) at \(TimelineLog.points(top))...\(TimelineLog.points(bottom))" + last
    }

    /// Not while scrolled by hand, which would be a line a frame.
    private func logGeometry(_ geometry: ScrollGeometry) {
        guard phase != .interacting, phase != .decelerating else { return }
        let below = geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
        log("geometry offset=\(TimelineLog.points(geometry.contentOffset.y)) "
            + "content=\(TimelineLog.points(geometry.contentSize.height)) "
            + "container=\(TimelineLog.points(geometry.containerSize.height)) below=\(TimelineLog.points(below))")
    }

    /// The turns in view by index; none with turns to show is the blank list.
    private func logVisible(_ ids: [String]) {
        let positions = Dictionary(agent.turns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = ids.compactMap { positions[$0] }
        if let first = shown.min(), let last = shown.max() {
            log("visible turns \(first)...\(last) (\(shown.count))")
        } else {
            log(agent.turns.isEmpty ? "visible none, no turns" : "visible NONE with turns: blank")
        }
    }
}

/// The reply streaming now, the only view that reads it, so the rest of
/// the list is not drawn again as it grows; `grew` keeps it in view.
private struct AgentReplyRow: View {
    let agent: AgentSession
    let grew: () -> Void

    var body: some View {
        if let reply = agent.reply {
            AgentTurnRow(turn: reply, name: agent.name, writing: true, agent: agent)
                .onChange(of: reply.text.count) { grew() }
                .onChange(of: reply.tools.count) { grew() }
                // A card replaces its row in place, taller: kept in view.
                .onChange(of: agent.waiting) { grew() }
            AgentRetryRow(agent: agent, grew: grew)
        }
    }
}

/// A model call made again on its own, under the reply, until the reply
/// goes on: "Rate limited by the provider. Retrying in 4 s…". Its own view,
/// so the reply's row does not read `retrying`.
private struct AgentRetryRow: View {
    let agent: AgentSession
    let grew: () -> Void

    var body: some View {
        if let retrying = agent.retrying {
            Callout(detail: RetryPolicy.note(after: retrying.after, retrying.reason), icon: .progress)
                .agentNoteRow()
                .onAppear { grew() }
        }
    }
}

/// Peel's first message: what it can do, and until a model is connected a
/// card to connect one.
private struct AgentIntro: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession

    var body: some View {
        AgentRow(author: .agent, name: agent.name) {
            Text("Hi, I'm \(agent.name == AgentSession.defaultName ? "Peel's agent" : agent.name). I can catch you up on chats and send messages for you.")
                .font(Theme.font(14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if agent.connection == nil {
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

/// One message: the person's on a faint tint with their photo, or the
/// agent's with its logo and AGENT; the tools a reply ran above it; how it
/// ended when not on its own ("Stopped").
private struct AgentTurnRow: View {
    let turn: AgentTurn
    let name: String
    var writing = false
    /// The reply streaming now: answers a card that waits.
    var agent: AgentSession?

    var body: some View {
        if !turn.tools.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // By position: a provider may repeat a call id across steps.
                ForEach(Array(turn.tools.enumerated()), id: \.offset) { AgentToolRow(tool: $0.element, agent: agent) }
            }
            .padding(.leading, 20 + MessageRow.avatarSize + MessageRow.gutterSpacing)
            .padding(.trailing, 20)
            .padding(.top, 6)
        }
        if turn.author == .user || writing || !turn.text.isEmpty || turn.ending != nil {
            AgentRow(author: turn.author, name: name, date: writing ? nil : turn.date, writing: writing,
                     menuID: turn.id, menu: menu) {
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

    /// The turn's menu, as a message's: Copy text, once it is said; the
    /// reply still writing has none.
    private var menu: (@MainActor () -> [MenuEntry])? {
        guard !writing, !turn.text.isEmpty else { return nil }
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
/// under it on an inset card. Tool rows and the summary row.
/// The row that uses it keeps `open`, so a tool row stays open when its
/// approval card comes and goes.
private struct AgentDisclosureRow<Label: View, Detail: View>: View {
    @Binding var open: Bool
    let label: Label
    /// Built only while open.
    let detail: () -> Detail

    init(open: Binding<Bool>, @ViewBuilder label: () -> Label, @ViewBuilder detail: @escaping () -> Detail) {
        _open = open
        self.label = label()
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureButton(open: $open) { label }
            if open {
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

/// Where the model's view of the conversation begins again: "Summarised
/// earlier conversation", which opens to the summary it is sent instead of
/// the turns above (they stay here in full).
private struct AgentSummaryRow: View {
    let summary: AgentSession.Summary
    @State private var open = false

    var body: some View {
        AgentDisclosureRow(open: $open) {
            Text("Summarised earlier conversation")
        } detail: {
            Text(summary.text)
                .font(Theme.font(12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 20 + MessageRow.avatarSize + MessageRow.gutterSpacing)
        .padding(.trailing, 20)
        .padding(.vertical, 6)
    }
}

/// A tool the agent ran, one quiet line ("Read the time · 0.1 s"); a click
/// opens what it was asked and what it answered. A tool that acts shows
/// its approval card in its place while it waits, then what it did and
/// how it was answered ("Send to Kate · Allowed once · 0.4 s · View").
private struct AgentToolRow: View {
    @Environment(AppModel.self) private var model
    let tool: ToolActivity
    var agent: AgentSession?
    @State private var open = false

    var body: some View {
        if tool.isWaiting, let agent, let approval = tool.approval {
            AgentApprovalCard(agent: agent, intent: approval.intent)
        } else {
            row
                .onChange(of: model.agentRowsOpened) { open = true }
        }
    }

    private var row: some View {
        AgentDisclosureRow(open: $open) {
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
            } else {
                ProgressView().controlSize(.mini)
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
            if let content = tool.approval?.intent.content { detail("Content", content) }
            detail("Asked", tool.input == .object([:]) ? "Nothing" : tool.input.jsonString)
            if let summary = tool.summary { detail("Answered", AgentToolTitle.summary(summary)) }
        }
    }

    private func detail(_ label: String, _ text: String) -> some View {
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

/// A tool that acts, waiting on you, where its row will be: what will
/// happen in plain words, the exact content, any cost, and Allow once
/// (Return), Always allow for its target, and Deny (Escape). Orange while
/// it waits; no red, since nothing is lost by declining. Once answered it
/// is the tool's row again, one line with the outcome.
private struct AgentApprovalCard: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession
    let intent: ToolIntent
    @FocusState private var focused: Bool

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
                    Button("Allow once") { agent.answer(.allowOnce) }
                        .buttonStyle(.peel(.primary, size: .sm))
                        .help(intent.cost == nil ? "Return" : "Click to pay and send")
                    if intent.mayBeAlwaysAllowed {
                        Button(intent.alwaysLabel) {
                            agent.answer(.alwaysAllow)
                        }
                        .buttonStyle(.peel(.outline, size: .sm))
                    }
                    Button("Deny") { agent.answer(.deny) }
                        .buttonStyle(.peel(.ghost, size: .sm))
                        .help("Escape")
                }
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: MessageRow.textWidth, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // Only while the card itself has the keys: Return on a button inside
        // it (Deny tabbed to) is not Allow once. A send that costs sats takes
        // a click on Allow once, never a key that may have been meant for
        // something else.
        .onKeyPress(.return) {
            guard focused, intent.cost == nil else { return .ignored }
            agent.answer(.allowOnce)
            return .handled
        }
        .onKeyPress(.escape) {
            guard focused else { return .ignored }
            agent.answer(.deny)
            return .handled
        }
        // It takes the keys only from an empty composer: a Return meant for
        // a half-typed message never allows a send unread.
        .onAppear { if (model.drafts[.agent] ?? "").trimmed.isEmpty { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting on you: \(intent.action)")
    }

    /// What else will happen, and what it costs.
    private var detail: String {
        let lines = intent.lines
        return lines.isEmpty ? "Nothing is sent until you allow it." : lines.joined(separator: "\n")
    }
}

/// Why a message got no reply, in the provider's plain words, with what
/// helps: Retry, Replace key for a key that stopped working, Connect when
/// none is. Quiet, not red: nothing was lost.
private struct AgentProblemRow: View {
    let agent: AgentSession
    let failure: AgentSession.Failure

    var body: some View {
        Callout(detail: words, icon: .problem) {
            switch failure {
            case .noModel:
                AgentConnectButton(source: .problem, title: "Connect", variant: .primary, size: .sm)
            case .model(.invalidKey):
                AgentConnectButton(source: .problem, title: "Replace key", variant: .primary, size: .sm)
            case .unreadableKey, .model:
                Button("Retry") { agent.retry() }
                    .buttonStyle(.peel(.outline, size: .sm))
            }
        }
        .agentNoteRow()
    }

    private var words: String {
        switch failure {
        case .noModel:
            "No model connected."
        case .unreadableKey(let reason):
            PeelError.problem(reason, couldNot: "read the API key on this Mac")
        case .model(.invalidKey(let message)):
            "Your \(agent.connection?.provider.name ?? "provider's") key stopped working."
                + (message.map { " (\($0))" } ?? "")
        case .model(let error):
            error.localizedDescription
        }
    }
}

extension View {
    /// A note in the agent chat (a failure, a retry), under the message it
    /// is about, in line with the messages' text.
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
