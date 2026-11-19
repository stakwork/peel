import PeelCore
import PeelUI
import SwiftUI

/// The chat's search on the iPhone (the Mac's `ChatSearchBar`, same
/// `ChatSearch` and `AppModel.runSearch`): under the header, the field,
/// "3 of 27", newer and older, the list of matches and close. Up goes to
/// the newer match, down to the older one; the keyboard's Search key goes
/// to the next older. Only in the main chat: a match in a thread opens the
/// thread sheet, and stepping goes on once that is closed.
struct PhoneChatSearchBar: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    @Bindable var search: ChatSearch
    let placeholder: String

    @FocusState private var focused: Bool
    @State private var listing = false
    /// The match tapped in the list, shown once the list's sheet is gone so
    /// it never stacks with the thread sheet a match may open.
    @State private var chosen: Int?

    /// How long typing rests before it searches, as on the Mac.
    private static let debounce = Duration.milliseconds(200)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                field
                stepButton("chevron.up", label: "Newer match", enabled: search.canStepNewer) { model.stepSearch(by: -1) }
                stepButton("chevron.down", label: "Older match", enabled: search.canStepOlder) { model.stepSearch(by: 1) }
                stepButton("list.bullet", label: "Search results", enabled: !search.matches.isEmpty) { listing = true }
                stepButton("xmark", label: "Close search", enabled: true) { model.closeSearch(refocusComposer: false) }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs)
            if let note = search.historyNote {
                Text(note)
                    .phoneFont(.time)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.bottom, Theme.Space.xs)
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
        .task(id: search.text) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await model.runSearch(search)
        }
        .task { focused = true }
        // Search again from the menu puts the cursor back; not while a
        // thread a match opened is over the chat.
        .onChange(of: search.focusRequests) {
            if router.thread.wrappedValue == nil { focused = true }
        }
        .sheet(isPresented: $listing, onDismiss: {
            guard let index = chosen else { return }
            chosen = nil
            model.showSearchMatch(index)
        }) {
            PhoneSearchResultsSheet(search: search) { index in
                chosen = index
                listing = false
            }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            TextField("Search", text: $search.text, prompt: Text(placeholder).foregroundStyle(Theme.tertiaryText))
                .phoneFont(.row)
                .focused($focused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(submit)
            if search.searching, search.matches.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Text(hint)
                    .phoneFont(.secondary)
                    .monospacedDigit()
                    .foregroundStyle(search.failed ? Theme.attention : Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(minHeight: 36)
        .background(Theme.menu, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    private func stepButton(_ image: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: Theme.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.text : Theme.tertiaryText)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// The Search key: the next older match once one is shown, else the
    /// first (`AppModel.searchReturn`, which waits for matches still coming).
    private func submit() {
        if search.current != nil, search.canStepOlder {
            model.stepSearch(by: 1)
        } else {
            _ = model.searchReturn()
        }
    }

    /// The count, "No matches", or how many characters a search needs.
    private var hint: String {
        if let status = search.status { return status }
        let typed = MessageQuery(search.text)
        return typed.isEmpty && typed.hasShortTerms ? "\(MessageQuery.minimum) or more characters" : ""
    }
}

/// The matches as a list in a sheet: who, a line around the first match
/// with it lit, and when. A tap picks the match; the bar shows it once
/// this sheet is down.
struct PhoneSearchResultsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let search: ChatSearch
    let pick: (Int) -> Void

    var body: some View {
        let terms = search.query?.terms ?? []
        NavigationStack {
            List {
                ForEach(Array(search.matches.enumerated()), id: \.offset) { index, message in
                    Button { pick(index) } label: {
                        row(message, snippet(message, terms), selected: index == search.current)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(index == search.current ? Theme.selection : Theme.background)
                }
                if let note = search.historyNote {
                    Text(note)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.tertiaryText)
                        .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ message: Message, _ snippet: AttributedString, selected: Bool) -> some View {
        let sender = model.sender(of: message)
        return HStack(spacing: Theme.Space.md) {
            Avatar(name: sender.avatarName, url: sender.photoURL, size: Theme.AvatarSize.sm, hue: sender.hue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.sm) {
                    Text(sender.label)
                        .phoneFont(PhoneFont.row.weight(.semibold))
                        .foregroundStyle(sender.hue.name)
                        .lineLimit(1)
                    if message.threadUUID != nil {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .accessibilityLabel("In a thread")
                    }
                    Spacer(minLength: 0)
                    Text(Formatting.relative(message.date))
                        .phoneFont(.time)
                        .monospacedDigit()
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                Text(snippet)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: Theme.touchTarget)
        .contentShape(Rectangle())
    }

    private func snippet(_ message: Message, _ terms: [String]) -> AttributedString {
        let line = search.query?.snippet(of: message.preview) ?? message.preview
        return AttributedString(line).highlighting(terms)
    }
}
