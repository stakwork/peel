import AgentKit
import Foundation
import PeelAgent
import PeelCore

/// Where a Connect panel was opened from, so it opens beside that button:
/// the chat's card or its error row, or the Account page's provider or key.
enum AgentConnectSource: Hashable {
    case chat, problem, account, accountKey, automations
}

extension AppModel {
    // MARK: The agent chat (docs/phases/09-agents.md, PR 5)

    /// `unattended`, for an automation's run: nothing about sending or
    /// scheduling, whose tools a run without an approver is not offered.
    static func agentSystemPrompt(remembers: Bool, unattended: Bool = false) -> String {
        """
        You are Peel's agent, a helper inside Peel, a Sphinx chat app on the user's Mac. Answer plainly and \
        briefly, in Markdown when it helps. Use a tool when it gives a better answer than guessing. When the \
        tools you have cannot do what is asked, say so.
        """ + " " + AgentMessageLink.instruction + " " + SphinxTools.systemPrompt + (unattended ? "" : " " + SphinxTools.sendPrompt)
            + (remembers ? " " + MemoryTools.systemPrompt : "")
            + (remembers && !unattended ? " " + AutomationTools.systemPrompt : "")
    }

    /// The tools the agent may use over the account's `engine`: the time,
    /// the Sphinx read tools and the send tool (`PeelAgent`), which waits on
    /// the person's approval for each message; and the memory and automation
    /// tools when a strut on this Mac has the memory steps. A run with no
    /// approver (an automation's) is not offered the tools that ask.
    static func agentTools(_ engine: Engine, memory: MemoryServer?) -> ToolRegistry {
        let sphinx = SphinxTools(storage: engine.storage)
        var tools = [.currentTime] + sphinx.tools + [sphinx.send(through: engine)]
        if let memory {
            tools += MemoryTools(server: memory).tools + AutomationTools(client: AutomationsClient(server: memory)).tools
        }
        return ToolRegistry(tools)
    }

    /// Opens one memory beside the agent chat: a fact or a name a memory
    /// row shows. From the panel itself it goes on from there, with Back.
    func openMemory(_ ref: MemoryRef) {
        guard let server = memoryServer else { return }
        if memoryPanel == nil { memoryPanel = MemoryPanel(server: server) }
        memoryPanel?.open(ref)
    }

    func closeMemory() {
        memoryPanel?.close()
        memoryPanel = nil
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
    /// development profile), and the memory, if a strut is running.
    func openAgent(_ profile: Profile, engine: Engine) {
        do {
            let store = try SQLiteAgentStore.open(for: profile, storage: engine.storage)
            profile.removeOldMemoryKey()
            let agent = AgentSession(
                store: store, credentials: KeptCredential(item: profile.agentCredential),
                tools: Self.agentTools(engine, memory: nil), systemPrompt: Self.agentSystemPrompt(remembers: false)
            ) { Self.agentClient($0, profile: profile) }
            agent.willRun = { [weak self] in self?.lookForMemory() }
            self.agent = agent
            lookForMemory(reporting: true)
        } catch {
            notice = PeelError.problem(error, couldNot: "open the agent chat")
        }
    }

    /// Gives the open agent the strut on this Mac while one is running with
    /// the memory steps, or takes it away once it is not: its tools, prompt
    /// and automations. Looked at when the agent opens and before each
    /// reply, so a strut started after Peel is found, and one that stopped
    /// (its port may now be anyone's) is not sent the key or memory text. A
    /// refused connection file is said when `reporting`.
    func lookForMemory(reporting: Bool = false) {
        guard let profile, let engine, let agent, let file = Self.memoryConnection(profile) else { return }
        var memory: MemoryServer?
        do {
            memory = try MemoryServer.onThisMac(file: file)
        } catch {
            if reporting { notice = PeelError.problem(error, couldNot: "turn on the agent's memory") }
        }
        guard memory != memoryServer else { return }
        memoryServer = memory
        closeMemory()
        agent.tools = Self.agentTools(engine, memory: memory)
        agent.systemPrompt = Self.agentSystemPrompt(remembers: memory != nil)
        stopAutomations()
        startAutomations(profile, engine: engine)
    }

    /// Where `profile` finds strut: its connection file for an app profile;
    /// for a development one only a file named by the `memoryConnection`
    /// default (`-memoryConnection <path>`), so a test account never writes
    /// to the real graph.
    private static func memoryConnection(_ profile: Profile) -> URL? {
        profile.kind == .app ? MemoryServer.connectionFile
            : UserDefaults.standard.string(forKey: "memoryConnection").map { URL(filePath: $0) }
    }

    /// The model client for `credential`; a development profile may name a
    /// local test server with `-agentBaseURL http://127.0.0.1:<port>`.
    nonisolated static func agentClient(_ credential: AgentCredential, profile: Profile) -> any ModelProvider {
        let baseURL = profile.kind == .development
            ? UserDefaults.standard.string(forKey: "agentBaseURL").flatMap(URL.init(string:)) : nil
        return credential.provider.client(apiKey: credential.apiKey, baseURL: baseURL)
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
        stopAutomations()
        agent?.close()
        agent = nil
        closeMemory()
        memoryServer = nil
        agentConnectFrom = nil
    }
}

/// The credential as JSON in one `SecretItem`: the Keychain in the app.
struct KeptCredential: AgentCredentialStore {
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
        "list_automations": "Read automations",
        "preview_schedule": "Checked a schedule",
        "create_automation": "Create an automation",
        "update_automation": "Change an automation",
        "delete_automation": "Delete an automation",
        "run_automation_now": "Run an automation",
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

/// One memory beside the agent chat, read from strut when it opens
/// (`MemoryServer.node`), so it shows what memory holds now. A fact or a
/// name in it opens that one in its place; Back goes to the one before.
@MainActor @Observable
final class MemoryPanel {
    let server: MemoryServer
    /// What was opened, the newest last.
    private(set) var trail: [MemoryRef] = []
    /// What each memory read as, so Back shows it again without a call.
    private var read: [String: MemoryNode] = [:]
    /// Why the newest could not be read.
    private(set) var problem: String?
    private var loading: Task<Void, Never>?

    init(server: MemoryServer) {
        self.server = server
    }

    var current: MemoryRef? { trail.last }
    var node: MemoryNode? { current.flatMap { read[$0.id] } }
    var canGoBack: Bool { trail.count > 1 }

    /// The one showing again is read again: after a failure, or to see it as it is now.
    func open(_ ref: MemoryRef) {
        if ref.id == current?.id {
            read[ref.id] = nil
        } else {
            trail.append(ref)
        }
        load()
    }

    func back() {
        guard canGoBack else { return }
        trail.removeLast()
        load()
    }

    func close() {
        loading?.cancel()
    }

    private func load() {
        loading?.cancel()
        problem = nil
        guard let ref = current, read[ref.id] == nil else { return }
        loading = Task {
            do {
                let node = try await server.node(ref.id)
                guard !Task.isCancelled else { return }
                if let node { read[ref.id] = node } else { problem = "This is no longer in memory." }
            } catch {
                guard !Task.isCancelled else { return }
                problem = PeelError.problem(error, couldNot: "read this memory")
            }
        }
    }
}
