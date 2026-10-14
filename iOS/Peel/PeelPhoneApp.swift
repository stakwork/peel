import PeelCore
import PeelUI
import SwiftUI
import UIKit

@main
struct PeelPhoneApp: App {
    @State private var model: AppModel
    @State private var router: PhoneRouter
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
        let model = AppModel(platform: .phone())
        _model = State(initialValue: model)
        _router = State(initialValue: PhoneRouter(model: model))
        // The tab badge is Sphinx blue, as on the Mac's rows, not the system's red.
        UITabBarItem.appearance().badgeColor = UIColor(Theme.accent)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
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
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        phase
            // Here, not in the tabs, so a chat opened while locked (a
            // notification) is the one shown after the PIN.
            .onChange(of: model.destination) { _, destination in
                router.follow(destination)
            }
    }

    @ViewBuilder private var phase: some View {
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
