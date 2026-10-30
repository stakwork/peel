import Foundation
import PeelCore
import PeelPush
import PeelUI
import UIKit
import UserNotifications
import os

/// The app delegate SwiftUI's `@UIApplicationDelegateAdaptor` needs for the
/// APNs callbacks, which `App` has no way to receive.
final class PeelAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
