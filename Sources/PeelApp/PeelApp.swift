import SwiftUI
import PeelCore
import PeelUI
import LiveKit

@main
struct PeelApp: App {
    @State private var model = AppModel(platform: .mac())
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif

    init() {
        // Everything this process creates (database, journal) is private to the user.
        umask(0o077)
        // At info and below LiveKit logs the server it connects to.
        LiveKitSDK.setLogLevel(.warning)
        #if os(macOS)
        // One main window: its tab bar's "+" would open a second.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Quits here, before any window, when asked for where it is refused.
        _ = Offscreen.drive
        #endif
    }

    var body: some Scene {
        // One main window (the web pane, the viewer and the selection are
        // the app's, not a window's): New Window brings it to the front.
        WindowGroup(id: MainWindow.id, for: MainWindow.Key.self) { _ in
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
                .task { await model.lockWhenIdle() }
                #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.lockIfDue()
                    // Asked first, so the open chat's `read` goes after the
                    // ask and its answer is not applied over it.
                    Task {
                        await model.engine?.refreshReadsAndMutes()
                        model.markSelectedChatRead()
                    }
                    Task { await model.engine?.refreshPreferences() }
                    Task { await model.notifier.refreshPermission() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.willTerminate()
                }
                #endif
        } defaultValue: {
            .main
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                MainWindow.MenuItem()
            }
            // The account screen stands in for Settings. Guarded in the
            // action, not `.disabled`: a command does not follow the model.
            CommandGroup(replacing: .appSettings) {
                Button("Account…") {
                    if model.phase == .ready { model.destination = .account }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘F from wherever the cursor is (`AppModel.find`). Never
            // `.disabled` by the model: a command does not follow it.
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.find() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            // ⌥⇧↓ and ⌥⇧↑ from anywhere in the window, as ⌘F; guarded in
            // `AppModel.takesCommands` for the same reason.
            CommandMenu("Go") {
                Button("Next Unread Chat") { model.openUnread(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                Button("Previous Unread Chat") { model.openUnread(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
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

/// The one main window: a group of windows that only ever shows `.main`,
/// so opening it again brings the open one to the front.
enum MainWindow {
    static let id = "main"

    enum Key: String, Codable, Hashable { case main }

    #if os(macOS)
    /// File › New Window (⌘N): the main window to the front, or opened
    /// again once it has been closed, never a second one.
    struct MenuItem: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("New Window") { openWindow(id: MainWindow.id, value: Key.main) }
                .keyboardShortcut("n", modifiers: .command)
        }
    }
    #endif
}

#if os(macOS)
/// Holds a quit until the call you are on has left its room, so the others
/// see you go at once rather than when the server gives up on you.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var quitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Offscreen.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OffscreenDriver.start { [weak self] in self?.model }
        // A key press, click or scroll in Peel's windows is use, which puts
        // the PIN timeout off.
        NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.model?.noteActivity() }
            return event
        }
    }

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
