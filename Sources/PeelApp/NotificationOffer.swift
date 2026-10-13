import SwiftUI

/// Offers notifications once the account is open.
struct NotificationOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "bell")
                .foregroundStyle(Theme.secondaryText)
            Text("Get notified about new messages?")
                .font(Theme.font(13))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The text gives way, never the buttons: their labels keep one line.
            Group {
                Button("Not now") { model.dismissNotificationOffer() }
                    .buttonStyle(.peel(.outline, size: .sm))
                Button("Turn on notifications") { Task { await model.enableNotifications() } }
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
