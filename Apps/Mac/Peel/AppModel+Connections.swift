import AgentKit
import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// Account › Connections: the services the agent uses with the person's
/// own credentials, kept in their strut (docs/connectors-and-authoring.md,
/// section 2). MCP servers first; Gmail and this Mac's own come later.
@MainActor @Observable
final class ConnectionsState {
    var servers: [MCPServer] = []
    /// What each server answered when last tested, by name.
    var probes: [String: MCPProbe] = [:]
    /// The servers being tested now.
    var testing: Set<String> = []
    /// Which agents reach each server (Peel's own strut only).
    var grants = MCPGrants()
    /// The last thing that went wrong, in words.
    var problem: String?
    /// Read from strut at least once since it started.
    var loaded = false
    /// Asked to be shown: Account scrolls to it each time this moves.
    var opened = 0

    func reset() {
        servers = []
        probes = [:]
        testing = []
        grants = MCPGrants()
        problem = nil
        loaded = false
    }
}

extension AppModel {
    var connections: ConnectionsState { macAgent.connections }

    /// Whether the toggles apply: Peel's own strut, whose host delta Peel
    /// writes. A home server's own settings decide for it.
    var grantsConnections: Bool { brain == .thisMac && strut != nil }

    /// The servers strut has, read when the screen opens and after each change.
    func loadConnections() async {
        guard let server = memoryServer else {
            connections.reset()
            return
        }
        do {
            let servers = try await AutomationsClient(server: server).mcpServers()
            connections.servers = servers
            // What was tested before is not taken for now; a server gone takes its grants with it.
            connections.probes = connections.probes.filter { name, _ in servers.contains { $0.name == name } }
            var grants = strut?.grants ?? MCPGrants()
            for name in grants.assistant.union(grants.jobs) where !servers.contains(where: { $0.name == name }) {
                grants = grants.dropping(name)
            }
            if let strut, grants != strut.grants { try? strut.keep(grants) }
            connections.grants = grants
            connections.loaded = true
            connections.problem = nil
        } catch {
            connections.problem = PeelError.problem(error, couldNot: "read the connected services")
        }
    }

    /// Registers a server (its key kept in strut, never here), tests it,
    /// and gives it to the assistant and its jobs. Nil when done; else why not.
    func addMCPServer(name: String, url: URL, key: String) async -> String? {
        guard let server = memoryServer else { return "Peel's memory is not running." }
        // The key goes with every call: never in the clear, but to a test server on this Mac.
        let local = url.scheme == "http" && url.host.map(ServerAddress.isLoopback) == true && strut?.allowsLocalMCP == true
        guard url.scheme == "https" || local else { return "Use an https address: your key goes with every call." }
        do {
            try await AutomationsClient(server: server).addMCPServer(name: name, url: url, key: key)
        } catch {
            return PeelError.problem(error, couldNot: "add \(name)")
        }
        await loadConnections()
        await testMCPServer(name)
        if grantsConnections, let strut {
            var grants = strut.grants
            grants.assistant.insert(name)
            grants.jobs.insert(name)
            keepGrants(grants)
        }
        return nil
    }

    func testMCPServer(_ name: String) async {
        guard let server = memoryServer else { return }
        connections.testing.insert(name)
        defer { connections.testing.remove(name) }
        do {
            connections.probes[name] = try await AutomationsClient(server: server).testMCPServer(name)
        } catch {
            connections.probes[name] = MCPProbe(tools: [], error: PeelError.problem(error, couldNot: "reach \(name)"))
        }
    }

    func removeMCPServer(_ name: String) async {
        guard let server = memoryServer else { return }
        do {
            try await AutomationsClient(server: server).removeMCPServer(name)
            connections.probes[name] = nil
            if let grants = strut?.grants, grants.assistant.contains(name) || grants.jobs.contains(name) {
                keepGrants(grants.dropping(name))
            }
            await loadConnections()
        } catch {
            connections.problem = PeelError.problem(error, couldNot: "remove \(name)")
        }
    }

    /// One agent's switch for one server: kept, then strut started again,
    /// whose next turns have the tools (or lose them).
    func setGrant(_ name: String, assistant: Bool? = nil, jobs: Bool? = nil) {
        guard var grants = strut?.grants else { return }
        if let assistant { if assistant { grants.assistant.insert(name) } else { grants.assistant.remove(name) } }
        if let jobs { if jobs { grants.jobs.insert(name) } else { grants.jobs.remove(name) } }
        keepGrants(grants)
    }

    private func keepGrants(_ grants: MCPGrants) {
        guard let strut, grants != strut.grants else { return }
        do {
            try strut.keep(grants)
            connections.grants = grants
            restartOwnStrut()
        } catch {
            connections.problem = PeelError.problem(error, couldNot: "change which agents use it")
        }
    }

    /// Peel's own strut stopped and started again, so it reads its host
    /// delta afresh; the bridge follows it. A turn under way is cut short
    /// and said so in the DM. While it is still starting, nothing: once up,
    /// `restartIfGrantsChanged` starts it once more if they (or the person
    /// it speaks for) moved meanwhile.
    func restartOwnStrut() {
        guard let strut, strut.server != nil, brain == .thisMac else { return }
        strut.stop()
        lookForMemory(reporting: true)
    }

    /// Called as Peel's strut comes up: started with grants that have
    /// changed since (a switch while it was starting), or for another
    /// person (a Stadeum pairing), it starts once more.
    func restartIfGrantsChanged() {
        guard let strut, strut.server != nil, strut.launchedStale else { return }
        restartOwnStrut()
    }
}
