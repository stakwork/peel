import AppKit
import ApplicationServices
import PeelUI

/// What the user did to the text Peel just typed (docs/dictation.md,
/// "Learning"): the field is read through Accessibility right after the
/// insertion and every `every` while it keeps the focus, for up to
/// `watchFor`, and `DictationEdit` says when the edit is done: left alone
/// for 2 s, or the field emptied by Return. The focus leaving, the next
/// dictation (which cancels the watch) or the time cap end it too. Once,
/// either way: strut runs a model on it. Nothing when the field shows
/// Accessibility no value (many Electron fields) or is a password field.
@MainActor
final class DictationEditWatch {
    /// How long a field is watched after Peel typed into it.
    static let watchFor: Duration = .seconds(45)
    /// Often enough to catch a fix made just before Return sends the message.
    private static let every: Duration = .milliseconds(500)
    /// A paste lands a moment after ⌘V.
    private static let settle: Duration = .milliseconds(400)
    /// Longer fields are not read: a whole document copied each time.
    private static let maxLength = 100_000

    /// Watches the focused field for what becomes of `typed`; `done` gets
    /// the user's version of it, once, or nil when it is unchanged or
    /// cannot be told.
    static func watch(typed: String, done: @escaping @MainActor (String?) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: settle)
            guard let element = focused(), let first = value(of: element), first.utf16.count <= maxLength,
                  let caret = caret(of: element),
                  var edit = DictationEdit(value: first, typed: typed, caret: caret) else { return done(nil) }
            let clock = ContinuousClock()
            let start = clock.now
            while clock.now - start < watchFor, !Task.isCancelled {
                try? await Task.sleep(for: every)
                // The focus left the field.
                guard let now = focused(), CFEqual(now, element), let reading = value(of: element) else { break }
                if edit.read(reading, at: clock.now - start) == .done { break }
            }
            done(edit.edited)
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
