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
    /// to the next direct message (or the one above, or nothing). With
    /// `movesSelection` false (the phone, where the next chat would open)
    /// nothing is selected instead.
    public func deleteContact(_ pubkey: String, movesSelection: Bool = true) async throws {
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
            let index = movesSelection ? direct.firstIndex(of: pubkey) : nil
            let next = index.flatMap { direct.indices.contains($0 + 1) ? direct[$0 + 1] : $0 > 0 ? direct[$0 - 1] : nil }
            destination = next.map(Destination.chat)
        }
    }

    /// What a typed, pasted or scanned code is, or why it is none (the Mac's
    /// Add contact and the phone's read it the same way).
    public static func readContactCode(_ text: String) -> (code: ContactCode?, problem: String?) {
        do {
            return (try ContactCode.read(text), nil)
        } catch {
            return (nil, PeelError.noted(error))
        }
    }

    /// Who the key exchange went to, for "Sent to …": the name typed, the
    /// inviter's, or "them".
    public static func addedName(alias: String, code: ContactCode?) -> String {
        alias.trimmed.nilIfEmpty ?? code?.inviterName ?? "them"
    }

    /// Since when someone is a contact: their chat's oldest message.
    public func contactSince(_ chat: String) -> Date? {
        (try? engine?.storage.firstMessageTime(in: chat)).flatMap { $0 }.map(Date.init(millisecondsSince1970:))
    }

    public func cancelInvite(_ code: String) async throws {
        try await signedIn().cancelInvite(code: code)
    }

    public func forgetInvite(_ code: String) async throws {
        try await signedIn().forgetInvite(code: code)
    }
}
