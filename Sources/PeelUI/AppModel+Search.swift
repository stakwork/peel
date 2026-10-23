import Foundation
import Observation
import PeelCore

/// A search in one chat (⌘F): what is typed, the matches newest first
/// (`Storage.searchMessages`, thread messages included) and which one is
/// shown. Its own object so typing and stepping redraw only what reads it.
@MainActor @Observable
public final class ChatSearch {
    /// The most matches listed; past it the count reads "1,000+".
    public static let limit = 1000

    public let chat: String
    public var text = ""
    /// What the matches are for, as searched: its terms are lit.
    public private(set) var query: MessageQuery?
    public private(set) var matches: [Message] = []
    /// The match selected in the list (the arrows move it, Return goes to
    /// it), 0 the newest.
    public private(set) var current: Int?
    public private(set) var searching = false
    public private(set) var failed = false
    /// Raised to put the cursor back in the field (⌘F while it is open).
    public var focusRequests = 0
    /// What was typed when Return came before its matches: the first of
    /// them is shown once they are found. Any other matches drop it.
    private var returnAwaits: MessageQuery?

    public init(chat: String) {
        self.chat = chat
    }

    /// "3 of 12", "12 matches", "No matches", or nothing while there is
    /// nothing to count.
    public var status: String? {
        if failed { return "Could not search" }
        guard query != nil, !searching || !matches.isEmpty else { return nil }
        if matches.isEmpty { return "No matches" }
        let total = matches.count >= Self.limit ? "\(Self.limit.formatted())+" : matches.count.formatted()
        guard let current else { return Formatting.count(matches.count, "match", "matches", shown: total) }
        return "\(current + 1) of \(total)"
    }

    public var canStepOlder: Bool { (current ?? -1) + 1 < matches.count }
    public var canStepNewer: Bool { (current ?? 0) > 0 }

    fileprivate func began() {
        searching = true
    }

    /// Return when the matches are not for what is typed yet: it waits
    /// for them, and says so.
    func waitForMatches() -> Bool {
        let typed = MessageQuery(text)
        guard !typed.isEmpty, query != typed else { return false }
        returnAwaits = typed
        return true
    }

    /// Lists the matches; true when Return waited for them and there is a
    /// first to show.
    @discardableResult
    func found(_ matches: [Message], for query: MessageQuery?, failed: Bool = false) -> Bool {
        let showsFirst = returnAwaits != nil && returnAwaits == query && !matches.isEmpty
        returnAwaits = nil
        self.query = query
        self.matches = matches
        self.failed = failed
        current = nil
        searching = false
        return showsFirst
    }

    fileprivate func select(_ index: Int) {
        current = index
    }
}

extension AppModel {
    /// Edit › Find (⌘F): the open chat's search, or the sidebar's when no
    /// chat is open (Threads, Mentions, Payments, the account, where it
    /// searches the account's categories). Only while the main window takes
    /// commands (`takesCommands`).
    public func find() {
        guard takesCommands else { return }
        if let chat = selectedChat { openSearch(in: chat) } else { sidebarSearchFocus += 1 }
    }

    /// Opens the chat's search, or puts the cursor back in it.
    public func openSearch(in chat: String) {
        if let search, search.chat == chat {
            search.focusRequests += 1
        } else {
            search = ChatSearch(chat: chat)
        }
    }

    /// Closes the search; the cursor goes back to the chat's composer.
    public func closeSearch() {
        guard let chat = search?.chat else { return }
        search = nil
        composerFocus[.chat(chat), default: 0] += 1
    }

    /// Searches the chat's stored messages for what `search` holds now, off
    /// the main actor, and lists the matches, none selected yet.
    public func runSearch(_ search: ChatSearch) async {
        let text = search.text
        let query = MessageQuery(text)
        guard let storage = engine?.storage, !query.isEmpty else {
            search.found([], for: nil)
            return
        }
        search.began()
        do {
            let matches = try await storage.searchMessages(query, in: search.chat, limit: ChatSearch.limit)
            // Typed on, or closed, meanwhile: a newer search has this.
            guard !Task.isCancelled, self.search === search, search.text == text else { return }
            if search.found(matches, for: query) { showSearchMatch(0) }
        } catch {
            guard !Task.isCancelled, self.search === search else { return }
            search.found([], for: query, failed: true)
        }
    }

    /// Return in the search field: goes to the selected match, the first
    /// when none is. Typed faster than the search, it goes to the first
    /// once the matches for what is typed come; false with nothing to do.
    public func searchReturn() -> Bool {
        guard let search else { return false }
        if search.waitForMatches() { return true }
        guard !search.matches.isEmpty else { return false }
        showSearchMatch(search.current ?? 0)
        return true
    }

    /// Selects the next match down the list (`by` 1, older) or up it (-1,
    /// newer), stopping at either end; `show` also goes to it.
    public func stepSearch(by step: Int, show: Bool = true) {
        guard let search else { return }
        let next = (search.current ?? -1) + step
        guard search.matches.indices.contains(next) else { return }
        if show { showSearchMatch(next) } else { search.select(next) }
    }

    /// Scrolls to a match and lights it, through the jump quotes and
    /// notifications use (which checks it was not deleted since); one in a
    /// thread opens its thread.
    public func showSearchMatch(_ index: Int) {
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
