import Foundation
import PeelCore

/// Jamie in Sphinx tribes (docs/hive-tribes.md): a tribe its owner linked
/// to one of their Stadeum orgs, where `@jamie` is a turn of that org's
/// assistant, run as the person asking when the tribe tells Jamie who is
/// speaking and Stadeum knows them, else as the owner; or added on one of
/// the boxes Peel is linked to, whose own Jamie answers there in the same
/// way, as people that box knows ("From a box"). The links are `Stadeum`'s
/// and `Boxes`'; this is what the account does around them.
extension AppModel {
    /// What a tribe's Jamie row offers and shows picked: Stadeum's orgs
    /// while it is connected, and each box Peel is linked to.
    public var jamieChoices: JamieChoices {
        JamieChoices(orgs: stadeum.jamieOrgs, boxes: boxes.links, places: boxes.places,
                     failed: Set(boxes.placesProblems.keys.filter { boxes.places[$0] == nil }))
    }

    /// Why a source of a tribe's Jamie row has not said: Stadeum's read
    /// that failed (the row waits for it), else a box's (left out of the
    /// row, which says so). Nil when every source has said or is being asked.
    public var jamieProblem: String? {
        if let orgs = stadeum.jamieOrgs, orgs.links == nil, let problem = stadeum.jamieProblem { return problem }
        return boxes.links.lazy.compactMap { box in self.boxes.places[box.url] == nil ? self.boxes.placesProblems[box.url] : nil }.first
    }

    /// The box a tribe's Jamie row is still asking, by its host, once
    /// Stadeum has said; nil while Stadeum is being asked.
    public var jamieAskingBox: String? {
        guard stadeum.jamieOrgs.map({ $0.links != nil }) ?? true else { return nil }
        return boxes.links.first { boxes.places[$0.url] == nil && boxes.placesProblems[$0.url] == nil }?.host
    }

    /// Reads again what every source says of Jamie: Hive while Stadeum is
    /// connected, and each box.
    public func readJamies() async {
        async let read: Void = boxes.readPlaces()
        if stadeum.status == .connected { await stadeum.readJamieLinks() }
        await read
    }

    /// Puts Jamie in `tribe` from `source`, or with `.noJamie` takes it out,
    /// as `JamieChoices.plan` says: the new one first, so a refusal
    /// (someone else's link, a box not ready) leaves the old one answering,
    /// then every other source that has it, as moving between two orgs
    /// does. Adding marks Jamie to know who is speaking there once it is in
    /// (`markJamie`): part of the link, never a second step. Removing takes
    /// the mark off once the source has removed it (a refused removal
    /// leaves Jamie linked and marked), best effort and without waiting on
    /// the tribes server, which drops it with the member anyway once Jamie
    /// leaves; this device then no longer counts it settled
    /// (`Engine.markSendersOnce`). A throw is the source's refusal; a
    /// `JamieStillIn` is an old one that would not go after a new one came.
    public func setJamie(_ source: JamieSource, for tribe: Tribe) async throws {
        let choices = jamieChoices
        guard let plan = choices.plan(source, in: tribe.pubkey) else {
            throw PeelError(String(localized: "Peel is still asking where Jamie is.", table: "Shared"))
        }
        if let add = plan.add, let jamie = try await addJamie(add, to: tribe, choices) {
            markJamie(jamie, in: tribe.pubkey)
        }
        for old in plan.remove {
            do {
                if let unlinked = try await removeJamie(old, from: tribe, choices), let engine {
                    try? await engine.stopShowingSenders(unlinked, in: tribe.pubkey)
                }
            } catch where source != .noJamie {
                throw JamieStillIn(name: choices.name(of: old), error: error)
            }
        }
    }

    /// Adds Jamie to `tribe` from an org or a box: its Jamie's key, nil
    /// when the account closed meanwhile.
    private func addJamie(_ source: JamieSource, to tribe: Tribe, _ choices: JamieChoices) async throws -> String? {
        switch source {
        case .noJamie:
            return nil
        case .org(let id):
            guard let peer = stadeum.live.first(where: { $0.id == id }) else {
                throw PeelError(String(localized: "Connect Hive to add Jamie from \(choices.name(of: source)).", table: "Shared"))
            }
            try await stadeum.setJamie(peer, for: tribe)
            return stadeum.jamieLinks?.jamie.pubkey
        case .box(let url):
            guard let box = choices.box(url) else {
                throw PeelError(String(localized: "Peel is no longer linked to \(choices.name(of: source)).", table: "Shared"))
            }
            return try await boxes.addJamie(to: tribe, from: box)
        }
    }

    /// Takes Jamie from `source` out of `tribe`: its key when it was this
    /// person's to take out, the member whose mark goes with it.
    private func removeJamie(_ source: JamieSource, from tribe: Tribe, _ choices: JamieChoices) async throws -> String? {
        switch source {
        case .noJamie:
            return nil
        case .org:
            return try await stadeum.setJamie(nil, for: tribe)
        case .box(let url):
            guard let box = choices.box(url) else { return nil }
            return try await boxes.removeJamie(from: tribe.pubkey, on: box)
        }
    }

    /// The Sphinx key of the Jamie `tribe`'s row shows picked; nil with
    /// none, or before its source has said.
    func pickedJamie(in tribe: String) -> String? {
        let choices = jamieChoices
        return choices.pick(of: tribe).flatMap(choices.jamie(of:))
    }

    /// What a tribe's Jamie row says when Jamie is in it from more than one
    /// source (a move whose old one would not go, or both devices at once):
    /// each answers. Nil otherwise.
    public func jamieTwice(in tribe: String) -> String? {
        let choices = jamieChoices
        guard let linked = choices.linked(tribe), linked.count > 1 else { return nil }
        let names = linked.map(choices.name(of:)).formatted(.list(type: .and))
        return String(localized: "Jamie is in this tribe from \(names), and each answers. Pick one.", table: "Shared")
    }

    /// Whether Jamie knows who is speaking in `tribe` (`TribeMember.seesSenders`),
    /// as its owner's member list last said; nil while the tribe has no
    /// Jamie of the person's, or the list has no Jamie in it, confirmed
    /// (not joined yet, or not read).
    public func jamieSeesSenders(in tribe: String) -> Bool? {
        guard let jamie = pickedJamie(in: tribe), let member = knownMembers[tribe]?.member(jamie), !member.pending
        else { return nil }
        return member.seesSenders
    }

    /// The owner's switch in a tribe's Jamie row: Jamie knows who is
    /// speaking in `tribe`, or not. A tribes server that does not answer is
    /// said in the row (`jamieMarkNotes`), the switch as it was; a throw is
    /// anything else that went wrong.
    public func setJamieSeesSenders(_ on: Bool, in tribe: String) async throws {
        guard let jamie = pickedJamie(in: tribe) else { throw PeelError(String(localized: "Jamie isn't in this tribe.", table: "Shared")) }
        do {
            knownMembers[tribe] = try await signedIn().showSenders(jamie, in: tribe, on: on)
            jamieMarkNotes[tribe] = nil
        } catch Engine.Failure.sendersNotShown {
            jamieMarkNotes[tribe] = Self.sendersNotShown
        }
    }

    /// What a tribe's Jamie row says when its tribes server does not answer
    /// the mark: one from before it does not know it. The link stands.
    static var sendersNotShown: String { String(localized: "This tribe's server can't tell Jamie who is speaking yet, so everyone here asks with your access.", table: "Shared") }

    /// As the account opens with a pairing (`Stadeum.opened`) and on each
    /// connection, only while connected (the lists need it), one at a time
    /// per pairing, until a sweep has read every list this run of Peel
    /// (`JamieSweep`): Jamie marked to know who is speaking
    /// in each tribe this person linked and owns that this device has not
    /// settled (`Engine.markSendersOnce`), which marks the tribes linked
    /// before Peel marked at linking, the first time this build opens. One
    /// whose server did not answer is said in its Jamie row and asked again
    /// at the next launch. Hive is asked which tribes are linked only when
    /// the account owns one.
    func markLinkedJamies() {
        guard let engine, let credential = stadeum.link?.credential, !stadeum.revoked else { return }
        let connected = connection == .connected
        Task {
            guard let sweep = await jamieSweep.run(
                on: engine, pairing: credential, connected: connected,
                owns: { (try? engine.storage.tribes())?.contains(where: self.offersJamie(in:)) == true },
                links: { await self.stadeum.readJamieLinks(ifOlderThan: 60) }
            ), self.engine === engine else { return }
            for (tribe, members) in sweep.members { knownMembers[tribe] = members }
            for tribe in sweep.silent { jamieMarkNotes[tribe] = Self.sendersNotShown }
        }
    }

    /// Marks `jamie` (its key) in `tribe` to know who is speaking once the tribes server
    /// lists it in (`Engine.showSendersOnceConfirmed`): Jamie joins a public
    /// tribe by itself a few seconds after the link, and a private one once
    /// approved (`checkJamie`). The list is asked for a minute at most, one
    /// look at a time per tribe. A tribes server that does not answer the
    /// mark cannot do it yet: said in the Jamie row (`jamieMarkNotes`); the
    /// link stands.
    func markJamie(_ jamie: String, in tribe: String) {
        let marking = "\(tribe.lowercased()) \(jamie)"
        guard let engine, tribes[tribe]?.canManage == true, jamieApprovals.marking.insert(marking).inserted else { return }
        Task {
            defer { jamieApprovals.marking.remove(marking) }
            do {
                guard let members = try await engine.showSendersOnceConfirmed(jamie, in: tribe, tries: 12, every: .seconds(5)),
                      self.engine === engine else { return }
                knownMembers[tribe] = members
                jamieMarkNotes[tribe] = nil
            } catch Engine.Failure.sendersNotShown {
                if self.engine === engine { jamieMarkNotes[tribe] = Self.sendersNotShown }
            } catch {
                if self.engine === engine { jamieMarkNotes[tribe] = PeelError.noted(error, couldNot: String(localized: "tell Jamie who is speaking", table: "Shared")) }
            }
        }
    }

    /// Whether `tribe`'s details offer its Jamie: to its owner, still in
    /// it, on a tribes server Hive can name for Jamie to join.
    public func offersJamie(in tribe: Tribe) -> Bool {
        tribe.canManage && tribe.host != nil
    }

    /// Jamie in `tribe`, or asking to join it, for an org the person did
    /// not pick: someone else linked the tribe (Hive gives a tribe to
    /// whoever links it first), and that org reads what is said there. In
    /// the words a tribe's Jamie row and its notice show; nil otherwise.
    public func othersJamie(in tribe: String) -> String? {
        guard stadeum.jamiePick(of: tribe) == "", let jamie = stadeum.jamieLinks?.jamie,
              let member = knownMembers[tribe]?.member(jamie.pubkey) else { return nil }
        return member.pending
            ? String(localized: "\(jamie.alias) is asking to join for an org you didn't pick: someone else linked this tribe. Approving it sends what's said here to that org.", table: "Shared")
            : String(localized: "\(jamie.alias) is in this tribe for an org you didn't pick: someone else linked it, and that org reads what's said here. Remove it in Members.", table: "Shared")
    }

    /// A request to join a tribe this account owns: approved unasked when
    /// the person linked the tribe to an org or added it on a box and the
    /// request is that Jamie's (docs/hive-tribes.md, "Approving Jamie"); Jamie asking for someone
    /// else's link is said above the composer instead. The request names
    /// only an alias, so the tribes server's list of who waits is asked
    /// for Jamie's key (`Engine.approveWaitingMember`). A request that
    /// arrives while a check is under way is looked at again once it ends.
    func approveJamie(asking message: Message) {
        guard message.type == MessageType.memberRequest, !message.fromMe, !message.deleted,
              tribes[message.chat]?.canManage == true, stadeum.link != nil || !boxes.links.isEmpty else { return }
        let tribe = message.chat
        guard jamieApprovals.checking.insert(tribe).inserted else {
            jamieApprovals.again.insert(tribe)
            return
        }
        Task {
            repeat {
                jamieApprovals.again.remove(tribe)
                await checkJamie(in: tribe)
            } while jamieApprovals.again.contains(tribe)
            jamieApprovals.checking.remove(tribe)
        }
    }

    /// One look at `tribe`'s waiting members for the Jamies this person
    /// put there (`jamies(in:)`). The server may list a request a moment
    /// after it arrives, so each is asked for up to three times. Each
    /// approval goes once a session: another costs the tribe's price again.
    private func checkJamie(in tribe: String) async {
        for jamie in await jamies(in: tribe) { await approve(jamie, in: tribe) }
        // Hive's Jamie for someone else's link is never approved here: said, for the owner to decide.
        guard stadeum.jamiePick(of: tribe) == "" else { return }
        _ = try? await tribeMembers(tribe)
        if let warning = othersJamie(in: tribe) { conversationNotices[tribe] = warning }
    }

    /// The Jamies this person put in `tribe`: Hive's when Stadeum links it
    /// to one of their orgs (read again unless read in the last minute, and
    /// again when it does not name the tribe: linked on the other device
    /// just now), and each box's added from this device this session
    /// (`Boxes.jamiesAdded`), never one a box's own list names.
    private func jamies(in tribe: String) async -> [JamieAccount] {
        let key = tribe.lowercased()
        var jamies: [JamieAccount] = []
        if stadeum.link != nil {
            var links = await stadeum.readJamieLinks(ifOlderThan: 60)
            if let cached = links, !cached.tribes.contains(where: { $0.pubkey == key }) {
                links = await stadeum.readJamieLinks()
            }
            if let links, links.tribes.contains(where: { $0.pubkey == key }) { jamies.append(links.jamie) }
        }
        return jamies + boxes.jamiesAdded(in: tribe).map { JamieAccount(pubkey: $0, alias: "Jamie") }
    }

    /// Approves `jamie`'s waiting request to join `tribe`, found by its key
    /// (`Engine.approveWaitingMember`), then marks it to know who is speaking.
    private func approve(_ jamie: JamieAccount, in tribe: String) async {
        let approval = "\(tribe.lowercased()) \(jamie.pubkey)"
        guard !jamieApprovals.approved.contains(approval) else { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            guard let engine, tribes[tribe]?.canManage == true else { return }
            do {
                if try await engine.approveWaitingMember(jamie.pubkey, in: tribe) {
                    jamieApprovals.approved.insert(approval)
                    // In now, or once the server has the approval: marked to know who is speaking.
                    markJamie(jamie.pubkey, in: tribe)
                    return
                }
            } catch Engine.Failure.alreadyAnswered {
                return
            } catch {
                // Still in Members to approve by hand.
                conversationNotices[tribe] = PeelError.noted(error, couldNot: String(localized: "approve \(jamie.alias)", table: "Shared"))
                return
            }
        }
    }
}

/// An old Jamie that would not go after a move brought the new one
/// (`AppModel.setJamie`): both answer in the tribe until it does.
public struct JamieStillIn: Error {
    /// The old source, as the person reads it.
    public let name: String
    public let error: any Error
}

/// What `AppModel.approveJamie` keeps for the session, by tribe.
struct JamieApprovals {
    /// Tribes a check is under way for.
    var checking: Set<String> = []
    /// Tribes a request arrived for during their check: looked at again.
    var again: Set<String> = []
    /// Approvals sent, as "<tribe> <Jamie's key>".
    var approved: Set<String> = []
    /// Marks under way (`markJamie`), as "<tribe> <Jamie's key>".
    var marking: Set<String> = []
}

/// The sweep for the tribes an older Peel linked (`AppModel.markLinkedJamies`),
/// as the account opens and on each connection: it runs only while
/// connected (the tribes server's lists need the connection), one at a
/// time per pairing, and until one has read every list this run of Peel;
/// a sweep that could not read one (no connection yet, a slow server)
/// records nothing and leaves it for the next.
@MainActor
final class JamieSweep {
    /// The pairings (by credential) whose sweep read every list, and those under way.
    private var swept: Set<String> = []
    private var sweeping: Set<String> = []

    /// One sweep for `pairing` on `engine` (`Engine.markSendersOnce`), with
    /// Hive's links (`links`), read only when the account `owns` a tribe
    /// Jamie can be in. Nil when it did not run, or read no links.
    func run(
        on engine: Engine, pairing: String, connected: Bool, owns: () -> Bool, links: () async -> JamieLinks?
    ) async -> Engine.SendersSweep? {
        guard connected, !swept.contains(pairing), sweeping.insert(pairing).inserted else { return nil }
        defer { sweeping.remove(pairing) }
        guard owns() else {
            swept.insert(pairing)
            return nil
        }
        guard let links = await links() else { return nil }
        let sweep = await engine.markSendersOnce(links.jamie.pubkey, in: links.tribes.map(\.pubkey))
        if sweep.complete { swept.insert(pairing) }
        return sweep
    }
}
