import Foundation
import PeelCore

extension AppModel {
    /// Adds whoever a scanned or pasted code names (`Engine.addContact(code:)`),
    /// through the engine's payment checks: the key exchange pays 5 sats.
    /// Someone already a contact is not added again: their chat opens.
    /// Returns whether a key exchange was started, once the engine went ahead.
    func addContact(code: String, alias: String, confirmedMsat: UInt64?) async -> (PaymentOutcome, Bool?) {
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
    func makeInvite(
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

    func cancelInvite(_ code: String) async throws {
        try await signedIn().cancelInvite(code: code)
    }

    func forgetInvite(_ code: String) async throws {
        try await signedIn().forgetInvite(code: code)
    }
}
