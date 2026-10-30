import PeelPush
import PeelPushCrypto
import UserNotifications

/// Words a push before it shows. The server sends no message text, only the
/// encrypted index of the chat (`aps.custom_data.child`); this decrypts it
/// with the push key from the shared Keychain group and names the chat from
/// the app group's map (sealed under the push key by the app,
/// `PushNameDirectoryWriter`). Whatever goes wrong, the push shows as "Peel" /
/// "You have new messages". The logic is PeelPush's `PushNotificationResolver`.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content
        // The generic line is already in place if the rest fails or runs out of time.
        if case .text(let title, let body) = PushNotificationContent.generic {
            content.title = title
            content.body = body
        }

        let config = PushConfig.current
        let pushKey = config.flatMap { PushKey.existing(in: KeychainPushKeyStore(accessGroup: $0.keychainGroup)) }
        // Any failure here (no group, no map, a blob that does not open under
        // this key) leaves no names: the generic line. Nothing is logged.
        let names = config.flatMap {
            PushNameDirectory.read(
                from: UserDefaultsPushNameStore(suiteName: $0.appGroup), pushKey: pushKey, sealer: RNCryptorSealer())
        }

        switch PushNotificationResolver.resolve(
            userInfo: request.content.userInfo, pushKey: pushKey, decryptor: SphinxChildDecryptor(), names: names
        ) {
        case .text(let title, let body):
            content.title = title
            content.body = body
        case .asSent:
            // A Hive link: the server's own words.
            contentHandler(request.content)
            clear()
            return
        }
        finish()
    }

    /// Out of time: shows what there is, the generic line at worst.
    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func finish() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        clear()
        handler(content)
    }

    private func clear() {
        contentHandler = nil
        bestAttempt = nil
    }
}
