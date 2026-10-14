import CoreGraphics
import Foundation
import PeelCore

/// How a boost or payment went from here.
public enum PaymentOutcome: Equatable, Sendable {
    case sent
    /// Over the confirmation threshold: show this amount and ask once more.
    case needsConfirmation(msat: UInt64)
    case refused(String)
    /// The same payment is already on its way (a double click).
    case busy
}

/// What decides whether an invoice can be paid from here: a change to any
/// of it asks the engine again (`AppModel.verdict(on:)`). Pay stays off
/// until the verdict for what is shown now is in.
public struct InvoiceCheck: Equatable, Sendable {
    public let invoice: Invoice
    public let expired: Bool
    public let balanceMsat: UInt64?
    /// Our payment of it, as stored.
    public let paymentStatus: InvoiceRecord.Status?
    /// Our payment of it is in the server's history.
    public let inHistory: Bool

    public init(invoice: Invoice, expired: Bool, balanceMsat: UInt64?, paymentStatus: InvoiceRecord.Status?, inHistory: Bool) {
        self.invoice = invoice
        self.expired = expired
        self.balanceMsat = balanceMsat
        self.paymentStatus = paymentStatus
        self.inHistory = inHistory
    }
}

/// The engine's answer for an `InvoiceCheck`: what stops paying it, and
/// when it was paid when that is what stops it.
public struct InvoiceVerdict: Sendable {
    public let check: InvoiceCheck
    public let problem: Engine.Failure?
    public let paidAt: Date?

    /// For the invoice shown: while a recheck runs, its last note stays.
    public func about(_ invoice: Invoice) -> InvoiceVerdict? { check.invoice == invoice ? self : nil }

    /// Pay may go: the verdict is for exactly what is shown, and nothing stops it.
    public func allowsPaying(_ current: InvoiceCheck) -> Bool { check == current && problem == nil }
}

extension AppModel {
    // MARK: Boosts and payments

    /// The one-tap Boost, as in the official apps (Tom, 2026-10-07): the
    /// boost amount, plus a tribe's price, at once, with no panel and no
    /// confirmation. The row shows it pending, then the bolt or Retry,
    /// through storage; the engine ignores a second tap within a second. A
    /// refusal (the balance) shows in the chat, as the official apps' alert.
    ///
    /// A boost amount set on another device and over the threshold takes a
    /// second click, as a payment does: the first one names the amount, the
    /// next Boost of the same message sends it and confirms it for this Mac,
    /// while that notice is still shown (dismissed or replaced, it asks again).
    public func quickBoost(_ message: Message) async {
        guard let id = message.id else { return }
        let asking = boostToConfirm.flatMap { $0.messageID == id && conversationNotices[message.chat] == $0.notice ? $0 : nil }
        let confirmed = asking?.msat
        switch await pay("boost \(id)", { try await $0.quickBoost(messageID: id, confirmedMsat: confirmed) }) {
        case .refused(let reason): conversationNotices[message.chat] = PeelError.problem(reason, couldNot: "boost")
        case .sent:
            boostToConfirm = nil
            sent(in: message.chat)
            if let notice = conversationNotices[message.chat], notice == asking?.notice || notice.hasPrefix("Could not boost") {
                conversationNotices[message.chat] = nil
            }
        case .needsConfirmation(let msat):
            let notice = "Your boost amount, \(Sats.format(msat: msat)), was set on another device. Boost this message again to send it."
            boostToConfirm = (id, msat, notice)
            conversationNotices[message.chat] = notice
        case .busy: break
        }
    }

    /// "Boost 100 sats": the boost amount only, as the hover bar and menu
    /// name it. Neither official app shows a tribe's price on a boost (the
    /// chip's total then includes it, as theirs does).
    public var quickBoostLabel: String { "Boost \(Sats.format(msat: boostAmountMsat))" }

    /// Over the confirmation threshold the engine asks first, as for a payment.
    public func setBoostAmount(msat: UInt64, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let engine else { return .refused("Not signed in.") }
        do {
            try await engine.setBoostAmount(msat: msat, confirmedMsat: confirmedMsat)
            boostAmountMsat = msat
            return .sent
        } catch Engine.Failure.needsConfirmation(let msat) {
            return .needsConfirmation(msat: msat)
        } catch {
            return .refused(PeelError.problem(error))
        }
    }

    /// Sends sats to a contact in their chat, with an optional note and
    /// payment template (its muid).
    public func sendPayment(
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
    public func paymentTemplates() async throws -> [PaymentTemplate] {
        try await signedIn().paymentTemplates()
    }

    /// A template's picture for the picker, drawn at `maxPixels`.
    public func templateImage(muid: String, maxPixels: Int) async -> CGImage? {
        guard let engine else { return nil }
        return await ImageCache.shared.image(template: muid, host: nil, maxPixels: maxPixels) {
            try await engine.templateImage(muid: muid)
        }
    }

    /// The picture a payment in the chat carries, drawn at `maxPixels`;
    /// nil when it cannot be had (another host's, or the server's refusal).
    public func templateImage(of message: Message, maxPixels: Int) async -> CGImage? {
        guard let engine, let id = message.id, let template = message.paymentTemplate else { return nil }
        return await ImageCache.shared.image(template: template.muid, host: template.host, maxPixels: maxPixels) {
            try await engine.templateImage(messageID: id)
        }
    }

    /// Sends a failed payment or boost again, for the amount it was for.
    public func retryPayment(_ message: Message, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This payment cannot be sent again.") }
        return await pay("retry \(id)") { try await $0.resend(messageID: id, confirmedMsat: confirmedMsat) }
    }

    /// One payment at a time per key, through the engine; its refusals in
    /// words, and the threshold's question as an outcome.
    public func pay(_ key: String, _ action: (Engine) async throws -> Void) async -> PaymentOutcome {
        guard let engine else { return .refused("Not signed in.") }
        guard moneyInFlight.insert(key).inserted else { return .busy }
        defer { moneyInFlight.remove(key) }
        do {
            try await action(engine)
            return .sent
        } catch Engine.Failure.needsConfirmation(let msat) {
            return .needsConfirmation(msat: msat)
        } catch {
            return .refused(PeelError.problem(error))
        }
    }

    public func setPaymentConfirmation(msat: UInt64) async throws {
        try await signedIn().setPaymentConfirmation(msat: msat)
        paymentConfirmationMsat = msat
    }

    // MARK: History and invoices

    /// The payment history as it is fetched and joined, newest first.
    public func paymentHistoryUpdates(limit: Int) -> (some AsyncSequence<[PaymentItem], any Error>)? {
        engine?.storage.paymentHistory(limit: limit)
    }

    /// Fetches the page of the server's history older than what is stored.
    /// Returns how many rows came: fewer than a page means the end.
    public func fetchOlderPayments() async throws -> Int {
        try await signedIn().fetchOlderPaymentHistory()
    }

    /// Fetches what is new in the server's history since the last fetch.
    public func refreshPaymentHistory() async throws {
        try await signedIn().refreshPaymentHistory()
    }

    public func createInvoice(amountMsat: UInt64, memo: String) async throws -> InvoiceRecord {
        try await signedIn().createInvoice(amountMsat: amountMsat, memo: memo.trimmed)
    }

    public func invoiceUpdates(_ paymentHash: String, incoming: Bool) -> (some AsyncSequence<InvoiceRecord?, any Error>)? {
        engine?.storage.invoiceUpdates(paymentHash: paymentHash, incoming: incoming)
    }

    /// What stops paying this invoice, by the engine's own rules, and when
    /// it was paid (here or from another device) when that is what stops
    /// it. These are storage reads, so they run off the main actor.
    public func invoiceProblem(_ invoice: Invoice) async -> (problem: Engine.Failure?, paidAt: Date?) {
        guard let engine else { return (nil, nil) }
        return await Task.detached {
            let problem = (try? engine.invoiceProblem(invoice)) ?? nil
            guard problem == .invoiceAlreadyPaid,
                  case .paid(let at)? = try? engine.storage.paidState(paymentHash: invoice.paymentHash) else { return (problem, nil) }
            return (problem, at)
        }.value
    }

    /// `invoiceProblem` for what a Pay screen shows now, kept with what it
    /// was asked for, so the screen can tell an answer still current.
    public func verdict(on check: InvoiceCheck) async -> InvoiceVerdict {
        let (problem, paidAt) = await invoiceProblem(check.invoice)
        return InvoiceVerdict(check: check, problem: problem, paidAt: paidAt)
    }

    /// Why an invoice cannot be paid from here (`invoiceProblem`), in words:
    /// a title and a line under it, for the Pay screens' amber note.
    public func invoiceBlocker(_ problem: Engine.Failure, invoice: Invoice, paidAt: Date?) -> (title: String, detail: String) {
        switch problem {
        case .invoiceWithoutAmount:
            ("This invoice names no amount", "Ask for one with an amount.")
        case .invoiceExpired:
            ("This invoice has expired", "Ask for a new one.")
        case .ownInvoice:
            ("This is your own invoice", "Send it to whoever is paying you.")
        case .invoiceAlreadyPaid:
            ("You already paid this invoice", paidAt.map { "On \(Formatting.moment($0))." } ?? "")
        case .invoicePending:
            ("A payment of this invoice is on its way", "It may have paid already.")
        case .insufficientBalance:
            ("Not enough sats",
             "Needs \(Sats.format(msat: invoice.amountMsat)) plus up to \(Sats.format(msat: Engine.feeReserveMsat(for: invoice.amountMsat))) "
                 + "in fees. You have \(Sats.format(msat: balanceMsat ?? 0)).")
        default:
            ("This invoice cannot be paid now", problem.description)
        }
    }

    public func payInvoice(_ invoice: Invoice, confirmedMsat: UInt64?) async -> PaymentOutcome {
        await pay("invoice \(invoice.paymentHash)") {
            _ = try await $0.payInvoice(invoice.bolt11, confirmedMsat: confirmedMsat)
        }
    }

    /// Pays someone's request in their chat.
    public func payRequest(_ message: Message, invoice: Invoice, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This request cannot be paid.") }
        return await pay("invoice \(invoice.paymentHash)") {
            _ = try await $0.payRequest(messageID: id, confirmedMsat: confirmedMsat)
        }
    }

    public func requestPayment(from chat: String, amountMsat: UInt64, memo: String) async throws {
        _ = try await signedIn().requestPayment(from: chat, amountMsat: amountMsat, memo: memo.trimmed)
    }

    /// A contact's name for a node key, when the key is a contact's.
    public func contactName(_ pubkey: String) -> String? {
        conversations.first { !$0.isTribe && $0.chat == pubkey }?.name
    }

    // MARK: Paid attachments

    /// Buys someone else's paid attachment; it opens once its seller sends the key.
    public func buyAttachment(_ message: Message, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This attachment cannot be bought.") }
        return await pay("purchase \(id)") { try await $0.buyAttachment(messageID: id, confirmedMsat: confirmedMsat) }
    }
}
