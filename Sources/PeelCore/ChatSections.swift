import Foundation

/// The sidebar's chats for an account with many of them (Tom, 2026-10-09):
/// Unread first, then the most recent tribes, then the most recent direct
/// messages, each trimmed to `recent` until shown in full. Worked out from
/// `Storage.conversations()` (newest first) and `Storage.readStates()`, so
/// anything that lists chats as the sidebar does gets the same order.
public struct ChatSections: Equatable, Sendable {
    /// What the person chose to see, kept with the account
    /// (`Engine.sidebarLayout`).
    public struct Layout: Codable, Equatable, Sendable {
        public var tribesOpen = true
        public var directOpen = true
        /// "Show all 14 tribes" was clicked.
        public var allTribes = false
        public var allDirect = false
        /// The apps pinned under the sidebar's Apps row, by key (`@<workspace>/<name>`,
        /// or the name alone for the person's own);
        /// none until the person pins one (Tom, 2026-10-26).
        public var pinnedApps: [String] = []
        /// The pinned apps show under the Apps row (Tom, 2026-10-28).
        public var appsOpen = true
        /// Tribes and direct messages show as one list, newest first, rather
        /// than in two sections.
        public var combinedView = false
        /// "Show all 32 chats" was clicked in the Recent view.
        public var allRecent = false

        public init() {}

        /// A field the saved layout lacks (an older or newer build's) keeps
        /// its default rather than resetting the rest.
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tribesOpen = try values.decodeIfPresent(Bool.self, forKey: .tribesOpen) ?? true
            directOpen = try values.decodeIfPresent(Bool.self, forKey: .directOpen) ?? true
            allTribes = try values.decodeIfPresent(Bool.self, forKey: .allTribes) ?? false
            allDirect = try values.decodeIfPresent(Bool.self, forKey: .allDirect) ?? false
            pinnedApps = try values.decodeIfPresent([String].self, forKey: .pinnedApps) ?? []
            appsOpen = try values.decodeIfPresent(Bool.self, forKey: .appsOpen) ?? true
            combinedView = try values.decodeIfPresent(Bool.self, forKey: .combinedView) ?? false
            allRecent = try values.decodeIfPresent(Bool.self, forKey: .allRecent) ?? false
        }

        /// Whether the app with key `id` (`WorkspaceApp.id`) is pinned.
        public func isPinned(_ id: String) -> Bool { pinnedApps.contains(id) }

        /// Pins the app with key `id` (last, in the order pinned) or takes it
        /// off. The first pin opens the fold, which was no longer there to
        /// open while nothing was pinned.
        public mutating func setPinned(_ id: String, _ pinned: Bool) {
            var pins = pinnedApps.filter { $0 != id }
            if pinned {
                if pins.isEmpty { appsOpen = true }
                pins.append(id)
            }
            if pins != pinnedApps { pinnedApps = pins }
        }

        /// The pinned ones of `apps`, in their order.
        public func pinned(_ apps: [WorkspaceApp]) -> [WorkspaceApp] {
            apps.filter { isPinned($0.id) }
        }
    }

    /// How many tribes and direct messages show before "Show all".
    public static let recent = 5
    /// How many chats the Recent view shows before "Show all".
    public static let recentCombined = 10

    /// Every chat with something unread: direct messages first, then tribes
    /// that mention you, then the other tribes, each newest first.
    public private(set) var unread: [Conversation] = []
    /// The tribes and direct messages not in `unread`, as shown: trimmed to
    /// `recent` (with the open chat however far down), only the open chat
    /// while the section is closed, every match while searching.
    public private(set) var tribes: [Conversation] = []
    public private(set) var direct: [Conversation] = []
    /// Every tribe and direct message not in `unread` (matching the search),
    /// merged and newest first, for the Recent view: trimmed to
    /// `recentCombined` (with the open chat however far down) until shown in full.
    public private(set) var combined: [Conversation] = []
    /// How many chats there are in all, unread included, for the Recent view's
    /// "Show all 32 chats" (or "Show fewer"); nil when it has no more to show.
    public private(set) var allCombined: Int?
    /// A search is filtering the lists: every section shows its matches,
    /// whatever the layout says.
    public private(set) var searching = false
    /// Whether each section shows its rows ("+" rows included), searching
    /// or not.
    public private(set) var tribesOpen = true
    public private(set) var directOpen = true
    /// How many tribes and people there are in all, unread included, for
    /// "Show all 14 tribes" (or "Show fewer" once shown in full); nil when
    /// the section has no more to show, closed or searching: no such row.
    public private(set) var allTribes: Int?
    public private(set) var allDirect: Int?

    /// `conversations` newest first; `open` is the chat in view.
    public init(
        _ conversations: [Conversation], states: [String: ChatReadState], layout: Layout = Layout(),
        query: String = "", open: String? = nil
    ) {
        let query = query.trimmingCharacters(in: .whitespaces)
        searching = !query.isEmpty
        var mentioning: [Conversation] = [], otherTribes: [Conversation] = []
        var tribes: [Conversation] = [], direct: [Conversation] = []
        var tribeCount = 0, directCount = 0
        for conversation in conversations {
            if conversation.isTribe { tribeCount += 1 } else { directCount += 1 }
            guard Self.matches(conversation.name, query: query) else { continue }
            let state = states[conversation.chat]
            switch (state?.isUnread == true, conversation.isTribe) {
            case (true, false): unread.append(conversation)
            case (true, true):
                if state?.mentions ?? 0 > 0 { mentioning.append(conversation) } else { otherTribes.append(conversation) }
            case (false, true): tribes.append(conversation)
            case (false, false): direct.append(conversation)
            }
        }
        unread += mentioning + otherTribes
        let merged = (tribes + direct).sorted { ($0.lastTimestamp ?? 0) > ($1.lastTimestamp ?? 0) }
        (combined, allCombined) = Self.shown(merged, open: true, all: layout.allRecent, searching: searching,
                                             total: tribeCount + directCount, chat: open, limit: Self.recentCombined)
        tribesOpen = layout.tribesOpen || searching
        directOpen = layout.directOpen || searching
        (self.tribes, allTribes) = Self.shown(tribes, open: tribesOpen, all: layout.allTribes,
                                              searching: searching, total: tribeCount, chat: open)
        (self.direct, allDirect) = Self.shown(direct, open: directOpen, all: layout.allDirect,
                                              searching: searching, total: directCount, chat: open)
    }

    /// Whether a chat named `name` shows for a search: every chat with no
    /// query, else one whose name holds it, whatever the case. The agent's
    /// row, which is not in the sections, goes by it too.
    public static func matches(_ name: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    /// A section's rows and its "Show all" count: the open chat alone while
    /// closed; every row while searching; the first `recent` and the open
    /// chat unless shown in full (`limit`, `recent` unless said).
    private static func shown(
        _ rows: [Conversation], open: Bool, all: Bool, searching: Bool, total: Int, chat: String?, limit: Int = recent
    ) -> ([Conversation], Int?) {
        guard open else { return (rows.filter { $0.chat == chat }, nil) }
        guard !searching, rows.count > limit else { return (rows, nil) }
        guard !all else { return (rows, total) }
        let trimmed = rows.enumerated().filter { $0.offset < limit || $0.element.chat == chat }.map(\.element)
        return (trimmed, trimmed.count < rows.count ? total : nil)
    }

    /// The unread chat `offset` places from `current`, going round; the
    /// first (or, going up, the last) when `current` is not unread; nil
    /// when there is no other.
    public func unread(from current: String?, by offset: Int) -> String? {
        let chats = unread.map(\.chat)
        guard let index = current.flatMap(chats.firstIndex(of:)) else { return offset > 0 ? chats.first : chats.last }
        let next = chats[((index + offset) % chats.count + chats.count) % chats.count]
        return next == current ? nil : next
    }
}
