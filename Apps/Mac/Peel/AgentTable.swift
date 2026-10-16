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
        case .turn: .init("agent-turn")
        case .intro, .summary, .problem: .init("agent-note")
        }
    }

    var estimatedHeight: CGFloat {
        switch kind {
        case .intro: return 90
        case .summary: return 36
        case .problem: return 64
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// None: an agent row shows its own More on hover (`AgentRow`).
    func hoverBar(in list: ComposerID) -> AnyView? { nil }

    static func listContent(_ rows: [AgentListRow], in list: ComposerID, reachesNewest: Bool, hasOlder: Bool) -> ListContent {
        ListContent(rows: rows.map { row in
            switch row.kind {
            case .turn(let turn, _, let writing):
                ChatListRow(id: row.id, canAnchor: !writing, isOwn: turn.author == .user, date: turn.date)
            case .intro, .summary, .problem:
                ChatListRow(id: row.id, canAnchor: false)
            }
        })
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
    }

    private var key: Key?
    private var settled: [AgentListRow] = []

    func rows(of agent: AgentSession, open: AgentOpenRows) -> [AgentListRow] {
        let turns = agent.turns
        let opened = open.open
        let key = Key(agent: ObjectIdentifier(agent), turns: turns.count, last: turns.last?.id, summary: agent.summary, problem: agent.problem,
                      name: agent.name, connected: agent.connection != nil, open: opened)
        // Each row's open parts, by the row's id.
        func parts(of id: String) -> Set<String> {
            opened.isEmpty ? [] : opened.filter { AgentDisclosures.key($0, isIn: id) }
        }
        if key != self.key {
            self.key = key
            settled = Self.settled(agent, open: open, parts: parts)
        }
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

    private static func settled(_ agent: AgentSession, open: AgentOpenRows,
                                parts: (String) -> Set<String>) -> [AgentListRow] {
        let name = agent.name
        func row(_ id: String, _ kind: AgentListRow.Kind, _ version: AgentListRow.Version) -> AgentListRow {
            AgentListRow(id: id, kind: kind, version: version, agent: agent, openRows: open)
        }
        let connected = agent.connection != nil
        var rows = [row("intro", .intro, .init(name: name, connected: connected))]
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
            if let problem, problem.turnID == turn.id {
                rows.append(row("problem-" + turn.id, .problem(problem.failure), .init(name: name, failure: problem.failure)))
            }
        }
        return rows
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
