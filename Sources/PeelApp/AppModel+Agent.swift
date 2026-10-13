import AgentKit
import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// The agent's pieces that need PeelAgent, for the model (`AgentHost`):
/// the memory, Peel's strut and the automations. The model reads them
/// through `AppModel.macAgent`.
@MainActor @Observable
final class MacAgent: AgentHost {
    /// The agent's memory: the running strut's address and key (`lookForMemory`).
    var memoryServer: MemoryServer?
    /// The strut Peel ships, if this build has one, for this launch's
    /// profile (`strut(for:)`): started when its agent opens, stopped when
    /// Peel quits.
    @ObservationIgnored var strut: BundledStrut?
    /// The one memory open beside the agent chat (`openMemory`), if any.
    var memoryPanel: MemoryPanel?
    /// Where strut reaches the agent when an automation fires (`AppModel+Automations`).
    @ObservationIgnored var automationServer: AutomationServer?
    /// The last server's close, which a new one waits for before taking its port.
    @ObservationIgnored var automationStopping: Task<Void, Never>?
    /// The token strut sends with each automation: made when the agent opens,
    /// in memory only, the same for every server and PUT until it closes.
    @ObservationIgnored var automationToken: String?
    /// The Automations view's list, read from strut.
    var automations = AutomationsState()

    func open(_ profile: Profile, engine: Engine, in model: AppModel) {
        model.openAgent(profile, engine: engine)
    }

    func close(in model: AppModel) {
        model.closeAgent()
    }

    func closeMemory(in model: AppModel) -> Bool {
        guard memoryPanel != nil else { return false }
        model.closeMemory()
        return true
    }

    func stop() {
        strut?.stop(quietly: true)
    }

    /// The app account's memory is erased even if its strut never started
    /// this launch (forgotten from the lock screen) or this build ships
    /// none; a development profile's is in its folder.
    func forget(_ profile: Profile) throws {
        strut?.stop(quietly: true)
        if profile.kind == .app { try BundledStrut.erase() }
    }
}

extension AppModel {
    /// The Mac's model is always made with a `MacAgent` (`Platform.mac`).
    var macAgent: MacAgent { agentHost as! MacAgent }

    var memoryServer: MemoryServer? {
        get { macAgent.memoryServer }
        set { macAgent.memoryServer = newValue }
    }

    var strut: BundledStrut? {
        get { macAgent.strut }
        set { macAgent.strut = newValue }
    }

    var memoryPanel: MemoryPanel? {
        get { macAgent.memoryPanel }
        set { macAgent.memoryPanel = newValue }
    }

    var automationServer: AutomationServer? {
        get { macAgent.automationServer }
        set { macAgent.automationServer = newValue }
    }

    var automationStopping: Task<Void, Never>? {
        get { macAgent.automationStopping }
        set { macAgent.automationStopping = newValue }
    }

    var automationToken: String? {
        get { macAgent.automationToken }
        set { macAgent.automationToken = newValue }
    }

    var automations: AutomationsState {
        get { macAgent.automations }
        set { macAgent.automations = newValue }
    }
}

extension AppModel {
    // MARK: The agent chat (docs/phases/09-agents.md, PR 5)

    /// The agent's tools and prompt over the account's `engine`
    /// (`AgentSetup`): the read tools, the send tool, and the memory and
    /// automation tools when a strut on this Mac has the memory steps.
    static func agentSetup(_ engine: Engine, memory: MemoryServer?) -> AgentSetup {
        AgentSetup(sending: engine, memory: memory, automations: true)
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
    /// development profile), and the memory: the strut Peel ships, started
    /// here if it is not running (`strut(for:)`).
    func openAgent(_ profile: Profile, engine: Engine) {
        do {
            let store = try SQLiteAgentStore.open(for: profile, storage: engine.storage)
            // One per account open, so every server and every PUT to strut agrees on it.
            automationToken = try AutomationServer.newKey()
            if strut == nil { strut = Self.strut(for: profile) }
            let setup = Self.agentSetup(engine, memory: nil)
            let agent = AgentSession(
                store: store, credentials: KeptCredential(item: profile.agentCredential),
                tools: setup.tools, systemPrompt: setup.systemPrompt()
            ) { Self.agentClient($0, profile: profile) }
            agent.willRun = { [weak self] in self?.lookForMemory() }
            self.agent = agent
            // A strut that stopped is not started again from here, only before the next reply: no crash loop.
            strut?.onChange = { [weak self] in self?.lookForMemory(restarting: false) }
            lookForMemory(reporting: true)
        } catch {
            notice = PeelError.problem(error, couldNot: "open the agent chat")
        }
    }

    /// Gives the open agent Peel's strut while it is running, or takes it
    /// away once it is not: its tools, prompt and automations. Looked at when
    /// the agent opens, when the strut starts or stops, and before each
    /// reply, which starts it again if it stopped (its port may now be
    /// anyone's, so the key and memory text are never sent to it). A failed
    /// start is said when `reporting`.
    func lookForMemory(reporting: Bool = false, restarting: Bool = true) {
        guard let profile, let engine, let agent else { return }
        let memory = strut?.server
        // Not running yet, or stopped since: started, and here once ready.
        if memory == nil, restarting, let strut { startStrut(strut, reporting: reporting) }
        guard memory != memoryServer else { return }
        memoryServer = memory
        closeMemory()
        let setup = Self.agentSetup(engine, memory: memory)
        agent.tools = setup.tools
        agent.systemPrompt = setup.systemPrompt()
        stopAutomations()
        startAutomations(profile, engine: engine)
    }

    private func startStrut(_ strut: BundledStrut, reporting: Bool) {
        Task {
            do { _ = try await strut.start() } catch {
                // Not said once the agent has closed (its account locked or forgotten).
                if reporting, agent != nil { notice = PeelError.problem(error, couldNot: "start the agent's memory") }
            }
        }
    }

    /// The strut `profile`'s agent uses, if this build ships one: the app
    /// account's in Peel's folder; a development profile's only with
    /// `-strut YES`, its data inside the profile's own folder, so a test
    /// account never writes to the real memory.
    static func strut(for profile: Profile) -> BundledStrut? {
        switch profile.kind {
        case .app: BundledStrut(secretKey: profile.strutKey)
        case .development:
            UserDefaults.standard.bool(forKey: "strut")
                ? BundledStrut(data: BundledStrut.dataFolder(for: profile), secretKey: profile.strutKey) : nil
        }
    }

    /// The model client for `credential`; a development profile may name a
    /// local test server with `-agentBaseURL http://127.0.0.1:<port>`.
    nonisolated static func agentClient(_ credential: AgentCredential, profile: Profile) -> any ModelProvider {
        let baseURL = profile.kind == .development
            ? UserDefaults.standard.string(forKey: "agentBaseURL").flatMap(URL.init(string:)) : nil
        return credential.provider.client(apiKey: credential.apiKey, baseURL: baseURL)
    }

    /// The agent chat's settings: Account, at its Peel agent section.
    func openAgentSettings() {
        showsAgentSettings = true
        destination = .account
    }

    func closeAgent() {
        stopAutomations()
        automationToken = nil
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
