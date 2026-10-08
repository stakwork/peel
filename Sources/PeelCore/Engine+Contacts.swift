import Foundation
import Sphinxrs

extension Engine {
    // MARK: - Adding by code

    /// Adds whoever a scanned or pasted code names (`ContactCode`): contact
    /// info, a `share_contact` link, or an invite's inviter. An invite is for
    /// a new account, so its code is never used here: the inviter is added
    /// as anyone would be and the invite's sats stay where they are. A tribe
    /// link, this account's own contact info or anything else is refused.
    /// Someone already a contact is not added again (another key exchange
    /// would cost sats for nothing). The key exchange pays `keyExchangeMsat`,
    /// through the usual balance and threshold checks (`checkPayment`): over
    /// the threshold it throws `needsConfirmation`, and the second call, with
    /// that amount as `confirmedMsat`, adds them. Too few sats, or no
    /// balance yet, throws `contactNeedsSats`. Returns their pubkey, which
    /// names the conversation, and whether a key exchange was started.
    @discardableResult
    public func addContact(
        code text: String, alias: String? = nil, confirmedMsat: UInt64? = nil
    ) async throws -> (pubkey: String, added: Bool) {
        let code = try ContactCode.read(text)
        guard let info = code.contactInfo, let pubkey = code.pubkey else { throw Failure.tribeLinkNotContact }
        if let own = try storage.value(for: .contactInfo).flatMap(ContactCode.contactInfo), own.hasPrefix(pubkey) {
            throw Failure.ownContactInfo
        }
        if Self.isPerson(pubkey, in: state) == true { return (pubkey, false) }
        // Nobody confirms a payment that cannot go.
        guard transport != nil else { throw Failure.notConnected }
        do {
            try checkPayment(Self.keyExchangeMsat, .threshold(confirmedMsat))
        } catch Failure.balanceUnknown, Failure.insufficientBalance {
            // Connected, no balance yet is a new account's 0 sats: its server
            // reports one only when it changes.
            throw Failure.contactNeedsSats
        }
        let name = alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? code.inviterName
        try await addContact(info, alias: name)
        return (pubkey, true)
    }

    // MARK: - Invites

    /// Makes an invite holding `amountMsat` for someone without an account,
    /// as the official apps do (`make_invite`): a keysend of the amount to
    /// this account's own server carrying a new code, which the server keeps
    /// with the sats (less its fee, if it charges one) until someone signs up
    /// with the invite or this account cancels it. The invite names this
    /// account, so whoever joins adds it as a contact.
    ///
    /// Every invite is confirmed with its amount, whatever the threshold:
    /// the sats leave for a code anyone holding it can spend. The balance and
    /// the connection are checked first, so nobody confirms an invite that
    /// cannot be made; then the first call throws `needsConfirmation`, and
    /// the second, with that amount as `confirmedMsat`, pays after the usual
    /// balance and threshold checks (`checkPayment`). Written before its
    /// payment is published; returned once the server confirms it, as the
    /// official apps show the code only then, or still sending when it does
    /// not within `wait` (`confirmedInvite`). The nickname and message are
    /// kept here only.
    public func makeInvite(
        amountMsat: UInt64, nickname: String? = nil, message: String? = nil, confirmedMsat: UInt64? = nil,
        wait: Duration = .seconds(30)
    ) async throws -> InviteRecord {
        guard amountMsat > 0, amountMsat <= UInt64(Int64.max) else { throw Failure.invalidAmount }
        let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard (nickname?.count ?? 0) <= InviteRecord.maxNicknameLength else { throw Failure.nicknameTooLong }
        guard (message?.count ?? 0) <= InviteRecord.maxMessageLength else { throw Failure.inviteMessageTooLong }
        try checkPayment(amountMsat, .unasked)
        guard isRegistered, transport != nil, let server else { throw Failure.notConnected }
        guard confirmedMsat == amountMsat else { throw Failure.needsConfirmation(amountMsat: amountMsat) }
        try checkPayment(amountMsat, .threshold(confirmedMsat))

        let time = clock.next()
        // The official apps also pass the tribes host and the config's
        // default tribe; with no default tribe (production's is empty) the
        // core leaves the tribe out, so neither is passed. The inviter is
        // this account, which the core fills in.
        let result = try Sphinxrs.makeInvite(
            seed: seed, uniqueTime: time, state: StateCodec.encode(state), host: "\(server.host):\(server.port)",
            amtMsat: amountMsat, myAlias: alias, tribeHost: nil, tribePubkey: nil, inviterPubkey: nil,
            inviterRouteHint: nil
        )
        guard let link = result.newInvite, let tag = result.msgs.first?.tag else {
            throw PeelError("the core made no invite")
        }
        let code = try Sphinxrs.codeFromInvite(inviteQr: link)
        let record = InviteRecord(
            code: code, link: link, amountMsat: Int64(amountMsat), nickname: nickname, message: message, tag: tag,
            status: .sending, createdAt: Date().millisecondsSince1970
        )
        let followUps = try commit(result, time: time, expectedSender: nil, invites: [record])
        do {
            try await complete(result, followUps)
        } catch Failure.notConnected {
            // The connection went before anything was published: nothing moved.
            _ = try? storage.setInviteStatus(code: code, to: .failed, from: [.sending])
            throw Failure.notConnected
        } catch {
            // Any other failure may have published the payment: waited for
            // like any other, and returned still sending if the server is quiet.
            emit.yield(.coreError(
                "The connection failed while making an invite; its payment may have gone. "
                    + "It stays unconfirmed until the server says (\(PeelError.readable(error)))"
            ))
        }
        return try await confirmedInvite(code: code, wait: wait)
    }

    /// The invite once the server confirms it, or as it stands after `wait`:
    /// still sending, its payment perhaps gone, so it is returned rather than
    /// thrown and nobody is offered to pay for it again. Whoever made it shows
    /// it waiting; the server is asked again on the next connect.
    func confirmedInvite(code: String, wait: Duration) async throws -> InviteRecord {
        do {
            _ = try await poll(timeout: wait, failure: .inviteNotConfirmed) { () -> Void? in
                (try? storage.invite(code: code))?.status == .sending ? nil : ()
            }
        } catch Failure.inviteNotConfirmed {}
        guard let invite = try storage.invite(code: code) else { throw Failure.noSuchInvite }
        if invite.status == .failed { throw Failure.inviteFailed }
        return invite
    }

    /// Asks the server for an invite's sats back (`cancel_invite`). The
    /// server answers only with the new balance, and with nothing at all
    /// when the invite was used meanwhile, so the invite counts as cancelled
    /// once the balance rises by at most its amount (the server may keep a
    /// fee). One at a time, so a rise is this cancel's (a payment of no more
    /// than the invite arriving at the same moment could still be taken for
    /// it). With no rise within `wait` it stays cancelling
    /// (`inviteNotRefunded`): it may have been used, or the sats may come
    /// later; it can be asked again, or forgotten (`forgetInvite`).
    @discardableResult
    public func cancelInvite(code: String, wait: Duration = .seconds(20)) async throws -> InviteRecord {
        let code = code.lowercased()
        guard let invite = try storage.invite(code: code) else { throw Failure.noSuchInvite }
        guard invite.status == .ready || invite.status == .cancelling else { throw Failure.inviteNotPending }
        guard isRegistered, transport != nil else { throw Failure.notConnected }
        guard !cancellingInvite else { throw Failure.cancelInProgress }
        cancellingInvite = true
        defer { cancellingInvite = false }

        guard let before = try balanceMsat() else { throw Failure.balanceUnknown }
        let wasReady = invite.status == .ready
        _ = try storage.setInviteStatus(code: code, to: .cancelling, from: [.ready, .cancelling])
        do {
            try await run { time, state in
                try Sphinxrs.cancelInvite(seed: seed, uniqueTime: time, state: state, inviteCode: code)
            }
        } catch Failure.notConnected {
            // Nothing was published.
            if wasReady { _ = try? storage.setInviteStatus(code: code, to: .ready, from: [.cancelling]) }
            throw Failure.notConnected
        }
        let most = UInt64(clamping: invite.amountMsat)
        try await poll(timeout: wait, failure: .inviteNotRefunded) { () -> Void? in
            guard let now = (try? storage.balanceMsat()) ?? nil, now > before, now - before <= most else { return nil }
            return ()
        }
        _ = try storage.setInviteStatus(code: code, to: .cancelled, from: [.cancelling])
        return try storage.invite(code: code) ?? invite
    }

    /// Drops an invite whose cancel the server never answered from the list:
    /// it was used, or its sats came back unnoticed. Only a cancelling one.
    public func forgetInvite(code: String) throws {
        guard try storage.setInviteStatus(code: code.lowercased(), to: .cancelled, from: [.cancelling]) else {
            throw Failure.inviteNotPending
        }
    }

}
