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

    /// A request to join a tribe this account owns: approved unasked when
    /// the person linked the tribe to an org and the request is Jamie's
    /// (docs/hive-tribes.md, "Approving Jamie"). The request names only an
    /// alias, so the tribes server's list of who waits is asked for
    /// Jamie's key (`Engine.approveWaitingMember`). Stadeum's links are
    /// read again first unless read in the last minute: the tribe may have
    /// been linked on the person's other device. The server may list the
    /// request a moment after it arrives, so it is asked up to three times.
    func approveJamie(asking message: Message) {
        guard message.type == MessageType.memberRequest, !message.fromMe, !message.deleted,
              tribes[message.chat]?.canManage == true, stadeum.link != nil else { return }
        let tribe = message.chat
        guard approvingJamie.insert(tribe).inserted else { return }
        Task {
            defer { approvingJamie.remove(tribe) }
            guard let links = await stadeum.readJamieLinks(ifOlderThan: 60),
                  links.tribes.contains(where: { $0.pubkey == tribe.lowercased() }) else { return }
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
                guard let engine, tribes[tribe]?.canManage == true else { return }
                do {
                    if try await engine.approveWaitingMember(links.jamie.pubkey, in: tribe) { return }
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
}
