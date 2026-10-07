import SwiftUI
import PeelCore

@main
struct PeelApp: App {
    @State private var model = AppModel()

    init() {
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
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
                .task { await model.start() }
                #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.lockIfDue()
                    model.markSelectedChatRead()
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        #endif
    }
}

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
        }
    }
}
