import SwiftUI
import PeelUI

/// Offers notifications once the account is open.
struct NotificationOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OfferBar(
            icon: "bell", text: "Get notified about new messages?", action: "Turn on notifications",
            dismiss: model.dismissNotificationOffer, accept: { Task { await model.enableNotifications() } }
        )
    }
}

/// A one-line offer at the foot of the window: "Not now", or yes.
struct OfferBar: View {
    let icon: String
    let text: String
    let action: String
    let dismiss: () -> Void
    let accept: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .foregroundStyle(Theme.secondaryText)
            Text(text)
                .font(Theme.font(13))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The text gives way, never the buttons: their labels keep one line.
            Group {
                Button("Not now", action: dismiss)
                    .buttonStyle(.peel(.outline, size: .sm))
                Button(action, action: accept)
                    .buttonStyle(.peel(.primary, size: .sm))
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }
}
