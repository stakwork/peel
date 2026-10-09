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
                HeaderButton(systemImage: "xmark", help: "Close (Escape)", action: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(20)
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

/// Facts in two columns: the name on the left, the value (with an icon, or
/// a Copy button) on the right.
struct KeyValues: View {
    struct Row: Identifiable {
        let key: String
        let value: String
        var symbol: String?
        var tint: Color?
        var monospaced = false
        /// Text a Copy button beside the value puts on the clipboard.
        var copy: String?
        var id: String { key }
    }

    let rows: [Row]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.key)
                        .foregroundStyle(Theme.secondaryText)
                        .gridColumnAlignment(.leading)
                    HStack(spacing: 6) {
                        if let symbol = row.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(row.tint ?? Theme.secondaryText)
                        }
                        Text(row.value)
                            .font(row.monospaced ? .system(size: 12, design: .monospaced) : Theme.font(13))
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let copy = row.copy {
                            CopyButton("Copy", text: copy).buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }
        }
        .font(Theme.font(13))
    }
}

/// An amber note: something blocks the next step. Never red: nothing was lost.
struct AttentionNote<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.attention)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(13, .semibold))
                Text(detail)
                    .font(Theme.font(13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.attention.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.attention.opacity(0.28)))
    }
}

extension AttentionNote where Actions == EmptyView {
    init(title: String, detail: String) {
        self.init(title: title, detail: detail, actions: { EmptyView() })
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
