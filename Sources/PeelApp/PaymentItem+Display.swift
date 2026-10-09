import Foundation
import PeelCore

/// The list's groups, by relative time.
enum PaymentSection: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "Earlier this week"
    case earlier = "Earlier"

    init(_ date: Date, now: Date = .now) {
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
    var title: String {
        if let counterpart { return counterpart }
        switch kind {
        case .invoice: return incoming ? "Invoice paid" : "Lightning invoice"
        case .keysend: return "Keysend"
        case .payment, .boost, .purchase, .messageFee: return chatName ?? Sender.unnamed
        }
    }

    private var isRefund: Bool { message?.type == MessageType.purchaseDeny }

    /// The one line under the name.
    var subtitle: String {
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
        }
    }

    /// "Boost received", "Payment sent".
    var headline: String {
        let what = switch kind {
        case .boost: "Boost"
        case .payment: "Payment"
        case .invoice: "Invoice payment"
        case .keysend: "Keysend"
        case .purchase: isRefund ? "Refund" : "Purchase"
        case .messageFee: "Message fee"
        }
        return "\(what) \(incoming ? "received" : status == .pending ? "on its way" : "sent")"
    }
}
