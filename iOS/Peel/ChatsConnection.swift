import PeelCore
import PeelUI
import SwiftUI

// Chats, not connected (docs/design/iphone.md, screen 9): an orange line
// under the large title and, from the bolt in the title capsule, a panel
// beside it. Being connected is the quiet case: neither shows. Both count
// down in the Mac's words (`ConnectionState.label(retryAt:now:)`).

/// The orange line under Chats' large title while not connected:
/// "Offline, retrying in 8s".
struct ConnectionSubtitle: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.toolbar {
            if model.connection != .connected {
                ToolbarItem(placement: .largeSubtitle) {
                    // Ticks only while shown, which is only while not connected.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.connection.label(retryAt: model.reconnectAt, now: context.date))
                            .phoneFont(.secondary)
                            .foregroundStyle(Theme.attention)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// The bolt's panel (the Mac's `ConnectionCard`): an opaque `menu` panel
/// beside the bolt with the state, the retry countdown, the last error and
/// Reconnect now. Never glass: it is content.
struct ConnectionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.attention)
                    .accessibilityHidden(true)
                Text(model.connection == .connecting ? "Connecting" : "Not connected")
                    .phoneFont(.headline)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.connection.label(retryAt: model.reconnectAt, now: context.date))
                    .phoneFont(.row)
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
            }
            Text("Your messages are here; new ones arrive once Peel reconnects.")
                .phoneFont(.row)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.connectionError {
                Text(error)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // While connecting there is nothing to start.
            if model.connection != .connecting {
                Button {
                    Task { await model.reconnectNow() }
                } label: {
                    Text("Reconnect now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.peel(.primary, size: .touch))
                .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 300, alignment: .leading)
        .background(Theme.menu)
        .environment(\.surface, .raised)
    }
}
