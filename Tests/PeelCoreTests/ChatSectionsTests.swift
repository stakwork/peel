import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The sidebar's sections: Unread first, then the recent tribes and direct
/// messages, trimmed, with the open chat always shown.
struct ChatSectionsTests {
    /// Newest first, as `Storage.conversations()` gives them.
    let chats: [Conversation] = (1...8).map { tribe("t\($0)") } + (1...7).map { person("p\($0)") }

    private static func tribe(_ name: String) -> Conversation {
        Conversation(chat: name, alias: name, isTribe: true)
    }

    private static func person(_ name: String) -> Conversation {
        Conversation(chat: name, alias: name, isTribe: false)
    }

    private func tribe(_ name: String) -> Conversation { Self.tribe(name) }
    private func person(_ name: String) -> Conversation { Self.person(name) }

    private func state(_ chat: String, unread: Int = 0, mentions: Int = 0, mute: MuteLevel = .all, isNew: Bool = false)
        -> (String, ChatReadState) {
        (chat, ChatReadState(chat: chat, unread: unread, mentions: mentions, muteLevel: mute.rawValue, isNew: isNew))
    }

    private func names(_ conversations: [Conversation]) -> [String] { conversations.map(\.chat) }

    @Test func unreadComesFirstDirectThenMentionsThenTribes() {
        let states = Dictionary(uniqueKeysWithValues: [
            state("t2", unread: 3),
            state("t5", unread: 1, mentions: 1),
            state("p6", unread: 1),
            state("p1", isNew: true),
            state("t3", unread: 4, mute: .muted),
            state("t4", unread: 2, mentions: 1, mute: .muted),
            state("t6", unread: 5, mute: .mentionsOnly),
            state("p3", unread: 2, mute: .muted),
        ])
        let sections = ChatSections(chats, states: states)
        #expect(names(sections.unread) == ["p1", "p6", "t4", "t5", "t2"])
        // Unread chats leave their own section while unread.
        #expect(names(sections.tribes) == ["t1", "t3", "t6", "t7", "t8"])
        #expect(names(sections.direct) == ["p2", "p3", "p4", "p5", "p7"])
    }

    /// Every message counts, only mentions, or nothing (the Dock badge);
    /// the sidebar still counts a muted chat's mentions.
    @Test func sidebarCountsMentionsOfAMutedChat() {
        #expect(ChatReadState(chat: "t", unread: 9, mentions: 2, muteLevel: MuteLevel.all.rawValue).shownUnread == 9)
        let mentionsOnly = ChatReadState(chat: "t", unread: 9, mentions: 2, muteLevel: MuteLevel.mentionsOnly.rawValue)
        #expect(mentionsOnly.shownUnread == 2)
        #expect(mentionsOnly.sidebarCount == 2)
        let muted = ChatReadState(chat: "t", unread: 9, mentions: 2, muteLevel: MuteLevel.muted.rawValue)
        #expect(muted.shownUnread == 0)
        #expect(muted.sidebarCount == 2)
        #expect(muted.isUnread)
        let quiet = ChatReadState(chat: "t", unread: 9, mentions: 0, muteLevel: MuteLevel.mentionsOnly.rawValue)
        #expect(!quiet.isUnread)
    }

    @Test func sectionsTrimToTheRecentAndKeepTheOpenChat() {
        let sections = ChatSections(chats, states: [:], open: "t8")
        #expect(names(sections.tribes) == ["t1", "t2", "t3", "t4", "t5", "t8"])
        #expect(sections.allTribes == 8)
        #expect(names(sections.direct) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(sections.allDirect == 7)
    }

    @Test func showAllCountsUnreadChatsTooAndStaysToShowFewer() {
        var layout = ChatSections.Layout()
        layout.allTribes = true
        let sections = ChatSections(chats, states: Dictionary(uniqueKeysWithValues: [state("t1", unread: 1)]),
                                    layout: layout)
        #expect(sections.tribes.count == 7)
        #expect(sections.allTribes == 8)
    }

    @Test func noShowAllWhenNothingIsHidden() {
        let few = ChatSections(Array(chats.prefix(5)) + [person("p1")], states: [:])
        #expect(few.allTribes == nil)
        // Six tribes, the sixth open: all six show, so nothing to show all.
        let six = ChatSections(Array(chats.prefix(6)), states: [:], open: "t6")
        #expect(names(six.tribes).count == 6)
        #expect(six.allTribes == nil)
    }

    @Test func aClosedSectionShowsOnlyTheOpenChat() {
        var layout = ChatSections.Layout()
        layout.tribesOpen = false
        let sections = ChatSections(chats, states: [:], layout: layout, open: "t7")
        #expect(!sections.tribesOpen)
        #expect(names(sections.tribes) == ["t7"])
        #expect(sections.allTribes == nil)
        #expect(ChatSections(chats, states: [:], layout: layout, open: "p1").tribes.isEmpty)
    }

    @Test func matchesANameAsTheSectionsDo() {
        #expect(ChatSections.matches("Peel", query: ""))
        #expect(ChatSections.matches("Peel", query: " pee "))
        #expect(!ChatSections.matches("Peel", query: "kate"))
    }

    @Test func searchFindsEveryMatchUntrimmedInClosedSections() {
        var layout = ChatSections.Layout()
        layout.tribesOpen = false
        let many = (1...9).map { tribe("hive \($0)") }
        let sections = ChatSections(many + chats, states: Dictionary(uniqueKeysWithValues: [state("hive 2", unread: 1)]),
                                    layout: layout, query: " HIVE ")
        #expect(sections.searching)
        #expect(sections.tribesOpen)
        #expect(names(sections.unread) == ["hive 2"])
        #expect(sections.tribes.count == 8)
        #expect(sections.allTribes == nil)
        #expect(sections.direct.isEmpty)
    }

    @Test func stepsThroughUnreadGoingRound() {
        let states = Dictionary(uniqueKeysWithValues: [state("t2", unread: 1), state("p4", unread: 1), state("t6", unread: 1)])
        let sections = ChatSections(chats, states: states)
        #expect(names(sections.unread) == ["p4", "t2", "t6"])
        #expect(sections.unread(from: nil, by: 1) == "p4")
        #expect(sections.unread(from: "t1", by: -1) == "t6")
        #expect(sections.unread(from: "p4", by: 1) == "t2")
        #expect(sections.unread(from: "t6", by: 1) == "p4")
        #expect(sections.unread(from: "p4", by: -1) == "t6")
        let one = ChatSections(chats, states: Dictionary(uniqueKeysWithValues: [state("t2", unread: 1)]))
        #expect(one.unread(from: "t2", by: 1) == nil)
        #expect(ChatSections(chats, states: [:]).unread(from: "t2", by: 1) == nil)
    }

    @Test func aSavedLayoutMissingAFieldKeepsTheRest() throws {
        let layout = try JSONDecoder().decode(ChatSections.Layout.self, from: Data(#"{"allTribes":true}"#.utf8))
        #expect(layout.allTribes)
        #expect(layout.tribesOpen && layout.directOpen && !layout.allDirect)
        // A layout from before pins: none pinned, and the Apps row open.
        #expect(layout.pinnedApps.isEmpty && layout.appsOpen)
        var changed = ChatSections.Layout()
        changed.directOpen = false
        let back = try JSONDecoder().decode(ChatSections.Layout.self, from: JSONEncoder().encode(changed))
        #expect(back == changed)
    }

    @Test func pinnedAppsAreKept() throws {
        var layout = ChatSections.Layout()
        layout.pinnedApps = ["@acme/invoices", "@stakwork/benchmarks"]
        let back = try JSONDecoder().decode(ChatSections.Layout.self, from: JSONEncoder().encode(layout))
        #expect(back.pinnedApps == layout.pinnedApps)
    }

    @Test func theLayoutIsKeptWithTheAccount() async throws {
        let profile = TempProfile()
        let engine = try testEngine(profile.storage())
        #expect(try await engine.sidebarLayout() == ChatSections.Layout())
        var layout = ChatSections.Layout()
        layout.allDirect = true
        try await engine.setSidebarLayout(layout)
        #expect(try await engine.sidebarLayout() == layout)
        #expect(await engine.settings().sidebarLayout == layout)
    }
}
