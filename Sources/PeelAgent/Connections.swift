import AgentKit
import Foundation
import PeelCore

// Connections (docs/connectors-and-authoring.md, sections 1 and 2): the
// services the agent uses with the person's own credentials, kept in their
// strut. An MCP server is registered with strut once (`/mcp-servers`, strut
// #286), its key a named secret in strut's encrypted store, never in Peel;
// which agents get its tools is Peel's host delta (`MCPGrants`). A tool that
// is not read-only asks first, through strut's proposals and the card.

/// One MCP server registered with strut.
public struct MCPServer: Sendable, Equatable, Identifiable {
    /// Its name, which prefixes its tools (`mcp/<name>/*`).
    public let name: String
    public let url: URL
    public var id: String { name }

    /// "mcp.linear.app": where it is, as a row says it.
    public var place: String { url.host ?? url.absoluteString }
}

/// What a server answered when strut connected to it (`POST …/test`).
public struct MCPProbe: Sendable, Equatable {
    public struct Tool: Sendable, Equatable {
        public let name: String
        /// Asks the person first: anything the server does not mark read-only.
        public let gated: Bool
    }

    public let tools: [Tool]
    /// Why it could not connect, in strut's words; nil when it did.
    public let error: String?

    public init(tools: [Tool], error: String?) {
        self.tools = tools
        self.error = error
    }
}

/// Which agents get each server's tools: the person's toggles, kept beside
/// strut's data (`BundledStrut.grants`), and read into the host delta at
/// each start. A server not named here reaches no agent.
public struct MCPGrants: Codable, Sendable, Equatable {
    /// The assistant in the DM (`orchestrator`).
    public var assistant: Set<String> = []
    /// The jobs it starts (`job`).
    public var jobs: Set<String> = []

    public init(assistant: Set<String> = [], jobs: Set<String> = []) {
        self.assistant = assistant
        self.jobs = jobs
    }

    /// The `agentTools` grant for each server: all of its tools.
    static func tools(_ servers: Set<String>) -> [String] {
        servers.sorted().map { "mcp/\($0)/*" }
    }

    /// Without `name`, on any agent: it was removed.
    public func dropping(_ name: String) -> MCPGrants {
        MCPGrants(assistant: assistant.subtracting([name]), jobs: jobs.subtracting([name]))
    }

    static func read(in folder: URL) -> MCPGrants {
        (try? Data(contentsOf: folder.appending(path: file))).flatMap { try? JSONDecoder().decode(MCPGrants.self, from: $0) } ?? MCPGrants()
    }

    func write(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: folder.appending(path: Self.file), options: .atomic)
    }

    static let file = "connections.json"
}

extension AutomationsClient {
    /// The servers strut has registered.
    public func mcpServers() async throws -> [MCPServer] {
        try await call("GET", "mcp-servers", what: "the connected services")["servers"]?.array?.compactMap { server in
            guard let name = server["name"]?.string, let url = server["url"]?.string.flatMap(URL.init(string:)) else { return nil }
            return MCPServer(name: name, url: url)
        } ?? []
    }

    /// Registers `url` as `name` and then puts its key (if any) in strut's
    /// secret store under a name only this server's can be, so the
    /// registration holds that name and never the key. A name already
    /// connected is refused: Remove it first. strut checks the rest (an
    /// https or allowed local address, no credentials or query in it); one
    /// it refuses leaves nothing behind.
    public func addMCPServer(name: String, url: URL, key: String?) async throws {
        try Self.mcpName(name)
        guard try await !mcpServers().contains(where: { $0.name == name }) else {
            throw PeelError("\u{201C}\(name)\u{201D} is already connected. Remove it first to change it.")
        }
        let keyed = key.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        var body: [String: AgentKit.JSONValue] = ["url": .string(url.absoluteString)]
        if keyed != nil { body["tokenSecret"] = .string(Self.mcpSecret(name)) }
        _ = try await call("PUT", "mcp-servers/\(name)", .object(body), what: name)
        guard let keyed else { return }
        do {
            _ = try await call("PUT", "secrets/\(Self.mcpSecret(name))", ["value": .string(keyed)], what: "the key for \(name)")
        } catch {
            _ = try? await request("DELETE", "mcp-servers/\(name)", nil, what: name)
            throw error
        }
    }

    /// Unregisters `name` and takes its key out of strut's secret store.
    public func removeMCPServer(_ name: String) async throws {
        try Self.mcpName(name)
        let (status, data) = try await request("DELETE", "mcp-servers/\(name)", nil, what: name)
        if status != 404 { _ = try Self.read(status, data) }
        try await deleteSecrets([Self.mcpSecret(name)], what: "the key for \(name)")
    }

    /// Connects to `name` as strut would for a turn and lists its tools.
    public func testMCPServer(_ name: String) async throws -> MCPProbe {
        try Self.mcpName(name)
        let probe = try await call("POST", "mcp-servers/\(name)/test", what: name)
        guard probe["ok"] == .bool(true) else {
            return MCPProbe(tools: [], error: Self.masked(ChatData.clean(probe["error"]?.string ?? "It did not answer.", max: 300)))
        }
        let tools = probe["tools"]?.array?.compactMap { tool -> MCPProbe.Tool? in
            tool["name"]?.string.map { MCPProbe.Tool(name: ChatData.clean($0, max: 80), gated: tool["gated"] != .bool(false)) }
        } ?? []
        return MCPProbe(tools: tools, error: nil)
    }

    /// strut's rule for a server's name, checked before it goes in a path.
    @discardableResult
    static func mcpName(_ name: String) throws -> String {
        guard name.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil else {
            throw PeelError("A name is 1 to 32 letters, digits, \u{201C}-\u{201D} or \u{201C}_\u{201D}.")
        }
        return name
    }

    /// The secret a server's key is kept under: its name in hex
    /// (`MCP_6C696E656172_KEY` for `linear`), so no two names (`linear`,
    /// `Linear`, `lin-ear`, `lin_ear`) ever share one.
    static func mcpSecret(_ name: String) -> String {
        "MCP_" + Data(name.utf8).map { String(format: "%02X", $0) }.joined() + "_KEY"
    }

    /// A server's error as shown: a bearer it echoed, or anything shaped
    /// like a key, hidden.
    static func masked(_ text: String) -> String {
        text.replacing(/(?i)bearer\s+[^\s:,"']+/, with: "Bearer •••").replacing(/[A-Za-z0-9_\-\.]{24,}/, with: "•••")
    }
}
