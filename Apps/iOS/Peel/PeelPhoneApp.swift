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
        // First: crash recording starts before anything that could crash, and
        // before the model, which reads how the last run ended.
        CrashRecorder.install()
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
        let model = AppModel(platform: .phone())
        _model = State(initialValue: model)
        _router = State(initialValue: PhoneRouter(model: model))
        // The tab badge is Sphinx blue, as on the Mac's rows, not the system's
        // red. iOS 26's tab bar ignores `UITabBarItem.badgeColor`; it reads
        // the badge from the bar's appearance, in each of its layouts.
        let tabs = UITabBarAppearance()
        tabs.configureWithDefaultBackground()
        for layout in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance, tabs.compactInlineLayoutAppearance] {
            for state in [layout.normal, layout.selected] {
                state.badgeBackgroundColor = UIColor(Theme.accent)
                state.badgeTextAttributes = [.foregroundColor: UIColor(Theme.buttonText)]
            }
        }
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .tint(Theme.accent)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.becameActive()
                        // Renewed when due: the hourly look may have slept through its turn.
                        model.stadeum.renewIfDue()
                    }
                    if phase == .background { model.leftForeground() }
                }
                // The PIN timeout, as on the Mac: from the last touch, in
                // front or away. Each touch in Peel's window is use
                // (`TouchWatch`); idle in front, it locks within half a
                // minute of the timeout, and coming back after it locks
                // first (`becameActive`).
                .background(TouchWatch { model.noteActivity() })
                .task { await model.lockWhenIdle() }
                // Stadeum opens with the account; locked or forgotten, its
                // tokens and an open org page go, read again when it opens.
                .onChange(of: model.phase) { _, phase in
                    if phase == .ready, let profile = model.profile {
                        // Renewed when due, not at every unlock.
                        model.stadeum.open(profile, renewNow: false)
                    } else {
                        model.stadeum.close()
                        router.orgPage = nil
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Diagnostics.memoryWarning()
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
        @Bindable var model = model
        phase
            .sheet(item: $model.diagnosticsRecord) { record in
                DiagnosticRecordSheet(record: record)
                    .environment(model)
            }
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
