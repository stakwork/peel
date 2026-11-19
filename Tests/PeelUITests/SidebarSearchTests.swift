import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// The sidebar's message search: debounced, the stale one dropped, capped,
/// and cleared back to nothing.
@MainActor
struct SidebarSearchTests {
    /// Counts what it was asked, answering with `found`.
    final class Finds: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(String, Int)] = []
        var found: [Message]
        var fails = false
        var delay = Duration.zero

        init(_ found: [Message] = []) { self.found = found }

        var queries: [(String, Int)] { lock.withLock { asked } }

        func find(_ query: MessageQuery, _ limit: Int) async throws -> [Message] {
            lock.withLock { asked.append((query.terms.joined(separator: " "), limit)) }
            if delay > .zero { try await Task.sleep(for: delay) }
            if fails { throw CocoaError(.fileReadUnknown) }
            return found
        }
    }

    private func search() -> SidebarSearch {
        let search = SidebarSearch()
        search.debounce = .milliseconds(5)
        return search
    }

    @Test func typingSearchesOnceAfterTheDebounce() async {
        let search = search(), finds = Finds([.fixture(content: "a needle")])
        search.update("nee", find: finds.find)
        search.update("need", find: finds.find)
        search.update("needle", find: finds.find)
        #expect(search.searching)
        await search.settled()
        #expect(finds.queries.map(\.0) == ["needle"])
        #expect(finds.queries.first?.1 == SidebarSearch.messageLimit)
        #expect(search.messages.count == 1)
        #expect(!search.searching && !search.failed)
    }

    @Test func aSlowSearchForOldTextIsIgnored() async {
        let search = search(), slow = Finds([.fixture(content: "old")]), fast = Finds([.fixture(content: "new")])
        slow.delay = .milliseconds(200)
        search.update("older", find: slow.find)
        try? await Task.sleep(for: .milliseconds(50))
        search.update("newer", find: fast.find)
        await search.settled()
        #expect(search.messages.first?.content == "new")
        #expect(search.query?.terms == ["newer"])
    }

    @Test func clearingDropsAnythingUnderWay() async {
        let search = search(), finds = Finds([.fixture(content: "a needle")])
        search.update("needle", find: finds.find)
        search.clear()
        await search.settled()
        #expect(finds.queries.isEmpty)
        #expect(search.isIdle && search.messages.isEmpty)
    }

    @Test func emptyOrTooShortTextRestoresTheList() async {
        let search = search(), finds = Finds([.fixture(content: "a needle")])
        search.update("needle", find: finds.find)
        await search.settled()
        #expect(!search.messages.isEmpty)
        search.update("ne", find: finds.find)
        #expect(search.isIdle && search.messages.isEmpty)
        search.update("", find: finds.find)
        #expect(search.isIdle)
        #expect(finds.queries.count == 1)
    }

    @Test func noMatchesIsAnEmptyAnswer() async {
        let search = search()
        search.update("needle", find: Finds().find)
        await search.settled()
        #expect(search.foundNone && !search.failed)
    }

    @Test func aFailureIsShownAndNotNoResults() async {
        let search = search(), finds = Finds()
        finds.fails = true
        search.update("needle", find: finds.find)
        await search.settled()
        #expect(search.failed && !search.foundNone && !search.searching)
        // Typing on tries again.
        finds.fails = false
        search.update("needles", find: finds.find)
        #expect(!search.failed && search.searching)
    }

    @Test func messagesAreCappedAtTheLimit() async {
        let search = search()
        let many = (0..<(SidebarSearch.messageLimit + 10)).map { Message.fixture(uuid: "u\($0)", content: "needle \($0)") }
        search.update("needle", find: Finds(many).find)
        await search.settled()
        #expect(search.messages.count == SidebarSearch.messageLimit)
    }

    @Test func chatsAreCapped() {
        let chats = (0..<20).map { Conversation(chat: "02\($0)", alias: "Chat \($0)", photoURL: nil, isTribe: false) }
        #expect(SidebarSearch.capped(chats).count == SidebarSearch.chatLimit)
        #expect(SidebarSearch.capped(Array(chats.prefix(3))).count == 3)
    }
}
