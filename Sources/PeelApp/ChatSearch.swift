import SwiftUI
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
        guard let current else { return matches.count == 1 ? "1 match" : "\(total) matches" }
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

/// The chat header's search button opens or closes the search (⌘F, Edit ›
/// Find, opens it: `AppModel.find`).
struct SearchHeaderButton: View {
    @Environment(AppModel.self) private var model
    let chat: String

    var body: some View {
        let open = model.search?.chat == chat
        IconButton("magnifyingglass", help: "Search in chat (⌘F)", lit: open) {
            if open { model.closeSearch() } else { model.openSearch(in: chat) }
        }
    }
}

/// Under the chat's header while searching: the field, "3 of 12", newer
/// and older, and close, then the matches. Words match in any order,
/// "quoted" as a phrase, and `from:name` narrows to a sender. From the
/// field, ↓ and ↑ move through the list and Return goes to the selected
/// match (the first when none is); Escape closes.
struct ChatSearchBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    @Bindable var search: ChatSearch
    let placeholder: String

    @FocusState private var focused: Bool
    @State private var hovering = false
    #if os(macOS)
    @State private var keys = KeyMonitor()
    #endif

    /// How long typing rests before it searches.
    private static let debounce = Duration.milliseconds(200)

    var body: some View {
        VStack(spacing: 0) {
            bar
            if !search.matches.isEmpty {
                SearchResults(search: search)
            }
        }
        .task(id: search.text) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await model.runSearch(search)
        }
        .task { focused = true }
        .onChange(of: search.focusRequests) { focused = true }
        #if os(macOS)
        .onChange(of: focused, initial: true) { _, focused in
            if focused { listen() } else { keys.stop() }
        }
        .onDisappear { keys.stop() }
        #endif
    }

    private var bar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                TextField("Search", text: $search.text, prompt: Text(placeholder).foregroundStyle(Theme.tertiaryText))
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .focused($focused)
                if search.searching, search.matches.isEmpty {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(hint)
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(search.failed ? Theme.attention : Theme.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .modifier(FieldChrome(focused: focused, hovering: hovering))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .onHover { hovering = $0 }
            HStack(spacing: 2) {
                IconButton("chevron.up", help: "Newer match") { model.stepSearch(by: -1) }
                    .disabled(!search.canStepNewer)
                IconButton("chevron.down", help: "Older match") { model.stepSearch(by: 1) }
                    .disabled(!search.canStepOlder)
                IconButton("xmark", help: "Close search (Esc)") { model.closeSearch() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }

    /// The count, "No matches", or how many characters a search needs.
    private var hint: String {
        if let status = search.status { return status }
        let typed = MessageQuery(search.text)
        return typed.isEmpty && typed.hasShortTerms ? "\(MessageQuery.minimum) or more characters" : ""
    }

    #if os(macOS)
    /// The field's keys, while it has the cursor, in its own window, under
    /// any menu, panel or the image viewer (`KeyMonitor`'s order); not while
    /// an input method is composing, whose Return and arrows are its own.
    private func listen() {
        keys.start { [model, presenter] event in
            guard presenter?.takesKeys(event) == true, model.viewer == nil else { return false }
            if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return false }
            switch event.keyCode {
            case KeyCode.down: model.stepSearch(by: 1, show: false)
            case KeyCode.up: model.stepSearch(by: -1, show: false)
            case KeyCode.return, KeyCode.enter:
                guard let search = model.search, !search.matches.isEmpty else { return false }
                model.showSearchMatch(search.current ?? 0)
            case KeyCode.escape: model.closeSearch()
            default: return false
            }
            return true
        }
    }
    #endif
}

/// The matches under the search bar, Slack's way: who, a line around the
/// first match with it lit, and when; the one shown selected and kept in
/// view as the arrows step. Five and a half rows tall at most, so a
/// longer list shows there is more.
private struct SearchResults: View {
    @Environment(AppModel.self) private var model
    let search: ChatSearch

    var body: some View {
        let terms = search.query?.terms ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(search.matches.enumerated()), id: \.offset) { index, message in
                        SearchResultRow(
                            message: message, sender: model.sender(of: message),
                            snippet: snippet(message, terms), selected: index == search.current
                        ) {
                            model.showSearchMatch(index)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: SearchResultRow.height * 5.5 + 8)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: search.current) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }

    private func snippet(_ message: Message, _ terms: [String]) -> AttributedString {
        let line = search.query?.snippet(of: message.preview) ?? message.preview
        return AttributedString(line).highlighting(terms)
    }
}

private struct SearchResultRow: View {
    let message: Message
    let sender: Sender
    let snippet: AttributedString
    let selected: Bool
    let action: () -> Void

    static let height: CGFloat = 36

    var body: some View {
        ListRow(selected: selected, minHeight: Self.height, action: action) {
            Avatar(name: sender.avatarName, url: sender.photoURL, size: 20, hue: sender.hue)
        } title: {
            HStack(spacing: 8) {
                Text(sender.label)
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(sender.hue.name)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(snippet)
                    .lineLimit(1)
            }
        } trailing: {
            HStack(spacing: 8) {
                if message.threadUUID != nil {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .help("In a thread")
                }
                Text(Formatting.relative(message.date))
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

extension AttributedString {
    /// With every occurrence of each of `terms` behind the search
    /// highlight, found as the index finds them (case and accents aside).
    func highlighting(_ terms: [String]) -> AttributedString {
        var result = self
        for term in terms where !term.isEmpty {
            var start = result.startIndex
            while start < result.endIndex,
                  let range = result[start...].range(of: term, options: MessageQuery.compareOptions) {
                result[range].backgroundColor = Theme.searchMatch
                start = range.upperBound
            }
        }
        return result
    }
}
