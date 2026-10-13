import PeelCore
import PeelUI
import SwiftUI
import UIKit

@main
struct PeelPhoneApp: App {
    @State private var model = AppModel(platform: .phone)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // As the Mac does when it comes to the front.
                    model.lockIfDue()
                    Task {
                        await model.engine?.refreshReadsAndMutes()
                        model.markSelectedChatRead()
                    }
                    Task { await model.engine?.refreshPreferences() }
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

    var body: some View {
        TabView {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right") {
                ChatsTab()
            }
            .badge(model.unreadCount)
            Tab("Account", systemImage: "person.crop.circle") {
                AccountTab()
            }
        }
    }
}
