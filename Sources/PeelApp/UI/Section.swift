import SwiftUI

/// A section's heading: 12 pt semibold in the secondary colour (shadcn's
/// blocks use `text-sm font-medium text-muted-foreground`). A form's
/// sections, the Account's, the Payments list's days, a panel's lists
/// (Waiting for approval, Members, All time zones) and a label over a
/// card's value (Public key). The caller places it.
struct SectionHeader: View {
    private let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Theme.font(12, .semibold))
            .foregroundStyle(Theme.secondaryText)
    }
}
