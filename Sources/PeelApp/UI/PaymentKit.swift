import PeelCore
import PeelUI
import SwiftUI

// Payments' pieces the Mac and the iPhone share: amounts as Payments and a
// chat show them, and an invoice's expiry as it comes.

/// The amount as banking apps show it: "+500" received (green), "−2,000"
/// sent in the text colour; the sign carries direction, not colour alone.
/// Pending reads grey, failed struck through.
struct SignedAmount: View {
    let msat: Int64
    let incoming: Bool
    var status: PaymentItem.Status = .complete
    var size: CGFloat = 14

    var body: some View {
        Text(Sats.signed(msat: msat, incoming: incoming))
        .strikethrough(status == .failed)
        .font(Theme.font(size, .semibold))
        .monospacedDigit()
        .foregroundStyle(status != .complete ? Theme.secondaryText : incoming ? Theme.confirmed : Theme.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let amount = Sats.format(msat: msat)
        switch status {
        case .complete: return "\(incoming ? "Received" : "Sent") \(amount)"
        case .pending: return "\(incoming ? "Receiving" : "Sending") \(amount), pending"
        case .unsettled: return "\(incoming ? "Receiving" : "Sending") \(amount), not settled"
        case .failed: return "\(incoming ? "Receipt" : "Send") of \(amount) failed"
        }
    }
}

/// A pane's or a request card's headline figure: the amount large and bold,
/// "sats" after it smaller and grey. With no colour, the amount takes the
/// surrounding one.
struct BigAmount: View {
    let amount: String
    var size: CGFloat = 32
    var color: Color?
    var struck = false
    var unitSize: CGFloat = 15
    var spacing: CGFloat = 7

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            Text(amount)
                .font(Theme.font(size, .bold))
                .strikethrough(struck)
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
            Text("sats").font(Theme.font(unitSize)).foregroundStyle(Theme.secondaryText)
        }
        .monospacedDigit()
    }
}

/// Its content, told whether the invoice has expired, and drawn again the
/// moment it does, so Pay goes then rather than at the next redraw.
struct UntilExpiry<Content: View>: View {
    let invoice: Invoice
    @ViewBuilder let content: (_ expired: Bool) -> Content

    var body: some View {
        TimelineView(.redrawing(at: invoice.expiresAt)) { context in
            content(invoice.isExpired(now: context.date))
        }
    }
}

/// A setting's presets, with its current value among them if it is not one.
func presets<Value: Comparable>(_ choices: [Value], including current: Value) -> [Value] {
    choices.contains(current) ? choices : (choices + [current]).sorted()
}
