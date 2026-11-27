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
                IconButton("xmark", help: String(localized: "Close (Escape)"), action: close)
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

/// A payment form as a card under the wallet's Deposit and Withdraw (Tom,
/// 2026-11-27: in the wallet's own space, not a panel from the right): its
/// title over what it holds; its own Cancel or Done, or the button again,
/// closes it.
struct PaymentCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(Theme.font(14, .bold))
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .endsEditingOnClick()
    }
}
