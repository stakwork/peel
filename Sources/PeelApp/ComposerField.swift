#if os(macOS)
import AppKit
import SwiftUI

/// The message field: Return sends, Shift-Return or Option-Return starts a new
/// line, paste brings in plain text only, and the field grows to eight lines
/// before it scrolls. A text view rather than a `TextField`, because a field
/// cannot tell Return from Shift-Return.
///
/// It also reports the `@word` being typed before the cursor (`mention`), lets
/// the composer take arrow keys, Tab, Return and Escape while suggestions
/// show (`suggestionKey`), and puts in a chosen alias (`insertion`).
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    /// Bump to put the cursor in the field.
    let focusRequest: Int
    let submit: () -> Void
    var mention: Binding<String?> = .constant(nil)
    var insertion: MentionInsertion?
    var suggestionKey: (SuggestionKey) -> Bool = { _ in false }
    /// Escape with no suggestions showing, such as to stop replying; returns
    /// whether it was taken.
    var escape: () -> Bool = { false }

    @State private var height: CGFloat = ComposerTextView.lineHeight

    var body: some View {
        ComposerTextView(
            text: $text, height: $height, mention: mention, focusRequest: focusRequest, insertion: insertion,
            submit: submit, suggestionKey: suggestionKey, escape: escape
        )
        .frame(height: height)
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, ComposerTextView.padding + 5)
                    .padding(.top, ComposerTextView.padding)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A key the mention suggestions may take while they show.
enum SuggestionKey { case up, down, accept, dismiss }

/// An alias to put in place of the `@word` being typed. A new `id` each time.
struct MentionInsertion: Equatable {
    let id: Int
    let alias: String
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var mention: String?
    let focusRequest: Int
    let insertion: MentionInsertion?
    let submit: () -> Void
    let suggestionKey: (SuggestionKey) -> Bool
    let escape: () -> Bool

    static let font = NSFont.systemFont(ofSize: 14)
    static let padding: CGFloat = 4
    static let maxLines: CGFloat = 8
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font) + padding * 2

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = NSColor(Theme.text)
        textView.insertionPointColor = NSColor(Theme.text)
        textView.textContainerInset = NSSize(width: 0, height: Self.padding)
        // Messages often carry code and addresses; leave what was typed alone.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Marked text (an input method mid-composition) is not in the binding yet.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            context.coordinator.measure(textView)
            context.coordinator.findMention(textView)
        }
        if let insertion, context.coordinator.insertedID != insertion.id {
            context.coordinator.insertedID = insertion.id
            context.coordinator.insert(insertion.alias, in: textView)
        }
        if context.coordinator.focusedRequest != focusRequest {
            context.coordinator.focusedRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusedRequest: Int?
        var insertedID: Int?
        /// Where the `@word` before the cursor sits, while there is one.
        private var mentionRange: NSRange?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            measure(textView)
            findMention(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            findMention(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if mentionRange != nil, let key = Self.suggestionKeys[selector], parent.suggestionKey(key) {
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) { return parent.escape() }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.submit()
            }
            return true
        }

        private static let suggestionKeys: [Selector: SuggestionKey] = [
            #selector(NSResponder.moveUp(_:)): .up,
            #selector(NSResponder.moveDown(_:)): .down,
            #selector(NSResponder.insertTab(_:)): .accept,
            #selector(NSResponder.insertNewline(_:)): .accept,
            #selector(NSResponder.cancelOperation(_:)): .dismiss,
        ]

        /// The word ending at the cursor, if it starts with `@`, as the Mac
        /// app looks for it; reported without the `@`.
        func findMention(_ textView: NSTextView) {
            let selection = textView.selectedRange()
            let string = textView.string as NSString
            var found: (NSRange, String)?
            if selection.length == 0, selection.location <= string.length {
                let before = string.substring(to: selection.location)
                let start = before.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
                    .map { $0.upperBound } ?? before.startIndex
                let word = before[start...]
                if word.hasPrefix("@") {
                    let length = (String(word) as NSString).length
                    found = (NSRange(location: selection.location - length, length: length), String(word.dropFirst()))
                }
            }
            mentionRange = found?.0
            if parent.mention != found?.1 {
                let query = found?.1
                Task { @MainActor in self.parent.mention = query }
            }
        }

        /// Replaces the `@word` with `@alias ` and leaves the cursor after it.
        func insert(_ alias: String, in textView: NSTextView) {
            guard let range = mentionRange else { return }
            textView.insertText("@\(alias) ", replacementRange: range)
        }

        func measure(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let line = layoutManager.defaultLineHeight(for: ComposerTextView.font)
            let content = max(line, layoutManager.usedRect(for: container).height)
            let height = min(content, line * ComposerTextView.maxLines) + ComposerTextView.padding * 2
            // Measuring can happen during a view update; change state after it.
            Task { @MainActor in
                if abs(self.parent.height - height) > 0.5 {
                    self.parent.height = height
                }
            }
        }
    }
}
#endif
