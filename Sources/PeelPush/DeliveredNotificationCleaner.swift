import Foundation

/// A delivered notification as the cleaner sees it: what `UNNotification`
/// carries that matters here, so tests need no notification center.
public struct DeliveredNotification {
    public let identifier: String
    /// `request.content.threadIdentifier`; empty when none was set.
    public let threadIdentifier: String
    public let date: Date
    public let userInfo: [AnyHashable: Any]

    public init(identifier: String, threadIdentifier: String, date: Date, userInfo: [AnyHashable: Any] = [:]) {
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.date = date
        self.userInfo = userInfo
    }
}

/// Which delivered pushes to take away once their chats are read, as the Mac
/// does for its own notifications (`Notifier.removeDelivered`). A push's
/// thread is `NotificationRoute.threadIdentifier(kind:index:)`, set by the
/// notification service extension; the app asks with the same function, so
/// the two cannot drift.
///
/// Limit: iOS runs app code only while the app is running, in front, or woken
/// by a background push. A notification delivered while the app is suspended
/// stays until the app next runs; removing it sooner needs a silent push
/// from the server.
public enum DeliveredNotificationCleaner {
    /// The request identifiers to remove: those of `threads` (by thread
    /// identifier, or by the child in `userInfo` when there is no thread)
    /// delivered at or before `observed`, the moment the read was seen. A
    /// later one is about a newer message: keep it.
    public static func identifiers(
        removing threads: Set<String>, from delivered: [DeliveredNotification], observedAt observed: Date
    ) -> [String] {
        guard !threads.isEmpty else { return [] }
        return delivered.filter { notification in
            guard notification.date <= observed else { return false }
            if !notification.threadIdentifier.isEmpty { return threads.contains(notification.threadIdentifier) }
            guard case .child(let kind, let index)? = NotificationRoute(userInfo: notification.userInfo) else { return false }
            return threads.contains(NotificationRoute.threadIdentifier(kind: kind, index: index))
        }.map(\.identifier)
    }
}
