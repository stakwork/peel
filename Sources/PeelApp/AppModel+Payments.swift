import CoreGraphics
import Foundation
import PeelCore

/// How a boost or payment went from here.
enum PaymentOutcome: Equatable {
    case sent
    /// Over the confirmation threshold: show this amount and ask once more.
    case needsConfirmation(msat: UInt64)
    case refused(String)
    /// The same payment is already on its way (a double click).
    case busy
}

extension AppModel {
    // MARK: Boosts and payments

    /// The one-tap Boost, as in the official apps (Tom, 2026-10-07): the
    /// boost amount, plus a tribe's price, at once, with no panel and no
    /// confirmation. The row shows it pending, then the bolt or Retry,
    /// through storage; the engine ignores a second tap within a second. A
    /// refusal (the balance) shows in the chat, as the official apps' alert.
    func quickBoost(_ message: Message) async {
        guard let id = message.id else { return }
        switch await pay("boost \(id)", { try await $0.quickBoost(messageID: id) }) {
        case .refused(let reason): conversationNotices[message.chat] = "Could not boost: \(reason)"
        case .sent:
            sent(in: message.chat)
            if conversationNotices[message.chat]?.hasPrefix("Could not boost") == true {
                conversationNotices[message.chat] = nil
            }
        case .needsConfirmation, .busy: break
        }
    }

    /// "Boost 100 sats": the boost amount only, as the hover bar and menu
    /// name it. Neither official app shows a tribe's price on a boost (the
    /// chip's total then includes it, as theirs does).
    var quickBoostLabel: String { "Boost \(Sats.format(msat: boostAmountMsat))" }

    /// Over the confirmation threshold the engine asks first, as for a payment.
    func setBoostAmount(msat: UInt64, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let engine else { return .refused("Not signed in.") }
        do {
            try await engine.setBoostAmount(msat: msat, confirmedMsat: confirmedMsat)
            boostAmountMsat = msat
            return .sent
        } catch Engine.Failure.needsConfirmation(let msat) {
            return .needsConfirmation(msat: msat)
        } catch {
            return .refused(PeelError.readable(error))
        }
    }

    /// Sends sats to a contact in their chat, with an optional note and
    /// payment template (its muid).
    func sendPayment(
        to chat: String, amountMsat: UInt64, note: String, template: String?, confirmedMsat: UInt64?
    ) async -> PaymentOutcome {
        let outcome = await pay("pay \(chat)") {
            try await $0.sendPayment(
                to: chat, amountMsat: amountMsat, text: note.trimmed, template: template, confirmedMsat: confirmedMsat
            )
        }
        if case .sent = outcome { sent(in: chat) }
        return outcome
    }

    // MARK: Payment templates

    /// The pictures a payment can carry, from the account's memes server.
    func paymentTemplates() async throws -> [PaymentTemplate] {
        try await signedIn().paymentTemplates()
    }

    /// A template's picture for the picker, drawn at `maxPixels`.
    func templateImage(muid: String, maxPixels: Int) async -> CGImage? {
        guard let engine else { return nil }
        return await ImageCache.shared.image(template: muid, host: nil, maxPixels: maxPixels) {
            try await engine.templateImage(muid: muid)
        }
    }

    /// The picture a payment in the chat carries, drawn at `maxPixels`;
    /// nil when it cannot be had (another host's, or the server's refusal).
    func templateImage(of message: Message, maxPixels: Int) async -> CGImage? {
        guard let engine, let id = message.id, let template = message.paymentTemplate else { return nil }
        return await ImageCache.shared.image(template: template.muid, host: template.host, maxPixels: maxPixels) {
            try await engine.templateImage(messageID: id)
        }
    }

    /// Sends a failed payment or boost again, for the amount it was for.
    func retryPayment(_ message: Message, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This payment cannot be sent again.") }
        return await pay("retry \(id)") { try await $0.resend(messageID: id, confirmedMsat: confirmedMsat) }
    }

    /// One payment at a time per key, through the engine; its refusals in
    /// words, and the threshold's question as an outcome.
    func pay(_ key: String, _ action: (Engine) async throws -> Void) async -> PaymentOutcome {
        guard let engine else { return .refused("Not signed in.") }
        guard moneyInFlight.insert(key).inserted else { return .busy }
        defer { moneyInFlight.remove(key) }
        do {
            try await action(engine)
            return .sent
        } catch Engine.Failure.needsConfirmation(let msat) {
            return .needsConfirmation(msat: msat)
        } catch {
            return .refused(PeelError.readable(error))
        }
    }

    func setPaymentConfirmation(msat: UInt64) async throws {
        try await signedIn().setPaymentConfirmation(msat: msat)
        paymentConfirmationMsat = msat
    }

    // MARK: History and invoices

    /// The payment history as it is fetched and joined, newest first.
    func paymentHistoryUpdates(limit: Int) -> (some AsyncSequence<[PaymentItem], any Error>)? {
        engine?.storage.paymentHistory(limit: limit)
    }

    /// Fetches the page of the server's history older than what is stored.
    /// Returns how many rows came: fewer than a page means the end.
    func fetchOlderPayments() async throws -> Int {
        try await signedIn().fetchOlderPaymentHistory()
    }

    /// Fetches what is new in the server's history since the last fetch.
    func refreshPaymentHistory() async throws {
        try await signedIn().refreshPaymentHistory()
    }

    func createInvoice(amountMsat: UInt64, memo: String) async throws -> InvoiceRecord {
        try await signedIn().createInvoice(amountMsat: amountMsat, memo: memo.trimmed)
    }

    func invoiceUpdates(_ paymentHash: String, incoming: Bool) -> (some AsyncSequence<InvoiceRecord?, any Error>)? {
        engine?.storage.invoiceUpdates(paymentHash: paymentHash, incoming: incoming)
    }

    /// What stops paying this invoice, by the engine's own rules, and when
    /// it was paid (here or from another device) when that is what stops
    /// it. These are storage reads, so they run off the main actor.
    func invoiceProblem(_ invoice: Invoice) async -> (problem: Engine.Failure?, paidAt: Date?) {
        guard let engine else { return (nil, nil) }
        return await Task.detached {
            let problem = (try? engine.invoiceProblem(invoice)) ?? nil
            guard problem == .invoiceAlreadyPaid,
                  case .paid(let at)? = try? engine.storage.paidState(paymentHash: invoice.paymentHash) else { return (problem, nil) }
            return (problem, at)
        }.value
    }

    func payInvoice(_ invoice: Invoice, confirmedMsat: UInt64?) async -> PaymentOutcome {
        await pay("invoice \(invoice.paymentHash)") {
            _ = try await $0.payInvoice(invoice.bolt11, confirmedMsat: confirmedMsat)
        }
    }

    /// Pays someone's request in their chat.
    func payRequest(_ message: Message, invoice: Invoice, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This request cannot be paid.") }
        return await pay("invoice \(invoice.paymentHash)") {
            _ = try await $0.payRequest(messageID: id, confirmedMsat: confirmedMsat)
        }
    }

    func requestPayment(from chat: String, amountMsat: UInt64, memo: String) async throws {
        _ = try await signedIn().requestPayment(from: chat, amountMsat: amountMsat, memo: memo.trimmed)
    }

    /// A contact's name for a node key, when the key is a contact's.
    func contactName(_ pubkey: String) -> String? {
        conversations.first { !$0.isTribe && $0.chat == pubkey }?.name
    }

    // MARK: Paid attachments

    /// Buys someone else's paid attachment; it opens once its seller sends the key.
    func buyAttachment(_ message: Message, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This attachment cannot be bought.") }
        return await pay("purchase \(id)") { try await $0.buyAttachment(messageID: id, confirmedMsat: confirmedMsat) }
    }
}
