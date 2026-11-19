import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// Return pressed before a search's matches come goes to the first of them
/// once they do, and only for what was typed when it was pressed.
@MainActor
struct ChatSearchTests {
    private let needle = MessageQuery("needle")
    private let match = Message.fixture(content: "a needle")

    private func typed(_ text: String) -> ChatSearch {
        let search = ChatSearch(chat: dm)
        search.text = text
        return search
    }

    @Test func returnBeforeTheMatchesShowsTheFirstWhenTheyCome() {
        let search = typed("needle")
        #expect(search.waitForMatches())
        #expect(search.found([match], for: needle))
        // Once: the next matches are only listed.
        #expect(!search.found([match], for: needle))
    }

    @Test func aNewerQueryDropsTheWait() {
        let search = typed("need")
        #expect(search.waitForMatches())
        search.text = "needle"
        #expect(!search.found([match], for: needle))
    }

    @Test func noMatchesShowNothing() {
        let search = typed("needle")
        #expect(search.waitForMatches())
        #expect(!search.found([], for: needle))
        #expect(!search.found([match], for: needle))
    }

    /// With the matches in, or nothing typed, Return goes (or does
    /// nothing) at once.
    @Test func returnWithNothingToWaitForDoesNotWait() {
        let search = typed("needle")
        search.found([match], for: needle)
        #expect(!search.waitForMatches())
        #expect(!typed("").waitForMatches())
    }

    /// Stepping stops at either end: up is newer, down older, and a match
    /// far older than one page of messages is reachable like any other.
    @Test func stepsOnlyWithinTheMatches() {
        let search = typed("needle")
        let old = Message.fixture(content: "an old needle", timestamp: 1_000)
        search.found([match, old], for: needle)
        #expect(!search.canStepNewer)
        #expect(search.canStepOlder)
        #expect(search.status == "2 matches")
    }

    /// Matches found while history still syncs say older ones may be
    /// missing; a later search without it drops the note.
    @Test func historySyncingIsNotedPerSearch() {
        let search = typed("needle")
        #expect(search.historyNote == nil)
        search.found([match], for: needle, historySyncing: true)
        #expect(search.historyNote == "Still loading older messages")
        search.found([], for: needle, historySyncing: true)
        #expect(search.historyNote != nil)
        search.found([match], for: needle)
        #expect(search.historyNote == nil)
    }
}
