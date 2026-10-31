import AgentKit
import Foundation
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// The cards for the agent's device requests that ask you (`DeviceActions`,
/// docs/agent-on-strut.md, "Approvals"): each waits in the agent's DM on
/// its request's line (`AppModel.waitingCards`) until you answer, it
/// expires, or the account closes; and the send grants your answers made,
/// for Account › Peel agent.
@MainActor @Observable
final class DeviceCards {
    /// The cards up, by request id: who asked, which card, and its answer.
    @ObservationIgnored private var answers: [String: (agent: String, card: UUID, answer: CheckedContinuation<ApprovalDecision?, Never>)] = [:]
    /// The send grants, oldest first, as last read.
    private(set) var grants: [SendGrant] = []
    @ObservationIgnored private var store: SendGrants?
    @ObservationIgnored weak var model: AppModel?

    /// The handler for `engine`'s device requests, its cards here, sharing
    /// `agent`'s "always" rules.
    func handler(for engine: Engine, agent: AgentSession) -> DeviceRequestHandler {
        store = SendGrants(beside: agent.rules)
        readGrants()
        // The proposals' records, read from Peel's strut as it runs now (its
        // port and key change as it starts again) and kept with the account.
        let strut: @Sendable () async throws -> AutomationsClient = { [weak self] in
            guard let server = await self?.model?.memoryServer else { throw PeelError("Peel's strut is not running.") }
            return AutomationsClient(server: server)
        }
        let read: @Sendable (String) async throws -> ProposalRead = { id in try await strut().readProposal(id) }
        model?.proposals.readLocal = read
        let actions = DeviceActions(
            engine: engine, rules: agent.rules,
            proposals: ProposalReader(
                read: read,
                peer: { record in try await strut().peerRequest(from: record) },
                keep: { [weak self] request, record in
                    await self?.model?.proposals.keep(record, source: .local, request: request.id,
                                                      notAfter: Int64(request.deadline.timeIntervalSince1970))
                }
            ),
            ask: { [weak self] request, approval in await self?.ask(request, approval) },
            changed: { [weak self, weak agent] in
                Task { @MainActor in
                    agent?.reloadRules()
                    self?.readGrants()
                }
            }
        )
        return actions.handler
    }

    /// Puts `approval`'s card up on `request`'s line and waits; cancelled,
    /// it comes down as a Deny.
    private func ask(_ request: DeviceRequest, _ approval: ApprovalRequest) async -> ApprovalDecision? {
        let id = request.id
        answer(id, nil)
        let card = UUID()
        // The isolation named, as in `Engine.nextChange`: inferred, an optimized build ran it off the actor.
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation(isolation: MainActor.shared) { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .deny) }
                answers[id] = (request.agent, card, continuation)
                model?.waitingCards[request.agent, default: [:]][id] = approval.intent
            }
        }, onCancel: {
            // Only this card: by then another may be up for the same request.
            Task { @MainActor in if self.answers[id]?.card == card { self.answer(id, .deny) } }
        }, isolation: MainActor.shared)
    }

    /// Answers request `id`'s card, once: a second click finds none. Nil
    /// takes it down unanswered.
    func answer(_ id: String, _ decision: ApprovalDecision?) {
        guard let waiting = answers.removeValue(forKey: id) else { return }
        model?.waitingCards[waiting.agent]?[id] = nil
        if model?.waitingCards[waiting.agent]?.isEmpty == true { model?.waitingCards[waiting.agent] = nil }
        waiting.answer.resume(returning: decision)
        // A proposal's card: the bridge tells strut within seconds, and the record follows.
        if decision != nil { model?.proposals.answered(request: id) }
    }

    /// The account closes: the cards come down unanswered, to be asked
    /// again when it opens.
    func close() {
        for id in Array(answers.keys) { answer(id, nil) }
        store = nil
        grants = []
        model?.proposals.readLocal = nil
    }

    func revoke(_ grant: SendGrant) throws {
        try store?.revoke(grant)
        readGrants()
    }

    /// An automation deleted here takes its grant with it, whether or not
    /// the device's handler was made.
    func revokeGrants(of automation: String) throws {
        guard let store = store ?? model?.agent.map({ SendGrants(beside: $0.rules) }) else { return }
        try store.revoke(automation: automation)
        readGrants()
    }

    /// The grants of automations strut no longer has go (one the agent
    /// deleted, or any other way): `held` is the ids of the person's
    /// automations now, `missed` the grants' ids it did not list at the last
    /// read. Only an id missing from both goes, so one read that lacks an
    /// automation takes nothing; and one kept in the last 10 minutes stays,
    /// since its automation is made just after its card is allowed. Returns
    /// the ids missing now, for the next read.
    func revokeGrants(missingFrom held: Set<String>, missedBefore missed: Set<String>) throws -> Set<String> {
        guard let store = store ?? model?.agent.map({ SendGrants(beside: $0.rules) }) else { return [] }
        let missing = Set(grants.map(\.automation)).subtracting(held)
        let kept = held.union(missing.subtracting(missed))
        if try store.revoke(allBut: kept, keptBefore: Date(timeIntervalSinceNow: -600)) > 0 { readGrants() }
        return missing
    }

    func readGrants() {
        grants = (try? store?.all()) ?? []
    }
}

/// A control message's line in a direct message; the agent's request whose
/// card waits on you (`ChatRow.approval`) draws the card in its place, and
/// its line once answered.
struct DeviceRequestLine: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    let line: String

    var body: some View {
        if case .envelope(let request)? = row.message.control, let id = request.id, id.hasPrefix(DeviceActions.proposalPrefix),
           let kept = model.proposals.kept(request: id), !kept.record.isHandOff {
            // One of strut's proposals: its card, from the record the Mac kept,
            // with its buttons while it waits here and its state after. A call
            // to a workspace keeps its own card below.
            ProposalCardView(
                proposal: kept, org: nil, stance: row.approval != nil ? .waiting : .answered(row.agentRequest?.status),
                note: model.proposals.notes[kept.key], input: AgentDisclosures(rowID: row.id, rows: model.agentOpenRows).open("input"),
                answer: row.approval == nil ? nil : { model.macAgent.deviceCards.answer(id, $0 ? .allowOnce : .deny) }
            )
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let intent = row.approval, case .envelope(let request)? = row.message.control, let id = request.id {
            AgentApprovalCard(intent: intent) { model.macAgent.deviceCards.answer(id, $0) }
                .padding(.vertical, Theme.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let reads = row.reads {
            // Reads back to back: one line, opening into a step per kind; its own
            // key, so a lone read's open row does not open the group it joins.
            AgentDisclosureRow(AgentDisclosures(rowID: row.id, rows: model.agentOpenRows).open("reads")) {
                Text(reads.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reads.summary)
                // A read still on this Mac: how it stands.
                AgentRequestStatus(request: reads.waiting)
                if reads.span >= 1 {
                    Text("· " + AgentToolTitle.duration(.seconds(reads.span)))
                        .monospacedDigit()
                        .fixedSize()
                }
            } detail: {
                AgentReadSteps(reads: reads)
            }
            .padding(.leading, MessageRow.avatarSize + MessageRow.gutterSpacing)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let request = row.agentRequest {
            // One quiet row, as an agent's tool, in line with the messages' text;
            // a click opens what it read or did.
            AgentDisclosureRow(AgentDisclosures(rowID: row.id, rows: model.agentOpenRows).open("request")) {
                Text(request.label)
                AgentRequestStatus(request: request)
            } detail: {
                DeviceRequestDetail(request: request)
            }
            .padding(.leading, MessageRow.avatarSize + MessageRow.gutterSpacing)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            NoteLine(text: line)
        }
    }
}

/// How a request to this Mac stands, after its words: a tick once done
/// (nil: all done), else its outcome, turning too late at its expiry.
private struct AgentRequestStatus: View {
    let request: AgentRequest?

    var body: some View {
        TimelineView(.redrawing(at: request?.changesAt)) { context in
            if let outcome = request?.outcome(at: context.date) {
                Text("· " + outcome).fixedSize()
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityLabel("Done")
            }
        }
    }
}

/// A chat a read covered, opening it.
private struct ChatLink: View {
    @Environment(AppModel.self) private var model
    let chat: ChatDataReading.Chat

    var body: some View {
        Button(chat.name) { model.destination = .chat(chat.chat) }
            .buttonStyle(.peel(.link))
            .help("Open \(chat.isTribe ? "the tribe" : "the chat")")
    }
}

/// Folded reads, opened: a step per kind of read, joined by a line, each
/// with the chats it covered, each opening its chat (or, before this Mac's
/// answer names them, as the agent asked for them), or a search's words.
private struct AgentReadSteps: View {
    let reads: AgentReads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(reads.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Image(systemName: Self.symbol(step.kind))
                            .font(.system(size: 10))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.panel))
                            .overlay(Circle().strokeBorder(Theme.divider))
                            .accessibilityHidden(true)
                        if index < reads.steps.count - 1 {
                            Theme.divider.frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.title).foregroundStyle(Theme.text)
                            if step.done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .accessibilityLabel("Done")
                            }
                        }
                        subjects(of: step)
                    }
                    .padding(.top, 3)
                    .padding(.bottom, index < reads.steps.count - 1 ? 10 : 0)
                }
            }
        }
        .font(Theme.font(12))
        .foregroundStyle(Theme.secondaryText)
    }

    /// The chats this Mac's answers named, each a link; else what the agent named.
    @ViewBuilder private func subjects(of step: AgentReads.Step) -> some View {
        let chats = step.kind == .search ? [] : Self.chats(in: step.requests)
        if !chats.isEmpty {
            ChipFlow(spacing: 8) {
                ForEach(chats.prefix(DeviceRequestDetail.chats), id: \.chat) { ChatLink(chat: $0) }
                if chats.count > DeviceRequestDetail.chats {
                    Text("and \(chats.count - DeviceRequestDetail.chats) more")
                }
            }
        } else if !step.subjects.isEmpty {
            Text(step.subjects.joined(separator: ", "))
        }
    }

    /// Each chat the answers read, once, in the order read.
    private static func chats(in requests: [AgentRequest]) -> [ChatDataReading.Chat] {
        var seen = Set<String>()
        return requests.flatMap { ChatDataReading($0.text ?? "").chats }.filter { seen.insert($0.chat).inserted }
    }

    private static func symbol(_ kind: AgentReads.Kind) -> String {
        switch kind {
        case .unseen: "tray"
        case .chats: "list.bullet"
        case .chat: "bubble.left"
        case .threads: "arrowshape.turn.up.left"
        case .search: "magnifyingglass"
        case .calendar: "calendar"
        }
    }
}

/// What a device request read or did, under its row: the chats a read
/// covered, each linked, with the messages it read (a few each, each
/// opening its message); the message a send sent, with View; what an
/// approval asked; why it was not done.
private struct DeviceRequestDetail: View {
    @Environment(AppModel.self) private var model
    let request: AgentRequest

    /// The most chats, and messages in each, shown; the rest counted.
    static let chats = 8
    private static let lines = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = request.reason {
                FactLine(label: "Why", text: reason)
            }
            // Outside the agent chat, one never answered was not this Mac's to do:
            // nothing of what its sender asked is shown.
            switch request.asker != nil && request.status == nil ? "" : request.kind {
            case "":
                Text("This Mac did not answer it.").foregroundStyle(Theme.secondaryText)
            case "send":
                if let text = Self.string("text", in: request.args) { FactLine(label: "Text", text: text) }
                if let said = request.text {
                    HStack(spacing: 6) {
                        Text(AgentToolTitle.summary(said)).foregroundStyle(Theme.text)
                        if let url = AgentMessageLink(summary: said)?.url {
                            Button("View") { _ = model.openAgentLink(url) }
                                .buttonStyle(.peel(.link))
                        }
                    }
                }
            case "approve":
                if case .object(let args)? = request.args, let intent = args["intent"] {
                    if let action = Self.string("action", in: intent) { FactLine(label: "Asked", text: action) }
                    if let content = Self.string("content", in: intent) { FactLine(label: "Content", text: content) }
                }
                if let said = request.text { FactLine(label: "Answer", text: said) }
            default:
                if let text = request.text { reading(ChatDataReading(text)) }
            }
            if request.asker == nil, request.status == nil, request.reason == nil {
                TimelineView(.redrawing(at: request.changesAt)) { context in
                    Text(request.isExpired(at: context.date) ? "Your Mac did not answer in time. Nothing was done."
                         : "Your Mac has not answered yet.").foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .font(Theme.font(12))
        .textSelection(.enabled)
    }

    @ViewBuilder private func reading(_ read: ChatDataReading) -> some View {
        Text(read.header).foregroundStyle(Theme.secondaryText)
        ForEach(Array(read.chats.prefix(Self.chats).enumerated()), id: \.offset) { _, chat in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ChatLink(chat: chat)
                    if let detail = chat.detail { Text(detail).foregroundStyle(Theme.secondaryText) }
                }
                ForEach(Array(chat.messages.prefix(Self.lines).enumerated()), id: \.offset) { _, line in
                    let text = Text("\(line.sender): ").foregroundStyle(Theme.secondaryText) + Text(line.text).foregroundStyle(Theme.text)
                    if let uuid = line.uuid, let url = AgentMessageLink(chat: chat.chat, uuid: uuid).url {
                        Button { _ = model.openAgentLink(url) } label: { text.lineLimit(1).truncationMode(.tail) }
                            .buttonStyle(.plain)
                            .help("Show this message")
                    } else {
                        text.lineLimit(1).truncationMode(.tail)
                    }
                }
                if chat.messages.count > Self.lines {
                    Text("and \(chat.messages.count - Self.lines) more").foregroundStyle(Theme.secondaryText)
                }
            }
        }
        if read.chats.count > Self.chats {
            Text("and \(read.chats.count - Self.chats) more chats").foregroundStyle(Theme.secondaryText)
        }
    }

    /// The string at `key` in an object the agent sent; nil for anything else.
    private static func string(_ key: String, in value: PeelCore.JSONValue?) -> String? {
        guard case .object(let object)? = value, case .string(let text)? = object[key] else { return nil }
        return text
    }

}

