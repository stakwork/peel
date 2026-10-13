import AgentKit
import Foundation
import PeelAgent
import PeelCore

/// Where a Connect panel was opened from, so it opens beside that button:
/// the chat's card or its error row, or the Account page's provider or key.
enum AgentConnectSource: Hashable {
    case chat, problem, account, accountKey
}

extension AppModel {
    // MARK: The agent chat (docs/phases/09-agents.md, PR 5)

    static func agentSystemPrompt(remembers: Bool) -> String {
        """
        You are Peel's agent, a helper inside Peel, a Sphinx chat app on the user's Mac. Answer plainly and \
        briefly, in Markdown when it helps. Use a tool when it gives a better answer than guessing. When the \
        tools you have cannot do what is asked, say so.
        """ + " " + AgentMessageLink.instruction + " " + SphinxTools.systemPrompt + " " + SphinxTools.sendPrompt
            + (remembers ? " " + MemoryTools.systemPrompt : "")
    }

    /// The tools the agent may use over the account's `engine`: the time,
    /// the Sphinx read tools and the send tool (`PeelAgent`), which waits on
    /// the person's approval for each message; and the memory tools when a
    /// memory server is set.
    static func agentTools(_ engine: Engine, memory: MemoryServer?) -> ToolRegistry {
        let sphinx = SphinxTools(storage: engine.storage)
        let remembering = memory.map { MemoryTools(server: $0).tools } ?? []
        return ToolRegistry([.currentTime] + sphinx.tools + [sphinx.send(through: engine)] + remembering)
    }

    /// The agent's memory (`docs/agent-brain.md`, an experiment): a strut on
    /// this Mac, named with `defaults write dev.peel.mac memoryServer
    /// http://127.0.0.1:<port>`. Nil when unset or not on this Mac.
    static var memoryServer: MemoryServer? {
        UserDefaults.standard.string(forKey: "memoryServer").flatMap(URL.init(string:)).flatMap(MemoryServer.init(base:))
    }

    /// Opens the message an agent's link names (`AgentMessageLink`), as a
    /// jump to it from a quote does (`focus(on:)`); says so in the chat when
    /// it is not here. False for any other link.
    func openAgentLink(_ url: URL) -> Bool {
        guard let link = AgentMessageLink(url) else { return false }
        guard let message = try? engine?.storage.message(uuid: link.uuid, in: link.chat) else {
            agent?.notice = "That message is not on this Mac."
            return true
        }
        focus(on: message)
        return true
    }

    /// Opens the account's agent chat: `agent.sqlite` beside its database,
    /// the connected model's key from this device's Keychain (a file on a
    /// development profile). A development profile may name a local test
    /// server with `-agentBaseURL http://127.0.0.1:<port>`.
    func openAgent(_ profile: Profile, engine: Engine) {
        do {
            let store = try SQLiteAgentStore.open(for: profile, storage: engine.storage)
            let baseURL = profile.kind == .development
                ? UserDefaults.standard.string(forKey: "agentBaseURL").flatMap(URL.init(string:)) : nil
            let memory = Self.memoryServer
            agent = AgentSession(
                store: store, credentials: KeptCredential(item: profile.agentCredential),
                tools: Self.agentTools(engine, memory: memory), systemPrompt: Self.agentSystemPrompt(remembers: memory != nil)
            ) { $0.provider.client(apiKey: $0.apiKey, baseURL: baseURL) }
        } catch {
            notice = PeelError.problem(error, couldNot: "open the agent chat")
        }
    }

    /// Where the connected model's key is kept, as the screens say it.
    var agentKeyPlace: String {
        profile?.kind == .development ? "a plain file of this development profile" : "this Mac's Keychain"
    }

    /// The agent chat's settings: Account, at its Peel agent section.
    func openAgentSettings() {
        showsAgentSettings = true
        destination = .account
    }

    func closeAgent() {
        agent?.close()
        agent = nil
        agentConnectFrom = nil
    }
}

/// The credential as JSON in one `SecretItem`: the Keychain in the app.
private struct KeptCredential: AgentCredentialStore {
    let item: any SecretItem

    func read() throws -> AgentCredential? {
        try item.read().map { try JSONDecoder().decode(AgentCredential.self, from: $0) }
    }

    func write(_ credential: AgentCredential) throws {
        try item.write(JSONEncoder().encode(credential))
    }

    func delete() throws {
        try item.delete()
    }
}

/// How the agent's tools read in its chat: "Read the time · 0.1 s".
enum AgentToolTitle {
    private static let titles = [
        "current_time": "Read the time",
        "get_contacts_and_tribes": "Read contacts and tribes",
        "read_recent_messages": "Read recent messages",
        "read_unseen_messages": "Read unseen messages",
        "read_threads": "Read threads",
        "search_messages": "Searched messages",
        "send_sphinx_message": "Send a message",
        "remember": "Remembered",
        "recall": "Searched memory",
        "read_memory": "Read memory",
        "memory_ontology": "Read memory's vocabulary",
        "forget_memory": "Forgot",
        "merge_memory": "Merged",
    ]

    static func of(_ name: String) -> String {
        if let title = titles[name] { return title }
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A result's first line as a row shows it: without chat ids, which
    /// the model needs and a person does not, or the colon before the data.
    static func summary(_ line: String) -> String {
        line.replacingOccurrences(of: #" \(chat=[^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    }

    /// How a tool that acts was answered: "Allowed once", "Declined".
    static func outcome(_ outcome: ApprovalOutcome, target: String?) -> String {
        switch outcome {
        case .allowedOnce: "Allowed once"
        case .alwaysAllowed: target.map { "Always allowed for \($0)" } ?? "Always allowed"
        case .allowedByRule: target.map { "Allowed, always for \($0)" } ?? "Allowed, always"
        case .denied: "Declined"
        case .stopped: "Stopped"
        }
    }

    /// "0.1 s", "12 s".
    static func duration(_ duration: Duration) -> String {
        let seconds = duration / .seconds(1)
        if seconds < 0.05 { return "<0.1 s" }
        return seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }
}
