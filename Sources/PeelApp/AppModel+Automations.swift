import AgentKit
import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// What the Automations view shows (`docs/phases/12-automations.md`): the
/// list strut keeps, and why it could not be read, if it could not.
struct AutomationsState: Equatable {
    var list: [Automation] = []
    var loaded = false
    var problem: String?
    /// strut's `peel-automation` workflow points here; tried again on each
    /// refresh until it does (strut may start after Peel).
    var installed = false
    /// Each automation's runs, newest first, once looked at.
    var runs: [String: [AutomationRunRecord]] = [:]

    /// One-offs still to come, then everything recurring, then one-offs done.
    var upcoming: [Automation] { list.filter { $0.isOnce && !$0.isDone } }
    var recurring: [Automation] { list.filter { !$0.isOnce } }
    var done: [Automation] { list.filter(\.isDone) }

    /// strut's clock is off when an enabled automation's time has passed unrun.
    func schedulerLooksOff(now: Date = .now) -> Bool { list.contains { $0.isOverdue(now: now) } }

    /// Automations whose last run failed: the sidebar's badge.
    var failed: Int { list.filter(\.lastRunFailed).count }
}

extension AppModel {
    // MARK: Automations (docs/phases/12-automations.md)

    /// Where strut reaches this Mac's agent: 4778 unless
    /// `defaults write dev.peel.mac automationPort <port>` says otherwise.
    static var automationPort: Int {
        let port = UserDefaults.standard.integer(forKey: "automationPort")
        return (1...65535).contains(port) ? port : 4778
    }

    /// The client for the memory's strut (`lookForMemory`); nil without one.
    var automationsClient: AutomationsClient? {
        memoryServer.map(AutomationsClient.init(server:))
    }

    /// While the agent chat is open with a strut found: listens for strut
    /// with the token made when the agent opened, hands it to strut's secret store
    /// and points strut's `peel-automation` workflow here. A development profile listens only
    /// with an `automationPort` of its own, never on the app's.
    func startAutomations(_ profile: Profile, engine: Engine) {
        guard let memory = memoryServer, let token = automationToken,
              profile.kind == .app || UserDefaults.standard.object(forKey: "automationPort") != nil else { return }
        let port = Self.automationPort
        let stopping = automationStopping
        Task {
            do {
                // The last server lets go of the port first (an account switched).
                await stopping?.value
                // Stopped with the agent chat (`closeAgent`), so holding the model is bounded.
                let server = try await AutomationServer.start(port: port, token: token) { request in
                    await self.runAutomation(request)
                }
                // Closed, another account opened, or the strut changed or stopped while it started.
                guard self.engine === engine, memoryServer == memory, automationServer == nil else {
                    return await server.stop()
                }
                automationServer = server
                await installAutomations()
            } catch {
                automations.problem = PeelError.problem(error, couldNot: "listen for automations on port \(port)")
            }
        }
    }

    func stopAutomations() {
        automations = AutomationsState()
        guard let server = automationServer else { return }
        automationServer = nil
        automationStopping = Task { await server.stop() }
    }

    /// Points strut's workflow at the listening server; says why when it
    /// cannot, and then nothing fires (no token but strut's store's).
    private func installAutomations() async {
        guard let client = automationsClient, let server = automationServer else { return }
        do {
            try await client.install(port: server.port, token: server.token)
            guard automationServer === server else { return }
            automations.installed = true
        } catch {
            automations.problem = PeelError.problem(error, couldNot: "set up automations on strut")
        }
    }

    /// One run: the agent with the read and memory tools and no send, its
    /// result delivered to the agent chat with a notification.
    func runAutomation(_ request: AutomationRequest) async -> AutomationReply {
        guard let profile, let engine, let agent else { return .failed("Peel's account is not open.") }
        let credential: AgentCredential
        do {
            guard let kept = try KeptCredential(item: profile.agentCredential).read() else {
                return .failed("No model is connected to Peel's agent.")
            }
            credential = kept
        } catch {
            return .failed("Could not read the connected model's key.")
        }
        let setup = Self.agentSetup(engine, memory: memoryServer)
        let loop = AgentLoop(
            provider: Self.agentClient(credential, profile: profile),
            tools: setup.tools, model: credential.model, systemPrompt: setup.systemPrompt(unattended: true))
        let reply = await AutomationRun.run(request, with: loop)
        // The account may have closed while it ran: nothing is kept for it.
        guard self.agent === agent else { return .failed("Peel's account closed during the run.") }
        if reply.status == .delivered, let text = reply.text {
            agent.deliver(text, from: request.name)
            notifier.automationDelivered(name: request.name, text: text, chatShown: agent.isShown && isFrontmost)
        }
        return reply
    }

    // MARK: The view's actions

    /// Reads the list from strut; says why when it cannot.
    func refreshAutomations() async {
        guard let client = automationsClient else {
            automations = AutomationsState(loaded: true)
            return
        }
        if !automations.installed { await installAutomations() }
        do {
            let list = try await client.list()
            // The strut changed while it was read.
            guard automationsClient?.server == client.server else { return }
            // Written only when changed: each write redraws what reads it.
            if automations.list != list { automations.list = list }
            // A failed install stays said until one succeeds.
            if automations.installed, automations.problem != nil { automations.problem = nil }
        } catch {
            automations.problem = PeelError.problem(error, couldNot: "read the automations")
        }
        if !automations.loaded { automations.loaded = true }
    }

    func refreshRuns(of id: String) async {
        guard let client = automationsClient else { return }
        if let runs = try? await client.runs(of: id) { automations.runs[id] = runs }
    }

    func setAutomation(_ automation: Automation, enabled: Bool) async {
        await changeAutomations("change \u{201C}\(automation.name)\u{201D}") { _ = try await $0.update(automation, enabled: enabled) }
    }

    func runAutomationNow(_ automation: Automation) async {
        await changeAutomations("run \u{201C}\(automation.name)\u{201D}") { try await $0.runNow(automation.id) }
    }

    func deleteAutomation(_ automation: Automation) async {
        await changeAutomations("delete \u{201C}\(automation.name)\u{201D}") { try await $0.delete(automation.id) }
    }

    func updateAutomationPrompt(_ automation: Automation, to prompt: String) async {
        await changeAutomations("change \u{201C}\(automation.name)\u{201D}") { _ = try await $0.update(automation, prompt: prompt) }
    }

    private func changeAutomations(_ what: String, _ change: (AutomationsClient) async throws -> Void) async {
        guard let client = automationsClient else { return }
        do {
            try await change(client)
        } catch {
            automations.problem = PeelError.problem(error, couldNot: what)
        }
        await refreshAutomations()
    }
}
