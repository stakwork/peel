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
        let actions = DeviceActions(
            engine: engine, rules: agent.rules,
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
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .deny) }
                answers[id] = (request.agent, card, continuation)
                model?.waitingCards[request.agent, default: [:]][id] = approval.intent
            }
        } onCancel: {
            // Only this card: by then another may be up for the same request.
            Task { @MainActor in if self.answers[id]?.card == card { self.answer(id, .deny) } }
        }
    }

    /// Answers request `id`'s card, once: a second click finds none. Nil
    /// takes it down unanswered.
    func answer(_ id: String, _ decision: ApprovalDecision?) {
        guard let waiting = answers.removeValue(forKey: id) else { return }
        model?.waitingCards[waiting.agent]?[id] = nil
        if model?.waitingCards[waiting.agent]?.isEmpty == true { model?.waitingCards[waiting.agent] = nil }
        waiting.answer.resume(returning: decision)
    }

    /// The account closes: the cards come down unanswered, to be asked
    /// again when it opens.
    func close() {
        for id in Array(answers.keys) { answer(id, nil) }
        store = nil
        grants = []
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

    func readGrants() {
        grants = (try? store?.all()) ?? []
    }
}

/// A control message's line in a direct message; the agent's request whose
/// card waits on you (`ChatRow.approval`) draws the card in its place, as
/// the agent chat draws a tool's, and its line once answered.
struct DeviceRequestLine: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    let line: String
    let composer: ComposerID

    var body: some View {
        if let intent = row.approval, case .envelope(let request)? = row.message.control, let id = request.id {
            AgentApprovalCard(intent: intent, composer: composer, takesFocus: false) { model.macAgent.deviceCards.answer(id, $0) }
                .padding(.vertical, Theme.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            NoteLine(text: line)
        }
    }
}
