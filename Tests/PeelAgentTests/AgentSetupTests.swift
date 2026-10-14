import AgentKit
import Foundation
import Synchronization
import Testing
@testable import peel
@testable import PeelAgent
@testable import PeelCore
@testable import PeelTestSupport

/// The one way the app and `peel agent` put the agent's tools and prompt
/// together (`AgentSetup`), and what `peel agent --memory` starts.
@MainActor
struct AgentSetupTests {
    static let reads = ["get_contacts_and_tribes", "read_recent_messages", "read_unseen_messages", "read_threads", "search_messages"]
    static let memory = ["remember", "recall", "read_memory", "memory_ontology", "forget_memory", "merge_memory"]
    static let automations = ["list_automations", "preview_schedule", "create_automation", "update_automation",
                              "delete_automation", "run_automation_now"]
    let server = MemoryServer(base: URL(string: "http://127.0.0.1:9")!, key: String(repeating: "ab", count: 32))

    @Test func theToolsFollowWhatTheCallerHas() throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        let engine = try testEngine(storage)
        func names(_ setup: AgentSetup) -> [String] { setup.tools.tools.map(\.name) }

        // `peel agent` with no profile; with one; with --memory.
        #expect(names(AgentSetup()) == ["current_time"])
        #expect(names(AgentSetup(storage: storage)) == ["current_time"] + Self.reads)
        #expect(names(AgentSetup(storage: storage, memory: server)) == ["current_time"] + Self.reads + Self.memory)
        // --send, and the app: the send tool only with an engine, automations only where asked and with memory.
        #expect(names(AgentSetup(sending: engine)) == ["current_time"] + Self.reads + ["send_sphinx_message"])
        #expect(names(AgentSetup(sending: engine, automations: true)) == ["current_time"] + Self.reads + ["send_sphinx_message"])
        #expect(names(AgentSetup(sending: engine, memory: server, automations: true))
                == ["current_time"] + Self.reads + ["send_sphinx_message"] + Self.memory + Self.automations)
    }

    @Test func anUnattendedRunIsToldNothingAboutSendingOrScheduling() throws {
        let profile = TempProfile()
        let engine = try testEngine(try profile.storage())
        let app = AgentSetup(sending: engine, memory: server, automations: true)
        let attended = app.systemPrompt(), unattended = app.systemPrompt(unattended: true)
        for prompt in [attended, unattended] {
            #expect(prompt.hasPrefix("You are Peel's agent"))
            #expect(prompt.contains(SphinxTools.systemPrompt) && prompt.contains(AgentMessageLink.instruction))
            #expect(prompt.contains(MemoryTools.systemPrompt))
        }
        #expect(attended.contains(SphinxTools.sendPrompt) && attended.contains(AutomationTools.systemPrompt))
        #expect(!unattended.contains(SphinxTools.sendPrompt) && !unattended.contains(AutomationTools.systemPrompt))

        // Without memory, nothing about it; the CLI's memory never mentions automations.
        #expect(!AgentSetup(sending: engine, automations: true).systemPrompt().contains(MemoryTools.systemPrompt))
        let cli = AgentSetup(storage: engine.storage, memory: server).systemPrompt()
        #expect(cli.contains(MemoryTools.systemPrompt) && !cli.contains(AutomationTools.systemPrompt)
                && !cli.contains(SphinxTools.sendPrompt))
        #expect(!AgentSetup().systemPrompt().contains(SphinxTools.systemPrompt))
    }

    /// A development profile's memory is inside its own folder, never the app account's.
    @Test func aDevelopmentProfilesMemoryIsItsOwn() throws {
        let development = try Profile(name: "agent-setup-test", kind: .development)
        #expect(BundledStrut.dataFolder(for: development) == development.directory.appending(path: "strut"))
        #expect(BundledStrut.dataFolder(for: try Profile(name: "x", kind: .app)) == BundledStrut.dataFolder)
    }

    @Test(arguments: [["--memory"], ["--send"], ["--send", "--memory"]])
    func sendingAndMemoryNeedAProfile(_ arguments: [String]) async {
        await #expect { try await AgentCommand.run(Arguments(arguments), profile: nil) } throws: {
            "\($0)".contains("needs --profile")
        }
    }

    /// Refused before anything starts: no strut, and nothing written for a profile that is not there.
    @Test func memoryOnAProfileThatIsNotThereStartsNothing() async throws {
        let name = "agent-setup-\(UUID().uuidString.prefix(8))"
        let directory = try Profile(name: name, kind: .development).directory
        await #expect { try await AgentCommand.run(Arguments(["--memory"]), profile: name) } throws: {
            "\($0)" == "no development profile named \(name)"
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// `peel agent --memory` against the staged strut (scripts/stage-strut.sh):
    /// the CLI's strut for a development profile, the tools it gets, and a
    /// remember then a recall in two turns, the model scripted.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: BundledStrut.staged.path)))
    func theCLIsMemoryRemembersAndRecalls() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "peel-cli-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let strut = try AgentCommand.strut(for: Profile(developmentAt: folder))
        defer { strut.stop(quietly: true) }
        let setup = AgentSetup(memory: try await strut.start())
        #expect(setup.tools.tools.map(\.name) == ["current_time"] + Self.memory)

        let kate: AgentKit.JSONValue = ["type": "Person", "name": "Kate"]
        let model = Script([
            [.toolCallCompleted(ToolCall(id: "r", name: "remember", input: [
                "episode": "My sister Kate bakes sourdough every Sunday.", "mentions": [kate],
                "facts": [["subject": kate, "predicate": "likes", "text": "Kate bakes sourdough every Sunday."]],
            ])), .finished(.toolUse)],
            [.textDelta("Noted."), .finished(.endTurn)],
            [.toolCallCompleted(ToolCall(id: "q", name: "recall", input: ["q": "Kate sourdough"])), .finished(.toolUse)],
            [.textDelta("She bakes sourdough."), .finished(.endTurn)],
        ])
        let loop = AgentLoop(provider: model, tools: setup.tools, model: "scripted", systemPrompt: setup.systemPrompt())
        let first = await loop.run(history: [], message: "Remember: Kate bakes sourdough on Sundays.")
        _ = await loop.run(history: first.messages, message: "What does Kate bake?")

        let results = model.requests.flatMap(\.messages).flatMap(\.content).compactMap {
            if case .toolResult(let result) = $0 { result } else { nil }
        }
        let remembered = try #require(results.first { $0.toolCallID == "r" })
        let recalled = try #require(results.first { $0.toolCallID == "q" })
        #expect(!remembered.isError && !recalled.isError, "\(remembered.content)\n\(recalled.content)")
        #expect(recalled.content.contains("sourdough"))
        // Its memory is in the profile's folder.
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "strut/workspace").path))
    }
}

/// Each request answered by the next scripted reply; keeps what it was asked.
private final class Script: ModelProvider {
    private let replies: Mutex<[[ModelEvent]]>
    private let asked = Mutex<[ModelRequest]>([])

    init(_ replies: [[ModelEvent]]) {
        self.replies = Mutex(replies)
    }

    var requests: [ModelRequest] { asked.withLock { $0 } }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        asked.withLock { $0.append(request) }
        let events = replies.withLock { $0.isEmpty ? [.finished(.endTurn)] : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
