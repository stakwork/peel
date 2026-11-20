import Foundation
import PeelCore

/// The list's groups, by relative time.
public enum PaymentSection: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "Earlier this week"
    case earlier = "Earlier"

    /// The section's header, in the reader's language (`rawValue` is the stable id).
    public var title: String {
        switch self {
        case .today: String(localized: "Today", table: "Shared")
        case .yesterday: String(localized: "Yesterday", table: "Shared")
        case .thisWeek: String(localized: "Earlier this week", table: "Shared")
        case .earlier: String(localized: "Earlier", table: "Shared")
        }
    }

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
        case .invoice: return incoming ? String(localized: "Invoice paid", table: "Shared") : String(localized: "Lightning invoice", table: "Shared")
        case .keysend: return String(localized: "Keysend", table: "Shared")
        case .payment, .boost, .purchase, .messageFee, .keyExchange: return chatName ?? Sender.unnamed
        }
    }

    /// A key exchange, from this account's side.
    private var keyExchangeLabel: String { addedThem ? String(localized: "Contact added", table: "Shared") : String(localized: "Added you", table: "Shared") }

    private var isRefund: Bool { message?.type == MessageType.purchaseDeny }

    /// The one line under the name.
    public var subtitle: String {
        if status == .failed, let error { return error }
        if kind == .boost { return isTribe ? String(localized: "Boost in #\(chatName ?? "")", table: "Shared") : String(localized: "Boost", table: "Shared") }
        if let note { return note }
        switch kind {
        case .keysend: return incoming ? String(localized: "Received, not tied to a chat", table: "Shared") : String(localized: "Sent, not tied to a chat", table: "Shared")
        case .invoice:
            return invoice.map { incoming ? String(localized: "Your invoice", table: "Shared") : String(localized: "To \(Formatting.shortKey($0.payee))", table: "Shared") } ?? String(localized: "Invoice", table: "Shared")
        case .payment, .boost: return isTribe ? String(localized: "In #\(chatName ?? "")", table: "Shared") : String(localized: "Payment", table: "Shared")
        case .purchase:
            if isRefund { return incoming ? String(localized: "Refund for an attachment you tried to buy", table: "Shared") : String(localized: "Refund of a purchase", table: "Shared") }
            return incoming ? String(localized: "Bought your paid attachment", table: "Shared") : String(localized: "Unlocked a paid attachment", table: "Shared")
        case .messageFee:
            let tribe = "#\(chatName ?? "")"
            switch message?.type {
            case MessageType.groupJoin: return String(localized: "Joined \(tribe)", table: "Shared")
            case MessageType.memberRequest: return String(localized: "Asked to join \(tribe)", table: "Shared")
            default: return String(localized: "Message fee in \(tribe)", table: "Shared")
            }
        case .keyExchange: return keyExchangeLabel
        }
    }

    /// Why a key exchange moves sats, for its detail.
    public var keyExchangeNote: String? {
        guard kind == .keyExchange else { return nil }
        let five = Sats.format(msat: Engine.keyExchangeMsat), three = Sats.format(msat: Engine.priceToMeetMsat)
        return addedThem
            ? String(localized: "Adding \(chatName ?? String(localized: "them", table: "Shared")) cost \(five), and \(three) came back.", table: "Shared")
            : String(localized: "\(chatName ?? String(localized: "They", table: "Shared")) paid \(five) to add you, and \(three) went back.", table: "Shared")
    }

    /// "Boost received", "Payment sent".
    public var headline: String {
        let what = switch kind {
        case .boost: String(localized: "Boost", table: "Shared")
        case .payment: String(localized: "Payment", table: "Shared")
        case .invoice: String(localized: "Invoice payment", table: "Shared")
        case .keysend: String(localized: "Keysend", table: "Shared")
        case .purchase: isRefund ? String(localized: "Refund", table: "Shared") : String(localized: "Purchase", table: "Shared")
        case .messageFee: String(localized: "Message fee", table: "Shared")
        case .keyExchange: String(localized: "\(keyExchangeLabel):", table: "Shared")
        }
        let how = switch status {
        case .pending where !incoming: String(localized: "on its way", table: "Shared")
        case .unsettled: String(localized: "not settled", table: "Shared")
        case .failed where incoming: String(localized: "not received", table: "Shared")
        default: incoming ? String(localized: "received", table: "Shared") : String(localized: "sent", table: "Shared")
        }
        return String(localized: "\(what) \(how)", table: "Shared")
    }

    /// A row's time with what is still to happen: "Pending · 14:22",
    /// "Waiting · 14:22" for a contact who is offline, "Failed · 14:22".
    public func timeWithStatus(_ time: String) -> String {
        switch status {
        case .complete: time
        case .pending: isToContact ? String(localized: "Waiting · \(time)", table: "Shared") : String(localized: "Pending · \(time)", table: "Shared")
        case .unsettled: String(localized: "Not settled · \(time)", table: "Shared")
        case .failed: incoming ? String(localized: "Not received · \(time)", table: "Shared") : String(localized: "Failed · \(time)", table: "Shared")
        }
    }

    /// Who it was with, under their name in its detail.
    public var context: String {
        if isTribe { return counterpart == nil ? String(localized: "In #\(chatName ?? "")", table: "Shared") : String(localized: "Member of #\(chatName ?? "")", table: "Shared") }
        if chat != nil { return String(localized: "Contact", table: "Shared") }
        if let invoice, !invoice.incoming {
            return String(localized: "To \(Formatting.shortKey(invoice.payee)), not a contact", table: "Shared")
        }
        return String(localized: "Not tied to a contact", table: "Shared")
    }

    /// The message a boost was for, or the one a fee was for, and what to call it.
    public var quoted: (label: String, message: Message)? {
        if let boosted { return (incoming ? String(localized: "Boosted your message", table: "Shared") : String(localized: "You boosted", table: "Shared"), boosted) }
        if kind == .messageFee, let message { return (String(localized: "Your message", table: "Shared"), message) }
        return nil
    }

    /// What an unsettled payment's detail says: the message went, the sats may not have.
    public static let notSettled = String(localized: "Unconfirmed. Check your balance to see if it went", table: "Shared")

    /// The status in its detail, and its symbol; `settled` when it is done.
    public var statusFact: (text: String, symbol: String, settled: Bool) {
        switch status {
        case .complete:
            (incoming ? String(localized: "Received", table: "Shared") : String(localized: "Settled", table: "Shared"), "checkmark", true)
        case .pending:
            (isToContact ? String(localized: "Waiting for \(chatName ?? String(localized: "them", table: "Shared")) to come online, can't be cancelled", table: "Shared") : String(localized: "Pending", table: "Shared"), "clock", false)
        case .unsettled:
            (Self.notSettled, "questionmark.circle", false)
        case .failed where incoming:
            (error ?? String(localized: "Not received", table: "Shared"), "xmark", false)
        case .failed:
            (error.map { String(localized: "Failed: \($0), nothing was sent", table: "Shared") } ?? String(localized: "Failed, nothing was sent", table: "Shared"), "xmark", false)
        }
    }
}
