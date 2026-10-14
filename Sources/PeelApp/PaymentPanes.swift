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
