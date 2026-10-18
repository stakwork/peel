import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// Account › Peel agent › "Run in strut (preview)" (docs/agent-on-strut.md,
/// PR 4): the agent's bridge (`BundledBridge`) beside Peel's strut, holding
/// the agent's own account, which this account adds as a contact. Offered
/// only in dev builds and off by default until PR 10; off, nothing of it
/// starts. Today's agent chat is unchanged either way.
@MainActor @Observable
final class AgentBridge {
    /// Where the preview is kept: this build's defaults, for every account.
    static let previewKey = "agentOnStrut"

    /// Whether this build offers the preview: dev builds only.
    static var offered: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The switch as this build keeps it, read before any account opens (`strut(for:)`).
    static var isOn: Bool { offered && UserDefaults.standard.bool(forKey: previewKey) }

    enum Status: Equatable {
        case off
        case starting
        /// The bridge runs and the agent is a contact.
        case running
        case failed(String)
    }

    /// The switch, for Account › Peel agent; kept in the build's defaults.
    var previewOn = AgentBridge.isOn {
        didSet { UserDefaults.standard.set(previewOn, forKey: Self.previewKey) }
    }
    /// What the preview is doing, for Account › Peel agent.
    var status = Status.off
    /// The bridge for this launch's profile, made when the preview first starts it.
    @ObservationIgnored var bridge: BundledBridge?
    /// The start in flight, and the strut it started beside.
    @ObservationIgnored var starting: Task<Void, Never>?
    @ObservationIgnored var strut: MemoryServer?
    /// The person turned the preview on, so the next start may pair the
    /// agent (an invite, a key exchange); a start on its own, never.
    @ObservationIgnored var pairing = false
    /// Turning the preview off taking this Mac's answers away (`setDeviceAgent(nil)`).
    @ObservationIgnored var clearing: Task<Void, Never>?
    /// Your messages in the agent's DM whose turn Stop ended here: no
    /// "writing…" for them, whether or not the bridge's "Stopped." comes.
    var stopped: Set<String> = []
    /// The person's automations moving between workflows (`AppModel.moveAutomations`), one move at a time.
    @ObservationIgnored var moving: Task<String?, Never>?

    func stop() {
        starting?.cancel()
        starting = nil
        strut = nil
        bridge?.stop(quietly: true)
        status = .off
    }
}

extension AppModel {
    var agentBridge: AgentBridge { macAgent.agentBridge }

    // MARK: The agent chat as the agent's DM (docs/agent-on-strut.md, "One conversation")

    /// The agent row's unread count: its DM's, or the local chat's.
    var agentUnread: Int {
        guard let agentChat else { return agent?.unread ?? 0 }
        return readStates[agentChat]?.sidebarCount ?? 0
    }

    /// Your message the agent is answering in its open DM
    /// (`agentUnanswered`), unless Stop ended it here.
    var agentAnswering: Message? {
        guard let agentChat, loadedChat == agentChat, let message = agentUnanswered,
              !(message.uuid.map(agentBridge.stopped.contains) ?? true) else { return nil }
        return message
    }

    /// A card waiting on you in the agent chat: the local loop's, or one
    /// in its DM.
    var agentWaiting: Bool {
        agent?.waiting != nil || agentChat.map { waitingCards[$0] != nil } == true
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

    /// Whether the preview's bridge belongs on this Mac: on, with the agent
    /// open and this Mac its brain.
    private var bridgeRunsHere: Bool { agentBridge.previewOn && agent != nil && brain == .thisMac }

    /// The agent's contact for the agent chat while the preview runs on
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

    /// Turns the preview on or off: on, Peel's strut (started for it on a
    /// development profile too) and the bridge beside it; off, the bridge
    /// stops, and a development profile's strut too unless `-strut YES` asked
    /// for it. The agent's account and contact stay, for the next time.
    func setAgentOnStrut(_ on: Bool) {
        agentBridge.previewOn = on
        // Off, or on again after a failure: a fresh start.
        agentBridge.stop()
        agentBridge.pairing = on
        guard let profile, agent != nil, brain == .thisMac else { return }
        macAgent.hasOwnStrut = Self.strut(for: profile) != nil
        if on {
            useOwnStrut(profile)
        } else {
            // Off, this Mac answers no agent's requests (on, once the bridge is set
            // up: `startBridge`), and strut forgets where the stopped bridge was, so
            // no step posts to that port again; the person's automations go back to
            // `peel-automation`; then a strut started only for the preview stops,
            // unless a reply or a move uses it (then at quit).
            let engine = engine, server = strut?.server
            var started: BundledStrut?
            if !macAgent.hasOwnStrut, agent?.isRunning != true, memoryMove?.isRunning != true {
                started = strut
                strut = nil
            }
            agentBridge.clearing = Task {
                try? await engine?.setDeviceAgent(nil)
                if let server {
                    let client = AutomationsClient(server: server)
                    try? await client.forgetBridge()
                    await moveAutomations(on: server, to: AutomationsClient.workflow, callback: nil)
                }
                started?.stop(quietly: true)
            }
            useAutomationTools()
        }
        lookForMemory(reporting: true)
        lookForBridge()
    }

    /// Starts the bridge when the preview is on and Peel's own strut runs,
    /// and stops it when either is no longer so. Looked at when the agent
    /// opens and whenever strut starts or stops; a strut started again
    /// (a new key and port) gets a new bridge.
    func lookForBridge() {
        lookForAgentContact()
        let bridge = agentBridge
        guard bridgeRunsHere, let profile, let engine,
              let server = strut?.server, !server.isHomeServer else {
            if bridge.status != .off { bridge.stop() }
            return
        }
        guard bridge.strut != server else { return }
        bridge.stop()
        bridge.strut = server
        bridge.status = .starting
        bridge.starting = Task {
            do {
                try await startBridge(bridge, for: profile, engine: engine, beside: server)
            } catch is CancellationError {
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
        running.onChange = { [weak self, weak bridge, weak running] in
            // Runner stopped by itself: tried again only when strut starts again or the preview is turned on.
            guard let bridge, let running, running.server == nil, bridge.bridge === running,
                  bridge.status != .off else { return }
            bridge.strut = nil
            bridge.status = .failed("The agent's bridge stopped.")
            // New automations go where they run without it.
            self?.useAutomationTools()
        }
        // The steps the orchestrator's turns ask this Mac through, before the bridge runs a turn.
        let client = AutomationsClient(server: server)
        try await client.installOrchestrator()
        let pair = bridge.pairing
        bridge.pairing = false
        let account = try await running.setUp(on: engine, beside: server, alias: agent?.name ?? "Agent", pair: pair)
        try Task.checkCancellation()
        // Only now does this Mac answer the agent's requests: its reads and cards
        // (after a clear from turning it off just before, which would undo it).
        await bridge.clearing?.value
        bridge.clearing = nil
        try await engine.setDeviceAgent(account.pubkey)
        agentContact = account.pubkey
        // Where the steps reach the bridge now.
        guard let reached = running.server else { throw PeelError("The agent's bridge stopped.") }
        try await client.useBridge(reached)
        try Task.checkCancellation()
        bridge.status = .running
        // The person's automations run here now, their reports to the DM (and the
        // agent's tools make new ones here, reporting there).
        useAutomationTools()
        await moveAutomations(on: server, to: Orchestrator.automationWorkflow, callback: reached.runEnds)
    }
}
