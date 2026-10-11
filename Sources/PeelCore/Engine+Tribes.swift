import Foundation
import Sphinxrs

extension Engine {
    // MARK: - Tribes

    /// What the tribes server says about the tribe a link points to, so the
    /// price can be shown before joining.
    public func tribeInfo(link text: String) async throws -> TribeInfo {
        guard let link = TribeLink(text) else { throw Failure.invalidTribeLink }
        return try await tribeInfo(link)
    }

    /// What a tribe linked in a message is, for its card: read only from the
    /// account's own tribes host (`isOwnTribeHost`), never from a host a
    /// message names. Nil for a link to any other host; Join's own lookup
    /// asks that one only when the person opens it.
    public func linkedTribeInfo(_ link: TribeLink) async throws -> TribeInfo? {
        guard isOwnTribeHost(link.host) else { return nil }
        return try await tribeInfo(link)
    }

    private func tribeInfo(_ link: TribeLink) async throws -> TribeInfo {
        // Plain http to this Mac is for the local test stack: a link someone
        // sent cannot point an account on a real server at a local service.
        guard !TribeLink.isLoopback(link.host) || server.map({ ServerAddress.isLoopback(host: $0.host) }) == true else {
            throw PeelError("\(link.host) is not on the internet")
        }
        let info = try await TribeInfo.fetch(pubkey: link.pubkey, host: link.host)
        guard info.deleted != true else { throw Failure.tribeDeleted }
        return info
    }

    /// Joins the tribe a `sphinx.chat://?action=tribeV2` link points to, paying
    /// its price to join (1 sat if it has none, as the official apps do). The
    /// tribe is recorded before the join goes out, so the history it replays
    /// is filed under the tribe. Joining a tribe already joined does nothing.
    /// `agreedJoinMsat` is the price the person was shown; the join fails
    /// rather than pay anything else. The price goes through the usual
    /// balance and threshold checks (`checkPayment`): over the threshold it
    /// throws `needsConfirmation`, and the second call, with that amount as
    /// `confirmedMsat`, joins.
    @discardableResult
    public func joinTribe(
        link text: String, agreedJoinMsat: UInt64? = nil, confirmedMsat: UInt64? = nil
    ) async throws -> Tribe {
        guard let link = TribeLink(text) else { throw Failure.invalidTribeLink }
        // A member the owner declined or removed may ask again.
        if var joined = tribes[link.pubkey], !joined.left, joined.status == .active || joined.status == .pending {
            // Found in history on another tribes server, so never looked up:
            // the link the person pasted says where it is listed.
            guard joined.host == nil else { return joined }
            joined.update(from: try await tribeInfo(link), trustingPrivacy: isOwnTribeHost(link.host))
            joined.host = link.host
            try record(joined)
            return joined
        }
        let info = try await tribeInfo(link)
        if let agreedJoinMsat, info.joinAmountMsat != agreedJoinMsat {
            throw Failure.joinPriceChanged
        }
        try checkPayment(info.joinAmountMsat, .threshold(confirmedMsat))
        // Offline, the core would take the join into its state and nothing would go.
        guard transport != nil else { throw Failure.notConnected }
        guard let routeHint = info.routeHint else { throw Failure.noRouteToTribe }
        let previous = tribes[link.pubkey]
        var tribe = previous ?? Tribe(pubkey: link.pubkey)
        tribe.update(from: info, trustingPrivacy: isOwnTribeHost(link.host))
        tribe.host = link.host
        tribe.left = false
        // A private tribe's owner must approve the request first. Asked as
        // the link's host says, wherever it is: only the time zone waits for
        // the account's own host to call a tribe private.
        let asksToJoin = info.isPrivate == true
        tribe.status = asksToJoin ? .pending : .active
        try record(tribe)
        do {
            try await run { time, state in
                try Sphinxrs.joinTribe(
                    seed: seed, uniqueTime: time, state: state, tribePubkey: tribe.pubkey, tribeRouteHint: routeHint,
                    alias: tribeAlias(alias), amtMsat: info.joinAmountMsat, isPrivate: asksToJoin
                )
            }
        } catch {
            try? record(previous, pubkey: tribe.pubkey)
            throw error
        }
        return tribe
    }

    /// Tells the tribe this account is leaving, as the official apps do, and
    /// hides it. The tribes server keeps the member on its list, so what the
    /// tribe still sends is dropped. A tribe that never accepted this account,
    /// removed it or was deleted refuses messages, so it is only hidden. The
    /// owner cannot leave, only delete the tribe, as in the official apps.
    public func leaveTribe(_ pubkey: String) async throws {
        guard let joined = tribes[pubkey], !joined.left else { throw Failure.notInTribe }
        if joined.isOwner, joined.status == .active {
            throw Failure.ownerCannotLeave
        }
        var tribe = joined
        tribe.left = true
        try record(tribe)
        guard joined.status == .active else { return }
        do {
            try await sendToTribe(joined, type: MessageType.groupLeave)
        } catch {
            try? record(joined)
            throw error
        }
    }

    /// A membership or owner message to a tribe: no text, the fields the
    /// official apps add, and the tribe's price per message, as they pay it.
    private func sendToTribe(_ tribe: Tribe, type: Int, fields: [String: String] = [:]) async throws {
        let body = try Self.json(fields.merging(["content": ""]) { field, _ in field })
        try await run { time, state in
            try Sphinxrs.send(
                seed: seed, uniqueTime: time, to: tribe.pubkey, msgType: UInt8(type), msgJson: body,
                state: state, myAlias: tribe.sentAlias(account: alias), myImg: tribe.sentPhoto(account: photoURL),
                amtMsat: tribe.messageAmountMsat,
                isTribe: true
            )
        }
    }

    /// A tribe this account owns and is still in.
    private func ownedTribe(_ pubkey: String) throws -> Tribe {
        guard let tribe = tribes[pubkey], tribe.canManage else { throw Failure.notTribeOwner }
        return tribe
    }

    /// Runs one change to a tribe this account owns (an update or the
    /// delete) with its registry host and the tribes server, one at a time
    /// per tribe: the server's reply names only the tribe, so a second change
    /// would take the first one's reply, and each would undo the other's fields.
    private func changeOwnedTribe<T>(
        _ pubkey: String, _ change: (_ tribe: Tribe, _ host: String, _ server: String) async throws -> T
    ) async throws -> T {
        let tribe = try ownedTribe(pubkey)
        guard let host = tribe.host else { throw Failure.noTribeServer }
        let server = try tribeServer()
        guard tribeWork.changing.insert(pubkey).inserted else {
            throw Failure.tribeChangeInProgress
        }
        defer { tribeWork.changing.remove(pubkey) }
        return try await change(tribe, host, server)
    }

    /// The owner approves or declines a request to join a private tribe. The
    /// answer names the request (`replyUuid`), as the official apps send it,
    /// and the member's key (`member`) when known, which the tribes server
    /// reads first. An approved member gets the recent history from the tribe.
    public func answerJoinRequest(in pubkey: String, _ request: JoinRequest, approve: Bool) async throws {
        var tribe = try ownedTribe(pubkey)
        var fields: [String: String] = [:]
        switch request {
        case .message(let uuid):
            fields["replyUuid"] = uuid
        case .member(let member, let alias):
            guard member.isPubkey else { throw Failure.notAMemberKey }
            // The request may not be stored, so the server's list must show
            // the member waiting; fetched when this session has none.
            if tribeWork.memberLists[pubkey] == nil {
                _ = try await tribeMembers(pubkey)
                tribe = try ownedTribe(pubkey)
            }
            guard tribeWork.memberLists[pubkey]?.pending.contains(where: { $0.pubkey == member }) == true else {
                throw Failure.memberNotWaiting
            }
            fields["member"] = member
            fields["replyUuid"] = try storage.joinRequest(in: pubkey, from: alias)
        }
        // Each answer costs the tribe's price; a request is answered once. Our
        // answer is stored only when the server echoes it, so until then the
        // request is held in `tribeWork.sentAnswers` and the member taken off the list.
        let replyUuid = fields["replyUuid"]
        if let replyUuid, try tribeWork.sentAnswers.contains(replyUuid) || storage.isAnswered(request: replyUuid, in: pubkey) {
            throw Failure.alreadyAnswered
        }
        if let replyUuid { tribeWork.sentAnswers.insert(replyUuid) }
        if let member = fields["member"] { tribeWork.memberLists[pubkey]?.pending.removeAll { $0.pubkey == member } }
        do {
            try await sendToTribe(tribe, type: approve ? MessageType.memberApprove : MessageType.memberReject, fields: fields)
        } catch {
            if let replyUuid { tribeWork.sentAnswers.remove(replyUuid) }
            if fields["member"] != nil { tribeWork.memberLists[pubkey] = nil }
            throw error
        }
    }

    /// The owner removes a member, named by the key on the owner's member
    /// list. The tribes server tells only that member and the owner, and
    /// refuses to remove the owner.
    public func kickMember(_ member: String, from pubkey: String) async throws {
        let tribe = try ownedTribe(pubkey)
        guard member.isPubkey else { throw Failure.notAMemberKey }
        try await sendToTribe(tribe, type: MessageType.groupKick, fields: ["member": member])
    }

    /// The owner deletes a tribe. The tribes server sends every member a
    /// delete message (type 22) from the tribe and drops it. The Mac app also
    /// sends its own type 22 first, but the command usually lands first and
    /// that payment then cannot be routed (the mixer answers "no root for
    /// scid"), so Peel sends only the command. The server's answer carries
    /// nothing a client can read, so the tribe is hidden here only once the
    /// registry stops listing it; until then the owner can try again.
    public func deleteTribe(_ pubkey: String) async throws {
        try await changeOwnedTribe(pubkey) { tribe, host, server in
            try await run { time, state in
                try Sphinxrs.deleteTribe(
                    seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribePubkey: pubkey
                )
            }
            // The registry is asked once a second: nothing here says when it changes.
            try await poll(timeout: .seconds(15), every: .seconds(1), failure: .tribeServerTimedOut) {
                await Self.isGone(pubkey, host: host) ? () : nil
            }
            var deleted = tribe
            deleted.left = true
            deleted.status = .deleted
            try record(deleted)
        }
    }

    /// Whether the registry has stopped serving a tribe (or says it is
    /// deleted). Any other failure, such as the network, counts as still there.
    private static func isGone(_ pubkey: String, host: String) async -> Bool {
        do {
            return try await TribeInfo.fetch(pubkey: pubkey, host: host).deleted == true
        } catch let error as TribeInfo.NotServed {
            return error.isGone
        } catch {
            return false
        }
    }

    /// What the tribe's registry says about it now, for its details: the
    /// owner, when it was made, its tags, prices and member count. What
    /// changed is kept, as the background refresh keeps it. The owner's
    /// photo is the one they last posted with, when they have.
    public func tribeDetails(_ pubkey: String) async throws -> TribeDetails {
        guard let host = tribes[pubkey]?.host else { throw Failure.noTribeServer }
        let asked = ContinuousClock.now
        let info = try await TribeInfo.fetch(pubkey: pubkey, host: host)
        saveRecords([info], asked: asked)
        let owner = info.ownerAlias?.nilIfEmpty
        let photo = try owner.flatMap { owner in try storage.tribeSenders(pubkey).first { $0.alias == owner }?.photoURL }
        return TribeDetails(info: info, ownerPhotoURL: photo)
    }

    /// How this account appears in a tribe it is in: a name and an https
    /// photo sent with each message there from now on, in place of the
    /// account's, as the official apps send `my_alias` and `my_photo_url`.
    /// Empty or nil is the account's own. Kept on this Mac only, as theirs
    /// are; members see it on the next message, never on what was sent.
    @discardableResult
    public func setTribeIdentity(_ pubkey: String, alias: String?, photoURL: String?) throws -> Tribe {
        guard var tribe = tribes[pubkey], !tribe.left else { throw Failure.notInTribe }
        let photo = photoURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let photo, photo.httpsOnly == nil { throw Failure.photoNotHTTPS }
        tribe.myAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        tribe.myPhotoURL = photo
        try record(tribe)
        checkMentionsIfNeeded()
        return tribe
    }

    /// What a tribe this account owns is set to, to start an edit from.
    public func tribeSettings(_ pubkey: String) async throws -> TribeSettings {
        guard let host = try ownedTribe(pubkey).host else { throw Failure.noTribeServer }
        return try await TribeInfo.fetch(pubkey: pubkey, host: host).settings
    }

    /// Changes a tribe this account owns and waits for the tribes server to
    /// confirm. Members see the change the next time they look the tribe up.
    @discardableResult
    public func updateTribe(_ pubkey: String, settings: TribeSettings) async throws -> Tribe {
        try await updateRegistry(pubkey) { record in
            try settings.validated(currentImage: record["img"] as? String).fields(over: record)
        }
    }

    /// Pins one of a tribe's messages for every member, or unpins with nil.
    /// Only the owner can; the pin is part of the tribe's registry record.
    public func pinMessage(_ uuid: String?, in pubkey: String) async throws {
        // Every member must hold the message under the same uuid: the tribe's.
        if let uuid, try storage.message(uuid: uuid, in: pubkey)?.isPinnable != true {
            throw Failure.notPinnable
        }
        try await updateRegistry(pubkey) { record in
            var record = record
            record["pin"] = uuid ?? NSNull()
            return record
        }
    }

    /// Sends the tribes server the tribe's whole record with `change` made to
    /// it: an update replaces the record, so the fields Peel does not edit
    /// go back as they were.
    @discardableResult
    private func updateRegistry(
        _ pubkey: String, _ change: ([String: Any]) throws -> [String: Any]
    ) async throws -> Tribe {
        try await changeOwnedTribe(pubkey) { tribe, host, server in
            let data = try await TribeInfo.record(pubkey: pubkey, host: host)
            guard let current = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  current["pubkey"] as? String == pubkey else {
                throw Failure.tribeServerMismatch
            }
            var fields = try change(current)
            fields["pubkey"] = pubkey
            if (fields["owner_alias"] as? String)?.isEmpty != false {
                fields["owner_alias"] = tribeAlias(alias)
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            tribeWork.updated.remove(pubkey)
            try await run { time, state in
                try Sphinxrs.updateTribe(
                    seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribeJson: json
                )
            }
            _ = try await poll(timeout: .seconds(15), failure: .tribeServerTimedOut) { tribeWork.updated.remove(pubkey) }
            return tribes[pubkey] ?? tribe
        }
    }

    /// Saves a tribe, or forgets it when nil, here and on disk.
    private func record(_ tribe: Tribe?, pubkey: String? = nil) throws {
        guard let pubkey = tribe?.pubkey ?? pubkey else { return }
        if let tribe { try storage.save([tribe]) } else { try storage.deleteTribe(pubkey) }
        tribes[pubkey] = tribe
    }

    /// The tribe's members. The tribes server gives the list only to the
    /// owner; anyone else gets the people seen posting.
    public func tribeMembers(_ pubkey: String) async throws -> TribeMembers {
        guard let tribe = tribes[pubkey], !tribe.left else { throw Failure.notInTribe }
        let seen = try storage.tribeSenders(pubkey)
        guard tribe.isOwner else { return TribeMembers(members: seen, complete: false) }
        let server = try tribeServer()
        tribeWork.memberLists[pubkey] = nil
        try await run { time, state in
            try Sphinxrs.listTribeMembers(
                seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribePubkey: pubkey
            )
        }
        let list = try await poll(timeout: .seconds(15), failure: .tribeServerTimedOut) { tribeWork.memberLists[pubkey] }
        // The server's list has no photos; take them from what members posted.
        let photos = Dictionary(seen.map { ($0.alias, $0.photoURL) }, uniquingKeysWith: { $1 })
        func members(_ entries: [TribeMembers.List.Entry], pending: Bool) -> [TribeMember] {
            entries.map { TribeMember(alias: $0.alias, photoURL: photos[$0.alias] ?? nil, pubkey: $0.pubkey, pending: pending) }
        }
        return TribeMembers(members: members(list.confirmed, pending: false) + members(list.pending, pending: true), complete: true)
    }

    /// Creates a tribe on the account's tribes server, owned by this account,
    /// and waits for the server to list it. Needs the tribes host recorded
    /// (from the config on signup or restore, or `--tribe-host`) so the new
    /// tribe has a link to share.
    @discardableResult
    public func createTribe(_ settings: TribeSettings) async throws -> Tribe {
        let new = try settings.validated()
        let server = try tribeServer()
        guard try storage.value(for: .tribeHost) != nil else { throw Failure.noTribeServer }
        let owned = Set(tribes.values.filter(\.isOwner).map(\.pubkey))
        var fields = try new.fields()
        fields["owner_alias"] = tribeAlias(alias)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        try await run { time, state in
            try Sphinxrs.createTribe(
                seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribeJson: json
            )
        }
        return try await poll(timeout: .seconds(15), failure: .tribeServerTimedOut) {
            tribes.values.first { $0.isOwner && !owned.contains($0.pubkey) && $0.name == new.name }
        }
    }

    /// A tribe this account is in but has no record of, as after a restore:
    /// a tribes server names its host on the joins it forwards, including our
    /// own join coming back. Only a core contact with no contact key can be a
    /// tribe (people always have one), and the host is kept only when it is
    /// the account's own tribes server, so a stranger cannot make Peel fetch
    /// from a host of their choosing.
    /// A chat the core holds a contact key for goes into `notTribes`, so it
    /// is looked up once per call.
    func discoveredTribe(
        _ message: Message, trustSender: Bool, state: [String: Data], notTribes: inout Set<String>
    ) throws -> Tribe? {
        guard trustSender || message.fromMe, let host = message.senderInfo?.host?.nilIfEmpty,
              let isPerson = Self.isPerson(message.chat, in: state) else { return nil }
        guard !isPerson else {
            notTribes.insert(message.chat)
            return nil
        }
        let tribeHost = try storage.value(for: .tribeHost)
        return Tribe(pubkey: message.chat, host: host == tribeHost ? host : nil)
    }

    /// Whether a copy the core calls ours by its tag is a member's replay of
    /// it. Our tag opens as ours whoever sends it (`dec_tag`), and a tribe
    /// forwards it to every member on each of our messages. A tag reaches
    /// them only after the tribe has forwarded our message to us too, and
    /// history comes oldest first, so the first copy with a tag is ours and
    /// a later one (another uuid, or the same at another server index) is
    /// a replay. Not always: a purchase or a join request goes to one
    /// member, a long message's earlier chunks carry tags we never store,
    /// and a fast member can race our own forward, so membership does not
    /// lean on this alone (`membership`). The member chooses the uuid
    /// bytes, hence `originalUuid`, and a chunk's uuid, so `original`
    /// counts only as our send not yet taken over, of the same type and
    /// words (`Storage.holdsTag`). `taken` holds the tags already taken in this
    /// core call, not yet stored. Checked before the copy names a tribe,
    /// changes our membership or aliases, or is stored. A person's chat is
    /// left to the signer check (`message(from:)`).
    func isReplay(
        _ message: Message, original: String?, state: [String: Data], taken: inout [String: String]
    ) throws -> Bool {
        guard message.fromMe, let tag = message.tag, Self.isPerson(message.chat, in: state) != true else { return false }
        // One delivery: its uuid at its server index (a chunked message's
        // uuid is the sender's own `chunk_id`, so a uuid alone is not one).
        let delivery = "\(message.uuid ?? "")@\(message.serverIndex.map(String.init) ?? "")"
        if let first = taken[tag] { return first != delivery }
        if try storage.holdsTag(tag, besides: message, takingOver: original) { return true }
        taken[tag] = delivery
        return false
    }

    /// What a tribe message says about this account's place in the tribe,
    /// or nil if nothing changes. Our own join replayed on a restore says
    /// we are in it. Otherwise our own join, leave and request count only
    /// as sent from this device, which records them: a copy that arrives
    /// may be a member's with our tag (the tribe forwards it, and a request
    /// goes to the owner alone, so it reaches us only to forge our own
    /// tribe's status). So a tribe left on another device, or before a
    /// restore, stays joined here (the server never removes a leaver). The owner's answers reach a
    /// member from the tribe itself: a rejection or a removal, which the
    /// tribes server sends only to that member and the owner, and the
    /// tribe's deletion. Someone else's join never concerns us. The owner's
    /// approval goes to every member, naming the approved one by their alias
    /// in the tribe, so it lets us in only when it names us (`approvalNamesUs`:
    /// the alias we send, `sent`, and those the tribe `echoed`). That is how a
    /// restore (with no request in history) sees a declined or removed member
    /// who asked again and was approved, while another member's approval or
    /// join heard after our removal leaves us out. Names are all an approval
    /// carries (the server drops the member key), so this can miss: a member
    /// renamed between asking and the approval, restored before anything of
    /// theirs echoed the old name, stays out. A member who is out hears no
    /// approvals live, so a wrong match (another `name_2`) needs history
    /// replayed out of order. The tribes server marks what the owner sends with role 0, including
    /// the join it sends the owner on creation, so our own message with it
    /// says this account owns the tribe, as after a restore.
    /// A restore (`replaying`) leaves deleted tribes out, as the Mac app does
    /// (it restores only tribes the registry still serves); a deletion heard
    /// otherwise keeps its bar so the user sees what happened.
    static func membership(
        after message: Message, in tribe: Tribe, sent: String, echoed: Set<String>, replaying: Bool
    ) -> Tribe? {
        var changed = tribe
        if message.fromMe {
            if message.senderInfo?.role == 0 { changed.isOwner = true }
            // Our own join, leave and request are recorded when sent
            // (`joinTribe`, `leaveTribe`); a copy that arrives may be a
            // member's, with our tag (`isReplay`), so only a restore, which
            // finds its tribes by our joins, takes a join from the network.
            if message.type == MessageType.groupJoin, replaying { changed.left = false; changed.status = .active }
        } else if [MessageType.tribeDelete, MessageType.groupKick, MessageType.memberReject, MessageType.memberApprove]
                    .contains(message.type), message.senderInfo?.role != 0 {
            // The owner's decisions carry the owner's role; the tribes server
            // already refuses them from anyone else, and this does not rely on it.
            return nil
        } else if message.type == MessageType.tribeDelete {
            // Only the owner can delete, so this is true for the owner too.
            changed.status = .deleted
            if replaying { changed.left = true }
        } else if !tribe.isOwner {
            switch message.type {
            case MessageType.memberApprove:
                if let alias = message.senderAlias, approvalNamesUs(alias, sent: sent, echoed: echoed),
                   [.pending, .rejected, .removed].contains(tribe.status) {
                    changed.status = .active
                }
            case MessageType.memberReject: changed.status = .rejected
            case MessageType.groupKick: changed.status = .removed
            default: break
            }
        }
        return changed == tribe ? nil : changed
    }

    /// Whether the core holds a contact key for `pubkey`: people always have
    /// one, tribes never. Nil when the core has no such contact.
    static func isPerson(_ pubkey: String, in state: [String: Data]) -> Bool? {
        contact(pubkey, in: state).map { $0.contactKey != nil }
    }

    /// The core's record of `pubkey`, read from its `c/` entry alone (all
    /// `get_contact` reads), so a lookup never encodes the whole state.
    static func contact(_ pubkey: String, in state: [String: Data]) -> Contact? {
        let key = "c/\(pubkey)"
        guard let entry = state[key],
              let json = try? Sphinxrs.getContact(state: StateCodec.encode([key: entry]), pubkey: pubkey) else { return nil }
        return JSON.decode(Contact.self, from: json)
    }

    private func tribeServer() throws -> String {
        guard let server = try? Sphinxrs.getDefaultTribeServer(state: StateCodec.encode(state)), !server.isEmpty else {
            throw Failure.noTribeServer
        }
        return server
    }

    /// An account made without the tribes host (the config could not be read
    /// at signup, or made before Peel kept it) takes it from the public config.
    /// Never from a joined link, which anyone can write.
    private func recordConfiguredTribeHost() async {
        guard (try? storage.value(for: .tribeHost)) == nil, let server, !ServerAddress.isLoopback(host: server.host),
              let host = try? await ServerConfig.fetch(network: network).usableTribeHost else { return }
        try? setTribeHost(host)
    }

    /// Runs `refreshTribes` in the background. A call while it runs makes it
    /// go round once more instead of starting a second one; `disconnect` cancels it.
    func refreshTribesInBackground() {
        tribeWork.needsRefresh = true
        startTribeRefresh()
    }

    private func startTribeRefresh() {
        guard !closed, tribeWork.refresh == nil else { return }
        tribeWork.refresh = Self.background { [weak self] in
            await self?.recordConfiguredTribeHost()
            await self?.refreshTribes()
        }
    }

    /// Whether `host` is the account's own tribes host (`tribeHost`), the
    /// one registry whose "private" counts (`Tribe.update(from:trustingPrivacy:)`).
    /// No host recorded, or one that cannot be read, trusts none.
    func isOwnTribeHost(_ host: String?) -> Bool {
        guard let host, let own = try? storage.value(for: .tribeHost) else { return false }
        return host.caseInsensitiveCompare(own) == .orderedSame
    }

    /// A joined tribe as its registry record now says, if that changes it.
    /// The record was read from the tribe's stored `host`.
    private func merged(_ info: TribeInfo) -> Tribe? {
        guard var current = tribes[info.pubkey], !current.left else { return nil }
        current.update(from: info, trustingPrivacy: isOwnTribeHost(current.host))
        return current == tribes[info.pubkey] ? nil : current
    }

    /// Takes the registry's current name, photo and prices for each joined
    /// tribe (or only those in `tribeWork.toRecheck`), a few at a time, and saves
    /// what changed in one write. Failures leave what is stored.
    private func refreshTribes() async {
        while tribeWork.needsRefresh || !tribeWork.toRecheck.isEmpty, !Task.isCancelled {
            let all = tribeWork.needsRefresh, only = tribeWork.toRecheck
            tribeWork.needsRefresh = false
            tribeWork.toRecheck = []
            let joined = tribes.values.compactMap { tribe in
                tribe.left || !(all || only.contains(tribe.pubkey)) ? nil : tribe.host.map { (tribe.pubkey, $0) }
            }
            let asked = ContinuousClock.now
            let infos = await withTaskGroup(of: TribeInfo?.self) { group in
                var pending = joined[...]
                func addNext() {
                    guard !Task.isCancelled, let (pubkey, host) = pending.popFirst() else { return }
                    group.addTask { try? await TribeInfo.fetch(pubkey: pubkey, host: host) }
                }
                for _ in 0..<4 { addNext() }
                var infos: [TribeInfo] = []
                while let result = await group.next() {
                    if let result { infos.append(result) }
                    addNext()
                }
                return infos
            }
            guard !Task.isCancelled else { break }
            saveRecords(infos, asked: asked)
        }
        // A cancelled refresh has already been replaced or stopped.
        if !Task.isCancelled { tribeWork.refresh = nil }
    }

    /// Saves what registry answers change in joined tribes, in one write,
    /// and notes when each answered tribe was asked (`tribeWork.readAt`).
    func saveRecords(_ infos: [TribeInfo], asked: ContinuousClock.Instant) {
        for info in infos { tribeWork.readAt[info.pubkey] = asked }
        let changed = infos.compactMap(merged)
        do {
            try storage.save(changed)
            for tribe in changed { tribes[tribe.pubkey] = tribe }
        } catch {
            emit.yield(.coreError("saving tribes: \(PeelError.readable(error))"))
        }
    }

    /// After a send that carried the offset to a tribe: queues its record
    /// for the background refresh when the last one read this session is
    /// older than `tribeRecheck`, so a tribe made public soon stops getting
    /// it (design README, "Time zones"). The send never waits. True when queued.
    @discardableResult
    func recheckIfStale(_ pubkey: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard tribeWork.readAt[pubkey].map({ now - $0 > Self.tribeRecheck }) ?? true,
              !tribeWork.toRecheck.contains(pubkey) else { return false }
        tribeWork.toRecheck.insert(pubkey)
        startTribeRefresh()
        return true
    }
}
