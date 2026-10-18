import AgentKit
import Foundation
import PeelCore

/// The agent's tools and system prompt, put together the one way the app
/// and `peel agent` share: the time; given an account's storage, the Sphinx
/// read tools; given its engine, the send tool too, which waits on the
/// person's approval for each message; given a memory, the memory tools;
/// and, where automations can run (the app's `AutomationServer`, or strut's
/// `peel-automation-run` with the strut preview on), the automation tools
/// beside them, over `automations`.
public struct AgentSetup: Sendable {
    public let storage: Storage?
    public let engine: Engine?
    public let memory: MemoryServer?
    public let automations: AutomationsClient?

    /// `storage` alone reads an account; `engine` reads its own storage and
    /// sends through it. Never both.
    public init(storage: Storage? = nil, sending engine: Engine? = nil, memory: MemoryServer? = nil, automations: AutomationsClient? = nil) {
        precondition(storage == nil || engine == nil, "AgentSetup: storage or an engine, not both")
        self.storage = storage ?? engine?.storage
        self.engine = engine
        self.memory = memory
        self.automations = automations
    }

    public var tools: ToolRegistry {
        var tools = [Tool.currentTime]
        if let storage {
            let sphinx = SphinxTools(storage: storage)
            tools += sphinx.tools
            if let engine { tools.append(sphinx.send(through: engine)) }
        }
        if let memory {
            tools += MemoryTools(server: memory).tools
            if let automations { tools += AutomationTools(client: automations).tools }
        }
        return ToolRegistry(tools)
    }

    /// `unattended`, for an automation's run: nothing about sending or
    /// scheduling, whose tools a run without an approver is not offered.
    public func systemPrompt(unattended: Bool = false) -> String {
        var prompt = """
            You are Peel's agent, a helper inside Peel, a Sphinx chat app on the user's Mac. Answer plainly and \
            briefly, in Markdown when it helps. Use a tool when it gives a better answer than guessing. When the \
            tools you have cannot do what is asked, say so.
            """
        if storage != nil { prompt += " " + AgentMessageLink.instruction + " " + SphinxTools.systemPrompt }
        if engine != nil, !unattended { prompt += " " + SphinxTools.sendPrompt }
        if memory != nil {
            prompt += " " + MemoryTools.systemPrompt
            if automations != nil, !unattended { prompt += " " + AutomationTools.systemPrompt }
        }
        return prompt
    }
}
