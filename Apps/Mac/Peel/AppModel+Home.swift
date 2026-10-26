import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// A move of Peel Home between this Mac and a home server
/// (docs/always-on.md), for Account › Brain: under way, or how it ended.
enum HomeMoveState: Equatable {
    enum Direction { case out, back }

    case running(Direction, PeelHomeMove.Step)
    case ended(PeelHomeMove.Outcome)

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

extension AppModel {
    var homeLink: HomeLink? {
        get { macAgent.homeLink }
        set { macAgent.homeLink = newValue }
    }

    var homeMove: HomeMoveState? {
        get { macAgent.homeMove }
        set { macAgent.homeMove = newValue }
    }

    /// A `peel://home-setup?…` link (`HomeLink`): it waits in Account ›
    /// Brain for the person's yes, a move there or back by where Peel Home is.
    func openHomeLink(_ link: HomeLink) {
        homeLink = link
        if phase == .ready { openAccount(.brain) }
    }

    /// Why Peel Home can't move from where it is now, in words; nil when it can.
    var homeMoveBlocker: String? {
        if homeMove?.isRunning == true { return "Peel Home is moving." }
        if let link = homeLink, let home = brain?.moved, let refusal = PeelHomeMove.refusal(link, from: home) { return refusal }
        if memoryMove?.isRunning == true { return "Wait for the memory move to finish." }
        switch brain {
        case .moved?: return nil
        case .thisMac?:
            guard hasOwnStrut else {
                return profile?.kind == .development
                    ? "This development profile runs Peel Home only when Peel is started with -strut YES."
                    : "This copy of Peel has no Peel Home of its own to move."
            }
            guard agentBridge.status == .running else { return "Set up your assistant first: Peel Home moves with it." }
            return nil
        case .homeServer?, nil:
            return "Peel Home moves from this Mac. Choose This Mac above first."
        }
    }

    /// The person's yes to the waiting link: out to the box while Peel Home
    /// is here, back from it once it has moved.
    func moveHome() {
        guard let link = homeLink, homeMoveBlocker == nil else { return }
        homeLink = nil
        if let home = brain?.moved {
            runHomeMove(.back) { move, progress in await move.back(link, from: home, progress: progress) }
        } else {
            runHomeMove(.out, needsIdentity: true) { move, progress in await move.out(link, progress: progress) }
        }
    }

    /// Cancel on a move under way: its strut command is stopped. The mark
    /// stays as far as it got, so this Mac's strut and bridge stay stopped
    /// once it was kept; Account › Brain then offers what is left.
    func cancelHomeMove() {
        macAgent.homeMoving?.cancel()
        macAgent.homeMoving = nil
        homeMove = nil
    }

    /// Pings the agent again after a move it had not answered.
    func pingHomeAgain() {
        guard let home = brain?.moved else { return }
        runHomeMove(.out) { move, progress in await move.pingAgain(home, progress: progress) }
    }

    /// "Use this Mac's copy": the folders kept at the move put back and
    /// started, for a home server that is gone.
    func useThisMacCopy() throws {
        guard let home = brain?.moved, homeMove?.isRunning != true, let profile else { return }
        try homeMove(for: profile, account: nil).useThisMacCopy(home)
        homeMove = nil
        // A send-back link waiting would read as a move out now.
        homeLink = nil
    }

    /// The move for `profile`: its strut's `move` and its folders, with the
    /// bridge's identity from the agent's `account`. Throws with no strut of
    /// Peel's own to run it.
    private func homeMove(for profile: Profile, account: AgentAccount?) throws -> PeelHomeMove {
        guard let mover = Self.strut(for: profile)?.mover else { throw PeelError("This copy of Peel has no Peel Home of its own to move.") }
        var parts = HomeParts(strut: BundledStrut.dataFolder(for: profile), bridge: BundledBridge.dataFolder(for: profile),
                              secretKey: profile.strutKey)
        if let account {
            parts.identity = BundledBridge.identity(account: account, alias: agent?.name ?? "Agent", actor: stadeum.link?.actor)
        }
        return PeelHomeMove(mover: mover, local: HomeLocal(model: self, profile: profile), parts: parts)
    }

    /// One move at a time; how it ended stays in Account › Brain.
    private func runHomeMove(
        _ direction: HomeMoveState.Direction, needsIdentity: Bool = false,
        _ run: @escaping @MainActor (PeelHomeMove, _ progress: @escaping (PeelHomeMove.Step) -> Void) async -> PeelHomeMove.Outcome
    ) {
        guard let profile, homeMove?.isRunning != true else { return }
        let engine = engine
        homeMove = .running(direction, .checking)
        macAgent.homeMoving = Task {
            // Only a move out carries the bridge's identity.
            let account = needsIdentity ? try? await engine?.agentAccount() : nil
            let ended: PeelHomeMove.Outcome
            do {
                ended = await run(try homeMove(for: profile, account: account)) { [weak self] step in
                    if self?.homeMove?.isRunning == true { self?.homeMove = .running(direction, step) }
                }
            } catch {
                ended = .unchanged(PeelError.noted(error))
            }
            // The account closed while it ran: what it kept is read again when it opens.
            guard !Task.isCancelled else { return }
            homeMove = .ended(ended)
            macAgent.homeMoving = nil
        }
    }

    /// Asks the agent in its DM to answer, and waits up to `timeout` for
    /// its reply to that message (as `AgentDM` reads an answer): with this
    /// Mac's bridge stopped only the home server's can send one, and back
    /// here only this Mac's.
    func pingAgent(_ text: String, within timeout: Duration = .seconds(180)) async -> Bool {
        // `sendText` gives the sent message's tag; a reply names its uuid.
        guard let engine, let agent = agentContact,
              let tag = try? await engine.sendText(text, to: agent),
              let asked = try? engine.storage.message(tag: tag)?.uuid else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await timeline in engine.storage.timeline(in: agent, limit: 20)
                    where AgentDM.answers(asked, in: timeline.messages) {
                        return true
                    }
                } catch {}
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let answered = await group.next() ?? false
            group.cancelAll()
            return answered
        }
    }
}

/// The app's side of a move (`PeelHomeLocal`): `Profile.brain`, Peel's own
/// strut and bridge, and the agent's DM.
@MainActor
private final class HomeLocal: PeelHomeLocal {
    private weak var model: AppModel?
    let profile: Profile

    init(model: AppModel, profile: Profile) {
        self.model = model
        self.profile = profile
    }

    /// The model while its open account is still the one the move is for.
    private var open: AppModel? {
        guard let model, model.agent != nil, model.profile?.directory == profile.directory else { return nil }
        return model
    }

    func keep(_ brain: Brain) throws {
        try brain.keep(in: profile.brain)
        open?.brain = brain
    }

    func stopHome() async -> BundledBridge.Server? {
        guard let model = open else { return nil }
        let running = model.agentBridge.bridge?.server
        model.agentBridge.stop()
        model.strut?.stop(quietly: true)
        model.strut = nil
        // Moved: nothing here starts them again.
        model.lookForMemory()
        model.lookForBridge()
        return running
    }

    func startHome() {
        guard let model = open else { return }
        model.useOwnStrut(profile)
        model.lookForMemory(reporting: true)
        model.lookForBridge()
    }

    func homeStarted() async -> Bool {
        guard let strut = open?.strut else { return false }
        return (try? await strut.start()) != nil
    }

    func pingAgent() async -> Bool {
        guard let model = open else { return false }
        let here = model.brain == .thisMac
        return await model.pingAgent(here
            ? "Peel Home is back on this Mac. Reply so Peel knows you're here."
            : "Peel Home moved to your home server. Reply so Peel knows you're there.")
    }
}
