import SwiftUI
import PeelCore

@main
struct PeelApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 460)
                .task { await model.start() }
        }
        .defaultSize(width: 1000, height: 660)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .onboarding:
            OnboardingView()
        case .ready:
            MainView()
        }
    }
}
