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
            // no step posts to that port again; then a strut started only for the
            // preview stops, unless a reply or a move uses it (then at quit).
            let engine = engine, server = strut?.server
            var started: BundledStrut?
            if !macAgent.hasOwnStrut, agent?.isRunning != true, memoryMove?.isRunning != true {
                started = strut
                strut = nil
            }
            agentBridge.clearing = Task {
                try? await engine?.setDeviceAgent(nil)
                if let server { try? await AutomationsClient(server: server).forgetBridge() }
                started?.stop(quietly: true)
            }
        }
        lookForMemory(reporting: true)
        lookForBridge()
    }

    /// Starts the bridge when the preview is on and Peel's own strut runs,
    /// and stops it when either is no longer so. Looked at when the agent
    /// opens and whenever strut starts or stops; a strut started again
    /// (a new key and port) gets a new bridge.
    func lookForBridge() {
        let bridge = agentBridge
        guard bridge.previewOn, let profile, let engine, agent != nil, brain == .thisMac,
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
        running.onChange = { [weak bridge, weak running] in
            // Runner stopped by itself: tried again only when strut starts again or the preview is turned on.
            guard let bridge, let running, running.server == nil, bridge.bridge === running,
                  bridge.status != .off else { return }
            bridge.strut = nil
            bridge.status = .failed("The agent's bridge stopped.")
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
        // Where the steps reach the bridge now.
        guard let reached = running.server else { throw PeelError("The agent's bridge stopped.") }
        try await client.useBridge(reached)
        try Task.checkCancellation()
        bridge.status = .running
    }
}
