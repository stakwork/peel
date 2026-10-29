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
        #if DEBUG
        // So a test push can be shown. Debug builds only; it touches neither
        // the hub flag nor the push-token registration.
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        #endif
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

    /// An account is open: ask permission (only if pushes can come), and
    /// register if the token is already here.
    func accountOpened(_ model: AppModel) {
        self.model = model
        if PeelPushFlags.registerWithHub() {
            // The system asks once; later calls return the answer.
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        }
        Task { await registerIfReady() }
    }

    func accountClosed() {
        model = nil
        registered = nil
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
