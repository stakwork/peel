import Foundation
import Sphinxrs

extension Engine {
    // MARK: - Contacts and messages

    /// What a key exchange pays: the official apps attach 5 sats to its first message.
    public static let keyExchangeMsat: UInt64 = 5_000
    /// What the other side's core pays back at once when answering a key
    /// exchange (`PRICE_TO_MEET` in the core's `bindings/mod.rs`).
    public static let priceToMeetMsat: UInt64 = 3_000

    /// Starts a key exchange with a contact given as `pubkey_lsp_scid`,
    /// paying `keyExchangeMsat` with no checks: `addContact(code:)` checks,
    /// and only a new account's inviter (`addInviterIfPending`) is added unchecked.
    public func addContact(_ contactInfo: String, alias theirAlias: String? = nil, inviteCode: String? = nil) async throws {
        guard let parts = Self.contactInfoParts(contactInfo) else { throw Failure.invalidContactInfo }
        try await run { time, state in
            try Sphinxrs.addContact(
                seed: seed, uniqueTime: time, state: state,
                toPubkey: parts[0], routeHint: "\(parts[1])_\(parts[2])",
                myAlias: alias, myImg: photoURL,
                amtMsat: Self.keyExchangeMsat,
                inviteCode: inviteCode, theirAlias: theirAlias
            )
        }
        try storage.upsertContact(pubkey: parts[0], alias: theirAlias)
    }

    /// Sends a text message to a contact or a tribe, optionally as a reply to
    /// one of its messages or into a thread (both by uuid), with the links
    /// set as the Mac app sets them: a reply joins its parent's thread, or
    /// starts one at the parent; `inThread` may name any message of the
    /// thread, and a reply given with it must be in that thread. Returns the
    /// tag the server will confirm. With `priceAtMost` (msat), a tribe whose
    /// price is now above it is refused (`tribePriceRose`) rather than paid:
    /// the price someone agreed to is the most the send pays.
    @discardableResult
    public func sendText(
        _ text: String, to pubkey: String, replyTo: String? = nil, inThread: String? = nil, priceAtMost: UInt64? = nil
    ) async throws -> String? {
        let links = try links(replyTo: replyTo, inThread: inThread, in: pubkey)
        var fields = ["content": text]
        fields["replyUuid"] = links.replyTo
        fields["threadUuid"] = links.thread
        return try await deliver(body: try Self.json(fields), to: pubkey, priceAtMost: priceAtMost, replacing: nil)
    }

    /// A control message to the contact `pubkey` (docs/agent-on-strut.md,
    /// "The device channel"): `text`, the line the official apps show, with
    /// `envelope` in its metadata. Never to a tribe: the channel is a DM.
    @discardableResult
    public func sendControl(_ envelope: ControlEnvelope, text: String, to pubkey: String) async throws -> String? {
        guard isContact(pubkey) else { throw Failure.notAContact }
        let body = try envelope.adding(to: Self.json(["content": text]))
        return try await deliver(body: body, to: pubkey, replacing: nil)
    }

    /// `replyUuid` and `threadUuid` for a message to `chat`, as the Mac app
    /// sets them: a reply joins its parent's thread (`Message.threadRoot`),
    /// or starts one at the parent; `inThread` may name any message of the
    /// thread, or the thread itself when only its messages are stored (the
    /// original older than this Mac's history), and a reply given with it
    /// must be in that thread.
    func links(
        replyTo: String?, inThread: String?, in chat: String
    ) throws -> (replyTo: String?, thread: String?) {
        var thread = try inThread.map { uuid in
            guard MessageUUID.isValid(uuid) else { throw Failure.noSuchMessage }
            if let named = try storage.message(uuid: uuid, in: chat) {
                // A deleted original still names its thread, which goes on.
                return named.deleted ? named.threadRoot : try linkable(uuid, in: chat).threadRoot
            }
            guard try storage.threadCount(uuid, in: chat) > 0 else { throw Failure.noSuchMessage }
            return uuid
        }
        if let replyTo {
            let parentThread = try linkable(replyTo, in: chat).threadRoot
            if let thread, parentThread != thread { throw Failure.notInThread }
            thread = parentThread
        }
        return (replyTo, thread)
    }

    /// Throws what `sendText` would refuse about `replyTo` and `inThread`
    /// in `chat`, without sending: for asking before a send.
    public func checkLinks(replyTo: String?, inThread: String?, in chat: String) throws {
        _ = try links(replyTo: replyTo, inThread: inThread, in: chat)
    }

    /// A stored text message or attachment of `chat` that others hold under
    /// the same uuid (`Message.isLinkable`).
    private func linkable(_ uuid: String, in chat: String) throws -> Message {
        guard MessageUUID.isValid(uuid), let message = try storage.message(uuid: uuid, in: chat),
              MessageType.content.contains(message.type) else {
            throw Failure.noSuchMessage
        }
        guard message.isLinkable(inTribe: tribes[chat] != nil) else { throw Failure.notDelivered }
        return message
    }

    /// Deletes a message for everyone, as the official apps do: a type 17
    /// message naming it in `replyUuid`. Our own messages, and in a tribe this
    /// account owns, anyone's (the tribes server refuses the rest). As in the
    /// Mac app, a thread's original cannot be deleted while it has two or
    /// more replies (`Message.isDeletable`). The row is emptied once the
    /// server has the delete; one that fails to send can be sent again. A
    /// tribe delete pays the tribe's price like any message.
    public func deleteMessage(id: Int64) async throws {
        guard let message = try storage.message(id: id), MessageType.content.contains(message.type),
              !message.deleted, let uuid = message.uuid else { throw Failure.noSuchMessage }
        let tribe = try openTribe(message.chat)
        guard message.isDeletable(
            inTribe: tribe != nil, ownsTribe: tribe?.canManage == true,
            threadCount: try storage.threadCount(uuid, in: message.chat)
        ) else {
            throw Failure.notDeletable
        }
        _ = try await deliver(
            body: try Self.json(["content": "", "replyUuid": uuid]), to: message.chat, type: MessageType.delete,
            replacing: nil
        )
    }

    /// Sends an undelivered message again. The core gives every send a new uuid
    /// and tag, so the same row takes them over and moves to now; the server's
    /// echo then matches that row rather than adding a second one. A tribe
    /// message pays the tribe's current price, as a first send would, but
    /// never more than the price it last went at (the row takes each send's
    /// sats): a raise since then shows in the tribe's header, and the
    /// message must be sent anew. One that went free (no sats) has no price
    /// to hold to, and goes at the current one.
    /// Anything that carried sats (a payment, a boost, or a tribe message,
    /// which paid the price) goes again only once it failed (`isRetryable`):
    /// an unconfirmed one may have paid. A payment or boost goes again for
    /// the same amount, within the balance and, like a new one, confirmed
    /// when over the threshold; a boost in a tribe only if that amount still
    /// covers the tribe's price, and only while its message can be boosted.
    /// On a connection it is pinged first (`connectionAnswers`): one that
    /// looks connected but no longer answers is dropped and reconnected, and
    /// the Retry refused as `connectionDropped`, rather than sent into it to
    /// wait unseen. The checks run after the ping, so nothing waits between
    /// them and the send's commit; with no connection at all they still run
    /// (a refusal says more), then `notConnected`.
    @discardableResult
    public func resend(messageID: Int64, confirmedMsat: UInt64? = nil) async throws -> String? {
        guard try storage.message(id: messageID)?.isRetryable() == true else { throw Failure.notRetryable }
        if transport != nil, await !connectionAnswers() { throw Failure.connectionDropped }
        return try await resend(messageID, confirmedMsat: confirmedMsat, auto: false)
    }

    /// `resend` without the ping. `auto`, for a reconnect's own sends
    /// (`resendRecent`, new on their connection), says nothing when one
    /// fails (the row shows it) and marks the row as sent again by itself.
    private func resend(_ messageID: Int64, confirmedMsat: UInt64?, auto: Bool) async throws -> String? {
        guard let message = try storage.message(id: messageID), message.isRetryable(), let body = message.body else {
            throw Failure.notRetryable
        }
        let tribe = try openTribe(message.chat)
        guard MessageType.payments.contains(message.type) else {
            if let tribe, let paid = message.msat, tribe.messageAmountMsat > UInt64(max(paid, 0)) {
                throw Failure.tribePriceRose(boost: false)
            }
            if message.type == MessageType.invoice,
               Self.requestInvoice(body)?.isExpired() != false {
                throw Failure.requestExpired
            }
            guard transport != nil else { throw Failure.notConnected }
            if message.type == MessageType.attachment {
                return try await uploadAndDeliver(message, auto: auto)
            }
            return try await deliver(body: body, to: message.chat, type: message.type, replacing: messageID, auto: auto)
        }
        guard let amount = message.amountMsat.flatMap(UInt64.init(exactly:)), amount > 0 else {
            throw Failure.notRetryable
        }
        // The same rule as a new boost: never pay for a message deleted since.
        if message.type == MessageType.boost {
            _ = try boostTarget(message.replyUUID.flatMap { try storage.message(uuid: $0, in: message.chat) })
        }
        if let tribe, tribe.paymentPriceMsat > amount {
            throw Failure.tribePriceRose(boost: true)
        }
        try checkPayment(amount, .threshold(confirmedMsat), reserveMsat: Self.pingMsat(toTribe: tribe != nil))
        guard transport != nil else { throw Failure.notConnected }
        return try await deliver(body: body, to: message.chat, type: message.type, amountMsat: amount, replacing: messageID)
    }

    /// How long a reconnect waits for the server's records of its candidates
    /// (`checkPendingSends`); without them it sends only what never got a tag.
    static let recordsWait: Duration = .seconds(10)

    /// The messages a reconnect may send again by itself, as of now: recent
    /// undelivered ones of ours that move no money (`Message.isAutoResendable`),
    /// never in a tribe, oldest first.
    func autoResendCandidates() throws -> [Message] {
        let since = Date.now.addingTimeInterval(-Message.autoResendWindow).millisecondsSince1970
        return try storage.undeliveredSends(since: since).filter { $0.isAutoResendable() && tribes[$0.chat] == nil }
    }

    /// After the connection comes back (`cameOnline`), on that connection:
    /// sends each `autoResendCandidates` row again by itself, once and oldest
    /// first, through `resend`'s checks. One with a tag goes only if
    /// `checkPendingSends` asked the server about that tag and its records do
    /// not name it, whatever their status: one that reached the server,
    /// however this Mac marked it, is never sent twice. One with no tag never
    /// left. A send that fails again stays failed, for Retry
    /// (`Message.autoResentAt` is stored, so a relaunch does not send it
    /// again), and nothing new is shown beyond its row.
    func resendRecent(on connection: Transport) async {
        _ = try? await poll(timeout: Self.recordsWait, failure: .notConnected) {
            resendGate == nil || resendGate?.recorded != nil ? () : nil
        }
        guard let candidates = try? autoResendCandidates() else { return }
        for candidate in candidates {
            guard transport === connection, !Task.isCancelled else { return }
            // As stored now: a record or an echo may have landed since.
            guard let id = candidate.id, let message = try? storage.message(id: id), tribes[message.chat] == nil,
                  Self.autoResends(message, gate: resendGate, now: .now) else { continue }
            _ = try? await resend(id, confirmedMsat: nil, auto: true)
        }
    }

    /// The tags of a reconnect's candidates the server was asked about, and
    /// those its records named, any status (nil until it answers).
    typealias ResendGate = (asked: Set<String>, recorded: Set<String>?)

    /// Whether a reconnect sends `message` again by itself: one of ours that
    /// moves no money (`Message.isAutoResendable`). With no tag it never
    /// left, so only a failed one goes. With a tag, only if the server was
    /// asked about it and its records do not name it, whatever their status;
    /// and a pending one only once first sent over `Message.inFlightLimit`
    /// ago, as the server records a send only once it has finished.
    static func autoResends(_ message: Message, gate: ResendGate?, now: Date) -> Bool {
        guard message.isAutoResendable(now: now) else { return false }
        guard let tag = message.tag else { return message.delivery == .failed }
        guard let gate, let recorded = gate.recorded, gate.asked.contains(tag), !recorded.contains(tag) else {
            return false
        }
        return message.delivery != .pending || now.timeIntervalSince(message.firstSent) > Message.inFlightLimit
    }

    /// Drops an undelivered message of ours from this Mac. It never reached the
    /// server, so there is nothing to delete anywhere else.
    public func discard(messageID: Int64) throws {
        guard let message = try storage.message(id: messageID), message.isDiscardable else {
            throw Failure.notRetryable
        }
        try storage.deleteMessage(id: messageID)
        try? FileManager.default.removeItem(at: media.outgoing(messageID))
    }

    /// The tribe a message to `pubkey` goes to, if it is one. Only a tribe
    /// this account is in and accepted by takes messages.
    func openTribe(_ pubkey: String) throws -> Tribe? {
        guard let tribe = tribes[pubkey] else { return nil }
        if tribe.status == .pending, !tribe.left { throw Failure.awaitingApproval }
        guard tribe.canPost else { throw Failure.notInTribe }
        return tribe
    }

    static func json(_ fields: [String: String]) throws -> String {
        String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    }

    /// Whether the core holds `pubkey` as a person (not a tribe).
    func isContact(_ pubkey: String) -> Bool { Self.isPerson(pubkey, in: state) == true }

    /// A tribe this account knows, as last stored.
    func knownTribe(_ pubkey: String) -> Tribe? { tribes[pubkey] }

    /// What a text message to `pubkey` pays now: a tribe's price
    /// (`Tribe.messagePrice`), nil for a contact. Throws as a send would
    /// for a tribe that takes no messages from this account.
    public func messagePrice(to pubkey: String) throws -> TribePrice? {
        try openTribe(pubkey)?.messagePrice
    }

    /// One message through the core: text, an attachment, a delete, a
    /// payment or a boost. A text message to a tribe carries sats (the
    /// tribe's current price, at least 3); a payment or boost carries
    /// `amountMsat`. A tribe message goes with the alias in the form tribes
    /// accept. The core only returns a tag and uuid for what was sent; the
    /// local row is written in the same transaction as the state, before
    /// publishing. If the publish fails the row is marked failed, ready to send
    /// again, and the failure is reported as a send status rather than thrown.
    /// Anything that carries sats (a payment, or a tribe's price) is marked
    /// failed only when nothing was published (`commitAndPublish`'s `.none`):
    /// once anything went out it may have paid, so it stays pending, never to
    /// be sent again, until the server says.
    /// `auto` (a reconnect's own resend) leaves a failure to the row alone.
    /// `priceAtMost` (msat) refuses a tribe's price above it
    /// (`tribePriceRose`) rather than pay it.
    func deliver(
        body: String, to pubkey: String, type: Int = MessageType.text, amountMsat: UInt64? = nil,
        priceAtMost: UInt64? = nil, replacing id: Int64?, auto: Bool = false
    ) async throws -> String? {
        let tribe = try openTribe(pubkey)
        if let priceAtMost, amountMsat == nil, let tribe, tribe.messageAmountMsat(type: type) > priceAtMost {
            throw Failure.tribePriceRose(boost: false)
        }
        // By what is stored: a send never waits on the network, so sends go
        // at once and in order (`TimeZones.swift`).
        let offset = try offsetShared(in: pubkey, type: type)
        var body = try TimeZoneOffset.setting(offset, in: body)
        if tribe != nil, offset != nil { recheckIfStale(pubkey) }
        let myAlias = tribe?.sentAlias(account: alias) ?? alias
        var photoURL = tribe?.sentPhoto(account: photoURL) ?? photoURL
        if amountMsat != nil { (body, photoURL) = try Self.fittingPayment(body, alias: myAlias, photoURL: photoURL) }
        let sats = amountMsat ?? tribe?.messageAmountMsat(type: type) ?? 0
        let time = clock.next()
        let result = try Sphinxrs.send(
            seed: seed, uniqueTime: time, to: pubkey, msgType: UInt8(type), msgJson: body,
            state: StateCodec.encode(state), myAlias: myAlias, myImg: photoURL,
            amtMsat: sats, isTribe: tribe != nil
        )
        let sent = result.msgs.first
        let now = Date().millisecondsSince1970
        var outgoing: Message?
        var resend: Storage.Commit.Resend?
        let msat = sats > 0 ? Int64(clamping: sats) : nil
        if let id {
            resend = (id, pubkey, sent?.uuid, sent?.tag, sent?.paymentHash, msat, now, auto)
        } else {
            let fields = BodyFields.decode(body)
            outgoing = Message(
                uuid: sent?.uuid, type: type, chat: pubkey, fromMe: true, body: body,
                content: fields?.content, msat: msat,
                timestamp: now, tag: sent?.tag, paymentHash: sent?.paymentHash,
                status: Message.Delivery.pending.rawValue,
                replyUUID: fields?.replyUuid, threadUUID: fields?.threadUuid,
                amountMsat: amountMsat.map { Int64(clamping: $0) }
            )
            if type == MessageType.invoice, let invoice = Self.requestInvoice(body) {
                outgoing?.paymentHash = invoice.paymentHash
                outgoing?.amountMsat = Int64(clamping: invoice.amountMsat)
            }
        }
        let failure: (any Error)?
        switch try await commitAndPublish(result, time: time, outgoing: outgoing, resend: resend) {
        case .all:
            failure = nil
        case .none:
            failure = Failure.notConnected
        case .unknown(let error) where sats > 0:
            let what = amountMsat == nil ? "message" : "payment"
            emit.yield(.conversationError(chat: pubkey, message: Self.mayHaveGone(error, what: what)))
            return sent?.tag
        case .unknown(let error):
            failure = error
        }
        if let failure {
            if let tag = sent?.tag {
                try storage.setStatus(.failed, tag: tag)
            }
            emit.yield(.sendStatus(tag: sent?.tag, status: Message.Delivery.failed.rawValue))
            if !auto {
                emit.yield(.conversationError(chat: pubkey, message: "Not delivered: \(PeelError.readable(failure))"))
            }
            return sent?.tag
        }
        // The server moves the chat's read marker to what was just sent.
        readsSentSinceGetReads.insert(pubkey)
        do {
            try storage.readBySending(in: pubkey)
        } catch {
            // Sent all the same; the next `getReads` brings the marker.
            emit.yield(.coreError("marking read after sending: \(PeelError.readable(error))"))
        }
        return sent?.tag
    }

    /// Marks a chat read up to its newest message, here and on the server, so
    /// the account's other devices agree. Never moves the marker back (the
    /// server's may be past what is stored here). Offline, the marker waits
    /// as pending and goes once the server answers `getReads`.
    public func markRead(_ chat: String) async throws {
        // Someone who added this account is new until their chat is read.
        _ = try storage.clearNewContact(chat)
        guard let index = try storage.highestServerIndex(in: chat),
              try storage.setRead(chat: chat, index: index, as: .read) else { return }
        try await publishRead(chat, index: index)
    }

    /// Marks a chat unread from one message (by server index) on, or from
    /// its newest incoming message so it counts one: the marker goes just
    /// before it, as the official apps' "Mark as Unread" does, and the server
    /// takes the lower marker as it is. Threads share the chat's marker.
    /// Returns the new marker.
    @discardableResult
    public func markUnread(_ chat: String, fromServerIndex index: Int64? = nil) async throws -> Int64 {
        // The server keeps markers only for core contacts (tribes included).
        guard state["c/\(chat)"] != nil else { throw Failure.notAChat }
        guard let index = try index ?? storage.newestIncomingIndex(in: chat), index > 0 else {
            throw Failure.noSuchMessage
        }
        if try storage.setRead(chat: chat, index: index - 1, as: .unread) {
            try await publishRead(chat, index: index - 1)
        }
        return index - 1
    }

    /// Sends a marker set here; once sent, it is no longer pending.
    func publishRead(_ chat: String, index: Int64) async throws {
        guard transport != nil, state["c/\(chat)"] != nil, let msgIdx = UInt64(exactly: index) else { return }
        try await run { time, state in
            try Sphinxrs.read(seed: seed, uniqueTime: time, state: state, pubkey: chat, msgIdx: msgIdx)
        }
        readsSentSinceGetReads.insert(chat)
        try storage.readSent(chat: chat, index: index)
    }

    /// Sets how loud a chat may be. The level lives on the server, which uses it
    /// for push notifications, so this needs a connection.
    public func setMute(_ chat: String, level: MuteLevel) async throws {
        guard transport != nil else { throw Failure.notConnected }
        try await run { time, state in
            try Sphinxrs.mute(seed: seed, uniqueTime: time, state: state, pubkey: chat, muteLevel: UInt8(level.rawValue))
        }
        mutesSetSinceGetMutes.insert(chat)
        try storage.setMute(chat: chat, level: level)
    }
}
