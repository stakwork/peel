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
    /// The agent's memory: the running strut's address and key, or the
    /// home server's (`lookForMemory`).
    var memoryServer: MemoryServer?
    /// The account's brain (`Profile.brain`), read when its agent opens;
    /// nil when it could not be read, and then no strut at all.
    var brain: Brain?
    /// What the home server said when last checked; nil while checking or on this Mac.
    var brainStatus: BrainStatus?
    /// A home server a pairing link named, waiting for the person's yes in
    /// Account › Brain.
    var pairing: MemoryServer?
    /// A move of memory between this Mac and the home server, under way or
    /// just ended (`setBrain`). While one
    /// runs the agent has no memory tools, so nothing writes into a graph
    /// being loaded.
    var memoryMove: MemoryMoveState?
    /// Whether this Mac's memory holds anything (`checkLocalMemory`, or
    /// what the last move left); nil when not known.
    var localHoldsMemory: Bool?
    /// Whether this build has a strut of its own to move memory from or
    /// into, for the open account (`strut(for:)`).
    var hasOwnStrut = false
    /// The move under way, and the strut started only for it (in home-server
    /// mode), both stopped when the account closes or is forgotten.
    @ObservationIgnored var moving: Task<Void, Never>?
    @ObservationIgnored var movingStrut: BundledStrut?
    /// This Mac's memory set aside while the home server's is brought back
    /// in its place: put back if the move is cut short.
    @ObservationIgnored var settingAside: MemoryBackup?
    /// The strut Peel ships, if this build has one, for this launch's
    /// profile (`strut(for:)`): started when its agent opens, stopped when
    /// Peel quits.
    @ObservationIgnored var strut: BundledStrut?
    /// The agent's bridge beside it, with the preview on (`AppModel+Bridge`).
    let agentBridge = AgentBridge()
    /// The one memory open beside the agent chat (`openMemory`), if any.
    var memoryPanel: MemoryPanel?
    /// The agent chat's tool rows and summaries open, kept past its list.
    let openRows = AgentOpenRows()
    /// Where strut reaches the agent when an automation fires (`AppModel+Automations`).
    @ObservationIgnored var automationServer: AutomationServer?
    /// The last server's close, which a new one waits for before taking its port.
    @ObservationIgnored var automationStopping: Task<Void, Never>?
    /// The token strut sends with each automation: made when the agent opens,
    /// in memory only, the same for every server and PUT until it closes.
    @ObservationIgnored var automationToken: String?
    /// The Automations view's list, read from strut.
    var automations = AutomationsState()
    /// What strut's secret store was last given (`AppModel.modelChanged`):
    /// which strut, and the connected model, nil for none.
    @ObservationIgnored var strutModel: (server: MemoryServer, credential: AgentCredential?)?
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

    func open(_ profile: Profile, engine: Engine, in model: AppModel) {
        model.openAgent(profile, engine: engine)
        deviceCards.model = model
    }

    /// The agent in strut asks this Mac for chat reads, sends and approvals
    /// (reads only if the agent chat did not open); the engine answers only
    /// once its contact is set (`Setting.deviceAgent`).
    func deviceRequests(for engine: Engine) -> DeviceRequestHandler? {
        guard let agent = deviceCards.model?.agent else { return DeviceReads(storage: engine.storage).handler }
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

    /// Cancels the move under way and stops the strut started for it;
    /// this Mac's memory, if it was set aside, is put back now, since Peel
    /// may be quitting before the move hears of it.
    func stopMove() {
        moving?.cancel()
        moving = nil
        movingStrut?.stop(quietly: true)
        movingStrut = nil
        if let settingAside {
            strut?.stop(quietly: true)
            try? settingAside.restore()
            self.settingAside = nil
        }
    }

    /// The app account's memory is erased even if its strut never started
    /// this launch (forgotten from the lock screen) or this build ships
    /// none; a development profile's is in its folder.
    func forget(_ profile: Profile) throws {
        stop()
        if profile.kind == .app { try BundledStrut.erase() }
        try BundledBridge.erase(data: BundledBridge.dataFolder(for: profile))
    }
}

extension AppModel {
    /// The Mac's model is always made with a `MacAgent` (`Platform.mac()`).
    var macAgent: MacAgent { agentHost as! MacAgent }

    var memoryServer: MemoryServer? {
        get { macAgent.memoryServer }
        set { macAgent.memoryServer = newValue }
    }

    var strut: BundledStrut? {
        get { macAgent.strut }
        set { macAgent.strut = newValue }
    }

    var brain: Brain? {
        get { macAgent.brain }
        set { macAgent.brain = newValue }
    }

    var brainStatus: BrainStatus? {
        get { macAgent.brainStatus }
        set { macAgent.brainStatus = newValue }
    }

    var pairing: MemoryServer? {
        get { macAgent.pairing }
        set { macAgent.pairing = newValue }
    }

    var memoryMove: MemoryMoveState? {
        get { macAgent.memoryMove }
        set { macAgent.memoryMove = newValue }
    }

    var localHoldsMemory: Bool? {
        get { macAgent.localHoldsMemory }
        set { macAgent.localHoldsMemory = newValue }
    }

    var hasOwnStrut: Bool { macAgent.hasOwnStrut }

    var agentOpenRows: AgentOpenRows { macAgent.openRows }

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

    var strutModel: (server: MemoryServer, credential: AgentCredential?)? {
        get { macAgent.strutModel }
        set { macAgent.strutModel = newValue }
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
    // MARK: The agent chat (docs/phases/09-agents.md, PR 5)

    /// The agent's tools and prompt over the account's `engine`
    /// (`AgentSetup`): the read tools, the send tool, and the memory tools
    /// with a strut; the automation tools only with Peel's own, since a home
    /// server cannot reach this Mac's `AutomationServer` (until automations
    /// by pull, `docs/peel-brain.md`).
    static func agentSetup(_ engine: Engine, memory: MemoryServer?) -> AgentSetup {
        AgentSetup(sending: engine, memory: memory, automations: memory?.isHomeServer == false)
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
    /// development profile), and the memory: the account's home server, or
    /// the strut Peel ships, started here if it is not running (`strut(for:)`).
    func openAgent(_ profile: Profile, engine: Engine) {
        do {
            let store = try SQLiteAgentStore.open(for: profile, storage: engine.storage)
            // One per account open, so every server and every PUT to strut agrees on it.
            automationToken = try AutomationServer.newKey()
            do {
                brain = try Brain.kept(in: profile.brain)
            } catch {
                // Not taken for "this Mac": no strut is started until it is set again.
                brain = nil
                notice = PeelError.problem(error, couldNot: "read the agent's brain")
            }
            let setup = Self.agentSetup(engine, memory: nil)
            let agent = AgentSession(
                store: store, credentials: KeptCredential(item: profile.agentCredential),
                tools: setup.tools, systemPrompt: setup.systemPrompt()
            ) { Self.agentClient($0, profile: profile) }
            agent.willRun = { [weak self] in self?.lookForMemory() }
            agent.credentialChanged = { [weak self] in self?.modelChanged() }
            self.agent = agent
            macAgent.hasOwnStrut = Self.strut(for: profile) != nil
            if brain == .thisMac { useOwnStrut(profile) }
            lookForMemory(reporting: true)
            lookForBridge()
            checkBrain()
            // A pairing link that came while the account was locked.
            if pairing != nil { openAgentSettings() }
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
    /// With a home server, its address always, reachable or not: the memory
    /// tools then say the brain is offline, and Peel's own strut is never
    /// started in its place.
    func lookForMemory(reporting: Bool = false, restarting: Bool = true) {
        guard let profile, let engine, let agent else { return }
        let memory: MemoryServer?
        switch brain {
        case _ where memoryMove?.isRunning == true:
            // Held until the move ends, which looks again.
            memory = nil
        case .homeServer(let server)?:
            memory = server
        case .thisMac?:
            memory = strut?.server
            // Not running yet, or stopped since: started, and here once ready.
            if memory == nil, restarting, let strut { startStrut(strut, reporting: reporting) }
        case nil:
            memory = nil
        }
        guard memory != memoryServer else { return }
        memoryServer = memory
        closeMemory()
        let setup = Self.agentSetup(engine, memory: memory)
        agent.tools = setup.tools
        agent.systemPrompt = setup.systemPrompt()
        stopAutomations()
        // First, so a model disconnected while strut was stopped leaves it before anything runs.
        modelChanged()
        startAutomations(profile, engine: engine)
    }

    // MARK: The brain (docs/peel-brain.md)

    /// Asks the home server how it is (`MemoryServer.health`), for Account › Brain.
    func checkBrain() {
        brainStatus = nil
        guard let server = brain?.homeServer else { return }
        Task {
            let status = await server.health()
            // The setting changed while it was asked.
            guard brain?.homeServer == server else { return }
            brainStatus = status
        }
    }

    /// Keeps `new` as the account's brain and moves the agent to it: with a
    /// home server Peel's own strut is stopped and never started; back on
    /// this Mac it is started again. When this copy of Peel has a strut of
    /// its own the memory goes along, with no option: from this Mac to a
    /// home server it is copied there after the switch, in place of any
    /// there, unless this Mac's is known empty (`moveMemoryToHomeServer`;
    /// "Reconnecting" in `docs/peel-brain.md`); back to this Mac the home server's replaces this Mac's
    /// (`bringMemoryBack`, which switches only once it is here). A reply
    /// under way is checked before the switch is kept, so it never switches
    /// without starting the move.
    func setBrain(_ new: Brain) throws {
        guard let profile else { throw PeelError("Peel's account is not open.") }
        // The move would lose the strut it reads or loads.
        guard memoryMove?.isRunning != true else { throw PeelError("Wait for the memory move to finish.") }
        let left = brain?.homeServer
        let bringing = hasOwnStrut && new == .thisMac && left != nil
        let copying = hasOwnStrut && brain == .thisMac && new != .thisMac && localHoldsMemory != false
        if bringing || copying, agent?.isRunning == true { throw PeelError("Wait for Peel's reply to finish, then switch.") }
        if bringing, let left {
            bringMemoryBack(from: left)
            return
        }
        try use(new, profile)
        if copying { moveMemoryToHomeServer() }
    }

    /// Keeps `new` and moves the agent to it (`setBrain`).
    private func use(_ new: Brain, _ profile: Profile) throws {
        try new.keep(in: profile.brain)
        brain = new
        pairing = nil
        switch new {
        case .homeServer:
            strut?.stop(quietly: true)
            strut = nil
        case .thisMac:
            useOwnStrut(profile)
        }
        lookForMemory(reporting: true)
        lookForBridge()
        // The same server kept again (a new key for the same address) is checked again too.
        checkBrain()
    }

    /// A `peel://brain?…` link (`Brain.pairing`): the home server it names
    /// waits in Account › Brain for the person's yes. False for any other link.
    func openPairingLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "peel" else { return false }
        guard let server = Brain.pairing(url) else {
            notice = "That home server link doesn't work. Copy it again from your home server."
            return true
        }
        pairing = server
        if phase == .ready { openAgentSettings() }
        return true
    }

    /// Asks this Mac's running strut whether its memory holds anything, so
    /// switching to a home server offers to move it (`memory/ontology`'s
    /// counts in use). Unknown (nil) when it is not running.
    func checkLocalMemory() {
        guard brain == .thisMac, let server = strut?.server else { return }
        Task {
            guard let vocabulary = try? await server.run("ontology", [:]) else { return }
            let used = (["entity_types", "predicates"] as [String]).flatMap { vocabulary[$0]?.array ?? [] }
            localHoldsMemory = used.contains { ($0["used"]?.int ?? 0) > 0 }
        }
    }

    /// Copies this Mac's memory to the home server in use, in place of its
    /// own, which strut keeps as a backup there: Peel's own strut started for the move and stopped after,
    /// since a home server never runs it. This Mac's memory stays as it was.
    private func moveMemoryToHomeServer() {
        guard let profile, let home = brain?.homeServer else { return }
        runMemoryMove(.toHomeServer) { [self] progress in
            guard let own = Self.strut(for: profile) else { throw PeelError("This copy of Peel has no memory of its own to move.") }
            // Started only for this, and stopped however it ends (or by
            // `MacAgent.stop` when the account goes): a strut left running
            // in home-server mode would be a second writer.
            macAgent.movingStrut = own
            defer {
                own.stop(quietly: true)
                if macAgent.movingStrut === own { macAgent.movingStrut = nil }
            }
            let local = try await own.start()
            try Task.checkCancellation()
            switch try await MemoryMove.toHomeServer(from: local, folder: BundledStrut.dataFolder(for: profile), to: home,
                                                     progress: progress) {
            case .copied(let moved, let replaced): return .done(.toHomeServer, moved.facts, keptBackup: replaced)
            case .nothingToCopy: return nil
            }
        }
    }

    /// Brings the home server's memory to this Mac in place of this Mac's
    /// own (`MemoryMove.replacingThisMac`), which is kept as a backup: while
    /// the home server was in use its memory was the truth. This Mac is
    /// used once the memory is here, or at once if the home server's holds
    /// nothing; on any failure this Mac's memory and the brain stay as they were.
    private func bringMemoryBack(from home: MemoryServer) {
        guard let profile else { return }
        runMemoryMove(.toThisMac) { [self] progress in
            guard let own = Self.strut(for: profile) else {
                throw PeelError("This copy of Peel has no memory of its own to bring it into.")
            }
            // Started only for this, and stopped however it ends: a strut
            // left running in home-server mode would be a second writer.
            macAgent.movingStrut = own
            defer {
                own.stop(quietly: true)
                if macAgent.movingStrut === own { macAgent.movingStrut = nil }
            }
            var mine: MemoryBackup?
            let brought = try await MemoryMove.replacingThisMac(
                with: home, folder: BundledStrut.memoryFolder(data: BundledStrut.dataFolder(for: profile)),
                stop: { own.stop(quietly: true) }, start: { try await own.start() },
                holding: { held in
                    // A move cut short and settling late never clears a newer one's.
                    if let held { mine = held }
                    if held != nil || macAgent.settingAside == mine { macAgent.settingAside = held }
                }, progress: progress
            )
            own.stop(quietly: true)
            do {
                try use(.thisMac, profile)
            } catch {
                // Still on the home server, so this Mac keeps its own memory.
                try? brought?.backup.restore()
                throw PeelError(PeelError.problem(error) + " This Mac's memory is as it was.")
            }
            guard let brought else { return nil }
            localHoldsMemory = brought.moved.holdsMemory
            return .done(.toThisMac, brought.moved.facts, keptBackup: !brought.backup.isEmpty)
        }
    }

    /// One move at a time, never while the agent is replying; the memory
    /// tools are held until it ends, and how it ended (`move`'s state; nil
    /// for nothing to say) stays in Account › Brain.
    private func runMemoryMove(
        _ direction: MemoryMoveState.Direction,
        _ move: @escaping (_ progress: @escaping @Sendable (MemoryMove.Step) async -> Void) async throws -> MemoryMoveState?
    ) {
        guard memoryMove?.isRunning != true else { return }
        guard agent?.isRunning != true else {
            memoryMove = .failed("Wait for Peel's reply to finish, then move the memory.")
            return
        }
        memoryMove = .running(direction, nil)
        lookForMemory()
        macAgent.moving = Task {
            do {
                let ended = try await move { step in
                    await MainActor.run {
                        if self.memoryMove?.isRunning == true { self.memoryMove = .running(direction, step) }
                    }
                }
                // The account closed while it ran: nothing of it is shown to the next one.
                guard !Task.isCancelled else { return }
                memoryMove = ended
            } catch {
                guard !Task.isCancelled else { return }
                memoryMove = .failed(PeelError.problem(error, couldNot: direction == .toHomeServer
                    ? "copy the memory to the home server" : "bring the memory back"))
            }
            macAgent.moving = nil
            lookForMemory(reporting: true)
        }
    }

    /// Peel's own strut for `profile`, made if there is none, and looked at
    /// again when it starts or stops. A strut that stopped is not started
    /// again from here, only before the next reply: no crash loop.
    func useOwnStrut(_ profile: Profile) {
        if strut == nil { strut = Self.strut(for: profile) }
        strut?.onChange = { [weak self] in
            self?.lookForMemory(restarting: false)
            self?.lookForBridge()
        }
    }

    private func startStrut(_ strut: BundledStrut, reporting: Bool) {
        Task {
            do { _ = try await strut.start() } catch {
                // Not said once the agent has closed (its account locked or
                // forgotten), or a home server took its place while it started.
                if reporting, agent != nil, self.strut === strut { notice = PeelError.problem(error, couldNot: "start the agent's memory") }
            }
        }
    }

    /// The strut `profile`'s agent uses, if this build ships one: the app
    /// account's in Peel's folder; a development profile's only with
    /// `-strut YES` or the bridge's preview on, its data inside the
    /// profile's own folder, so a test account never writes to the real memory.
    static func strut(for profile: Profile) -> BundledStrut? {
        switch profile.kind {
        case .app: BundledStrut(secretKey: profile.strutKey)
        case .development:
            UserDefaults.standard.bool(forKey: "strut") || AgentBridge.isOn
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
        // A move's strut and its state are this account's alone.
        macAgent.stopMove()
        memoryMove = nil
        localHoldsMemory = nil
        stopAutomations()
        automationToken = nil
        agentBridge.stop()
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
                problem = PeelError.problem(error, couldNot: "read this memory")
            }
        }
    }
}

/// A move of memory between this Mac and the home server, for Account › Brain.
enum MemoryMoveState: Equatable {
    enum Direction { case toHomeServer, toThisMac }

    /// Under way, at `step` once the bundled strut is up.
    case running(Direction, MemoryMove.Step?)
    /// Ended, with the facts that arrived, and whether the older memory
    /// where they arrived was kept as a backup (on that machine) to make room.
    case done(Direction, Int, keptBackup: Bool)
    /// Ended without moving anything, or with what arrived not matching; why, as a sentence.
    case failed(String)

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}
