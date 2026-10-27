import PeelCore
import PeelUI
#if os(macOS)
import AppKit
import SwiftUI

/// The message field: Return sends, Shift-Return or Option-Return starts a new
/// line, paste brings in plain text only (files and images, pasted or
/// dropped, go to `attach` for the tray), and the field grows to eight lines before it
/// scrolls. A text view rather than a `TextField`, because a field
/// cannot tell Return from Shift-Return.
///
/// It also reports the `@word` being typed before the cursor, or with
/// `commands` a `/word` opening the message (`mention`, trigger included),
/// lets the composer take arrow keys, Tab, Return and Escape while
/// suggestions show (`suggestionKey`), and puts in a chosen one (`insertion`).
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    /// Bump to put the cursor in the field.
    let focusRequest: Int
    /// Takes the cursor when it appears, not only on a bump.
    var focusesOnAppear = true
    let submit: () -> Void
    var mention: Binding<String?> = .constant(nil)
    /// A `/` opening the message is a command (the agent's DM).
    var commands = false
    var insertion: MentionInsertion?
    var suggestionKey: (SuggestionKey) -> Bool = { _ in false }
    /// Escape with no suggestions showing, such as to stop replying; returns
    /// whether it was taken.
    var escape: () -> Bool = { false }
    /// Files or images pasted or dropped into the field.
    let attach: ([PasteboardFiles.Item]) -> Void
    /// A drag with files is over the field (true) or has left it.
    let dropTargeted: (Bool) -> Void

    @State private var height: CGFloat = ComposerTextView.lineHeight

    var body: some View {
        ComposerTextView(
            text: $text, height: $height, mention: mention, commands: commands, focusRequest: focusRequest,
            focusesOnAppear: focusesOnAppear, insertion: insertion,
            submit: submit, suggestionKey: suggestionKey, escape: escape, attach: attach,
            dropTargeted: dropTargeted
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

/// What to put in place of the word being typed, its trigger included
/// (`@ann`, `/new`). A new `id` each time.
struct MentionInsertion: Equatable {
    let id: Int
    let text: String
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var mention: String?
    let commands: Bool
    let focusRequest: Int
    let focusesOnAppear: Bool
    let insertion: MentionInsertion?
    let submit: () -> Void
    let suggestionKey: (SuggestionKey) -> Bool
    let escape: () -> Bool
    let attach: ([PasteboardFiles.Item]) -> Void
    let dropTargeted: (Bool) -> Void

    static let font = NSFont.systemFont(ofSize: 14)
    static let padding: CGFloat = 4
    static let maxLines: CGFloat = 8
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font) + padding * 2

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // As `NSTextView.scrollableTextView()` sets one up, with Peel's own class.
        let textView = AttachingTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        textView.attach = { [weak coordinator = context.coordinator] in coordinator?.parent.attach($0) }
        textView.dropTargeted = { [weak coordinator = context.coordinator] in coordinator?.parent.dropTargeted($0) }
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
            context.coordinator.insert(insertion.text, in: textView)
        }
        // Covered by a panel (`SidePanelSplit`): the keyboard leaves it, and
        // comes back once it shows again if nothing else has taken it.
        let enabled = !context.environment.coveredByPanel
        if textView.isEditable != enabled, let window = textView.window {
            textView.isEditable = enabled
            if !enabled, window.firstResponder === textView {
                context.coordinator.hadKeysWhenCovered = true
                window.makeFirstResponder(nil)
            } else if enabled, context.coordinator.hadKeysWhenCovered {
                context.coordinator.hadKeysWhenCovered = false
                DispatchQueue.main.async {
                    if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(textView) }
                }
            }
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
        /// It had the keyboard when a panel covered it.
        var hadKeysWhenCovered = false
        /// Where the `@word` or `/word` before the cursor sits, while there is one.
        private var mentionRange: NSRange?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            if !parent.focusesOnAppear { focusedRequest = parent.focusRequest }
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

        /// The word ending at the cursor, if it starts with `@` (or `/`
        /// opening the message, with `commands`); reported with its trigger.
        func findMention(_ textView: NSTextView) {
            let selection = textView.selectedRange()
            let found = MentionQuery.word(in: textView.string, cursor: selection.location,
                                          selectionLength: selection.length, commands: parent.commands)
            mentionRange = found?.range
            let word = found.map { String($0.trigger) + $0.query }
            if parent.mention != word {
                let query = word
                Task { @MainActor in self.parent.mention = query }
            }
        }

        /// Replaces the word with `text` and a space, the cursor after it.
        func insert(_ text: String, in textView: NSTextView) {
            guard let range = mentionRange else { return }
            textView.insertText("\(text) ", replacementRange: range)
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

/// The field's text view: Paste with files or an image on the clipboard
/// hands them to `attach` instead of pasting their names, and a drag of
/// files, images or file promises over the field is taken the same way
/// (with the conversation's drop overlay, through `dropTargeted`) rather
/// than putting text in it.
private final class AttachingTextView: NSTextView {
    var attach: (([PasteboardFiles.Item]) -> Void)?
    var dropTargeted: ((Bool) -> Void)?
    /// The drag over the field holds files; decided once as it enters.
    private var takesDrag = false

    /// A screenshot copied to the clipboard is image bytes with no text, and
    /// a plain-text field reads none of its types, so AppKit would grey out
    /// Edit > Paste and ⌘V would do nothing before `paste` is ever called.
    /// Paste is on whenever the clipboard holds something for the tray.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), isEditable, PasteboardFiles.hasFiles(.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        let items = PasteboardFiles.items(on: .general, promises: false)
        if items.isEmpty { super.paste(sender) } else { attach?(items) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrag = PasteboardFiles.hasFiles(sender.draggingPasteboard)
        guard takesDrag else { return super.draggingEntered(sender) }
        dropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrag ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if takesDrag { dropTargeted?(false) } else { super.draggingExited(sender) }
        takesDrag = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        takesDrag || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard takesDrag else { return super.performDragOperation(sender) }
        dropTargeted?(false)
        let items = PasteboardFiles.items(on: sender.draggingPasteboard, promises: true)
        if !items.isEmpty { attach?(items) }
        return !items.isEmpty
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if takesDrag { takesDrag = false } else { super.concludeDragOperation(sender) }
    }
}
#endif
