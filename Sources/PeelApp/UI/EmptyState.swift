import SwiftUI

/// An empty place: shadcn's `Empty`, the words a screen, pane or list
/// shows when it has nothing to show (or could not load it), centred in
/// the room it is given, with an optional title above and actions below.
/// The words are selectable, since they may be a problem worth copying.
///
/// ```swift
/// EmptyState("Payments you send and receive show up here.")
/// EmptyState("No time zone matches.", size: .sm)            // in a panel's list
/// EmptyState(problem, title: "Could not open example.com") {
///     Button("Try again", action: retry).buttonStyle(.peel(.outline, size: .sm))
/// }
/// ```
struct EmptyState<Actions: View>: View {
    enum Size {
        /// A list in a panel: 12 pt, 8 of padding.
        case sm
        /// A screen or pane: 14 pt alone, or 13 under a 15 pt semibold
        /// title; 24 of padding.
        case md
    }

    private let message: String
    private let title: String?
    private let size: Size
    private let actions: Actions

    init(_ message: String, title: String? = nil, size: Size = .md, @ViewBuilder actions: () -> Actions) {
        self.message = message
        self.title = title
        self.size = size
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            if let title {
                Text(title)
                    .font(Theme.font(15, .semibold))
                    .multilineTextAlignment(.center)
            }
            Text(message)
                .font(Theme.font(messageSize))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            actions
        }
        .padding(size == .sm ? 8 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageSize: CGFloat {
        switch size {
        case .sm: 12
        case .md: title == nil ? 14 : 13
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ message: String, title: String? = nil, size: Size = .md) {
        self.init(message, title: title, size: size) { EmptyView() }
    }
}
