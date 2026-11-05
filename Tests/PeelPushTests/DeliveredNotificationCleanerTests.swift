import Foundation
import Testing
@testable import PeelPush

struct DeliveredNotificationCleanerTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let thread = NotificationRoute.threadIdentifier(kind: .contact, index: 3)

    private func note(_ id: String, thread: String, at offset: TimeInterval = -10, info: [AnyHashable: Any] = [:]) -> DeliveredNotification {
        DeliveredNotification(identifier: id, threadIdentifier: thread, date: now.addingTimeInterval(offset), userInfo: info)
    }

    @Test func matchesByThreadIdentifier() {
        let ids = DeliveredNotificationCleaner.identifiers(
            removing: [thread], from: [note("a", thread: thread), note("b", thread: thread)], observedAt: now)
        #expect(ids == ["a", "b"])
    }

    @Test func keepsNewerNotifications() {
        let ids = DeliveredNotificationCleaner.identifiers(
            removing: [thread], from: [note("old", thread: thread), note("same", thread: thread, at: 0), note("new", thread: thread, at: 5)],
            observedAt: now)
        #expect(ids == ["old", "same"])
    }

    @Test func fallsBackToUserInfoWithoutThread() {
        let info = NotificationRoute.userInfo(into: [:], kind: .contact, index: 3)
        let other = NotificationRoute.userInfo(into: [:], kind: .tribe, index: 3)
        let ids = DeliveredNotificationCleaner.identifiers(
            removing: [thread], from: [note("a", thread: "", info: info), note("b", thread: "", info: other), note("c", thread: "")],
            observedAt: now)
        #expect(ids == ["a"])
    }

    @Test func ignoresOtherChats() {
        let other = NotificationRoute.threadIdentifier(kind: .tribe, index: 3)
        #expect(DeliveredNotificationCleaner.identifiers(removing: [thread], from: [note("a", thread: other)], observedAt: now).isEmpty)
        #expect(DeliveredNotificationCleaner.identifiers(removing: [], from: [note("a", thread: thread)], observedAt: now).isEmpty)
    }

    /// What the extension writes is what the app looks up.
    @Test func extensionIdentifierIsWhatTheAppLooksUp() {
        #expect(NotificationRoute.threadIdentifier(kind: .tribe, index: 42) == "child-tribe-42")
        let info = NotificationRoute.userInfo(into: [:], kind: .tribe, index: 42)
        guard case .child(let kind, let index)? = NotificationRoute(userInfo: info) else {
            Issue.record("no child route"); return
        }
        let sent = note("a", thread: NotificationRoute.threadIdentifier(kind: .tribe, index: 42), info: info)
        #expect(DeliveredNotificationCleaner.identifiers(
            removing: [NotificationRoute.threadIdentifier(kind: kind, index: index)], from: [sent], observedAt: now) == ["a"])
    }
}
