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
    /// Each automation's runs, newest first, once looked at.
    var runs: [String: [AutomationRunRecord]] = [:]
    /// The automations (by id) with a send grant that strut did not list at the last read
    /// (`DeviceCards.revokeGrants`).
    var grantsMissed: Set<String> = []
    /// System workflows' descriptions, read once (`AutomationsClient.list`).
    var descriptions: [String: String] = [:]
    /// The system automations Peel has turned on once, by workflow, as
    /// last read or written (`Engine.systemAutomationsOn`).
    var turnedOn: Set<String>?

    /// The person's own: one-offs still to come, then everything
    /// recurring, then one-offs done.
    var yours: [Automation] { list.filter(\.isYours) }
    var upcoming: [Automation] { yours.filter { $0.isOnce && !$0.isDone } }
    var recurring: [Automation] { yours.filter { !$0.isOnce } }
    var done: [Automation] { yours.filter(\.isDone) }
    /// The ones strut ships (`docs/system-automations.md`).
    var system: [Automation] { list.filter(\.isSystem) }
    /// What the view shows: any other workflow's are strut's own business.
    var shown: [Automation] { list.filter { $0.isYours || $0.isSystem } }

    /// strut's clock is off when an enabled automation's time has passed unrun.
    func schedulerLooksOff(now: Date = .now) -> Bool { shown.contains { $0.isOverdue(now: now) } }

    /// Automations whose last run failed, the person's and the system's:
    /// the sidebar's badge.
    var failed: Int { shown.filter(\.lastRunFailed).count }
}

extension AppModel {
    // MARK: Automations (docs/phases/12-automations.md)

    /// The client for the memory's strut (`lookForMemory`); nil without one.
    var automationsClient: AutomationsClient? {
        memoryServer.map { AutomationsClient(server: $0) }
    }

    /// The same, only for Peel's own strut: the one place a home server is
    /// left out of what Peel hands strut (the connected model's key), which
    /// it keeps its own of.
    private var ownStrutClient: AutomationsClient? {
        automationsClient.flatMap { $0.server.isHomeServer ? nil : $0 }
    }

    /// The connected model, read from the Keychain; nil without one. Throws
    /// when it cannot be read or no account is open: not known to be gone.
    private func connectedCredential() throws -> AgentCredential? {
        guard let profile else { throw PeelError("Peel's account is not open.") }
        return try KeptCredential(item: profile.agentCredential).read()
    }

    /// strut started, or the connected model changed (connected, another
    /// model, removed): strut's secret store is given the model, for the
    /// agent and the system automations. One hand-over at a time; a change while one runs is handed over after it.
    func modelChanged() {
        modelHandingAgain = true
        guard modelHanding == nil else { return }
        modelHanding = Task {
            while modelHandingAgain {
                modelHandingAgain = false
                await handModelToStrut()
            }
            modelHanding = nil
        }
    }

    /// Gives strut the connected model, or takes it out with none; then,
    /// with one, reads the list, which turns the system automations on.
    /// Only Peel's own: a home server keeps its own model and key
    /// (`docs/peel-brain.md`, "Keys live on the brain"), which a disconnect
    /// here must not take out.
    private func handModelToStrut() async {
        guard let client = ownStrutClient else { return }
        let credential: AgentCredential?
        do {
            credential = try connectedCredential()
        } catch {
            // A Keychain that cannot be read is not a model removed: strut's store is left as it is.
            automations.problem = PeelError.problem(error, couldNot: "read the connected model's key")
            return
        }
        // This strut has it already (`connection` set again to the same).
        if let handed = strutModel, handed.server == client.server, handed.credential == credential { return }
        do {
            try await client.setModel(credential)
        } catch {
            strutModel = nil
            automations.problem = PeelError.problem(error, couldNot: "give strut the connected model")
            return
        }
        guard automationsClient?.server == client.server else { return }
        strutModel = (client.server, credential)
        if credential != nil { await refreshAutomations() }
    }

    // MARK: The view's actions

    /// Reads the list from strut; says why when it cannot.
    func refreshAutomations() async {
        guard let client = automationsClient else {
            automations = AutomationsState(loaded: true)
            return
        }
        let own = ownStrutClient != nil
        // Not handed to this strut yet, or it failed: tried again.
        if own, strutModel?.server != client.server { modelChanged() }
        do {
            var descriptions = automations.descriptions
            var list = try await client.list(descriptions: &descriptions)
            // The strut changed while it was read.
            guard automationsClient?.server == client.server else { return }
            automations.descriptions = descriptions
            if automations.problem != nil { automations.problem = nil }
            list = await turnOnSystemAutomations(in: list, with: client)
            // Peel's own strut is where the Mac's send grants point: those of automations it no longer has go.
            if own, let missed = try? macAgent.deviceCards.revokeGrants(
                missingFrom: Set(list.filter(\.isYours).map(\.id)), missedBefore: automations.grantsMissed) {
                automations.grantsMissed = missed
            }
            // Written only when changed: each write redraws what reads it.
            if automations.list != list { automations.list = list }
        } catch {
            automations.problem = PeelError.problem(error, couldNot: "read the automations")
        }
        if !automations.loaded { automations.loaded = true }
    }

    /// Once strut has a model (`handModelToStrut`), turns on each system
    /// automation Peel never turned on before, once per profile; `list` as
    /// it is then. Says why when what was turned on cannot be read or kept.
    private func turnOnSystemAutomations(in list: [Automation], with client: AutomationsClient) async -> [Automation] {
        guard let handed = strutModel, handed.server == client.server, handed.credential != nil,
              list.contains(where: \.isSystem) else { return list }
        do {
            let done = try await systemTurnedOn()
            guard list.contains(where: { $0.isSystem && !done.contains($0.workflow) }) else { return list }
            let (list, now) = await client.turnOnSystem(in: list, done: done)
            try await markTurnedOn(now)
            return list
        } catch {
            automations.problem = PeelError.problem(error, couldNot: "keep which system automations are turned on")
            return list
        }
    }

    /// The system automations Peel has turned on once, by workflow
    /// (`Engine.systemAutomationsOn`), read once per strut.
    private func systemTurnedOn() async throws -> Set<String> {
        if let done = automations.turnedOn { return done }
        guard let engine else { throw PeelError("Peel's account is not open.") }
        let done = try await engine.systemAutomationsOn()
        automations.turnedOn = done
        return done
    }

    /// Records `workflows` as turned on once: never turned on for the person again.
    private func markTurnedOn(_ workflows: Set<String>) async throws {
        let done = try await systemTurnedOn()
        guard !workflows.isSubset(of: done) else { return }
        guard let engine else { throw PeelError("Peel's account is not open.") }
        try await engine.setSystemAutomationsOn(done.union(workflows))
        automations.turnedOn = done.union(workflows)
    }

    func refreshRuns(of automation: Automation) async {
        guard let client = automationsClient else { return }
        if let runs = try? await client.runs(of: automation) { automations.runs[automation.id] = runs }
    }

    func setAutomation(_ automation: Automation, enabled: Bool) async {
        await changeAutomations("change \u{201C}\(automation.name)\u{201D}") {
            _ = try await $0.update(automation, enabled: enabled)
            // The person's own choice, once strut took it: never turned on for them after it.
            if automation.isSystem { try await markTurnedOn([automation.workflow]) }
        }
    }

    func runAutomationNow(_ automation: Automation) async {
        await changeAutomations("run \u{201C}\(automation.name)\u{201D}") { try await $0.runNow(automation) }
    }

    func deleteAutomation(_ automation: Automation) async {
        await changeAutomations("delete \u{201C}\(automation.name)\u{201D}") { client in
            try await client.delete(automation)
            try macAgent.deviceCards.revokeGrants(of: automation.id)
        }
    }

    func updateAutomationPrompt(_ automation: Automation, to prompt: String) async {
        await changeAutomations("change \u{201C}\(automation.name)\u{201D}") { _ = try await $0.update(automation, prompt: prompt) }
    }

    /// Moves the person's automations to `workflow` on `server`
    /// (`AutomationsClient.moveYours`), their run ends to `callback`, one move
    /// at a time (each bridge start moves them). Says which it could not move,
    /// or why none moved; then the list is read again.
    func moveAutomations(on server: MemoryServer, to workflow: String, callback: URL?) async {
        let client = AutomationsClient(server: server, yours: workflow, callback: callback)
        let bridge = agentBridge
        let before = bridge.moving
        let move = Task { () -> String? in
            _ = await before?.value
            do {
                // The ones there already first: those the move makes carry it.
                if let callback { try await client.pointRunEnds(at: callback) }
                let stuck = try await client.moveYours()
                guard !stuck.isEmpty else { return nil }
                let names = ListFormatter.localizedString(byJoining: stuck.map { "\u{201C}\($0)\u{201D}" })
                return "Couldn't move \(names) to \(workflow): it stays where it was until the next try."
            } catch {
                return PeelError.problem(error, couldNot: "move the automations to \(workflow)")
            }
        }
        bridge.moving = move
        let problem = await move.value
        guard automationsClient?.server == server else { return }
        await refreshAutomations()
        // After the read, which clears what it last said.
        if let problem { automations.problem = problem }
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
