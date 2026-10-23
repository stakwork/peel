import AgentKit
import AppKit
import SwiftUI
import PeelCore
import PeelUI

/// One row of the agent chat's list (`MessageTableEngine`): Peel's intro,
/// an earlier local turn (its day line, tool calls and text), or a row of
/// the agent's DM. The intro and the earlier turns never hold the list's
/// place (`docs/reviews/2026-10-14-message-lists.md`, section 7 of the design).
struct AgentListRow: TableRow {
    enum Kind {
        case intro
        /// A turn of the chat Peel's own loop kept on this Mac, read only.
        case turn(AgentTurn, startsDay: Bool)
        /// Over the earlier local turns: "Old assistant chats (this Mac only)".
        case earlier
        /// One row of the agent's DM as the chat draws it, with the tools
        /// an agent's reply ran above it (`AgentDMRows`).
        case dm(ChatRow)
        /// The agent answering your message in its DM: "writing…".
        case answering
    }

    /// What a row's height depends on beyond its id; equal versions draw
    /// alike. An earlier turn never changes, so its text's length stands for it.
    struct Version: Equatable {
        var name: String
        /// Its tool rows open now, by key (`AgentOpenRows`).
        var open: Set<String> = []
        var startsDay = false
        var text = 0
        var connected = false
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
        case .intro, .earlier: .init("agent-note")
        case .dm(let row): .init("agent-" + row.reuse.rawValue)
        }
    }

    var estimatedHeight: CGFloat {
        switch kind {
        case .intro: return 90
        case .earlier: return 40
        case .answering: return 50
        case .dm(let row):
            let lines = row.agentTools.count + row.agentArtifacts.count + (row.agentJob == nil ? 0 : 1)
            return row.estimatedHeight + CGFloat(lines) * 24
        case .turn(let turn, let startsDay):
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
                case .turn(let turn, let startsDay):
                    if startsDay {
                        DayDivider(date: turn.date)
                            .padding(.horizontal, 20)
                    }
                    AgentTurnRow(turn: turn, name: version.name, disclosures: disclosures)
                case .earlier:
                    TitledDivider(title: Self.oldChatsTitle)
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
            case .turn(let turn, _):
                // Earlier turns: never new, never yours to follow.
                return ChatListRow(id: row.id, canAnchor: true, isOwn: false, date: turn.date)
            case .dm(let chatRow):
                if chatRow.startsNew, divider == nil { divider = row.id }
                return chatRow.listRow(in: list)
            case .intro, .earlier, .answering:
                return ChatListRow(id: row.id, canAnchor: false)
            }
        }
        return ListContent(rows: listed, divider: divider, reachesNewest: reachesNewest, hasOlder: hasOlder)
    }

    /// What the chat Peel's own loop kept is called, over its turns and in
    /// Account › Peel agent.
    static let oldChatsTitle = "Old assistant chats (this Mac only)"

    /// An earlier turn's row id.
    static func id(of turn: AgentTurn) -> String { "turn-" + turn.id }
}

/// The agent chat's rows, oldest first. The intro and the earlier turns
/// are made again only when they change (Clear, the name, what is open).
@MainActor final class AgentRows {
    private struct Key: Equatable {
        var agent: ObjectIdentifier
        var turns: Int
        var last: String?
        var name: String
        var connected: Bool
        var open: Set<String>
        /// The DM's rows start at its first (`AgentDMRows.fromStart`): the
        /// intro and the earlier turns go above them; else they wait.
        var fromStart: Bool
    }

    private var key: Key?
    private var settled: [AgentListRow] = []

    /// The earlier local turns under "Old assistant chats (this Mac only)", read only,
    /// once `dm` (the agent's DM, `AppModel.agentChat`, or none yet) has no
    /// older page to load; then the DM's rows.
    func rows(of agent: AgentSession, open: AgentOpenRows, dm: AgentDMRows) -> [AgentListRow] {
        let turns = agent.turns
        let opened = open.open
        let key = Key(agent: ObjectIdentifier(agent), turns: turns.count, last: turns.last?.id,
                      name: agent.name, connected: agent.connection != nil, open: opened,
                      fromStart: dm.fromStart)
        // Each row's open parts, by the row's id.
        func parts(of id: String) -> Set<String> {
            opened.isEmpty ? [] : opened.filter { AgentDisclosures.key($0, isIn: id) }
        }
        if key != self.key {
            self.key = key
            settled = key.fromStart ? Self.settled(agent, open: open, parts: parts) : []
        }
        return settled + dm.rows(agent: agent, open: open, name: key.name)
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
        if turns.isEmpty { return rows }
        rows.append(row("earlier", .earlier, .init(name: name)))
        rows.reserveCapacity(turns.count + 2)
        let calendar = Calendar.current
        for (index, turn) in turns.enumerated() {
            let startsDay = index == 0 || !calendar.isDate(turn.date, inSameDayAs: turns[index - 1].date)
            let id = AgentListRow.id(of: turn)
            rows.append(row(id, .turn(turn, startsDay: startsDay),
                            .init(name: name, open: parts(id), startsDay: startsDay, text: turn.text.utf8.count)))
        }
        return rows
    }
}

/// The agent's DM as the agent chat draws it: its rows as `ChatRow.rows`
/// makes them for it (`agentDM`: only the bridge's lines a person reads,
/// an agent's reply with its tool rows and no quote), and "writing…"
/// while it answers you.
@MainActor struct AgentDMRows {
    let rows: [ChatRow]
    /// Your message it is answering (`AppModel.agentAnswering`).
    let answering: Message?
    /// The rows start at the DM's first message: the intro and the local
    /// turns go above them. Otherwise nothing does, so the list's first row
    /// is the DM's and a jump to an older message waits for its page.
    let fromStart: Bool

    func rows(agent: AgentSession, open: AgentOpenRows, name: String) -> [AgentListRow] {
        var shown = rows.map { row in
            // Its opened part (a request's details), so the row is measured again as it opens.
            AgentListRow(id: row.id, kind: .dm(row),
                         version: .init(name: name, open: open.open.filter { AgentDisclosures.key($0, isIn: row.id) }, row: row),
                         agent: agent, openRows: open)
        }
        if let answering {
            shown.append(AgentListRow(id: "answering-" + (answering.uuid ?? ""), kind: .answering,
                                      version: .init(name: name), agent: agent, openRows: open))
        }
        return shown
    }
}

/// Which tool rows and request details the agent chat has open, by key (the
/// row's id, then the part's): kept beside the list, not in a cell, so a
/// row scrolled away and back, or measured off the screen, is as it was.
@MainActor @Observable final class AgentOpenRows {
    var open: Set<String> = []

    /// Every tool row open (the offscreen driver's `agent-rows`).
    func openTools(of agent: AgentSession) {
        for turn in agent.turns {
            let parts = AgentDisclosures(rowID: AgentListRow.id(of: turn), rows: self)
            for index in turn.tools.indices { parts.open("tool\(index)").set(true) }
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

/// One part a click opens (a tool's details, a request's): open while its
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
