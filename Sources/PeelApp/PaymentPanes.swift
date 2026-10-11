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

extension TimelineSchedule where Self == ExplicitTimelineSchedule<[Date]> {
    /// Draws now and again at `date`. `.now` comes first because, before
    /// its first entry, a timeline draws with that entry's date: a lone
    /// future date reads as already passed. A date already passed is left
    /// out: entries must not go back in time, or the timeline redraws on
    /// every frame for as long as it is on screen.
    static func redrawing(at date: Date?) -> Self {
        let now = Date.now
        return .explicit([now] + [date].compactMap { $0 }.filter { $0 > now })
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
