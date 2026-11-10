import PeelCore
import PeelUI
import SwiftUI

// The connection on Chats (docs/design/iphone.md, screens 1 and 9; Tom,
// 2026-10-14): the bolt is always in the title capsule, green when
// connected and orange when not, and always opens its panel beside it.
// Nothing is laid out around the state: a line under the title shifted the
// list down at launch and back up once connected, so the state lives only in
// the bolt and its panel, which count down in the Mac's words
// (`ConnectionState.label(retryAt:now:)`). Green is earned: a connection that
// is up but has not fetched what came while the app was away is syncing
// (`ConnectionHealth`), orange with a gentle pulse, and green only once synced.

/// The bolt in Chats' title capsule: green (`confirmed`) once synced, orange
/// (`attention`) when offline, and orange pulsing (none with Reduce Motion)
/// while connected but still syncing; a tap opens `ConnectionPanel` beside it.
struct ConnectionBolt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var dimmed = false

    var body: some View {
        let health = model.connectionHealth
        let synced = health == .synced
        // A catch-up that keeps failing (`failing`) is orange and pulsing too, and says Reconnecting.
        let syncing = health == .syncing || health == .failing
        let breathing: Animation? = reduceMotion ? nil
            : syncing ? Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true) : Animation.easeOut(duration: 0.3)
        Button { shown = true } label: {
            Image(systemName: "bolt.fill")
                .foregroundStyle(synced ? Theme.confirmed : Theme.attention)
                .opacity(dimmed ? 0.4 : 1)
                // A quiet cross-fade between orange and green, none with Reduce Motion;
                // syncing breathes until it is done.
                .animation(breathing, value: dimmed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: synced)
        }
        .tint(synced ? Theme.confirmed : Theme.attention)
        .onChange(of: syncing, initial: true) { _, now in dimmed = now && !reduceMotion }
        // Colour is never the only signal: the label says the state.
        .accessibilityLabel(model.connection == .connected ? health.label : model.connection.label)
        .accessibilityHint(model.connection == .connected ? "Shows the connection" : "Shows the connection and Reconnect now")
        .popover(isPresented: $shown) {
            ConnectionPanel()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The bolt's panel (the Mac's `ConnectionCard`): an opaque `menu` panel
/// beside the bolt with the state, the retry countdown, the last error and,
/// while offline, Reconnect now. Never glass: it is content. It follows the
/// connection while open, so it can be watched coming back.
struct ConnectionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connected = model.connection == .connected
        let health = model.connectionHealth
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(health == .synced ? Theme.confirmed : Theme.attention)
                    .accessibilityHidden(true)
                Text(connected ? health.label : model.connection == .connecting ? "Connecting" : "Not connected")
                    .phoneFont(.headline)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
            }
            if health == .failing {
                Text("Peel is having trouble loading new messages and is retrying")
                    .phoneFont(.row)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else if health == .syncing {
                Text("Connected. Peel is fetching what came while it was away; your messages are here.")
                    .phoneFont(.row)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else if connected {
                Text(model.myServer.map { "New messages arrive as they're sent, through \($0)." }
                     ?? "New messages arrive as they're sent.")
                    .phoneFont(.row)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Ticks only while not connected.
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
            }
            if let error = model.connectionError {
                Text(error)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only while offline: connecting or connected, there is nothing to start.
            if case .offline = model.connection {
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
        .animation(.easeOut(duration: 0.2), value: health)
    }
}
