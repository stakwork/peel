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
    /// Where Peel Home is (`Profile.brain`), read when its agent opens;
    /// nil when it could not be read, and then no strut at all.
    var brain: Brain?
    /// A Peel Home link (`HomeLink`) waiting for the person's yes in Account › Brain.
    var homeLink: HomeLink?
    /// A Peel Home move under way, or how the last one ended (`AppModel+Home`).
    var homeMove: HomeMoveState?
    @ObservationIgnored var homeMoving: Task<Void, Never>?
    /// Whether this build has a strut of its own, for the open account (`strut(for:)`).
    var hasOwnStrut = false
    /// The strut Peel ships, if this build has one, for this launch's
    /// profile (`strut(for:)`): started when its agent opens, stopped when
    /// Peel quits.
    @ObservationIgnored var strut: BundledStrut?
    /// The agent's bridge beside it (`AppModel+Bridge`).
    let agentBridge = AgentBridge()
    /// The one memory open beside the agent chat (`openMemory`), if any.
    var memoryPanel: MemoryPanel?
    /// The agent chat's tool rows and request details open, kept past its list.
    let openRows = AgentOpenRows()
    /// The Automations view's list, read from strut.
    var automations = AutomationsState()
    /// What strut's secret store was last given (`AppModel.modelChanged`):
    /// which strut, and the connected model, nil for none.
    @ObservationIgnored var strutModel: (server: MemoryServer, credential: AgentCredential?)?
    /// Whether strut has what the person connected or removed, as the last
    /// hand-over left it, for Account › Peel agent; nil with no strut of
    /// Peel's own to hand it to.
    var modelHandOver: ModelHandOver?
    /// The one hand-over to strut in flight, and whether it runs again
    /// after (the model or strut changed while it ran).
    @ObservationIgnored var modelHanding: Task<Void, Never>?
    @ObservationIgnored var modelHandingAgain = false
    /// The Automations view's tab and its one opened row, kept while the
    /// view is away (and set by the offscreen driver's `automations-system`
    /// and `system-open`).
    var automationsTab = AutomationsView.Tab.yours
    var openedAutomation: String?
    /// The device requests' cards and the send grants.
    let deviceCards = DeviceCards()
    /// Account › Connections (`AppModel+Connections`).
    let connections = ConnectionsState()
    /// The Mac's side of the person's Stadeum workspaces, paired as peers (`AppModel+Hive`).
    let stadeumHost = MacStadeumHost()

    func open(_ profile: Profile, engine: Engine, in model: AppModel) {
        model.openAgent(profile, engine: engine)
        deviceCards.model = model
    }

    /// The agent in strut asks this Mac for chat reads, sends and approvals
    /// (reads only if the agent chat did not open); the engine answers only
    /// once its contact is set (`Setting.deviceAgent`).
    func deviceRequests(for engine: Engine) -> DeviceRequestHandler? {
        guard let agent = deviceCards.model?.agent else { return DeviceReads(storage: engine.storage, myAlias: { await engine.myAlias }).handler }
        return deviceCards.handler(for: engine, agent: agent)
    }

    func close(in model: AppModel) {
        deviceCards.close()
        model.closeAgent()
    }

    func closeMemory(in model: AppModel) -> Bool {
        guard memoryPanel != nil else { return false }
        model.closeMemory()
        return true
    }

    func stop() {
        stopMove()
        deviceCards.close()
        agentBridge.stop()
        strut?.stop(quietly: true)
    }

    /// Cancels a Peel Home move under way; its mark stays, and the account
    /// reads it again when it opens.
    func stopMove() {
        homeMoving?.cancel()
        homeMoving = nil
    }

    /// The app account's memory is erased even if its strut never started
    /// this launch (forgotten from the lock screen) or this build ships
    /// none; a development profile's is in its folder.
    func forget(_ profile: Profile) throws {
        stop()
        if profile.kind == .app { try BundledStrut.erase() }
        try BundledBridge.erase(data: BundledBridge.dataFolder(for: profile))
        // Peel Home's copies from a move: the agent's key and strut's secrets.
        try PeelHomeMove.eraseCopies(of: BundledStrut.dataFolder(for: profile))
        try PeelHomeMove.eraseCopies(of: BundledBridge.dataFolder(for: profile))
    }
}

extension AppModel {
    /// The Mac's model is always made with a `MacAgent` (`Platform.mac()`).
    var macAgent: MacAgent { agentHost as! MacAgent }

    var memoryServer: MemoryServer? {
        get { macAgent.memoryServer }
        set {
            macAgent.memoryServer = newValue
            // A deliverable open in the web pane was the strut before's (its port and key).
            web.strutChanged(to: newValue)
        }
    }

    var strut: BundledStrut? {
        get { macAgent.strut }
        set {
            macAgent.strut = newValue
            strutChanged()
        }
    }

    /// Dictation turns speech into text on this strut, the open account's.
    func strutChanged() {
        DictationController.shared.strutChanged(strut?.server)
    }

    var brain: Brain? {
        get { macAgent.brain }
        set { macAgent.brain = newValue }
    }

    var hasOwnStrut: Bool { macAgent.hasOwnStrut }

    var agentOpenRows: AgentOpenRows { macAgent.openRows }

    var memoryPanel: MemoryPanel? {
        get { macAgent.memoryPanel }
        set { macAgent.memoryPanel = newValue }
    }

    var strutModel: (server: MemoryServer, credential: AgentCredential?)? {
        get { macAgent.strutModel }
        set { macAgent.strutModel = newValue }
    }

    var modelHandOver: ModelHandOver? {
        get { macAgent.modelHandOver }
        set { macAgent.modelHandOver = newValue }
    }

    var modelHanding: Task<Void, Never>? {
        get { macAgent.modelHanding }
        set { macAgent.modelHanding = newValue }
    }

    var modelHandingAgain: Bool {
        get { macAgent.modelHandingAgain }
        set { macAgent.modelHandingAgain = newValue }
    }

    var automations: AutomationsState {
        get { macAgent.automations }
        // In place: `automations.runs[id] = …` copies nothing.
        _modify { yield &macAgent.automations }
    }

    var automationsTab: AutomationsView.Tab {
        get { macAgent.automationsTab }
        set { macAgent.automationsTab = newValue }
    }

    var openedAutomation: String? {
        get { macAgent.openedAutomation }
        set { macAgent.openedAutomation = newValue }
    }
}

extension AppModel {
    // MARK: The agent (docs/agent-on-strut.md)

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

    /// Opens the account's agent: `agent.sqlite` beside its database (its
    /// name, rules and the earlier local chat), the connected model's key
    /// from this device's Keychain (a file on a development profile), and
    /// Peel Home: the strut Peel ships, started here if it is not running
    /// (`strut(for:)`), with the agent's bridge beside it, unless Peel Home
    /// moved to a home server.
    func openAgent(_ profile: Profile, engine: Engine) {
        do {
            let store = try SQLiteAgentStore.open(for: profile, storage: engine.storage)
            do {
                let (kept, oldHomeServer) = try Brain.read(profile.brain)
                brain = kept
                // A home server kept the old way, by address and key: Peel Home is on this Mac now, said once.
                if oldHomeServer, (try? profile.brain.delete()) != nil {
                    notice = "Peel no longer connects to a home server by address. Your assistant runs on this Mac; "
                        + "to keep it answering while this Mac sleeps, set up Peel Home on your home server."
                }
            } catch {
                // Not taken for "this Mac": no strut is started until it is set again.
                brain = nil
                notice = PeelError.noted(error, couldNot: "read where Peel Home is")
            }
            let agent = AgentSession(store: store, credentials: KeptCredential(item: profile.agentCredential))
            agent.credentialChanged = { [weak self] in self?.modelChanged() }
            self.agent = agent
            macAgent.hasOwnStrut = Self.strut(for: profile) != nil
            if brain == .thisMac { useOwnStrut(profile) }
            openHive(profile)
            lookForMemory(reporting: true)
            lookForBridge()
            // A Peel Home link that came while the account was locked.
            if homeLink != nil { openAccount(.brain) }
        } catch {
            notice = PeelError.noted(error, couldNot: "open the agent chat")
        }
    }

    /// Gives the open agent Peel's strut while it is running, or takes it
    /// away once it is not: its memory, model and automations. Looked at when
    /// the agent opens, when the strut starts or stops, and on Set up, which
    /// starts it again if it stopped (its port may now be anyone's, so the
    /// key is never sent to it). A failed start is said when `reporting`.
    /// With Peel Home moved, none: the agent is reached over Sphinx.
    func lookForMemory(reporting: Bool = false, restarting: Bool = true) {
        guard agent != nil else { return }
        let memory = brain == .thisMac ? strut?.server : nil
        // Not running yet, or stopped since: started, and here once ready.
        if brain == .thisMac, memory == nil, restarting, let strut { startStrut(strut, reporting: reporting) }
        guard memory != memoryServer else { return }
        memoryServer = memory
        closeMemory()
        automations = AutomationsState()
        modelChanged()
    }

    // MARK: Peel Home's place (`Brain`)

    /// "Use this Mac" when where Peel Home is could not be read: kept as this
    /// Mac, and its strut and bridge started. Never while it moved, or is moving.
    func useThisMac() throws {
        guard let profile else { throw PeelError("Peel's account is not open.") }
        // Its mark is all that keeps this Mac's bridge stopped while the box's runs.
        guard brain?.moved == nil, macAgent.homeMove?.isRunning != true else {
            throw PeelError("Peel Home is on your home server, or moving. Move it back to this Mac first.")
        }
        try Brain.thisMac.keep(in: profile.brain)
        brain = .thisMac
        useOwnStrut(profile)
        lookForMemory(reporting: true)
        lookForBridge()
    }

    /// A `peel://` link Peel takes: a Peel Home link (`HomeLink`), which waits
    /// in Account › Brain for the person's yes. False for any other scheme.
    func openPeelLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "peel" else { return false }
        if url.host?.lowercased() == "home-setup", let link = HomeLink(url) {
            openHomeLink(link)
        } else if url.host?.lowercased() == "brain" {
            notice = "That link is for the old home server, which Peel no longer uses. Set up Peel Home on your home server and open its link."
        } else {
            notice = "That Peel Home link doesn't work. Open it again from your home server's page."
        }
        return true
    }

    /// Peel's own strut for `profile`, made if there is none, and looked at
    /// again when it starts or stops. A strut that stopped is not started
    /// again from here, only by the person's Set up or Try again: no crash loop.
    func useOwnStrut(_ profile: Profile) {
        if strut == nil { strut = Self.strut(for: profile) }
        // Whose orgs it speaks for, kept across a switch of brain.
        strut?.person = stadeum.link?.actor
        strut?.onChange = { [weak self] in
            self?.lookForMemory(restarting: false)
            self?.lookForBridge()
            self?.restartIfGrantsChanged()
            self?.strutChanged()
        }
    }

    private func startStrut(_ strut: BundledStrut, reporting: Bool) {
        Task {
            do { _ = try await strut.start() } catch {
                // Not said once the agent has closed (its account locked or
                // forgotten), or Peel Home moved while it started.
                if reporting, agent != nil, self.strut === strut { notice = PeelError.noted(error, couldNot: "start the agent's memory") }
                // The agent needs it: said in the agent chat, with Try again.
                if agent != nil, self.strut === strut, strut.server == nil {
                    agentBridge.fail(PeelError.noted(error, couldNot: "start Peel's memory"))
                }
            }
        }
    }

    /// The strut `profile`'s agent uses, if this build ships one: the app
    /// account's in Peel's folder; a development profile's only with
    /// `-strut YES` (its agent needs it), its data inside the profile's own
    /// folder, so a test account never writes to the real memory.
    static func strut(for profile: Profile) -> BundledStrut? {
        switch profile.kind {
        case .app: BundledStrut(secretKey: profile.strutKey)
        case .development:
            UserDefaults.standard.bool(forKey: "strut") ? {
                let strut = BundledStrut(data: BundledStrut.dataFolder(for: profile), secretKey: profile.strutKey)
                // A test MCP server on this Mac, for a development profile only.
                strut?.allowsLocalMCP = true
                return strut
            }() : nil
        }
    }

    func closeAgent() {
        // A Peel Home move under way is this account's alone.
        macAgent.stopMove()
        homeMove = nil
        automations = AutomationsState()
        agentBridge.stop()
        connections.reset()
        closeHive()
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

extension AgentToolTitle {
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
final class MemoryPanel: Identifiable {
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
                problem = PeelError.noted(error, couldNot: "read this memory")
            }
        }
    }
}
