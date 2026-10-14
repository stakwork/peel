import Foundation
import PeelCore

extension AppModel {
    /// Adds whoever a scanned or pasted code names (`Engine.addContact(code:)`),
    /// through the engine's payment checks: the key exchange pays 5 sats.
    /// Someone already a contact is not added again: their chat opens.
    /// Returns whether a key exchange was started, once the engine went ahead.
    public func addContact(code: String, alias: String, confirmedMsat: UInt64?) async -> (PaymentOutcome, Bool?) {
        var added: Bool?
        let outcome = await pay("add contact") {
            let (pubkey, started) = try await $0.addContact(code: code, alias: alias.trimmed, confirmedMsat: confirmedMsat)
            if !started { destination = .chat(pubkey) }
            added = started
        }
        return (outcome, added)
    }

    /// Makes an invite with sats, through the engine's payment checks; the
    /// engine always asks to confirm the amount first.
    public func makeInvite(
        amountMsat: UInt64, nickname: String, message: String, confirmedMsat: UInt64?
    ) async -> (PaymentOutcome, InviteRecord?) {
        var made: InviteRecord?
        let outcome = await pay("invite") {
            made = try await $0.makeInvite(
                amountMsat: amountMsat, nickname: nickname, message: message, confirmedMsat: confirmedMsat
            )
        }
        return (outcome, made)
    }

    /// Removes a contact (`Engine.deleteContact`), then what this window
    /// kept for their chat: a call in it is left, its thread, drafts,
    /// replies, files waiting and notifications go, and the selection moves
    /// to the next direct message (or the one above, or nothing).
    public func deleteContact(_ pubkey: String) async throws {
        let direct = sidebarSections.direct.map(\.chat)
        try await signedIn().deleteContact(pubkey)
        if calls.call?.chat == pubkey { calls.leave() }
        if openThread?.chat == pubkey { openThread = nil }
        let composers = Set(drafts.keys).union(replyTargets.keys).union(pendingFiles.keys).union(attachmentPrices.keys)
        for composer in composers where composer.chat == pubkey {
            drafts[composer] = nil
            replyTargets[composer] = nil
            attachmentPrices[composer] = nil
            pendingFiles.removeValue(forKey: composer)?.forEach { IncomingFiles.discard($0) }
        }
        conversationNotices[pubkey] = nil
        notifier.removeDelivered(in: [pubkey])
        if selectedChat == pubkey {
            let index = direct.firstIndex(of: pubkey)
            let next = index.flatMap { direct.indices.contains($0 + 1) ? direct[$0 + 1] : $0 > 0 ? direct[$0 - 1] : nil }
            destination = next.map(Destination.chat)
        }
    }

    public func cancelInvite(_ code: String) async throws {
        try await signedIn().cancelInvite(code: code)
    }

    public func forgetInvite(_ code: String) async throws {
        try await signedIn().forgetInvite(code: code)
    }
}
