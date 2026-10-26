import AgentKit
import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// The person's Hive workspaces as peers of Peel's strut
/// (docs/connectors-and-authoring.md, "Peers"): paired once by Hive's device
/// flow, the credential in the Keychain (`Profile.hive`), each org's record on
/// strut, renewed daily. Account › Connections shows it (`StadeumSection`);
/// the person knows it as Stadeum.
@MainActor @Observable
final class HiveState {
    enum Status: Equatable {
        case off
        /// A code waiting for the person's yes in Hive.
        case pairing(HiveClient.Pairing)
        case connected
        /// Hive no longer knows this Mac (revoked, or never collected): Pair again.
        case needsPairing
    }

    var status = Status.off
    /// What is kept: the orgs, and those Hive gave no record for.
    var link: HiveLink?
    /// The last thing that went wrong, in words; nil once something works.
    var problem: String?
    /// The actor of a pairing undone while the bridge was not running: its
    /// org tokens are cleared from runner once it runs.
    var unpaired: String?
    /// Hive answered 401: the orgs are taken off strut and runner (their
    /// tokens may still work for days) and stay listed until paired again.
    var revoked = false
    /// The person's own apps and those the workspaces pinned as tabs, A–Z
    /// (`refreshApps`): the sidebar's Apps.
    var apps: [WorkspaceApp] = []
    /// The read of `apps` under way; a newer one replaces it.
    @ObservationIgnored var appsReading: Task<Void, Never>?

    /// The orgs strut and runner may use: none once revoked.
    var live: [HivePeer] { revoked ? [] : link?.peers ?? [] }
    @ObservationIgnored var pairing: Task<Void, Never>?
    @ObservationIgnored var renewing: Task<Void, Never>?

    /// Back to how it stands without a pairing under way: off, or kept but
    /// needing Hive again.
    func settle() {
        pairing = nil
        status = link == nil ? .off : .needsPairing
    }

    func reset() {
        pairing?.cancel()
        renewing?.cancel()
        pairing = nil
        renewing = nil
        status = .off
        link = nil
        problem = nil
        unpaired = nil
        revoked = false
        appsReading?.cancel()
        appsReading = nil
        // The workspaces' go with them; the person's own are not Stadeum's.
        apps.removeAll { $0.peer != nil }
    }
}

extension AppModel {
    var hive: HiveState { macAgent.hive }

    /// The Hive a development profile pairs with: `-hiveURL` (a local or
    /// staging Hive, or a test's stand-in); the app account's is Hive itself.
    var hiveClient: HiveClient {
        if profile?.kind == .development, let given = UserDefaults.standard.string(forKey: "hiveURL"),
           let url = URL(string: given), Web.isStrut(url) {
            return HiveClient(hive: url)
        }
        return HiveClient()
    }

    /// Reads what this account kept of Hive when its agent opens, tells
    /// Peel's strut whose orgs they are before it starts, and keeps it renewed.
    func openHive(_ profile: Profile) {
        hive.reset()
        do {
            hive.link = try HiveLink.read(from: profile.hive)
        } catch {
            hive.problem = PeelError.noted(error, couldNot: "read your Stadeum connection")
        }
        guard let link = hive.link else { return }
        hive.status = .connected
        strut?.person = link.actor
        keepHiveRenewed(now: true)
    }

    func closeHive() {
        hive.reset()
    }

    /// Connect Hive: a code to approve in Hive, polled until the person
    /// answers there or it runs out.
    func connectHive() {
        hive.pairing?.cancel()
        hive.problem = nil
        guard let account = profile?.directory else { return }
        let client = hiveClient
        let name = Host.current().localizedName ?? "Mac"
        hive.pairing = Task {
            do {
                let pairing = try await client.start(name: name)
                // Cancelled while Hive answered: its code is never shown.
                try Task.checkCancellation()
                hive.status = .pairing(pairing)
                switch try await client.answer(to: pairing, name: name) {
                case .pending:
                    return
                case .denied:
                    settle("It was turned down in Stadeum.")
                case .expired:
                    settle("The code ran out before it was approved. Try again.")
                case .paired(let link):
                    // Cancelled, or the account changed, while Hive answered: nothing kept.
                    guard !Task.isCancelled, profile?.directory == account else { return }
                    try keepHive(link)
                    hive.status = .connected
                    keepHiveRenewed(now: false)
                }
            } catch is CancellationError {
            } catch {
                settle(PeelError.noted(error, couldNot: "connect Stadeum"))
            }
        }
        /// Ends this pairing with `problem`, unless it was cancelled: a newer one may be under way.
        func settle(_ problem: String) {
            guard !Task.isCancelled else { return }
            hive.settle()
            hive.problem = problem
        }
    }

    func cancelHivePairing() {
        hive.pairing?.cancel()
        hive.settle()
    }

    /// Disconnect: the orgs off strut, the credential gone. Hive keeps the
    /// device until it is revoked there, and its tokens age out in a week.
    func disconnectHive() {
        guard let profile else { return }
        let actor = hive.link?.actor
        hive.reset()
        // Runner forgets the orgs' tokens, now or once it runs again.
        hive.unpaired = actor
        do {
            try profile.hive.delete()
            // Its "Always allow" rules go too: a slug Hive gives later may be another org's.
            try revokeWorkspaceRules { _ in true }
        } catch {
            hive.problem = PeelError.noted(error, couldNot: "forget the Stadeum connection")
        }
        Task {
            // Runner lets go of the orgs' rooms and tokens before strut (and it) start again,
            // and the bridge, started again, takes the orgs off strut.
            await handHiveToBridge()
            strut?.person = nil
            restartOwnStrut()
        }
    }

    /// Renews whenever due, looking every hour while the account is open, and
    /// `now` too (as the account opens, so a Mac revoked in Hive says so).
    private func keepHiveRenewed(now: Bool) {
        hive.renewing?.cancel()
        hive.renewing = Task {
            var first = now
            while !Task.isCancelled {
                if let link = hive.link, first || link.due() { await renewHive(link) }
                first = false
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func renewHive(_ link: HiveLink) async {
        do {
            let renewed = try await HiveClient(hive: link.hive).renew(link)
            // Disconnected or closed meanwhile: nothing of it is kept or said.
            guard !Task.isCancelled, hive.link?.credential == link.credential else { return }
            guard let renewed else {
                // Revoked in Hive: its tokens may still work until they expire, so they stop being used now.
                hive.status = .needsPairing
                hive.revoked = true
                if let server = memoryServer, brain == .thisMac { await syncHive(on: server) }
                await handHiveToBridge()
                return
            }
            try keepHive(renewed)
        } catch is CancellationError {
        } catch {
            // Tried again within the hour; the tokens last a week.
            hive.problem = PeelError.noted(error, couldNot: "renew your Stadeum workspaces")
        }
    }

    /// Keeps `link` (the Keychain first) and puts its orgs on strut and
    /// runner when they changed. Speaking for another person, strut starts
    /// again (the bridge follows it, and syncs the peers); a conversation
    /// keeps its first turn's prompt, so the DM knows the orgs after `/new`.
    private func keepHive(_ link: HiveLink) throws {
        guard let profile else { return }
        // An Always for a workspace holds only while it is the same account's same org:
        // another account, or a slug no longer among the orgs (later maybe another org's), asks again.
        let kept = hive.link
        try revokeWorkspaceRules { peer in
            kept?.actor != link.actor || kept?.hive != link.hive || !link.peers.contains { $0.id == peer }
        }
        try link.write(to: profile.hive)
        let changed = hive.revoked || kept?.peers != link.peers
        hive.link = link
        hive.revoked = false
        hive.problem = nil
        if strut?.person != link.actor {
            strut?.person = link.actor
            restartOwnStrut()
        } else if changed, let server = memoryServer, brain == .thisMac {
            Task {
                await syncHive(on: server)
                await handHiveToBridge()
            }
        }
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
        guard let link = hive.link else {
            if let actor = hive.unpaired, (try? await bridge.usePeers(actor: actor, tokens: [:])) != nil { hive.unpaired = nil }
            return
        }
        do {
            try await bridge.usePeers(actor: link.actor, tokens: Dictionary(hive.live.map { ($0.id, $0.token) }) { _, last in last })
        } catch {
            hive.problem = PeelError.noted(error, couldNot: "give the agent's bridge your Stadeum workspaces")
        }
    }

    /// Strut's peers made Hive's: the kept orgs put on, any other taken
    /// off (Peel puts no peers of its own). Called as the bridge starts; a
    /// failure is said in Account › Connections, not the agent chat.
    func syncHive(on server: MemoryServer) async {
        do {
            try await AutomationsClient(server: server).syncPeers(hive.live)
        } catch {
            hive.problem = PeelError.noted(error, couldNot: "give the agent your Stadeum workspaces")
        }
        // Not waited for: a slow workspace never holds up the bridge.
        refreshApps()
    }

    /// Reads the apps through Peel's own strut: the person's own on it
    /// (`AutomationsClient.ownApps`) and those each workspace pinned as a
    /// tab (`pinnedApps`), all at once; a newer read replaces one under
    /// way. None with the memory on a home server, which holds none of this
    /// Mac's. While Peel's strut is away (starting again, a memory move) the
    /// list stays as it was, and a list that cannot be read keeps what it
    /// last listed. Without `workspaces`, only the person's own are read
    /// (Apps opening: one just built shows), the workspaces' kept as they are.
    func refreshApps(workspaces: Bool = true) {
        // A read under way reads the person's own too: not cut short for less.
        guard workspaces || hive.appsReading == nil else { return }
        let peers = hive.live.map(\.id)
        // Strut away (starting again, a memory move): what is read stays as it is.
        guard let server = memoryServer else { return }
        hive.appsReading?.cancel()
        hive.appsReading = nil
        guard !server.isHomeServer else {
            if !hive.apps.isEmpty { hive.apps = [] }
            return
        }
        let client = AutomationsClient(server: server)
        let reading = workspaces ? peers : []
        hive.appsReading = Task {
            // Done, unless a newer read took its place.
            defer { if !Task.isCancelled { hive.appsReading = nil } }
            // By peer, the person's own under nil.
            let read = await withTaskGroup(of: (String?, [WorkspaceApp]?).self) { group in
                group.addTask { (nil, try? await client.ownApps()) }
                for peer in reading {
                    group.addTask { (peer, try? await client.pinnedApps(of: peer)) }
                }
                var read: [String?: [WorkspaceApp]] = [:]
                for await (peer, apps) in group {
                    if let apps { read[peer] = apps }
                }
                return read
            }
            // A newer read, or strut or the workspaces changed meanwhile: theirs, not this.
            guard !Task.isCancelled, memoryServer == server, hive.live.map(\.id) == peers else { return }
            let sources: [String?] = [nil] + peers
            let listed = WorkspaceApp.byTitle(sources.flatMap { peer in read[peer] ?? hive.apps.filter { $0.peer == peer } })
            if hive.apps != listed { hive.apps = listed }
        }
    }

    /// The listed app a destination opens.
    func app(peer: String?, name: String) -> WorkspaceApp? {
        hive.apps.first { $0.peer == peer && $0.name == name }
    }

    /// Where the listed apps come from, as the person reads them: Yours
    /// first, then the workspaces A–Z (`WorkspaceApp.source`).
    var appSources: [String] {
        let peers = Set(hive.apps.compactMap(\.peer)).sorted().map { "@\($0)" }
        return (hive.apps.contains { $0.peer == nil } ? [WorkspaceApp.yours] : []) + peers
    }

    /// Whether an app's source shows (its sidebar row, card and header):
    /// only when the apps come from several (Tom, 2026-10-26).
    var showsAppSources: Bool {
        Set(hive.apps.map(\.peer)).count > 1
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
