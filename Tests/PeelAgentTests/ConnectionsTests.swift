import AgentKit
import Foundation
import Testing
@testable import PeelAgent
import PeelCore
@testable import PeelTestSupport

/// Connections: an MCP server registered with the staged strut (strut #286),
/// against a stand-in server on this Mac (a development profile's
/// `STRUT_MCP_LOCAL`): its key kept in strut by name only, tested, given to
/// the agents Peel's grants name, and removed with its key.
@MainActor
struct ConnectionsTests {
    @Test func theGrantsAreEachAgentsToolsInTheDelta() throws {
        let config = try AgentKit.JSONValue(parsing: String(decoding: try Orchestrator.hostConfig(grants: MCPGrants(assistant: ["linear"], jobs: ["linear", "notion"])), as: UTF8.self))
        let assistant = config["orchestrator"]?["tools"]?.array?.compactMap(\.string) ?? []
        #expect(assistant.last == "mcp/linear/*" && assistant.filter { $0.hasPrefix("mcp/") }.count == 1)
        #expect(config["job"]?["tools"] == ["mcp/linear/*", "mcp/notion/*"])
        #expect(try AgentKit.JSONValue(parsing: String(decoding: try Orchestrator.hostConfig(), as: UTF8.self))["job"]?["tools"] == [])
        #expect(MCPGrants(assistant: ["a", "b"], jobs: ["b"]).dropping("b") == MCPGrants(assistant: ["a"]))
        // A name strut would refuse is refused before anything is sent; the secret follows the name.
        #expect(throws: PeelError.self) { try AutomationsClient.mcpName("lin ear/../x") }
        // No two names share a key, and a key a server echoes is not shown.
        let secrets = ["linear", "Linear", "lin-ear", "lin_ear"].map(AutomationsClient.mcpSecret)
        #expect(Set(secrets).count == 4 && secrets[0] == "MCP_6C696E656172_KEY")
        #expect(AutomationsClient.masked("401 for Bearer lin_api_secret: token lin_api_0123456789abcdefghij bad") == "401 for Bearer •••: token ••• bad")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.appending(path: "build/mcp-registry.js").path)))
    func aServerIsAddedTestedGrantedAndRemovedWithItsKey() async throws {
        let mcp = try await MCPStub()
        let root = FileManager.default.temporaryDirectory.appending(path: "peel-connections-\(UUID().uuidString)")
        defer {
            mcp.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let strut = try #require(BundledStrut(folder: BundledStrut.staged, data: root.appending(path: "data"),
                                              secretKey: FileItem(file: root.appending(path: "strut-key"))))
        strut.allowsLocalMCP = true
        try strut.keep(MCPGrants(assistant: ["linear"], jobs: ["linear"]))
        defer { strut.stop(quietly: true) }
        let server = try await strut.start()
        let client = AutomationsClient(server: server)

        try await client.addMCPServer(name: "linear", url: mcp.url, key: "lin_api_secret")
        #expect(try await client.mcpServers() == [MCPServer(name: "linear", url: mcp.url)])
        // strut holds the key by a name only this server's can be; the registration names it, never the value.
        let secret = AutomationsClient.mcpSecret("linear")
        let registration = try await client.call("GET", "mcp-servers/linear", what: "it")
        #expect(registration["tokenSecret"] == .string(secret) && !registration.jsonString.contains("lin_api_secret"))
        #expect(try await client.call("GET", "secrets", what: "names").jsonString.contains(secret))

        let probe = try await client.testMCPServer("linear")
        #expect(probe.error == nil && probe.tools == [.init(name: "list_issues", gated: false), .init(name: "create_issue", gated: true)])
        #expect(mcp.bearers.contains("lin_api_secret"))

        // The grants reach the agents strut seeds: the assistant and its jobs.
        for workflow in ["orchestrator", "job"] {
            let tools = try await client.call("GET", "workflows/\(workflow)/flow", what: workflow)["params"]?["tools"]?.array?.compactMap(\.string) ?? []
            #expect(tools.contains("mcp/linear/*"), "\(workflow): \(tools)")
        }

        try await client.removeMCPServer("linear")
        #expect(try await client.mcpServers().isEmpty)
        #expect(try await !client.call("GET", "secrets", what: "names").jsonString.contains(secret))
        // Linear beside linear keeps its own key: each server is sent only its own.
        try await client.addMCPServer(name: "linear", url: mcp.url, key: "first")
        try await client.addMCPServer(name: "Linear", url: mcp.url, key: "second")
        _ = try await client.testMCPServer("linear")
        _ = try await client.testMCPServer("Linear")
        #expect(mcp.bearers.suffix(8).contains("first") && mcp.bearers.suffix(8).contains("second"))
        try await client.removeMCPServer("Linear")
        _ = try await client.testMCPServer("linear")
        #expect(mcp.bearers.last == "first", "removing Linear kept linear's key")
        // A name already connected is not silently re-pointed.
        await #expect(throws: PeelError.self) { try await client.addMCPServer(name: "linear", url: URL(string: "https://example.com/mcp")!, key: "x") }
        // One strut refuses (a query in its address) leaves no registration and no key.
        await #expect(throws: PeelError.self) {
            try await client.addMCPServer(name: "query", url: URL(string: "https://example.com/mcp?key=x")!, key: "kept?")
        }
        #expect(try await client.mcpServers().map(\.name) == ["linear"])
        #expect(try await !client.call("GET", "secrets", what: "names").jsonString.contains(AutomationsClient.mcpSecret("query")))
        try await client.removeMCPServer("linear")
        // One that does not answer says so, in words.
        try await client.addMCPServer(name: "gone", url: URL(string: "http://127.0.0.1:9/mcp")!, key: nil)
        #expect(try await client.testMCPServer("gone").error?.isEmpty == false)
    }

    /// Coding agents (docs/local-coding-agents.md): folders and the login
    /// shell's PATH reach the job launcher, and the assistant is told of
    /// them, only once there is a folder and an agent to work in it.
    @Test func codingAgentsReachTheJobAndTheAssistantOnlyWhenUsable() throws {
        let setup = CodingSetup(folders: ["peel": "/Users/t/Documents/peel"], path: "/opt/homebrew/bin:/usr/bin", agents: ["goose", "claude"])
        let config = try AgentKit.JSONValue(parsing: String(decoding: try Orchestrator.hostConfig(coding: setup), as: UTF8.self))
        #expect(config["job"]?["folders"] == ["peel": "/Users/t/Documents/peel"])
        #expect(config["job"]?["path"] == "/opt/homebrew/bin:/usr/bin")
        let system = config["orchestrator"]?["system"]?.string ?? ""
        #expect(system.contains("goose (goose), Claude Code (claude)") && system.contains("peel (/Users/t/Documents/peel)"))
        #expect(system.contains("else claude"), "Claude Code first when it is there")
        for unusable in [CodingSetup(folders: ["peel": "/p"], path: "/usr/bin"), CodingSetup(path: "/usr/bin", agents: ["goose"])] {
            let none = try AgentKit.JSONValue(parsing: String(decoding: try Orchestrator.hostConfig(coding: unusable), as: UTF8.self))
            #expect(none["job"]?["folders"] == nil && none["job"]?["path"] == nil)
            #expect(none["orchestrator"]?["system"]?.string?.contains("Coding agents") == false)
        }
    }

    /// A folder's name is one strut takes as an id (its host config refuses
    /// any other, and would not start): lower case, no spaces, unique.
    @Test func aFolderIsNamedAsStrutTakesNames() {
        var setup = CodingSetup()
        #expect(setup.name(for: URL(filePath: "/Users/t/Documents/My Peel App")) == "my-peel-app")
        setup.folders["peel"] = "/Users/t/Documents/peel"
        #expect(setup.name(for: URL(filePath: "/Users/t/Work/peel")) == "peel-2")
        #expect(setup.name(for: URL(filePath: "/Users/t/Documents/peel")) == "peel", "the same folder keeps its name")
        #expect(setup.name(for: URL(filePath: "/Users/t/…")) == "folder")
        for name in ["my-peel-app", "peel-2", "folder"] {
            #expect(name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil, "\(name)")
        }
    }

    /// The login shell's answer: its last PATH line (a profile may print
    /// first), absolute folders only; an agent counts when all its commands are there.
    @Test func theLoginShellsAnswerIsReadStrictly() {
        let found = CodingAgents.parse("Welcome!\nPATH=/opt/homebrew/bin:/usr/bin\nHAS=npx\nHAS=claude\nHAS=goose\nHAS=codex-not\n")
        #expect(found?.path == "/opt/homebrew/bin:/usr/bin")
        #expect(found?.agents == ["claude", "goose"], "codex needs npx and codex")
        #expect(CodingAgents.parse("PATH=bin:/usr/bin\n") == nil, "a relative folder")
        #expect(CodingAgents.parse("HAS=goose\n") == nil)
        #expect(CodingAgents.parse("PATH=/usr/bin\n")?.agents == [])
    }
}
