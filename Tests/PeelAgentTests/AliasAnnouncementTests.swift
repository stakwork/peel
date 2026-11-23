import Testing
@testable import PeelAgent

/// When a rename is announced by the agent, how a retry after a restart goes,
/// and that a newer rename supersedes an older announcement.
struct AliasAnnouncementTests {
    @Test func onlyARealChangeIsAnnounced() {
        #expect(AliasAnnouncement.shouldAnnounce(old: "Peel", new: "Scout"))
        #expect(AliasAnnouncement.shouldAnnounce(old: "Peel", new: "  Scout \n"))
        #expect(AliasAnnouncement.shouldAnnounce(old: "Peel", new: "peel"))
        #expect(!AliasAnnouncement.shouldAnnounce(old: "Peel", new: "Peel"))
        #expect(!AliasAnnouncement.shouldAnnounce(old: "Peel", new: "Peel  "))
        #expect(!AliasAnnouncement.shouldAnnounce(old: "Peel ", new: "Peel"))
        #expect(!AliasAnnouncement.shouldAnnounce(old: "Peel", new: ""))
        #expect(!AliasAnnouncement.shouldAnnounce(old: "Peel", new: " \t\n"))
        #expect(!AliasAnnouncement.shouldAnnounce(old: nil, new: "Scout"))
    }

    @Test func aRetryStopsWhereNothingWillChange() {
        #expect(AliasAnnouncement.step(afterStatus: 200) == .done)
        #expect(AliasAnnouncement.step(afterStatus: 404) == .stop)
        #expect(AliasAnnouncement.step(afterStatus: 400) == .stop)
        #expect(AliasAnnouncement.step(afterStatus: 503) == .retry)
        #expect(AliasAnnouncement.step(afterStatus: nil) == .retry)
        #expect(AliasAnnouncement.tries == 5)
    }

    @Test func aNewerRenameSupersedesAnOlderAnnouncement() {
        var announcement = AliasAnnouncement()
        let first = announcement.begin()
        #expect(announcement.isCurrent(first))
        let second = announcement.begin()
        #expect(!announcement.isCurrent(first))
        #expect(announcement.isCurrent(second))
        // The older one finishing does not end the newer.
        announcement.finish(first)
        #expect(announcement.isCurrent(second))
        announcement.finish(second)
        #expect(!announcement.isCurrent(second))
    }
}
