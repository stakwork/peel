import AgentKit
import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// The Mac's side of Stadeum (PeelUI's `Stadeum`, `AppModel.stadeum`):
/// the workspaces put on Peel's strut as peers
/// (docs/connectors-and-authoring.md, "Peers"), their tokens handed to the
/// bridge for its rooms, the "Always allow" rules per workspace, and the
/// apps read through Peel's strut. Account › Connections shows it
/// (`StadeumSection`); the person knows it as Stadeum.
@MainActor
final class MacStadeumHost: StadeumHost {
    weak var model: AppModel?
    /// The actor of a pairing undone while the bridge was not running: its
    /// org tokens are cleared from runner once it runs.
    var unpaired: String?

    func stadeum(willKeep link: HiveLink, replacing kept: HiveLink?) throws {
        // An Always for a workspace holds only while it is the same account's same org:
        // another account, or a slug no longer among the orgs (later maybe another org's), asks again.
        try model?.revokeWorkspaceRules { peer in
            kept?.actor != link.actor || kept?.hive != link.hive || !link.peers.contains { $0.id == peer }
        }
    }

    /// Speaking for another person, strut starts again (the bridge follows
    /// it, and syncs the peers); a conversation keeps its first turn's
    /// prompt, so the DM knows the orgs after `/new`. Otherwise the orgs,
    /// when they changed, go on strut and runner.
    func stadeum(kept link: HiveLink, changed: Bool) {
        guard let model else { return }
        if model.strut?.person != link.actor {
            model.strut?.person = link.actor
            model.restartOwnStrut()
        } else if changed, let server = model.memoryServer {
            Task {
                await model.syncHive(on: server)
                await model.handHiveToBridge()
            }
        }
    }

    /// Revoked in Stadeum: the orgs come off strut and runner (their tokens
    /// may still work for days) and stay listed until paired again.
    func stadeumRevoked() {
        guard let model else { return }
        Task {
            if let server = model.memoryServer { await model.syncHive(on: server) }
            await model.handHiveToBridge()
        }
    }

    func stadeumDisconnected(actor: String?) throws {
        guard let model else { return }
        // Runner forgets the orgs' tokens, now or once it runs again.
        unpaired = actor
        Task {
            // Runner lets go of the orgs' rooms and tokens before strut (and it) start again,
            // and the bridge, started again, takes the orgs off strut.
            await model.handHiveToBridge()
            model.strut?.person = nil
            model.restartOwnStrut()
        }
        // Its "Always allow" rules go too: a slug Hive gives later may be another org's.
        try model.revokeWorkspaceRules { _ in true }
    }
}

extension AppModel {
    /// Reads what this account kept of Stadeum when its agent opens, tells
    /// Peel's strut whose orgs they are before it starts, and keeps it renewed.
    func openHive(_ profile: Profile) {
        let host = macAgent.stadeumHost
        host.model = self
        host.unpaired = nil
        stadeum.host = host
        stadeum.open(profile)
        if let actor = stadeum.link?.actor { strut?.person = actor }
    }

    func closeHive() {
        stadeum.close()
        macAgent.stadeumHost.unpaired = nil
    }

    /// Connect Stadeum: a code to approve there, naming this Mac. The
    /// account's Stadeum is opened first if its agent did not open it.
    func connectHive() {
        if !stadeum.isOpen, let profile { openHive(profile) }
        stadeum.connect(as: Host.current().localizedName ?? "Mac")
    }

    func cancelHivePairing() {
        stadeum.cancelPairing()
    }

    /// Disconnect: the orgs off strut, the credential gone
    /// (`MacStadeumHost.stadeumDisconnected`).
    func disconnectHive() {
        if !stadeum.isOpen, let profile { openHive(profile) }
        stadeum.disconnect()
    }

    /// The workspaces' "Always allow" rules for which `dropping` (given the
    /// peer id) is true, revoked.
    func revokeWorkspaceRules(_ dropping: (String) -> Bool) throws {
        for rule in agent?.approvalRules ?? [] where rule.tool == DeviceActions.peerTool {
            if dropping(rule.target.flatMap(DeviceActions.peer(ofRule:)) ?? "") { try agent?.revoke(rule) }
        }
    }

    /// Hands the running bridge the orgs' person tokens (strut never
    /// returns one), for its rooms on their struts; said in Account if it fails.
    /// Unpaired while it was not running: runner forgets the tokens instead.
    func handHiveToBridge() async {
        guard let bridge = agentBridge.bridge, bridge.server != nil else { return }
        let host = macAgent.stadeumHost
        guard let link = stadeum.link else {
            if let actor = host.unpaired, (try? await bridge.usePeers(actor: actor, tokens: [:])) != nil { host.unpaired = nil }
            return
        }
        do {
            try await bridge.usePeers(actor: link.actor, tokens: Dictionary(stadeum.live.map { ($0.id, $0.token) }) { _, last in last })
        } catch {
            stadeum.problem = PeelError.noted(error, couldNot: "give the agent's bridge your Stadeum workspaces")
        }
    }

    /// Strut's peers made Hive's: the kept orgs put on, any other taken
    /// off (Peel puts no peers of its own). Called as the bridge starts; a
    /// failure is said in Account › Connections, not the agent chat.
    func syncHive(on server: MemoryServer) async {
        do {
            try await AutomationsClient(server: server).syncPeers(stadeum.live)
        } catch {
            stadeum.problem = PeelError.noted(error, couldNot: "give the agent your Stadeum workspaces")
        }
        // Not waited for: a slow workspace never holds up the bridge.
        refreshApps()
    }

    /// Reads the apps through Peel's own strut: the person's own on it
    /// (`AutomationsClient.ownApps`) and those each workspace pinned as a
    /// tab (`pinnedApps`), all at once; a newer read replaces one under
    /// way. None with Peel Home moved, whose strut this Mac doesn't reach.
    /// While Peel's strut is away (starting again) the list stays as it was,
    /// and a list that cannot be read keeps what it last listed. Without `workspaces`, only the person's own are read
    /// (Apps opening: one just built shows), the workspaces' kept as they are.
    func refreshApps(workspaces: Bool = true) {
        // A read under way reads the person's own too: not cut short for less.
        guard workspaces || !stadeum.readingApps else { return }
        // Peel Home moved: its strut is not this Mac's to read.
        guard brain?.moved == nil else {
            stadeum.stopReadingApps()
            if !stadeum.apps.isEmpty { stadeum.apps = [] }
            return
        }
        // Strut away (starting again): what is read stays as it is.
        guard let server = memoryServer else { return }
        let client = AutomationsClient(server: server)
        stadeum.readApps(own: { try await client.ownApps() }, workspaces: workspaces,
                         pinned: { try await client.pinnedApps(of: $0.id) },
                         still: { [weak self] in self?.memoryServer == server })
    }

    /// The listed app a destination opens.
    func app(peer: String?, name: String) -> WorkspaceApp? {
        stadeum.apps.first { $0.peer == peer && $0.name == name }
    }

    /// Where the listed apps come from, as the person reads them: Yours
    /// first, then the workspaces A–Z (`WorkspaceApp.source`).
    var appSources: [String] {
        let peers = Set(stadeum.apps.compactMap(\.peer)).sorted().map { "@\($0)" }
        return (stadeum.apps.contains { $0.peer == nil } ? [WorkspaceApp.yours] : []) + peers
    }

    /// Whether an app's source shows (its sidebar row, card and header):
    /// only when the apps come from several (Tom, 2026-10-26).
    var showsAppSources: Bool {
        Set(stadeum.apps.map(\.peer)).count > 1
    }

    /// Whether the person pinned `app` under the sidebar's Apps row
    /// (`ChatSections.Layout.pinnedApps`); none are until they do.
    func isPinned(_ app: WorkspaceApp) -> Bool {
        sidebarLayout.pinnedApps.contains(app.id)
    }

    /// Puts `app` under the sidebar's Apps row, or takes it off, kept with
    /// the account's sidebar layout.
    func setPinned(_ app: WorkspaceApp, _ pinned: Bool) {
        var pins = sidebarLayout.pinnedApps.filter { $0 != app.id }
        if pinned { pins.append(app.id) }
        if pins != sidebarLayout.pinnedApps { sidebarLayout.pinnedApps = pins }
    }
}
