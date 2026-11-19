import Foundation
import Observation
import PeelCore

/// The sidebar's search beyond chat names: the messages in every chat that
/// match what is typed (`Storage.searchMessages` with no chat). Chats are
/// filtered by name as before (`ChatSections`); this adds the "Messages"
/// section under them. Typing rests `debounce` before it searches, a newer
/// text cancels the search before it, and a result for text no longer
/// typed is dropped.
@MainActor @Observable
public final class SidebarSearch {
    /// The most messages asked for and listed.
    public static let messageLimit = 25
    /// The most chats a list of name matches shows.
    public static let chatLimit = 8

    /// What finds the messages for a query, at most `limit`, newest first.
    public typealias Finder = @Sendable (MessageQuery, Int) async throws -> [Message]

    /// What the matches are for, as searched: its terms are lit.
    public private(set) var query: MessageQuery?
    public private(set) var messages: [Message] = []
    public private(set) var searching = false
    public private(set) var failed = false
    /// How long typing rests before it searches.
    @ObservationIgnored public var debounce = Duration.milliseconds(250)

    @ObservationIgnored private var text = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    /// Nothing is typed that a message search takes (a word under
    /// `MessageQuery.minimum` characters is left out).
    public var isIdle: Bool { query == nil && !searching && !failed }

    /// Searched, found nothing, and not failed: "No results" when the
    /// chats found nothing too.
    public var foundNone: Bool { query != nil && !searching && !failed && messages.isEmpty }

    /// `chats` as many as the list shows.
    public static func capped(_ chats: [Conversation]) -> [Conversation] {
        Array(chats.prefix(chatLimit))
    }

    /// The text is now `text`: searches for it after the debounce, with
    /// `find`; empty (or only words too short) restores the plain list.
    public func update(_ text: String, find: @escaping Finder) {
        self.text = text
        task?.cancel()
        task = nil
        let query = MessageQuery(text)
        guard !query.isEmpty else {
            reset()
            return
        }
        searching = true
        failed = false
        let wait = debounce
        task = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            let found: [Message]?
            do {
                found = try await find(query, Self.messageLimit)
            } catch {
                found = nil
            }
            // Typed on, or cleared, meanwhile: a newer search has this.
            guard let self, !Task.isCancelled, self.text == text else { return }
            self.query = query
            self.messages = Array((found ?? []).prefix(Self.messageLimit))
            self.failed = found == nil
            self.searching = false
        }
    }

    /// The search is cleared (also Escape, or a new account): nothing kept.
    public func clear() {
        text = ""
        task?.cancel()
        task = nil
        reset()
    }

    /// Waits for the search under way, if any (for tests).
    func settled() async {
        await task?.value
    }

    private func reset() {
        query = nil
        messages = []
        searching = false
        failed = false
    }
}

extension AppModel {
    /// The sidebar's search text changed: searches the messages of every chat.
    public func updateSidebarSearch() {
        guard let storage = engine?.storage else {
            sidebarSearch.clear()
            return
        }
        sidebarSearch.update(searchQuery) { query, limit in
            try await storage.searchMessages(query, in: nil, limit: limit)
        }
    }

    /// Opens a result's chat scrolled to the message, lit, through the jump
    /// quotes and notifications use (it selects the chat); one in a thread
    /// opens its thread.
    public func openSidebarMessage(_ message: Message) {
        focus(on: message, inThread: message.threadUUID != nil)
    }

    /// Escape in the sidebar's search, or its clear: the normal list again.
    public func clearSidebarSearch() {
        searchQuery = ""
        sidebarSearch.clear()
    }
}
