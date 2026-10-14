import Foundation
import PeelCore

/// The list's groups, by relative time.
public enum PaymentSection: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "Earlier this week"
    case earlier = "Earlier"

    public init(_ date: Date, now: Date = .now) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            self = .today
        } else if calendar.isDateInYesterday(date) {
            self = .yesterday
        } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear), date < now {
            self = .thisWeek
        } else {
            self = .earlier
        }
    }
}

extension PaymentItem {
    /// The row's name: who, or what it was when nobody is known.
    public var title: String {
        if let counterpart { return counterpart }
        switch kind {
        case .invoice: return incoming ? "Invoice paid" : "Lightning invoice"
        case .keysend: return "Keysend"
        case .payment, .boost, .purchase, .messageFee, .keyExchange: return chatName ?? Sender.unnamed
        }
    }

    /// A key exchange, from this account's side.
    private var keyExchangeLabel: String { addedThem ? "Contact added" : "Added you" }

    private var isRefund: Bool { message?.type == MessageType.purchaseDeny }

    /// The one line under the name.
    public var subtitle: String {
        if status == .failed, let error { return error }
        if kind == .boost { return isTribe ? "Boost in #\(chatName ?? "")" : "Boost" }
        if let note { return note }
        switch kind {
        case .keysend: return incoming ? "Received, not tied to a chat" : "Sent, not tied to a chat"
        case .invoice:
            return invoice.map { incoming ? "Your invoice" : "To \(Formatting.shortKey($0.payee))" } ?? "Invoice"
        case .payment, .boost: return isTribe ? "In #\(chatName ?? "")" : "Payment"
        case .purchase:
            if isRefund { return incoming ? "Refund for an attachment you tried to buy" : "Refund of a purchase" }
            return incoming ? "Bought your paid attachment" : "Unlocked a paid attachment"
        case .messageFee:
            let tribe = "#\(chatName ?? "")"
            switch message?.type {
            case MessageType.groupJoin: return "Joined \(tribe)"
            case MessageType.memberRequest: return "Asked to join \(tribe)"
            default: return "Message fee in \(tribe)"
            }
        case .keyExchange: return keyExchangeLabel
        }
    }

    /// Why a key exchange moves sats, for its detail.
    public var keyExchangeNote: String? {
        guard kind == .keyExchange else { return nil }
        let five = Sats.format(msat: Engine.keyExchangeMsat), three = Sats.format(msat: Engine.priceToMeetMsat)
        return addedThem
            ? "Adding \(chatName ?? "them") cost \(five), and \(three) came back."
            : "\(chatName ?? "They") paid \(five) to add you, and \(three) went back."
    }

    /// "Boost received", "Payment sent".
    public var headline: String {
        let what = switch kind {
        case .boost: "Boost"
        case .payment: "Payment"
        case .invoice: "Invoice payment"
        case .keysend: "Keysend"
        case .purchase: isRefund ? "Refund" : "Purchase"
        case .messageFee: "Message fee"
        case .keyExchange: "\(keyExchangeLabel):"
        }
        let how = switch status {
        case .pending where !incoming: "on its way"
        case .unsettled: "not settled"
        case .failed where incoming: "not received"
        default: incoming ? "received" : "sent"
        }
        return "\(what) \(how)"
    }

    /// A row's time with what is still to happen: "Pending · 14:22",
    /// "Waiting · 14:22" for a contact who is offline, "Failed · 14:22".
    public func timeWithStatus(_ time: String) -> String {
        switch status {
        case .complete: time
        case .pending: "\(isToContact ? "Waiting" : "Pending") · \(time)"
        case .unsettled: "Not settled · \(time)"
        case .failed: "\(incoming ? "Not received" : "Failed") · \(time)"
        }
    }

    /// Who it was with, under their name in its detail.
    public var context: String {
        if isTribe { return counterpart == nil ? "In #\(chatName ?? "")" : "Member of #\(chatName ?? "")" }
        if chat != nil { return "Contact" }
        if let invoice, !invoice.incoming {
            return "To \(Formatting.shortKey(invoice.payee)), not a contact"
        }
        return "Not tied to a contact"
    }

    /// The message a boost was for, or the one a fee was for, and what to call it.
    public var quoted: (label: String, message: Message)? {
        if let boosted { return (incoming ? "Boosted your message" : "You boosted", boosted) }
        if kind == .messageFee, let message { return ("Your message", message) }
        return nil
    }

    /// What an unsettled payment's detail says: the message went, the sats may not have.
    public static let notSettled = "Unconfirmed. Check your balance to see if it went"

    /// The status in its detail, and its symbol; `settled` when it is done.
    public var statusFact: (text: String, symbol: String, settled: Bool) {
        switch status {
        case .complete:
            (incoming ? "Received" : "Settled", "checkmark", true)
        case .pending:
            (isToContact ? "Waiting for \(chatName ?? "them") to come online, can't be cancelled" : "Pending", "clock", false)
        case .unsettled:
            (Self.notSettled, "questionmark.circle", false)
        case .failed where incoming:
            (error ?? "Not received", "xmark", false)
        case .failed:
            ("Failed\(error.map { ": \($0)" } ?? ""), nothing was sent", "xmark", false)
        }
    }
}
