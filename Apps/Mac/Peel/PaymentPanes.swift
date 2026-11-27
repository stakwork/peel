import SwiftUI
import PeelCore

/// How a payment pane is drawn: beside the list with its own header and
/// close (a payment's details), or as a card under the wallet's Deposit
/// and Withdraw (Tom, 2026-11-27: in the wallet's own space, not a panel
/// from the right).
enum PaneStyle { case pane, card }

extension EnvironmentValues {
    @Entry var paneStyle = PaneStyle.pane
}

/// A payment pane: its title, a close button, and what it holds; a card
/// with its title over what it holds in `.card` (`paneStyle`).
struct PaneFrame<Content: View>: View {
    @Environment(\.paneStyle) private var style
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if style == .card {
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
        } else {
            pane
        }
    }

    private var pane: some View {
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
