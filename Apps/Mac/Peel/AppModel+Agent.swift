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
    /// The person's Hive workspaces, paired as peers (`AppModel+Hive`).
    let hive = HiveState()

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
    /// the memory: the account's home server, or the strut Peel ships,
    /// started here if it is not running (`strut(for:)`), with the agent's
    /// bridge beside it.
    func openAgent(_ profile: Profile, engine: Engine) {
        do {
            let store = try SQLiteAgentStore.open(for: profile, storage: engine.storage)
            do {
                brain = try Brain.kept(in: profile.brain)
            } catch {
                // Not taken for "this Mac": no strut is started until it is set again.
                brain = nil
                notice = PeelError.noted(error, couldNot: "read the agent's brain")
            }
            let agent = AgentSession(store: store, credentials: KeptCredential(item: profile.agentCredential))
            agent.credentialChanged = { [weak self] in self?.modelChanged() }
            self.agent = agent
            macAgent.hasOwnStrut = Self.strut(for: profile) != nil
            if brain == .thisMac { useOwnStrut(profile) }
            openHive(profile)
            lookForMemory(reporting: true)
            lookForBridge()
            checkBrain()
            // A pairing link that came while the account was locked.
            if pairing != nil { openAccount(.brain) }
        } catch {
            notice = PeelError.noted(error, couldNot: "open the agent chat")
        }
    }

    /// Gives the open agent Peel's strut while it is running, or takes it
    /// away once it is not: its memory, model and automations. Looked at when
    /// the agent opens, when the strut starts or stops, and on Set up, which
    /// starts it again if it stopped (its port may now be anyone's, so the
    /// key is never sent to it). A failed start is said when `reporting`.
    /// With a home server, its address always, reachable or not: the memory
    /// tools then say the brain is offline, and Peel's own strut is never
    /// started in its place.
    func lookForMemory(reporting: Bool = false, restarting: Bool = true) {
        guard agent != nil else { return }
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
        automations = AutomationsState()
        modelChanged()
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
    /// (`bringMemoryBack`, which switches only once it is here).
    func setBrain(_ new: Brain) throws {
        guard let profile else { throw PeelError("Peel's account is not open.") }
        // The move would lose the strut it reads or loads.
        guard memoryMove?.isRunning != true else { throw PeelError("Wait for the memory move to finish.") }
        let left = brain?.homeServer
        let bringing = hasOwnStrut && new == .thisMac && left != nil
        let copying = hasOwnStrut && brain == .thisMac && new != .thisMac && localHoldsMemory != false
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
            // The agent's bridge runs only here: this Mac answers its requests
            // again once it does (`startBridge`).
            let engine = engine
            Task { try? await engine?.setDeviceAgent(nil) }
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
        if phase == .ready { openAccount(.brain) }
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
                throw PeelError(PeelError.noted(error) + " This Mac's memory is as it was.")
            }
            guard let brought else { return nil }
            localHoldsMemory = brought.moved.holdsMemory
            return .done(.toThisMac, brought.moved.facts, keptBackup: !brought.backup.isEmpty)
        }
    }

    /// One move at a time; the memory is held from the agent until it ends, and how it ended (`move`'s state; nil
    /// for nothing to say) stays in Account › Brain.
    private func runMemoryMove(
        _ direction: MemoryMoveState.Direction,
        _ move: @escaping (_ progress: @escaping @Sendable (MemoryMove.Step) async -> Void) async throws -> MemoryMoveState?
    ) {
        guard memoryMove?.isRunning != true else { return }
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
                memoryMove = .failed(PeelError.noted(error, couldNot: direction == .toHomeServer
                    ? "copy the memory to the home server" : "bring the memory back"))
            }
            macAgent.moving = nil
            lookForMemory(reporting: true)
        }
    }

    /// Peel's own strut for `profile`, made if there is none, and looked at
    /// again when it starts or stops. A strut that stopped is not started
    /// again from here, only by the person's Set up or Try again: no crash loop.
    func useOwnStrut(_ profile: Profile) {
        if strut == nil { strut = Self.strut(for: profile) }
        // Whose orgs it speaks for, kept across a switch of brain.
        strut?.person = hive.link?.actor
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
                // forgotten), or a home server took its place while it started.
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
        // A move's strut and its state are this account's alone.
        macAgent.stopMove()
        memoryMove = nil
        localHoldsMemory = nil
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
