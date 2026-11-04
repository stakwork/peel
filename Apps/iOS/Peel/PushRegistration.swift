import Foundation
import PeelCore
import PeelPush
import PeelUI
import UIKit
import UserNotifications
import os

/// The app delegate SwiftUI's `@UIApplicationDelegateAdaptor` needs for the
/// APNs callbacks, which `App` has no way to receive.
final class PeelAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before launch finishes, so the tap that launched a killed app is
        // delivered here (it is held in `PendingNavigation` until the account is open).
        UNUserNotificationCenter.current().delegate = self
        // A token needs no permission, so it is asked for at every launch
        // (Apple advises it: the token can change).
        application.registerForRemoteNotifications()
        // The permission question is not asked here: with no account yet it
        // waits for the account to open (`PushCoordinator.requestLaunchPermission`).
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCoordinator.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushCoordinator.shared.failed(error)
    }

    /// A tap on a push: the route is kept, not opened, since the app may be
    /// launching, locked or still onboarding; `PushCoordinator.openPending`
    /// opens it when an account is open. Foreground presentation is left to
    /// the system's default (unchanged).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        PendingNavigation.shared.submit(
            userInfo: response.notification.request.content.userInfo, id: response.notification.request.identifier)
    }

    /// Portrait, except on the chat (see `OrientationLock`).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// Remote push on the phone (docs/phases/07-iphone.md, "Push: what is
/// built"): holds the APNs token, makes the push key in the Keychain group
/// the notification extension shares, and, only when
/// `PeelPushFlags.registerWithHub` is on, registers the token with the
/// account's server. Never logs the token or the key.
@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()

    private static let log = Logger(subsystem: "com.sphinx.peel", category: "push")
    private let config = PushConfig.current
    private var token: String?
    private weak var model: AppModel?
    private var registered: String?
    /// The names map being written; the next write waits for it, so the last
    /// one started is the last one kept.
    private var namesTask: Task<Void, Never>?

    private var launchPermissionAsked = false

    /// So a test push can be shown. Debug builds only; it touches neither the
    /// hub flag nor any registration. Asked at most once per launch: at
    /// launch when an account exists (locked, or open), otherwise when the
    /// account first opens after onboarding (a new account or a restore).
    func requestLaunchPermission() {
        #if DEBUG
        guard !launchPermissionAsked else { return }
        launchPermissionAsked = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        #endif
    }

    /// An account is open: ask permission (only if pushes can come), and
    /// register if the token is already here.
    func accountOpened(_ model: AppModel) {
        self.model = model
        requestLaunchPermission()
        if PeelPushFlags.registerWithHub() {
            // The system asks once; later calls return the answer.
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        }
        Task { await registerIfReady() }
        refreshNames()
    }

    /// The account's server is reached. A registration tried while it was
    /// still connecting sent nothing, so it is tried again; one already
    /// registered is not sent twice.
    func connected() {
        Task { await registerIfReady() }
    }

    private var opening = false

    /// Opens the tapped push's chat if one waits and an account is open;
    /// otherwise it stays pending (locked, onboarding, still loading). The
    /// route is taken once, so a second call finds nothing. A chat the
    /// account does not have is dropped quietly; one whose chats have not
    /// loaded yet is kept pending, not dropped.
    func openPending(model: AppModel, router: PhoneRouter) {
        guard !opening, model.phase == .ready, let engine = model.engine, PendingNavigation.shared.hasPending else { return }
        guard let route = PendingNavigation.shared.take() else { return }
        opening = true
        Task {
            defer { opening = false }
            // Chats load just after the account opens; a cold start can be slow.
            for _ in 0..<33 where model.conversations.isEmpty && model.phase == .ready {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard model.phase == .ready else { PendingNavigation.shared.submit(route); return }
            // Still no chats: they have not loaded, so keep the route for the next try.
            guard !model.conversations.isEmpty else { PendingNavigation.shared.submit(route); return }
            let chat: String?
            switch route {
            case .chat(let id): chat = id
            case .child(let kind, let index):
                let contacts = (try? await engine.contacts()) ?? []
                chat = contacts.first { $0.childIndex == index }.map(\.pubkey).flatMap { key in
                    model.conversations.first { $0.chat == key && $0.isTribe == (kind == .tribe) }?.chat
                }
            }
            guard model.phase == .ready else { PendingNavigation.shared.submit(route); return }
            guard let chat, model.conversations.contains(where: { $0.chat == chat }) else { return }
            router.openChat(chat)
        }
    }

    func accountClosed() {
        model = nil
        registered = nil
        // The names go with the account: a push shows the generic line until
        // the next account opens. Pending writes are not waited for, but
        // each checks again that an account is open before it keeps anything.
        namesTask?.cancel()
        namesTask = nil
        if let config { PushNameDirectoryWriter.clear(store: UserDefaultsPushNameStore(suiteName: config.appGroup)) }
    }

    /// Keeps the names the notification extension shows (sphinx-ios-v2's
    /// childIndexes map, `PushNameDirectoryWriter`): on opening an account, on
    /// coming to the front and when a chat or its name changes. It stores
    /// local names only and does not depend on, or call, the hub registration.
    /// Needs the push key and the app group; without them nothing is written.
    func refreshNames() {
        guard let config, let model, model.phase == .ready, let engine = model.engine,
              let key = PushKey.loadOrCreate(in: KeychainPushKeyStore(accessGroup: config.keychainGroup))
        else { return }
        let chats = model.conversations
        let previous = namesTask
        namesTask = Task {
            await previous?.value
            await Task.detached { () -> Void in
                guard !Task.isCancelled, let contacts = try? await engine.contacts() else { return }
                PushNameDirectoryWriter.write(
                    PushNames.entries(contacts: contacts, chats: chats), pushKey: key, sealer: RNCryptorSealer(),
                    store: UserDefaultsPushNameStore(suiteName: config.appGroup))
            }.value
            // An account that closed meanwhile has its names cleared, not kept.
            if self.model == nil { PushNameDirectoryWriter.clear(store: UserDefaultsPushNameStore(suiteName: config.appGroup)) }
        }
    }

    func received(token data: Data) {
        let hex = PushToken.hex(data)
        token = hex
        #if DEBUG
        // `print`, not os_log, so Xcode's console shows it unredacted. Debug
        // builds only. The push key is never printed.
        print("[Peel push] APNs device token (\(config?.environment.rawValue ?? "unknown"), app \(config?.appID ?? "unknown")): \(hex)")
        #endif
        Task { await registerIfReady() }
    }

    func failed(_ error: any Error) {
        // Expected in the simulator and without the push capability in the App ID.
        Self.log.error("remote notification registration failed: \((error as NSError).code, privacy: .public)")
        #if DEBUG
        print("[Peel push] registration failed: \(error)")
        #endif
    }

    private func registerIfReady() async {
        guard let config, let token else { return }
        // The key exists before anything is registered, so the extension can read it.
        guard let key = PushKey.loadOrCreate(in: KeychainPushKeyStore(accessGroup: config.keychainGroup)) else {
            Self.log.error("the push key could not be kept")
            return
        }
        guard let engine = model?.engine, registered != token else { return }
        let registration = PushRegistration(token: token, appID: config.appID, environment: config.environment)
        // The flag is checked inside as well; off, this sends nothing.
        if (try? await engine.registerPushToken(registration, pushKey: key)) == true { registered = token }
    }
}
