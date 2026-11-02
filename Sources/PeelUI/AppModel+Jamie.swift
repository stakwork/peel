import Foundation
import PeelCore

/// Jamie in Sphinx tribes (docs/hive-tribes.md): a tribe its owner linked
/// to one of their Stadeum orgs, where `@jamie` is a turn of that org's
/// assistant, run as the person asking when the tribe tells Jamie who is
/// speaking and Stadeum knows them, else as the owner. The links are
/// `Stadeum`'s; this is what the account does around them.
extension AppModel {
    /// Links `tribe` to `peer`'s org, or with nil unlinks it
    /// (`Stadeum.setJamie`). Linking marks Jamie to know who is speaking
    /// there once it is in (`markJamie`): part of the link, never a second
    /// step. Unlinking takes the mark off once Hive has unlinked it (a
    /// refused unlink leaves Jamie linked and marked), best effort and
    /// without waiting on the tribes server, which drops it with the member
    /// anyway once Jamie leaves; this device then no longer counts it
    /// settled (`Engine.markSendersOnce`). A throw is Hive's refusal.
    public func setJamie(_ peer: HivePeer?, for tribe: Tribe) async throws {
        let unlinked = try await stadeum.setJamie(peer, for: tribe)
        if peer != nil { markJamie(in: tribe.pubkey) }
        if let unlinked, let engine { try? await engine.stopShowingSenders(unlinked, in: tribe.pubkey) }
    }

    /// Whether Jamie knows who is speaking in `tribe` (`TribeMember.seesSenders`),
    /// as its owner's member list last said; nil while the tribe has no
    /// Jamie of the person's, or the list has no Jamie in it, confirmed
    /// (not joined yet, or not read).
    public func jamieSeesSenders(in tribe: String) -> Bool? {
        guard stadeum.jamiePick(of: tribe)?.isEmpty == false, let jamie = stadeum.jamieLinks?.jamie.pubkey,
              let member = knownMembers[tribe]?.member(jamie), !member.pending
        else { return nil }
        return member.seesSenders
    }

    /// The owner's switch in a tribe's Jamie row: Jamie knows who is
    /// speaking in `tribe`, or not. A tribes server that does not answer is
    /// said in the row (`jamieMarkNotes`), the switch as it was; a throw is
    /// anything else that went wrong.
    public func setJamieSeesSenders(_ on: Bool, in tribe: String) async throws {
        guard let jamie = stadeum.jamieLinks?.jamie.pubkey else { throw PeelError("Jamie isn't in this tribe.") }
        do {
            knownMembers[tribe] = try await signedIn().showSenders(jamie, in: tribe, on: on)
            jamieMarkNotes[tribe] = nil
        } catch Engine.Failure.sendersNotShown {
            jamieMarkNotes[tribe] = Self.sendersNotShown
        }
    }

    /// What a tribe's Jamie row says when its tribes server does not answer
    /// the mark: one from before it does not know it. The link stands.
    static let sendersNotShown = "This tribe's server can't tell Jamie who is speaking yet, so everyone here asks with your access."

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

    /// Marks Jamie in `tribe` to know who is speaking once the tribes server
    /// lists it in (`Engine.showSendersOnceConfirmed`): Jamie joins a public
    /// tribe by itself a few seconds after the link, and a private one once
    /// approved (`checkJamie`). The list is asked for a minute at most, one
    /// look at a time per tribe. A tribes server that does not answer the
    /// mark cannot do it yet: said in the Jamie row (`jamieMarkNotes`); the
    /// link stands.
    func markJamie(in tribe: String) {
        guard let engine, tribes[tribe]?.canManage == true, let jamie = stadeum.jamieLinks?.jamie.pubkey,
              jamieApprovals.marking.insert(tribe).inserted else { return }
        Task {
            defer { jamieApprovals.marking.remove(tribe) }
            do {
                guard let members = try await engine.showSendersOnceConfirmed(jamie, in: tribe, tries: 12, every: .seconds(5)),
                      self.engine === engine else { return }
                knownMembers[tribe] = members
                jamieMarkNotes[tribe] = nil
            } catch Engine.Failure.sendersNotShown {
                if self.engine === engine { jamieMarkNotes[tribe] = Self.sendersNotShown }
            } catch {
                if self.engine === engine { jamieMarkNotes[tribe] = PeelError.noted(error, couldNot: "tell Jamie who is speaking") }
            }
        }
    }

    /// Whether `tribe`'s details offer its Jamie: to its owner, still in
    /// it, on a tribes server Hive can name for Jamie to join.
    public func offersJamie(in tribe: Tribe) -> Bool {
        tribe.canManage && tribe.host != nil
    }

    /// The org a tribe's Jamie row offers in one tap while it has no Jamie:
    /// the one its app or second brain is on, as a call there chooses
    /// (`HivePeer.jamie`, docs/hive-calls.md). Nil once it has one, before
    /// Hive has said, or with no such org.
    public func jamieSuggestion(for tribe: Tribe) -> HivePeer? {
        guard stadeum.jamiePick(of: tribe.pubkey) == "" else { return nil }
        return HivePeer.jamie(picked: nil, pages: [tribe.appURL, tribe.secondBrainURL], in: stadeum.live)
    }

    /// Jamie in `tribe`, or asking to join it, for an org the person did
    /// not pick: someone else linked the tribe (Hive gives a tribe to
    /// whoever links it first), and that org reads what is said there. In
    /// the words a tribe's Jamie row and its notice show; nil otherwise.
    public func othersJamie(in tribe: String) -> String? {
        guard stadeum.jamiePick(of: tribe) == "", let jamie = stadeum.jamieLinks?.jamie,
              let member = knownMembers[tribe]?.member(jamie.pubkey) else { return nil }
        return member.pending
            ? "\(jamie.alias) is asking to join for an org you didn't pick: someone else linked this tribe. Approving it sends what's said here to that org."
            : "\(jamie.alias) is in this tribe for an org you didn't pick: someone else linked it, and that org reads what's said here. Remove it in Members."
    }

    /// A request to join a tribe this account owns: approved unasked when
    /// the person linked the tribe to an org and the request is Jamie's
    /// (docs/hive-tribes.md, "Approving Jamie"); Jamie asking for someone
    /// else's link is said above the composer instead. The request names
    /// only an alias, so the tribes server's list of who waits is asked
    /// for Jamie's key (`Engine.approveWaitingMember`). A request that
    /// arrives while a check is under way is looked at again once it ends.
    func approveJamie(asking message: Message) {
        guard message.type == MessageType.memberRequest, !message.fromMe, !message.deleted,
              tribes[message.chat]?.canManage == true, stadeum.link != nil else { return }
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

    /// One look at `tribe`'s waiting members for Jamie. Stadeum's links are
    /// read again unless read in the last minute, and again when they do
    /// not name the tribe (linked on the other device just now). The
    /// server may list a request a moment after it arrives, so it is asked
    /// up to three times. Each approval goes once a session: another costs
    /// the tribe's price again.
    private func checkJamie(in tribe: String) async {
        var links = await stadeum.readJamieLinks(ifOlderThan: 60)
        if let cached = links, !cached.tribes.contains(where: { $0.pubkey == tribe.lowercased() }) {
            links = await stadeum.readJamieLinks()
        }
        guard let links else { return }
        guard links.tribes.contains(where: { $0.pubkey == tribe.lowercased() }) else {
            // Someone else's Jamie is never approved here: said, for the owner to decide.
            _ = try? await tribeMembers(tribe)
            if let warning = othersJamie(in: tribe) { conversationNotices[tribe] = warning }
            return
        }
        let approval = "\(tribe.lowercased()) \(links.jamie.pubkey)"
        guard !jamieApprovals.approved.contains(approval) else { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            guard let engine, tribes[tribe]?.canManage == true else { return }
            do {
                if try await engine.approveWaitingMember(links.jamie.pubkey, in: tribe) {
                    jamieApprovals.approved.insert(approval)
                    // In now, or once the server has the approval: marked to know who is speaking.
                    markJamie(in: tribe)
                    return
                }
            } catch Engine.Failure.alreadyAnswered {
                return
            } catch {
                // Still in Members to approve by hand.
                conversationNotices[tribe] = PeelError.noted(error, couldNot: "approve \(links.jamie.alias)")
                return
            }
        }
    }
}

/// What `AppModel.approveJamie` keeps for the session, by tribe.
struct JamieApprovals {
    /// Tribes a check is under way for.
    var checking: Set<String> = []
    /// Tribes a request arrived for during their check: looked at again.
    var again: Set<String> = []
    /// Approvals sent, as "<tribe> <Jamie's key>".
    var approved: Set<String> = []
    /// Tribes Jamie is being marked in (`markJamie`).
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
