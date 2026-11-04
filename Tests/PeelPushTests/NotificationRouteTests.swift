import Foundation
import Testing
@testable import PeelPush

struct NotificationRouteTests {
    @Test func childRoundTripsThroughUserInfo() {
        let info = NotificationRoute.userInfo(into: ["aps": ["alert": "x"]], kind: .tribe, index: 42)
        #expect(info["aps"] != nil)
        #expect(NotificationRoute(userInfo: info) == .child(kind: .tribe, index: 42))
        #expect(NotificationRoute(userInfo: NotificationRoute.userInfo(into: [:], kind: .contact, index: 0)) == .child(kind: .contact, index: 0))
    }

    @Test func numericIndexAndChatIdAreRead() {
        #expect(NotificationRoute(userInfo: ["peelChild": ["kind": "contact", "index": 7]]) == .child(kind: .contact, index: 7))
        #expect(NotificationRoute(userInfo: ["peelChat": "02abc"]) == .chat("02abc"))
        // A named chat wins over a child.
        #expect(NotificationRoute(userInfo: ["peelChat": "02abc", "peelChild": ["kind": "contact", "index": "1"]]) == .chat("02abc"))
    }

    @Test func malformedPayloadsGiveNoRoute() {
        #expect(NotificationRoute(userInfo: [:]) == nil)
        #expect(NotificationRoute(userInfo: ["peelChat": ""]) == nil)
        #expect(NotificationRoute(userInfo: ["peelChild": "x"]) == nil)
        #expect(NotificationRoute(userInfo: ["peelChild": ["kind": "group", "index": "1"]]) == nil)
        #expect(NotificationRoute(userInfo: ["peelChild": ["kind": "tribe", "index": "-1"]]) == nil)
        #expect(NotificationRoute(userInfo: ["peelChild": ["kind": "tribe", "index": "abc"]]) == nil)
        #expect(NotificationRoute(userInfo: ["peelChild": ["kind": "tribe", "index": -3]]) == nil)
        #expect(NotificationRoute(userInfo: ["peelChild": ["kind": "tribe"]]) == nil)
    }

    @Test func threadIdentifierIsStablePerChild() {
        #expect(NotificationRoute.threadIdentifier(kind: .contact, index: 5) == "child-contact-5")
    }
}

struct PendingNavigationTests {
    @Test func postsDidChangeOnMainWhenSubmittedFromBackground() async {
        let pending = PendingNavigation()
        let onMain: Bool = await withCheckedContinuation { continuation in
            let token = NotificationCenter.default.addObserver(forName: PendingNavigation.didChange, object: pending, queue: nil) { _ in
                continuation.resume(returning: Thread.isMainThread)
            }
            DispatchQueue.global().async {
                pending.submit(.chat("abc"))
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { NotificationCenter.default.removeObserver(token) }
            }
        }
        #expect(onMain)
        #expect(pending.take() == .chat("abc"))
    }

    @Test func aRouteIsTakenOnce() {
        let pending = PendingNavigation()
        #expect(pending.take() == nil && !pending.hasPending)
        pending.submit(.chat("a"))
        #expect(pending.hasPending)
        #expect(pending.take() == .chat("a"))
        #expect(pending.take() == nil)
    }

    @Test func theSameNotificationIsNotQueuedTwice() {
        let pending = PendingNavigation()
        #expect(pending.submit(.chat("a"), id: "n1"))
        #expect(pending.take() == .chat("a"))
        #expect(!pending.submit(.chat("a"), id: "n1"))
        #expect(pending.take() == nil)
        #expect(pending.submit(.chat("a"), id: "n2"))
    }

    @Test func theLatestTapWins() {
        let pending = PendingNavigation()
        pending.submit(.chat("a"), id: "1")
        pending.submit(.child(kind: .contact, index: 3), id: "2")
        #expect(pending.take() == .child(kind: .contact, index: 3))
    }

    @Test func userInfoWithoutARouteKeepsNothing() {
        let pending = PendingNavigation()
        #expect(!pending.submit(userInfo: ["aps": [:]], id: "1"))
        #expect(!pending.hasPending)
        #expect(pending.submit(userInfo: ["peelChat": "z"], id: "2"))
        pending.clear()
        #expect(pending.take() == nil)
    }
}

struct PushRouteResolutionTests {
    private let key = String(repeating: "ab", count: 32)
    private let names = PushNameDirectory(contacts: [3: "Bob"], tribes: [7: "Peelers"])
    private func payload(_ child: String) -> [AnyHashable: Any] { ["aps": ["custom_data": ["child": child]]] }
    private struct Fake: ChildIndexDecrypting {
        var index: UInt64
        func decrypt(child: String, pushKey: String) throws -> UInt64 { index }
    }

    @Test func aKnownChildCarriesItsRoute() {
        let contact = PushNotificationResolver.resolveWithRoute(userInfo: payload("e"), pushKey: key, decryptor: Fake(index: 3), names: names)
        #expect(contact.route == .child(kind: .contact, index: 3))
        let tribe = PushNotificationResolver.resolveWithRoute(userInfo: payload("e"), pushKey: key, decryptor: Fake(index: 7), names: names)
        #expect(tribe.route == .child(kind: .tribe, index: 7))
    }

    @Test func anUnknownOrUndecryptableChildHasNoRoute() {
        let unknown = PushNotificationResolver.resolveWithRoute(userInfo: payload("e"), pushKey: key, decryptor: Fake(index: 99), names: names)
        #expect(unknown.route == nil && unknown.content == .generic)
        #expect(PushNotificationResolver.resolveWithRoute(userInfo: [:], pushKey: key, decryptor: Fake(index: 3), names: names).route == nil)
        let hive = PushNotificationResolver.resolveWithRoute(userInfo: payload("ws/task:1"), pushKey: key, decryptor: Fake(index: 3), names: names)
        #expect(hive.content == .asSent && hive.route == nil)
    }
}
