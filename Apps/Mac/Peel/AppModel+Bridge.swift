import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// The agent (docs/agent-on-strut.md, PR 10): its bridge (`BundledBridge`)
/// beside Peel's strut, holding the agent's own account, which this account
/// adds as a contact once, when the person sets it up ("Give your assistant
/// its own account"). Until then nothing of it starts, and nothing is paid.
@MainActor @Observable
final class AgentBridge {
    enum Status: Equatable {
        /// Not on this Mac: no agent, the brain elsewhere, or no strut running.
        case off
        /// The agent's account is not a contact yet: the person's "Set up" starts it.
        case notSetUp
        case starting
        /// The bridge runs and the agent is a contact.
        case running
        case failed(String)
    }

    /// What the bridge is doing, for the agent chat and Account › Peel agent.
    var status = Status.off
    /// The bridge for this launch's profile, made when it first starts.
    @ObservationIgnored var bridge: BundledBridge?
    /// The start in flight, and the strut it started beside.
    @ObservationIgnored var starting: Task<Void, Never>?
    @ObservationIgnored var strut: MemoryServer?
    /// This start may pair the agent (an invite, a key exchange): it came
    /// from the person's Set up, where the cost was shown. A start on its
    /// own, never; any stop forgets it.
    var pairing = false
    /// Your messages in the agent's DM whose turn Stop ended here: no
    /// "writing…" for them, whether or not the bridge's "Stopped." comes.
    var stopped: Set<String> = []
    /// The person's automations moving between workflows (`AppModel.moveAutomations`), one move at a time.
    @ObservationIgnored var moving: Task<String?, Never>?

    /// Stopped, and `problem` said with Try again; a failure said already stays.
    func fail(_ problem: String) {
        let said = status
        stop()
        status = if case .failed = said { said } else { .failed(problem) }
    }

    func stop() {
        starting?.cancel()
        starting = nil
        strut = nil
        pairing = false
        bridge?.stop(quietly: true)
        status = .off
    }
}

/// Where the agent's own account stands, for the agent chat (in the
/// composer's place until its DM is the chat) and Account › Peel agent.
struct AgentSetUp: Equatable {
    var line: String
    /// Something went wrong: said in the attention colour.
    var problem = false
    /// Under way: a spinner.
    var busy = false
    /// The person's next step: "Set up", or "Try again".
    var action: String?

    /// What the first set-up shows before anything is paid.
    static let offer = AgentSetUp(
        line: "Your assistant gets its own Sphinx account, made from your words, and becomes a contact you message from this Mac or your phone. "
            + "Setting it up costs up to \(Sats.format(msat: BundledBridge.setUpMsat)) from your balance: "
            + "\(Sats.format(msat: BundledBridge.inviteMsat)) to open its account and "
            + "\(Sats.format(msat: Engine.keyExchangeMsat + Engine.pingMsat(toTribe: false))) to add it as a contact.",
        action: "Set up"
    )
}

extension AppModel {
    var agentBridge: AgentBridge { macAgent.agentBridge }

    /// The agent's own account, as the person sees it (`AgentSetUp`).
    var agentSetUp: AgentSetUp {
        guard agent?.connection != nil else { return AgentSetUp(line: "Connect a model first: your assistant answers with it.") }
        guard brain == .thisMac else {
            return AgentSetUp(line: "Your assistant runs with Peel's memory on this Mac. Choose This Mac under Brain to use it.")
        }
        guard hasOwnStrut else {
            return AgentSetUp(line: profile?.kind == .development
                ? "This development profile runs your assistant only when Peel is started with -strut YES."
                : "This copy of Peel has no memory of its own to run your assistant.")
        }
        switch agentBridge.status {
        case .off: return AgentSetUp(line: "Starting Peel's memory…", busy: true)
        case .notSetUp: return .offer
        case .starting:
            return AgentSetUp(line: agentBridge.pairing ? "Setting up your assistant's account. This can take a minute." : "Starting your assistant…",
                              busy: true)
        case .running: return AgentSetUp(line: "Your assistant is a contact in Direct messages.")
        case .failed(let problem): return AgentSetUp(line: problem, problem: true, action: "Try again")
        }
    }

    // MARK: The agent chat as the agent's DM (docs/agent-on-strut.md, "One conversation")

    /// The agent row's unread count: its DM's.
    var agentUnread: Int {
        agentChat.flatMap { readStates[$0]?.sidebarCount } ?? 0
    }

    /// Your message the agent is answering in its open DM
    /// (`agentUnanswered`), unless Stop ended it here.
    var agentAnswering: Message? {
        guard let agentChat, loadedChat == agentChat, let message = agentUnanswered,
              !(message.uuid.map(agentBridge.stopped.contains) ?? true) else { return nil }
        return message
    }

    /// A card waiting on you in the agent's DM.
    var agentWaiting: Bool {
        agentChat.map { waitingCards[$0] != nil } == true
    }

    /// Stop in the agent's DM: a `cancel` for the turn in flight, which the
    /// bridge passes to strut, and the cards that turn put up (requests
    /// since your message) come down as Deny; an automation's stay.
    /// "writing…" goes now, so a bridge that never answers leaves nothing
    /// running here.
    func stopAgentTurn() {
        guard let engine, let agentChat, let answering = agentAnswering, let uuid = answering.uuid else { return }
        agentBridge.stopped.insert(uuid)
        let asked = Set(timeline.messages.lazy.filter { !$0.fromMe && $0.date >= answering.date }.compactMap { message in
            if case .envelope(let request)? = message.control, request.op == .request { request.id } else { nil }
        })
        for id in (waitingCards[agentChat] ?? [:]).keys where asked.contains(id) { macAgent.deviceCards.answer(id, .deny) }
        Task {
            do {
                _ = try await engine.sendControl(ControlEnvelope(op: .cancel), text: "Stop", to: agentChat)
            } catch {
                conversationNotices[agentChat] = PeelError.problem(error, couldNot: "stop the agent")
            }
        }
    }

    /// Whether the agent's bridge belongs on this Mac: the agent open and
    /// this Mac its brain.
    private var bridgeRunsHere: Bool { agent != nil && brain == .thisMac }

    /// The agent's contact for the agent chat while its bridge runs on
    /// this Mac: the one the bridge last set up (`Setting.deviceAgent`),
    /// read now so its DM is the chat before the bridge is back up.
    private func lookForAgentContact() {
        guard bridgeRunsHere, let engine else {
            agentContact = nil
            return
        }
        guard agentContact == nil else { return }
        Task {
            let contact = await engine.deviceAgent
            guard self.engine === engine, bridgeRunsHere, agentContact == nil else { return }
            agentContact = contact
        }
    }

    /// The person's "Set up" (or "Try again"): Peel's strut started again
    /// if it stopped, and a fresh start of the bridge, which pairs the agent
    /// (`BundledBridge.setUp`) only where the cost was on the screen: the
    /// offer, or a Try again after a set-up that failed.
    func setUpAgent() {
        let bridge = agentBridge
        let pair = bridge.status == .notSetUp || bridge.pairing
        bridge.stop()
        lookForMemory(reporting: true)
        lookForBridge(pairing: pair)
    }

    /// Starts the bridge when the agent is open here and Peel's own strut
    /// runs, and stops it when either is no longer so. Looked at when the agent
    /// opens and whenever strut starts or stops; a strut started again
    /// (a new key and port) gets a new bridge.
    func lookForBridge(pairing: Bool = false) {
        lookForAgentContact()
        let bridge = agentBridge
        guard bridgeRunsHere, let profile, let engine,
              let server = strut?.server, !server.isHomeServer else {
            // Peel's strut stopped under it: said, with Try again, since nothing else starts it again now.
            if bridgeRunsHere, bridge.status != .off {
                bridge.fail("Peel's memory on this Mac stopped.")
            } else if bridge.status != .off {
                bridge.stop()
            }
            return
        }
        guard bridge.strut != server else { return }
        // A start still running (a key exchange cannot be cut short) ends first.
        let previous = bridge.starting
        bridge.stop()
        bridge.strut = server
        bridge.pairing = pairing
        bridge.status = .starting
        bridge.starting = Task {
            await previous?.value
            do {
                try await startBridge(bridge, for: profile, engine: engine, beside: server)
            } catch is CancellationError {
            } catch is BundledBridge.NotSetUp {
                bridge.status = .notSetUp
            } catch {
                guard !Task.isCancelled else { return }
                bridge.bridge?.stop(quietly: true)
                bridge.status = .failed(PeelError.problem(error, couldNot: "start the agent's bridge"))
            }
        }
    }

    /// The bridge for `profile`, set up for the agent's account (`BundledBridge.setUp`).
    private func startBridge(_ bridge: AgentBridge, for profile: Profile, engine: Engine, beside server: MemoryServer) async throws {
        guard let running = bridge.bridge ?? BundledBridge(data: BundledBridge.dataFolder(for: profile)) else {
            throw PeelError("This build of Peel has no bridge (scripts/stage-bridge.sh).")
        }
        bridge.bridge = running
        running.onChange = { [weak bridge, weak running] in
            // Runner stopped by itself: tried again only when strut starts again or on the person's Try again.
            guard let bridge, let running, running.server == nil, bridge.bridge === running,
                  bridge.status != .off else { return }
            bridge.strut = nil
            bridge.status = .failed("The agent's bridge stopped.")
            // No step posts to its port again.
            Task { try? await AutomationsClient(server: server).forgetBridge() }
        }
        // The steps the orchestrator's turns ask this Mac through, before the bridge runs a turn.
        let client = AutomationsClient(server: server)
        try await client.installOrchestrator()
        let account = try await running.setUp(on: engine, beside: server, alias: agent?.name ?? "Agent", pair: bridge.pairing)
        try Task.checkCancellation()
        // Only now does this Mac answer the agent's requests: its reads and cards.
        try await engine.setDeviceAgent(account.pubkey)
        agentContact = account.pubkey
        // Where the steps reach the bridge now.
        guard let reached = running.server else { throw PeelError("The agent's bridge stopped.") }
        try await client.useBridge(reached)
        try Task.checkCancellation()
        bridge.status = .running
        // The person's automations run here now, their reports to the DM.
        await moveAutomations(on: server, to: Orchestrator.automationWorkflow, callback: reached.runEnds)
    }
}
