import PeelCore
import PeelUI
import SwiftUI
import UIKit

@main
struct PeelPhoneApp: App {
    @State private var model = AppModel(platform: .phone())
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
        // Unread is Sphinx blue, as on the Mac's rows, not the system's red.
        UITabBarItem.appearance().badgeColor = UIColor(Theme.accent)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.becameActive() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    model.willTerminate()
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
        case .locked:
            LockScreen()
        case .onboarding:
            Onboarding()
        case .ready:
            MainTabs()
        }
    }
}

/// Chats and Account; more tabs come with what they hold
/// (docs/phases/07-iphone.md, "The app").
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    enum Name { case chats, account }
    @State private var selection = Name.chats
    /// The chat open under Chats while Account is shown.
    @State private var chatAway: AppModel.Destination?

    var body: some View {
        TabView(selection: $selection) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: Name.chats) {
                ChatsTab()
            }
            .badge(model.unreadCount)
            Tab("Account", systemImage: "person.crop.circle", value: Name.account) {
                AccountTab()
            }
        }
        // Account is a destination, as on the Mac, so a chat behind it is
        // not read while out of sight; it is back on returning to Chats.
        .onChange(of: selection) { _, tab in
            var quietly = Transaction()
            quietly.disablesAnimations = true
            withTransaction(quietly) {
                switch tab {
                case .account:
                    chatAway = model.destination
                    model.destination = .account
                case .chats:
                    model.destination = chatAway
                    chatAway = nil
                }
            }
        }
    }
}
