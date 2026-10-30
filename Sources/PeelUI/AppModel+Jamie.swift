import Foundation
import PeelCore

/// Jamie in Sphinx tribes (docs/hive-tribes.md): a tribe its owner linked
/// to one of their Stadeum orgs, where `@jamie` is a turn of that org's
/// assistant, run as the owner. The links are `Stadeum`'s; this is what
/// the account does around them.
extension AppModel {
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
              let member = knownMembers[tribe]?.members.first(where: { $0.pubkey?.lowercased() == jamie.pubkey }) else { return nil }
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
}
