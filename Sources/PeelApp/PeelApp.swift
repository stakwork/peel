import SwiftUI
import PeelCore
import LiveKit

@main
struct PeelApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif

    init() {
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
        // At info and below LiveKit logs the server it connects to.
        LiveKitSDK.setLogLevel(.warning)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 460)
                #endif
                .task {
                    #if os(macOS)
                    delegate.model = model
                    #endif
                    await model.start()
                }
                #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.lockIfDue()
                    model.markSelectedChatRead()
                    Task { await model.notifier.refreshPermission() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.willTerminate()
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            // The account screen stands in for Settings.
            CommandGroup(replacing: .appSettings) {
                Button("Account…") { model.destination = .account }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(model.phase != .ready)
            }
            CommandGroup(after: .windowArrangement) {
                if CallTest.config(for: model) != nil { CallTestMenuItem() }
            }
        }
        #endif

        #if os(macOS)
        // The call you are on: 960 × 640 at first, then where you left it.
        Window("Call", id: CallWindow.id) {
            CallWindow()
                .environment(model)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 640)
        .commandsRemoved()
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Development only; never listed, restored or opened without
        // `-callTestToken` and a development profile.
        Window("Test Room", id: CallTest.windowID) {
            if let config = CallTest.config(for: model) { CallTestView(url: config.url, token: config.token) }
        }
        .commandsRemoved()
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(CallTest.config(for: model) != nil ? .presented : .suppressed)
        #endif
    }
}

#if os(macOS)
/// Holds a quit until the call you are on has left its room, so the others
/// see you go at once rather than when the server gives up on you.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var quitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.call != nil || model.callLeaving != nil else { return .terminateNow }
        quitting = false
        // Whichever comes first: the goodbye, or two seconds, so a quit
        // never waits on a dead network.
        Task { await model.endCall(); quit(sender) }
        Task { try? await Task.sleep(for: .seconds(2)); quit(sender) }
        return .terminateLater
    }

    private func quit(_ sender: NSApplication) {
        guard !quitting else { return }
        quitting = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
#endif

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .locked:
            LockView()
        case .onboarding:
            OnboardingView()
        case .ready:
            MainView()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.notifier.offersPermission { NotificationOffer() }
                }
        }
    }
}
