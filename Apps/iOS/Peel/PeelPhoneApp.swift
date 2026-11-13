import Combine
import PeelCore
import PeelPush
import PeelUI
import SwiftUI
import UIKit

@main
struct PeelPhoneApp: App {
    @UIApplicationDelegateAdaptor(PeelAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var router: PhoneRouter
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // First: crash recording starts before anything that could crash, and
        // before the model, which reads how the last run ended.
        CrashRecorder.install()
        MetricKitRecorder.shared.start()
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
        let model = AppModel(platform: .phone())
        _model = State(initialValue: model)
        // A push can launch the app in the background with no window, so
        // `.task { model.start() }` never runs; the fetch reaches the model here.
        PushCoordinator.shared.use(model)
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
                    switch phase {
                    case .active: Diagnostics.recordScenePhase(.active)
                    case .inactive: Diagnostics.recordScenePhase(.inactive)
                    case .background: Diagnostics.recordScenePhase(.background)
                    @unknown default: break
                    }
                    if phase == .active {
                        model.becameActive()
                        PushCoordinator.shared.refreshNames()
                        PushCoordinator.shared.openPending(model: model, router: router)
                        PushCoordinator.shared.removeDeliveredOfReadChats(model: model, frontmost: true)
                    }
                    if phase == .background { model.leftForeground() }
                }
                // The names a push shows follow the chats and their names, not
                // every new message.
                .onChange(of: PushNames.signature(model.conversations)) { _, _ in
                    PushCoordinator.shared.refreshNames()
                }
                // Pushes of a chat go when it is read or opened, here or on
                // another device (its read marker moves).
                .onChange(of: model.readStates) { _, _ in
                    PushCoordinator.shared.removeDeliveredOfReadChats(model: model, frontmost: scenePhase == .active)
                }
                .onChange(of: model.selectedChat) { _, _ in
                    PushCoordinator.shared.removeDeliveredOfReadChats(model: model, frontmost: scenePhase == .active)
                }
                // The push token waits for the connection: an account opened
                // before it was up registered nothing.
                .onChange(of: model.connection == .connected) { _, connected in
                    if connected { PushCoordinator.shared.connected() }
                }
                // The PIN timeout counts the time Peel is away: in front is
                // in use (the phone locks itself when it is not), noted as
                // it comes back, every half minute, and as it leaves; on
                // coming back `becameActive` locks first if it is due.
                .task(id: scenePhase == .active) {
                    model.noteActivity()
                    while scenePhase == .active, (try? await Task.sleep(for: .seconds(30))) != nil {
                        model.noteActivity()
                    }
                }
                // Stadeum opens with the account; locked or forgotten, its
                // tokens and an open org page go, read again when it opens.
                .onChange(of: model.phase) { _, phase in
                    if phase == .ready, let profile = model.profile {
                        // Renewed when due, not at every unlock.
                        model.stadeum.open(profile, renewNow: false)
                        PushCoordinator.shared.accountOpened(model)
                        PushCoordinator.shared.openPending(model: model, router: router)
                        router.openWaitingLink()
                    } else {
                        // An account exists but is locked, or failed to open:
                        // the launch-time question is not held back. With
                        // none, it waits for the account to open.
                        if phase == .locked || model.profile?.hasAccount == true { PushCoordinator.shared.requestLaunchPermission() }
                        PushCoordinator.shared.accountClosed()
                        model.stadeum.close()
                        router.orgPage = nil
                        router.publicPage = nil
                    }
                }
                // A tapped push: opened now if an account is open, else it
                // waits for the PIN or onboarding (the phase handler above).
                // Delivered on main: the delegate submits from a background thread.
                .onReceive(NotificationCenter.default.publisher(for: PendingNavigation.didChange).receive(on: DispatchQueue.main)) { _ in
                    PushCoordinator.shared.openPending(model: model, router: router)
                }
                // `peel://open?url=<address>`: a stranger's public app, opened here directly.
                .onOpenURL { url in _ = router.open(peelLink: url) }
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
        @Bindable var router = router
        phase
            .sheet(item: $model.diagnosticsRecord) { record in
                DiagnosticRecordSheet(record: record)
                    .environment(model)
            }
            .fullScreenCover(isPresented: $router.callShown) {
                IOSCallScreen()
                    .environment(model)
                    .environment(router)
            }
            // Your other device is already on the call being joined: choose
            // before anything connects. Cancel (or dismissing) joins nothing.
            .confirmationDialog(
                "You are already on this call on another of your devices.",
                isPresented: Binding(
                    get: { model.calls.choosingDevice != nil },
                    // Deferred: a button's own action runs first, and a choice
                    // already made leaves nothing to cancel.
                    set: { if !$0 { Task { @MainActor in model.calls.cancelDeviceChoice() } } }
                ),
                titleVisibility: .visible
            ) {
                Button("Switch to this device") { model.calls.switchToThisDevice() }
                Button("Stay on both devices") { model.calls.stayOnBothDevices() }
                Button("Cancel", role: .cancel) {}
            }
            // Talk to Jamie (docs/talk.md): up while there is a Talk call,
            // starting or failed; it goes when the call does.
            .fullScreenCover(isPresented: Binding(
                get: { model.talk.home != nil && !router.talkMinimized },
                set: { if !$0, !router.talkMinimized { model.talk.hangUp() } }
            )) {
                TalkView()
                    .environment(model)
                    .environment(router)
            }
            // The call screens are portrait only, even when started from a chat.
            .onChange(of: model.talk.home?.id) { router.talkMinimized = false }
            .onChange(of: router.callShown || (model.talk.home != nil && !router.talkMinimized), initial: true) { _, shown in
                OrientationLock.shared.callShown = shown
                OrientationLock.shared.update()
            }
            // Here, not in the tabs, so a chat opened while locked (a
            // notification) is the one shown after the PIN.
            .onChange(of: model.destination) { _, destination in
                router.follow(destination)
            }
            // Onboarding starts from Chats: the tab left selected by a
            // forgotten account (You, Profile) must not outlive it.
            .onChange(of: model.phase) { _, phase in
                if phase == .onboarding { router.reset() }
            }
            .onAppear { if model.phase == .onboarding { router.reset() } }
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
