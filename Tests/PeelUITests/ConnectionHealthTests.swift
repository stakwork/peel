import Foundation
import PeelCore
import Testing
@testable import PeelUI

/// What the bolt says: green only once the connection has caught up, and
/// the notices of a connection failing going stale.
struct ConnectionHealthTests {
    @Test func offlineAndConnectingAreOfflineWhateverWasCaughtUp() {
        #expect(ConnectionHealth(connection: .offline(retryIn: 4), caughtUp: true) == .offline)
        #expect(ConnectionHealth(connection: .connecting, caughtUp: false) == .offline)
    }

    @Test func connectedIsSyncingUntilCaughtUp() {
        #expect(ConnectionHealth(connection: .connected, caughtUp: false) == .syncing)
        #expect(ConnectionHealth(connection: .connected, caughtUp: true) == .synced)
    }

    @Test func syncingSaysSo() {
        #expect(ConnectionHealth.syncing.label == "Syncing…")
        #expect(ConnectionHealth.synced.label == "Connected")
    }

    private let sent = "The connection failed while sending; the payment may have gone. It stays unconfirmed"

    @Test func aFreshNoticeOfAFailedConnectionStaysUntilStaleOrSynced() {
        var notices = ConnectionNotices()
        let now = Date(timeIntervalSince1970: 1_000)
        notices.noted(sent, shown: "shown", in: "chat", at: now)
        #expect(!notices.isStale("shown", in: "chat", synced: false, at: now.addingTimeInterval(10)))
        #expect(notices.isStale("shown", in: "chat", synced: false, at: now.addingTimeInterval(ConnectionNotices.staleAfter + 1)))
        // Dropped once: nothing is left to drop.
        #expect(!notices.isStale("shown", in: "chat", synced: true, at: now))
    }

    @Test func aSyncedConnectionDropsTheNotice() {
        var notices = ConnectionNotices()
        let now = Date(timeIntervalSince1970: 1_000)
        notices.noted(sent, shown: "shown", in: "chat", at: now)
        #expect(notices.isStale("shown", in: "chat", synced: true, at: now))
    }

    @Test func otherNoticesAndReplacedOnesAreLeftAlone() {
        var notices = ConnectionNotices()
        let now = Date(timeIntervalSince1970: 1_000)
        let later = now.addingTimeInterval(600)
        notices.noted("A message could not be read: x", shown: "other", in: "a", at: now)
        #expect(!notices.isStale("other", in: "a", synced: true, at: later))
        notices.noted(sent, shown: "shown", in: "b", at: now)
        #expect(!notices.isStale("Could not send.", in: "b", synced: true, at: later))
        #expect(!notices.isStale("shown", in: "b", synced: true, at: later))
    }
}
