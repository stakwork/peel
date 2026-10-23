import AppKit
import ApplicationServices

/// What the user did to the text Peel just typed (docs/dictation-lingo.md,
/// "Capturing what the user did"): the field is read through Accessibility
/// right after the insertion and again while it keeps the focus, for up to
/// `watchFor`; once the user moves on, or an edit has been left alone for
/// `settled`, the span between the text that was
/// before and after Peel's is what became of it. Nothing when the field
/// shows Accessibility no value (many Electron fields), when the text
/// around Peel's changed too, or when the field is a password field.
@MainActor
final class DictationEditWatch {
    /// How long a field is watched after Peel typed into it.
    static let watchFor: Duration = .seconds(45)
    /// Often enough to catch a fix made just before Return sends the message.
    private static let every: Duration = .milliseconds(500)
    /// An edit left alone this long is done: learned now, not when the user
    /// leaves the field.
    private static let settled: Duration = .seconds(2)
    /// A paste lands a moment after ⌘V.
    private static let settle: Duration = .milliseconds(400)
    /// Longer fields are not read: a whole document copied each time.
    private static let maxLength = 100_000

    /// Watches the focused field for what becomes of `typed`; `done` gets
    /// the user's version of it, or nil when it cannot be told.
    /// `teaches`: whether an edit so far has something to learn; only then
    /// does a pause end the watch (a word deleted, its fix not yet typed, does not).
    static func watch(
        typed: String, teaches: @escaping @MainActor (String) async -> Bool, done: @escaping @MainActor (String?) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: settle)
            guard let element = focused(), let before = value(of: element), before.utf16.count <= maxLength,
                  let caret = caret(of: element) else { return done(nil) }
            // Peel's text ends at the caret right after the insertion.
            let text = before as NSString
            let length = (typed as NSString).length
            guard caret >= length, caret <= text.length, text.substring(with: NSRange(location: caret - length, length: length)) == typed else {
                return done(nil)
            }
            let prefix = text.substring(to: caret - length), suffix = text.substring(from: caret)
            // The last reading with the text around Peel's still in place: a
            // field emptied by sending (Return in a chat) keeps the fix made
            // just before it.
            let around = { (value: String) in
                value.hasPrefix(prefix) && value.hasSuffix(suffix)
                    && (value as NSString).length >= (prefix as NSString).length + (suffix as NSString).length
            }
            let span = { (value: String) in
                let start = (prefix as NSString).length
                let end = (value as NSString).length - (suffix as NSString).length
                return (value as NSString).substring(with: NSRange(location: start, length: end - start))
            }
            var latest = before
            let clock = ContinuousClock()
            let until = clock.now + watchFor
            var changedAt = clock.now
            while clock.now < until, !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard let now = focused(), CFEqual(now, element), let value = value(of: element) else { break }
                guard around(value) else { continue }
                if value != latest {
                    latest = value
                    changedAt = clock.now
                } else if latest != before, clock.now - changedAt >= settled, await teaches(span(latest)) {
                    // Edited, then left alone: done.
                    break
                }
            }
            done(span(latest))
        }
    }

    /// The focused element, never a password field; through `DictationFocus`'s
    /// system-wide element, whose 0.25 s timeout keeps a hung app from stalling Peel.
    private static func focused() -> AXUIElement? {
        guard let focused = DictationFocus.value(DictationFocus.system, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        if DictationFocus.value(element, kAXSubroleAttribute) as? String == "AXSecureTextField" { return nil }
        return element
    }

    private static func value(of element: AXUIElement) -> String? {
        DictationFocus.value(element, kAXValueAttribute) as? String
    }

    /// Where the caret is, in UTF-16 units.
    private static func caret(of element: AXUIElement) -> Int? {
        guard let value = DictationFocus.value(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }
}
