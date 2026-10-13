import Foundation
import Observation
import PeelCore

/// A search in one chat (⌘F): what is typed, the matches newest first
/// (`Storage.searchMessages`, thread messages included) and which one is
/// shown. Its own object so typing and stepping redraw only what reads it.
@MainActor @Observable
final class ChatSearch {
    /// The most matches listed; past it the count reads "1,000+".
    static let limit = 1000

    let chat: String
    var text = ""
    /// What the matches are for, as searched: its terms are lit.
    private(set) var query: MessageQuery?
    private(set) var matches: [Message] = []
    /// The match selected in the list (the arrows move it, Return goes to
    /// it), 0 the newest.
    private(set) var current: Int?
    private(set) var searching = false
    private(set) var failed = false
    /// Raised to put the cursor back in the field (⌘F while it is open).
    var focusRequests = 0

    init(chat: String) {
        self.chat = chat
    }

    /// "3 of 12", "12 matches", "No matches", or nothing while there is
    /// nothing to count.
    var status: String? {
        if failed { return "Could not search" }
        guard query != nil, !searching || !matches.isEmpty else { return nil }
        if matches.isEmpty { return "No matches" }
        let total = matches.count >= Self.limit ? "\(Self.limit.formatted())+" : matches.count.formatted()
        guard let current else { return Formatting.count(matches.count, "match", "matches", shown: total) }
        return "\(current + 1) of \(total)"
    }

    var canStepOlder: Bool { (current ?? -1) + 1 < matches.count }
    var canStepNewer: Bool { (current ?? 0) > 0 }

    fileprivate func began() {
        searching = true
    }

    fileprivate func found(_ matches: [Message], for query: MessageQuery?, failed: Bool = false) {
        self.query = query
        self.matches = matches
        self.failed = failed
        current = nil
        searching = false
    }

    fileprivate func select(_ index: Int) {
        current = index
    }
}

extension AppModel {
    /// Edit › Find (⌘F): the open chat's search, or the sidebar's when no
    /// chat is open (Threads, Mentions, Payments, the account). Only while
    /// the main window takes commands (`takesCommands`).
    func find() {
        guard takesCommands else { return }
        if let chat = selectedChat { openSearch(in: chat) } else { sidebarSearchFocus += 1 }
    }

    /// Opens the chat's search, or puts the cursor back in it.
    func openSearch(in chat: String) {
        if let search, search.chat == chat {
            search.focusRequests += 1
        } else {
            search = ChatSearch(chat: chat)
        }
    }

    /// Closes the search; the cursor goes back to the chat's composer.
    func closeSearch() {
        guard let chat = search?.chat else { return }
        search = nil
        composerFocus[.chat(chat), default: 0] += 1
    }

    /// Searches the chat's stored messages for what `search` holds now, off
    /// the main actor, and lists the matches, none selected yet.
    func runSearch(_ search: ChatSearch) async {
        let text = search.text
        let query = MessageQuery(text)
        guard let storage = engine?.storage, !query.isEmpty else { return search.found([], for: nil) }
        search.began()
        do {
            let matches = try await storage.searchMessages(query, in: search.chat, limit: ChatSearch.limit)
            // Typed on, or closed, meanwhile: a newer search has this.
            guard !Task.isCancelled, self.search === search, search.text == text else { return }
            search.found(matches, for: query)
        } catch {
            guard !Task.isCancelled, self.search === search else { return }
            search.found([], for: query, failed: true)
        }
    }

    /// Selects the next match down the list (`by` 1, older) or up it (-1,
    /// newer), stopping at either end; `show` also goes to it.
    func stepSearch(by step: Int, show: Bool = true) {
        guard let search else { return }
        let next = (search.current ?? -1) + step
        guard search.matches.indices.contains(next) else { return }
        if show { showSearchMatch(next) } else { search.select(next) }
    }

    /// Scrolls to a match and lights it, through the jump quotes and
    /// notifications use (which checks it was not deleted since); one in a
    /// thread opens its thread.
    func showSearchMatch(_ index: Int) {
        guard let search, search.matches.indices.contains(index) else { return }
        let message = search.matches[index]
        search.select(index)
        let inThread = message.threadUUID != nil
        focus(on: message, inThread: inThread)
        // Opening a thread puts the cursor in its composer; the arrows
        // belong to the search until it closes.
        if inThread {
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                search.focusRequests += 1
            }
        }
    }
}
