import Foundation
import Testing
@testable import PeelCore

/// The rules a chat's menu and the connection's countdown share between
/// the Mac and the iPhone: which notification levels a chat offers, Mark as
/// read or unread, and the retry countdown's words.
struct ChatMenuRulesTests {
    @Test func aDirectMessageHasNoMentionsOnly() {
        #expect(MuteLevel.choices(isTribe: true) == [.all, .mentionsOnly, .muted])
        #expect(MuteLevel.choices(isTribe: false) == [.all, .muted])
        #expect(MuteLevel.choices(isTribe: true).map(\.title) == ["All messages", "Mentions only", "Nothing (mute)"])
        #expect(MuteLevel.choices(isTribe: true).map(\.short) == ["All", "Mentions", "Muted"])
    }

    @Test func unreadOffersMarkReadWithoutAskingStorage() {
        var asked = false
        let toggle = ReadToggle.offered(unread: 3) { asked = true; return true }
        #expect(toggle == .markRead)
        #expect(!asked)
    }

    @Test func readOffersMarkUnreadOnlyWithAnIncomingMessage() {
        #expect(ReadToggle.offered(unread: 0) { true } == .markUnread)
        #expect(ReadToggle.offered(unread: 0) { false } == nil)
    }

    @Test func countdownUsesTheMacsWords() {
        let now = Date(timeIntervalSince1970: 1_000)
        let offline = Engine.ConnectionState.offline(retryIn: 8)
        #expect(offline.label(retryAt: now.addingTimeInterval(7.2), now: now) == "Offline, retrying in 8s")
        #expect(offline.label(retryAt: now.addingTimeInterval(-1), now: now) == "Offline, retrying")
        #expect(offline.retrySeconds(retryAt: now.addingTimeInterval(-1), now: now) == 0)
        // No retry set, or not offline: the state's own words, no countdown.
        #expect(offline.label(retryAt: nil, now: now) == offline.label)
        #expect(Engine.ConnectionState.connecting.label(retryAt: now, now: now) == "Connecting")
        #expect(Engine.ConnectionState.connecting.retrySeconds(retryAt: now, now: now) == nil)
    }
}
