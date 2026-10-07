#if os(macOS)
import AppKit
import SwiftUI

/// The message field: Return sends, Shift-Return or Option-Return starts a new
/// line, paste brings in plain text only, and the field grows to eight lines
/// before it scrolls. A text view rather than a `TextField`, because a field
/// cannot tell Return from Shift-Return.
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    /// Bump to put the cursor in the field.
    let focusRequest: Int
    let submit: () -> Void

    @State private var height: CGFloat = ComposerTextView.lineHeight

    var body: some View {
        ComposerTextView(text: $text, height: $height, focusRequest: focusRequest, submit: submit)
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

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusRequest: Int
    let submit: () -> Void

    static let font = NSFont(name: "Roboto-Regular", size: 14) ?? .systemFont(ofSize: 14)
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

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            measure(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.submit()
            }
            return true
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
