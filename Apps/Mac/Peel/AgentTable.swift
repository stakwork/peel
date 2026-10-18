import AgentKit
import AppKit
import SwiftUI
import PeelCore
import PeelUI

/// One row of the agent chat's list (`MessageTableEngine`): Peel's intro,
/// a turn (its day line, tool calls and text), the summary under the turn
/// it reaches, or a turn's problem. The reply streaming now is the row of
/// the turn it becomes, under one id throughout (`AgentSession.streamedAs`),
/// so saving it changes the row in place: what is open in it or selected
/// stays. The intro, summary, problem and the reply never hold the list's
/// place; only your own turn takes it to the newest
/// (`docs/reviews/2026-10-14-message-lists.md`, section 7 of the design).
struct AgentListRow: TableRow {
    enum Kind {
        case intro
        /// `writing`: the reply streaming now.
        case turn(AgentTurn, startsDay: Bool, writing: Bool)
        case summary(AgentSession.Summary)
        case problem(AgentSession.Failure)
        /// Over the old local turns when the chat is the agent's DM:
        /// "Earlier, on this Mac", read only.
        case earlier
        /// One row of the agent's DM as the chat draws it, with the tools
        /// an agent's reply ran above it (`AgentDMRows`).
        case dm(ChatRow)
        /// The agent answering your message in its DM: "writing…".
        case answering
    }

    /// What a row's height depends on beyond its id; equal versions draw
    /// alike. A saved turn never changes, so its text's length stands for
    /// it; the reply streaming adds its tools and any retry note.
    struct Version: Equatable {
        var name: String
        /// Its tool rows and summary open now, by key (`AgentOpenRows`).
        var open: Set<String> = []
        var startsDay = false
        var writing = false
        var text = 0
        var tools: [ToolActivity] = []
        var retrying: AgentSession.Retrying?
        var ending: AgentTurn.Ending?
        var connected = false
        var failure: AgentSession.Failure?
        /// A DM row as drawn (`dm`).
        var row: ChatRow?
    }

    let id: String
    let kind: Kind
    let version: Version
    let agent: AgentSession
    let openRows: AgentOpenRows

    /// The row's id and its version: a few small values, not the turn's text.
    nonisolated static func == (a: AgentListRow, b: AgentListRow) -> Bool {
        a.id == b.id && a.version == b.version
    }

    var reuse: NSUserInterfaceItemIdentifier {
        switch kind {
        case .turn, .answering: .init("agent-turn")
        case .intro, .summary, .problem, .earlier: .init("agent-note")
        case .dm(let row): .init("agent-" + row.reuse.rawValue)
        }
    }

    var estimatedHeight: CGFloat {
        switch kind {
        case .intro: return 90
        case .summary: return 36
        case .problem: return 64
        case .earlier: return 40
        case .answering: return 50
        case .dm(let row): return row.estimatedHeight + CGFloat(row.agentTools.count) * 24
        case .turn(let turn, let startsDay, _):
            let lines = max(1, (turn.text.utf8.count + 69) / 70)
            return CGFloat(lines) * 18 + 36 + CGFloat(turn.tools.count) * 24 + (startsDay ? 40 : 0)
        }
    }

    func content(in list: ComposerID, canAnswer: Bool) -> AnyView {
        let disclosures = AgentDisclosures(rowID: id, rows: openRows)
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                switch kind {
                case .intro:
                    AgentIntro(agent: agent)
                case .turn(let turn, let startsDay, let writing):
                    // One shape writing or saved, so the views (and a
                    // selection in them) outlive the save.
                    if startsDay {
                        DayDivider(date: turn.date)
                            .padding(.horizontal, 20)
                    }
                    AgentTurnRow(turn: turn, name: version.name, writing: writing, agent: writing ? agent : nil,
                                 disclosures: disclosures)
                    if writing { AgentRetryRow(agent: agent) }
                case .summary(let summary):
                    AgentSummaryRow(summary: summary, disclosures: disclosures)
                case .problem(let failure):
                    AgentProblemRow(agent: agent, failure: failure)
                case .earlier:
                    TitledDivider(title: "Earlier, on this Mac")
                        .padding(.horizontal, 20)
                case .dm(let row):
                    AgentDMRow(row: row, composer: list, canAnswer: canAnswer)
                case .answering:
                    AgentAnsweringRow(name: version.name)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// A DM row's, as in a chat; none on the rest: an agent row shows its
    /// own More on hover (`AgentRow`).
    func hoverBar(in list: ComposerID) -> AnyView? {
        if case .dm(let row) = kind { row.hoverBar(in: list) } else { nil }
    }

    static func listContent(_ rows: [AgentListRow], in list: ComposerID, reachesNewest: Bool, hasOlder: Bool) -> ListContent {
        var divider: String?
        let listed = rows.map { row in
            switch row.kind {
            case .turn(let turn, _, let writing):
                // The old local turns over the DM: never new, never yours to follow.
                return ChatListRow(id: row.id, canAnchor: !writing, isOwn: list == .agent && turn.author == .user,
                                   date: turn.date)
            case .dm(let chatRow):
                if chatRow.startsNew, divider == nil { divider = row.id }
                return chatRow.listRow(in: list)
            case .intro, .summary, .problem, .earlier, .answering:
                return ChatListRow(id: row.id, canAnchor: false)
            }
        }
        return ListContent(rows: listed, divider: divider, reachesNewest: reachesNewest, hasOlder: hasOlder)
    }

    /// A turn's row id: the reply's it streamed as, else its own.
    @MainActor static func id(of turn: AgentTurn, in agent: AgentSession) -> String {
        id(streaming: agent.streamedAs[turn.id] ?? turn.id)
    }

    /// The row id of a reply streaming under `id`, kept once it is saved.
    static func id(streaming id: String) -> String { "turn-" + id }
}

/// The agent chat's rows, oldest first. The rows above the reply are made
/// again only when they change (a turn, the summary, a problem, the name,
/// what is open); while a reply streams, only its row is.
@MainActor final class AgentRows {
    private struct Key: Equatable {
        var agent: ObjectIdentifier
        var turns: Int
        var last: String?
        var summary: AgentSession.Summary?
        var problem: AgentSession.Problem?
        var name: String
        var connected: Bool
        var open: Set<String>
        var earlier: Earlier
    }

    /// The local turns: the chat itself, or over the agent's DM (shown, or
    /// held back, the intro too, until the DM's rows start at its first).
    private enum Earlier { case none, shown, hidden }

    private var key: Key?
    private var settled: [AgentListRow] = []

    /// With `dm`, the chat is the agent's DM (`AppModel.agentChat`): the
    /// local turns above it under "Earlier, on this Mac", read only, once
    /// the DM has no older page to load.
    func rows(of agent: AgentSession, open: AgentOpenRows, dm: AgentDMRows? = nil) -> [AgentListRow] {
        let turns = agent.turns
        let opened = open.open
        let key = Key(agent: ObjectIdentifier(agent), turns: turns.count, last: turns.last?.id, summary: agent.summary, problem: agent.problem,
                      name: agent.name, connected: agent.connection != nil, open: opened,
                      earlier: dm.map { $0.fromStart ? .shown : .hidden } ?? .none)
        // Each row's open parts, by the row's id.
        func parts(of id: String) -> Set<String> {
            opened.isEmpty ? [] : opened.filter { AgentDisclosures.key($0, isIn: id) }
        }
        if key != self.key {
            self.key = key
            settled = Self.settled(agent, open: open, earlier: key.earlier, parts: parts)
        }
        if let dm { return settled + dm.rows(agent: agent, open: open, name: key.name) }
        guard let reply = agent.reply else { return settled }
        let id = AgentListRow.id(streaming: reply.id)
        let startsDay = turns.last.map { !Calendar.current.isDate(reply.date, inSameDayAs: $0.date) } ?? true
        let version = AgentListRow.Version(
            name: key.name, open: parts(of: id), startsDay: startsDay, writing: true, text: reply.text.utf8.count,
            tools: reply.tools, retrying: agent.retrying, ending: reply.ending
        )
        return settled + [AgentListRow(id: id, kind: .turn(reply, startsDay: startsDay, writing: true), version: version,
                                       agent: agent, openRows: open)]
    }

    private static func settled(_ agent: AgentSession, open: AgentOpenRows, earlier: Earlier,
                                parts: (String) -> Set<String>) -> [AgentListRow] {
        let name = agent.name
        func row(_ id: String, _ kind: AgentListRow.Kind, _ version: AgentListRow.Version) -> AgentListRow {
            AgentListRow(id: id, kind: kind, version: version, agent: agent, openRows: open)
        }
        let connected = agent.connection != nil
        if earlier == .hidden { return [] }
        var rows = [row("intro", .intro, .init(name: name, connected: connected))]
        if earlier == .shown && agent.turns.isEmpty { return rows }
        if earlier == .shown { rows.append(row("earlier", .earlier, .init(name: name))) }
        let turns = agent.turns
        let summary = agent.summary
        let problem = agent.problem
        rows.reserveCapacity(turns.count + 4)
        let calendar = Calendar.current
        for (index, turn) in turns.enumerated() {
            let startsDay = index == 0 || !calendar.isDate(turn.date, inSameDayAs: turns[index - 1].date)
            let id = AgentListRow.id(of: turn, in: agent)
            rows.append(row(id, .turn(turn, startsDay: startsDay, writing: false),
                            .init(name: name, open: parts(id), startsDay: startsDay, text: turn.text.utf8.count,
                                  ending: turn.ending)))
            if let summary, summary.through == turn.id {
                let id = "summary-" + summary.id
                rows.append(row(id, .summary(summary), .init(name: name, open: parts(id))))
            }
            // Read only over the DM: nothing to retry.
            if earlier == .none, let problem, problem.turnID == turn.id {
                rows.append(row("problem-" + turn.id, .problem(problem.failure), .init(name: name, failure: problem.failure)))
            }
        }
        return rows
    }
}

/// The agent's DM as the agent chat draws it: its rows as `ChatRow.rows`
/// makes them for it (`agentDM`: only the bridge's lines a person reads,
/// an agent's reply with its tool rows and no quote), and "writing…"
/// while it answers you.
struct AgentDMRows {
    let rows: [ChatRow]
    /// Your message it is answering (`AppModel.agentAnswering`).
    let answering: Message?
    /// The rows start at the DM's first message: the intro and the local
    /// turns go above them. Otherwise nothing does, so the list's first row
    /// is the DM's and a jump to an older message waits for its page.
    let fromStart: Bool

    func rows(agent: AgentSession, open: AgentOpenRows, name: String) -> [AgentListRow] {
        var shown = rows.map { row in
            AgentListRow(id: row.id, kind: .dm(row), version: .init(name: name, row: row), agent: agent, openRows: open)
        }
        if let answering {
            shown.append(AgentListRow(id: "answering-" + (answering.uuid ?? ""), kind: .answering,
                                      version: .init(name: name, writing: true), agent: agent, openRows: open))
        }
        return shown
    }
}

/// Which tool rows and summaries the agent chat has open, by key (the
/// row's id, then the part's): kept beside the list, not in a cell, so a
/// row scrolled away and back, or measured off the screen, is as it was.
@MainActor @Observable final class AgentOpenRows {
    var open: Set<String> = []

    /// Every tool row open (the offscreen driver's `agent-rows`).
    func openTools(of agent: AgentSession) {
        for turn in agent.turns {
            let parts = AgentDisclosures(rowID: AgentListRow.id(of: turn, in: agent), rows: self)
            for index in turn.tools.indices { parts.open("tool\(index)").set(true) }
        }
        if let reply = agent.reply {
            let parts = AgentDisclosures(rowID: AgentListRow.id(streaming: reply.id), rows: self)
            for index in reply.tools.indices { parts.open("tool\(index)").set(true) }
        }
    }
}

/// One row's parts a click opens.
struct AgentDisclosures {
    let rowID: String
    let rows: AgentOpenRows

    func open(_ part: String) -> AgentDisclosure {
        AgentDisclosure(rowID: rowID, key: rowID + "#" + part, rows: rows)
    }

    /// Whether an open part's `key` is one of the row's with this id.
    static func key(_ key: String, isIn rowID: String) -> Bool {
        key.hasPrefix(rowID + "#")
    }
}

/// One part a click opens (a tool's details, the summary): open while its
/// key is kept.
struct AgentDisclosure {
    let rowID: String
    let key: String
    let rows: AgentOpenRows

    @MainActor var isOpen: Bool { rows.open.contains(key) }

    @MainActor func set(_ open: Bool) {
        if open { rows.open.insert(key) } else { rows.open.remove(key) }
    }

    /// A click on its chevron: the list told first (`listRowExpanding`),
    /// so the row keeps its top as it opens or closes.
    @MainActor func toggle(expanding: (String) -> Void) {
        expanding(rowID)
        set(!isOpen)
    }
}
