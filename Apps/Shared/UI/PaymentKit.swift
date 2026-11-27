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
        case .complete: return incoming ? String(localized: "Received \(amount)", table: "Shared") : String(localized: "Sent \(amount)", table: "Shared")
        case .pending: return incoming ? String(localized: "Receiving \(amount), pending", table: "Shared") : String(localized: "Sending \(amount), pending", table: "Shared")
        case .unsettled: return incoming ? String(localized: "Receiving \(amount), not settled", table: "Shared") : String(localized: "Sending \(amount), not settled", table: "Shared")
        case .failed: return incoming ? String(localized: "Receiving \(amount) failed", table: "Shared") : String(localized: "Sending \(amount) failed", table: "Shared")
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
    /// The number `amount` shows, for a figure that changes in place (the
    /// balance): it rolls digit by digit when the change comes in an
    /// animation (`MoneyArrivals` rolls only a rise a payment explains),
    /// and otherwise just changes. nil for a figure that never changes.
    var rolling: Double?
    /// The widest the figure will be while it rolls, laid out hidden, so
    /// "sats" never slides as digits come.
    var widest: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            ZStack(alignment: .leading) {
                if let widest { Text(widest).hidden() }
                Text(amount)
                    .strikethrough(struck)
                    .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
                    .contentTransition(rolling.map { reduceMotion ? .identity : .numericText(value: $0) } ?? .identity)
            }
            .font(Theme.font(size, .bold))
            Text("sats", tableName: "Shared").font(Theme.font(unitSize)).foregroundStyle(Theme.secondaryText)
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
