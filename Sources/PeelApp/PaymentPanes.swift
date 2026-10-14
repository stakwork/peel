import SwiftUI
import PeelCore

/// A right-hand pane: its title, a close button, and what it holds.
struct PaneFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: title, leading: { EmptyView() }) {
                IconButton("xmark", help: "Close (Escape)", action: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                // In the scroll view as well: a click there never reaches a gesture outside it.
                .endsEditingOnClick()
            }
        }
        .endsEditingOnClick()
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
