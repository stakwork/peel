import Foundation
import Observation
import PeelCore

/// The proposals Peel shows cards for (`ProposalRecord`, docs/agent-on-strut.md,
/// "Built: proposal cards"), on the Mac (`AppModel.proposals`; the iPhone
/// draws none yet, so it opens no watch): Peel's own strut's, which the
/// bridge brings to the Mac as `approve` device requests and the Mac reads
/// from its strut's record (`readLocal`, kept here by `DeviceActions`
/// through `keep`), and the person's own on each Stadeum workspace's strut,
/// read with the person token Peel holds and decided with it here
/// (`decide`). Each is kept as last read (`Storage.keepProposal`), so a
/// restart draws the cards as they stood before the next read. No one
/// pushes a change, so this polls: the workspaces' pending lists while Peel
/// is in front, every open record after an answer until it is over, and
/// once more when Peel comes to the front or a hand-off to a workspace went
/// through (that is when the workspace is most likely to propose something).
@MainActor @Observable
public final class ProposalWatch {
    /// Every proposal kept, by where it is and its id.
    public private(set) var kept: [ProposalKey: KeptProposal] = [:]
    /// What the last read or decision said that the record does not, one
    /// line a card shows: strut's words on a decision it would not take,
    /// why Peel gave up on one.
    public private(set) var notes: [ProposalKey: String] = [:]
    /// Decisions on a workspace's strut under way, and which way (true: accept).
    public private(set) var deciding: [ProposalKey: Bool] = [:]
    /// The workspaces whose strut did not answer the last read, by peer id.
    public private(set) var unreachable: Set<String> = []
    /// The workspaces whose strut refused the person's token at the last
    /// read, by peer id, with what to do: the pairing renews it.
    public private(set) var refused: [String: String] = [:]
    /// The cards drawn at the end of the agent chat, oldest first: a paired
    /// workspace's open proposals, and those over for less than
    /// `shownAfterOver`, each with what its card shows beside the record.
    public private(set) var orgCards: [OrgCard] = []

    /// How Peel's own strut's record is read, installed by the Mac
    /// (`DeviceCards`); nil on a device with no strut, whose own cards are
    /// then only as last kept.
    @ObservationIgnored public var readLocal: (@Sendable (String) async throws -> ProposalRead)?
    /// The workspaces and the person's actor on them, from the account's
    /// Stadeum pairing (`AppModel`); a test's or the offscreen driver's stand-in.
    @ObservationIgnored public var orgs: @MainActor () -> (peers: [HivePeer], actor: String?) = { ([], nil) }
    /// Whether Peel is in front: the workspaces are listed often then, seldom otherwise.
    @ObservationIgnored var inFront: @MainActor () -> Bool = { true }
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    @ObservationIgnored private var storage: Storage?
    @ObservationIgnored private var byRequest: [String: ProposalKey] = [:]
    /// When each open record is read again by itself; none for one the list covers or that is over.
    @ObservationIgnored private var due: [ProposalKey: Date] = [:]
    /// Reads of a record since its card was answered here, which pace the reads after it.
    @ObservationIgnored private var reads: [ProposalKey: Int] = [:]
    /// Reads of a record that got no answer in a row, for the backoff.
    @ObservationIgnored private var failures: [ProposalKey: Int] = [:]
    /// The writes to the store, off the main actor, each after the one
    /// before (its tail): what is read back is never older than what was
    /// written, and a reopen reads after every write.
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var listedAt = Date.distantPast
    @ObservationIgnored private var listSoon = false
    /// Until when the workspaces are listed often: a hand-off just went through.
    @ObservationIgnored private var burstUntil = Date.distantPast
    /// Workspaces whose strut listed other people's proposals: one from
    /// before strut#404, whose gate refuses a person's decide.
    @ObservationIgnored private var oldStruts: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var nap: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// How often the workspaces' pending lists are read while Peel is in front, and behind.
    static let listEvery: TimeInterval = 45
    static let listEveryBehind: TimeInterval = 300
    /// After a hand-off went through: often, for a while.
    static let listBurst: TimeInterval = 15
    static let burstFor: TimeInterval = 90
    /// An open card not yet answered here: a decision made elsewhere (strut's UI) shows within this.
    static let reReadEvery: TimeInterval = 30
    /// An accepted proposal: its step runs.
    static let runningEvery: TimeInterval = 5
    /// After an answer here, until the bridge's decide lands on the record; then every `reReadAfter`.
    static let answeredSteps: [TimeInterval] = [2, 4, 8, 15, 30]
    static let reReadAfter: TimeInterval = 10
    /// How long a workspace's card stays at the end of the chat once over.
    public static let shownAfterOver: TimeInterval = 10 * 60
    /// How long a workspace's proposal that is over is kept at all.
    static let keptAfterOver: TimeInterval = 7 * 24 * 3600
    /// Reads of a workspace's record with no answer in a row after which Peel gives up on it.
    static let givenUpAfter = 5

    public init() {}

    // MARK: - Open and close

    /// The account opened: what was kept (read after every write still on
    /// its way, so a close and reopen sees the latest), and the watch. A
    /// record kept meanwhile (a card asked as the account opens) is newer
    /// than the store's and stays.
    public func open(_ storage: Storage) async {
        close()
        self.storage = storage
        let generation = generation
        let now = now()
        let cutoff = now.addingTimeInterval(-Self.keptAfterOver)
        let tail = writes
        let loaded = await Task.detached {
            await tail?.value
            try? storage.forgetOrgProposals(endedBefore: cutoff)
            return (try? storage.proposals()) ?? []
        }.value
        guard generation == self.generation, self.storage === storage else { return }
        for proposal in loaded where proposal.source == .local || (proposal.ending?.at ?? now) >= cutoff {
            guard kept[proposal.key] == nil else { continue }
            kept[proposal.key] = proposal
            if let request = proposal.request { byRequest[request] = proposal.key }
            schedule(proposal, at: now)
        }
        listSoon = true
        refreshCards(at: now)
        loop = Task { await run(generation) }
    }

    /// The account closed: nothing kept here (the store has it), nothing read.
    public func close() {
        generation += 1
        loop?.cancel()
        loop = nil
        nap?.cancel()
        nap = nil
        storage = nil
        kept = [:]
        byRequest = [:]
        due = [:]
        reads = [:]
        failures = [:]
        notes = [:]
        deciding = [:]
        unreachable = []
        refused = [:]
        oldStruts = []
        orgCards = []
        listedAt = .distantPast
        listSoon = false
        burstUntil = .distantPast
    }

    // MARK: - What is kept

    /// Keeps `record` as read now: Peel's own strut's, for the device
    /// request whose card it is (`request`, running out at `notAfter`), or a
    /// workspace's. A record read before is replaced (`KeptProposal.updated`);
    /// the request and its expiry stay once given.
    public func keep(_ record: ProposalRecord, source: ProposalSource, request: String? = nil, notAfter: Int64? = nil) {
        let now = now()
        let key = ProposalKey(source: source, id: record.id)
        var proposal = kept[key]?.updated(with: record, at: now)
            ?? KeptProposal(source: source, record: record, request: request, notAfter: notAfter, readAt: now)
        if proposal.request == nil, let request { proposal.request = request }
        if proposal.notAfter == nil, let notAfter { proposal.notAfter = notAfter }
        store(proposal, at: now)
    }

    /// The proposal whose card device request `request` is, as last read.
    public func kept(request: String) -> KeptProposal? {
        byRequest[request].flatMap { kept[$0] }
    }

    /// A workspace by name, for its cards; nil for Peel's own strut.
    public func orgName(_ source: ProposalSource) -> String? {
        guard let id = source.peer else { return nil }
        return peer(id)?.name ?? "@" + HivePeer.name(label: nil, id: id)
    }

    /// The Mac answered a card of Peel's own strut: the bridge tells strut
    /// within seconds, so the record is read soon and often until it moves.
    public func answered(request: String) {
        guard let key = byRequest[request], var proposal = kept[key], !proposal.isOver else { return }
        let now = now()
        proposal.answeredAt = now
        reads[key] = 0
        store(proposal, at: now)
        due[key] = now.addingTimeInterval(Self.answeredSteps[0])
        wake()
    }

    /// Peel came to the front: the workspaces are listed now.
    public func cameToFront() {
        listSoon = true
        wake()
    }

    private func peer(_ id: String) -> HivePeer? {
        orgs().peers.first { $0.id == id }
    }

    /// Keeps `proposal` in memory and, off the main actor, in the store;
    /// sets its next read; and, for a hand-off just gone through, lists the
    /// workspaces often for a while. One read again and the same but for
    /// when is only given its next read.
    private func store(_ proposal: KeptProposal, at now: Date) {
        let key = proposal.key
        let before = kept[key]
        var unchanged = false
        if var same = before {
            same.readAt = proposal.readAt
            unchanged = same == proposal
        }
        if !unchanged { kept[key] = proposal }
        if let request = proposal.request { byRequest[request] = key }
        schedule(proposal, at: now)
        guard !unchanged else { return }
        if proposal.source == .local, proposal.record.isHandOff, proposal.record.status == .applied, before?.record.status != .applied {
            burstUntil = now.addingTimeInterval(Self.burstFor)
            listSoon = true
        }
        write(proposal)
        refreshCards(at: now)
        wake()
    }

    /// Writes `proposal` off the main actor (the engine may hold the
    /// database for a commit), after every write before it.
    private func write(_ proposal: KeptProposal) {
        guard let storage else { return }
        let previous = writes
        writes = Task.detached {
            await previous?.value
            do {
                try storage.keepProposal(proposal)
            } catch {
                Diagnostics.note(error: error)
            }
        }
    }

    /// When `proposal` is read again by itself: soon and often after an
    /// answer here, every few seconds while its step runs, every half
    /// minute while its card waits on this Mac, never once it is over or
    /// its card has run out, nor for a workspace's pending one, which its
    /// list covers.
    private func schedule(_ proposal: KeptProposal, at now: Date) {
        let key = proposal.key
        guard !proposal.isOver, !proposal.isExpired(at: now) else {
            due[key] = nil
            return
        }
        let interval: TimeInterval?
        if proposal.record.status == .accepted {
            interval = Self.runningEvery
        } else if proposal.answeredAt != nil {
            let read = reads[key, default: 0]
            interval = read < Self.answeredSteps.count ? Self.answeredSteps[read] : Self.reReadAfter
        } else if proposal.source == .local {
            interval = Self.reReadEvery
        } else {
            interval = nil
        }
        due[key] = interval.map { now.addingTimeInterval($0) }
    }

    /// Peel is done with `proposal` though strut never said it was final:
    /// gone, not this person's, or never readable. Its card goes as a final one does.
    private func finish(_ proposal: KeptProposal, _ ending: KeptProposal.Ending, at now: Date) {
        var proposal = proposal
        proposal.ending = ending
        store(proposal, at: now)
    }

    private func refreshCards(at now: Date) {
        let paired = orgs().peers
        let cards = kept.values.filter { proposal in
            paired.contains { $0.id == proposal.source.peer }
                && (proposal.ending.map { now.timeIntervalSince($0.at) < Self.shownAfterOver } ?? true)
        }.sorted { ($0.record.createdAt ?? $0.readAt, $0.record.id) < ($1.record.createdAt ?? $1.readAt, $1.record.id) }
            .map { proposal in
                let id = proposal.source.peer ?? ""
                let name = paired.first { $0.id == id }?.name ?? HivePeer.name(label: nil, id: id)
                let silent = unreachable.contains(id) ? "\(name) is not answering; shown as last read." : nil
                return OrgCard(kept: proposal, org: name, deciding: deciding[proposal.key], note: notes[proposal.key] ?? refused[id] ?? silent)
            }
        if cards != orgCards { orgCards = cards }
    }

    // MARK: - Deciding on a workspace

    /// Decides a workspace's proposal as the person, with their token: an
    /// accept runs the step there and then, and the record after is kept.
    /// Decided already (in Stadeum, say): its state as it stands. Not to
    /// be decided yet, not this person's to decide, or a workspace whose
    /// strut is from before a person could: said on the card, nothing else.
    public func decide(_ key: ProposalKey, accept: Bool) async {
        guard let id = key.source.peer, let peer = peer(id), kept[key] != nil, deciding[key] == nil else { return }
        deciding[key] = accept
        if notes[key] != nil { notes[key] = nil }
        refreshCards(at: now())
        let generation = generation
        defer {
            deciding[key] = nil
            refreshCards(at: now())
        }
        let outcome: ProposalDecided
        do {
            outcome = try await peer.decide(key.id, accept: accept)
        } catch {
            guard generation == self.generation else { return }
            notes[key] = "\(peer.name) could not be reached, so nothing was decided. Try again in a moment."
            return
        }
        guard generation == self.generation, let proposal = kept[key] else { return }
        let now = now()
        switch outcome {
        case .decided(let record):
            keep(record, source: key.source)
        case .alreadyDecided(let record?, let words):
            // Still open (it waits on another proposal first): strut's words say why.
            if record.isOpen { notes[key] = words }
            keep(record, source: key.source)
        case .alreadyDecided(nil, _):
            due[key] = now
            wake()
        case .notYours:
            notes[key] = oldStruts.contains(id)
                ? "You can't decide this one here: \(peer.name)'s workspace runs an older strut, which needs an update first."
                : "You can't decide this one here."
        case .invalid(let words):
            notes[key] = "\(peer.name) refused: \(words)"
        case .gone:
            notes[key] = "\(peer.name) no longer has this proposal."
            finish(proposal, .gone(now), at: now)
        }
    }

    // MARK: - The watch

    private func run(_ generation: Int) async {
        while !Task.isCancelled, generation == self.generation {
            await tick()
            guard !Task.isCancelled, generation == self.generation else { return }
            let delay = nextDelay()
            let nap = Task<Void, Never> { try? await Task.sleep(for: .seconds(delay)) }
            self.nap = nap
            await nap.value
            if self.nap == nap { self.nap = nil }
        }
    }

    /// The watch goes on now rather than after its nap.
    private func wake() {
        nap?.cancel()
    }

    /// Seconds until something is due: a list, or a record's read; an hour
    /// at most, a second at least.
    private func nextDelay() -> TimeInterval {
        let now = now()
        var next = due.values.min() ?? .distantFuture
        if !orgs().peers.isEmpty { next = min(next, listedAt.addingTimeInterval(listInterval(at: now))) }
        if listSoon { next = now }
        return min(max(next.timeIntervalSince(now), 1), 3600)
    }

    private func listInterval(at now: Date) -> TimeInterval {
        if now < burstUntil { return Self.listBurst }
        return inFront() ? Self.listEvery : Self.listEveryBehind
    }

    /// One pass: the workspaces' pending lists when due, then every record
    /// due a read. A read is claimed before it starts, so two passes never
    /// read one record at once.
    func tick() async {
        let generation = generation
        var now = now()
        let (peers, actor) = orgs()
        // With no workspace there is no list to read: nothing to do soon.
        if peers.isEmpty || actor == nil { listSoon = false }
        if !peers.isEmpty, let actor, listSoon || now.timeIntervalSince(listedAt) >= listInterval(at: now) {
            listSoon = false
            listedAt = now
            await listPending(on: peers, actor: actor)
            guard generation == self.generation else { return }
            now = self.now()
        }
        for key in due.filter({ $0.value <= now }).keys.sorted(by: { $0.id < $1.id }) {
            due[key] = nil
            // A card whose time ran out meanwhile is over here, whatever strut would say.
            guard let proposal = kept[key], !proposal.isExpired(at: now) else { continue }
            await reRead(key)
            guard generation == self.generation else { return }
        }
        refreshCards(at: self.now())
    }

    /// Each workspace's pending proposals of the person, read at once; one
    /// that does not answer keeps what was shown, its records' own reads
    /// put off, and is asked again next time; one that refuses the token
    /// says so. A pending one no longer listed was decided elsewhere: read
    /// by itself now.
    private func listPending(on peers: [HivePeer], actor: String) async {
        let generation = generation
        let results = await withTaskGroup(of: (String, Result<(mine: [ProposalRecord], others: Int), Error>).self) { group in
            for peer in peers {
                group.addTask { (peer.id, await Result { try await peer.pendingProposals(actor: actor) }) }
            }
            var results: [(String, Result<(mine: [ProposalRecord], others: Int), Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard generation == self.generation else { return }
        let now = now()
        for (peer, result) in results {
            let listed: (mine: [ProposalRecord], others: Int)
            switch result {
            case .success(let read):
                listed = read
                if unreachable.contains(peer) { unreachable.remove(peer) }
                if refused[peer] != nil { refused[peer] = nil }
            case .failure(let refusal as StrutRefusal) where refusal.isAuth:
                refused[peer] = "\(refusal.name) no longer takes this device's token; Stadeum renews it, or connect again."
                if unreachable.contains(peer) { unreachable.remove(peer) }
                continue
            case .failure:
                unreachable.insert(peer)
                // Its records' own reads would wait on the same silence: put off.
                for proposal in kept.values where proposal.source == .org(peer) && due[proposal.key] != nil {
                    due[proposal.key] = now.addingTimeInterval(60)
                }
                continue
            }
            if listed.others > 0 { oldStruts.insert(peer) } else { oldStruts.remove(peer) }
            var ids: Set<String> = []
            for record in listed.mine {
                ids.insert(record.id)
                keep(record, source: .org(peer))
            }
            for proposal in kept.values where proposal.source == .org(peer) && !proposal.isOver && !ids.contains(proposal.record.id) {
                due[proposal.key] = now
            }
        }
    }

    /// Reads one record again: by Peel's own strut, or by the workspace's
    /// with the person's token. Not answered: what is shown stays, and the
    /// next try waits longer; a workspace's that never answers is given up
    /// on. Gone, or not this person's: said, and over.
    private func reRead(_ key: ProposalKey) async {
        guard kept[key] != nil else { return }
        let generation = generation
        var read: ProposalRead?
        var org: HivePeer?
        do {
            switch key.source {
            case .local:
                guard let readLocal else { return }
                read = try await readLocal(key.id)
            case .org(let id):
                guard let peer = peer(id) else { return }
                org = peer
                read = try await peer.proposal(key.id)
            }
        } catch {
            read = nil
        }
        guard generation == self.generation, let current = kept[key] else { return }
        let now = now()
        reads[key, default: 0] += 1
        switch read {
        case .record(let record)?:
            if let org, unreachable.contains(org.id) { unreachable.remove(org.id) }
            failures[key] = nil
            if notes[key] != nil { notes[key] = nil }
            keep(record, source: key.source)
        case .gone?:
            notes[key] = "\(org?.name ?? "strut") no longer has this proposal."
            finish(current, .gone(now), at: now)
        case .forbidden?:
            notes[key] = "You can't see this one here."
            finish(current, .forbidden(now), at: now)
        case nil:
            let failed = failures[key, default: 0] + 1
            failures[key] = failed
            if let org {
                unreachable.insert(org.id)
                // A workspace's record its list no longer shows and that never reads (a shape this Peel does not know).
                if failed >= Self.givenUpAfter {
                    notes[key] = "\(org.name)'s record of this could not be read."
                    finish(current, .unreadable(now), at: now)
                    return
                }
            }
            due[key] = now.addingTimeInterval(min(60, 5 * pow(2, Double(failed - 1))))
        }
    }
}

/// One workspace's proposal as its card at the end of the agent chat
/// draws it: the record as kept, the workspace by name, whether it is
/// being decided (and which way), and the one line the record does not say.
public struct OrgCard: Equatable, Sendable {
    public let kept: KeptProposal
    public let org: String
    public let deciding: Bool?
    public let note: String?

    public init(kept: KeptProposal, org: String, deciding: Bool? = nil, note: String? = nil) {
        self.kept = kept
        self.org = org
        self.deciding = deciding
        self.note = note
    }

    public var key: ProposalKey { kept.key }
}
