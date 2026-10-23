import AppKit
import ApplicationServices
import PeelUI

/// What the user did to the text Peel just typed (docs/dictation.md,
/// "Learning"): the field is read through Accessibility right after the
/// insertion and every `every` while it keeps the focus, for up to
/// `watchFor`, and `DictationEdit` says when the edit is done: left alone
/// for 2 s, the field emptied by Return, or words written on after it. The
/// focus leaving, the next dictation or insertion (which cancel the watch)
/// or the time cap end it too. Once, either way: strut runs a model on it.
/// Nothing when the field shows Accessibility no value (many Electron
/// fields), is a password field, or is a terminal's (its value is the scrollback).
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
    /// Terminal, iTerm2, Warp, kitty, Ghostty, Alacritty and WezTerm.
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "org.alacritty", "com.github.wez.wezterm",
    ]

    /// Watches the focused field for what becomes of `typed`; `done` gets
    /// the user's version of it, once, or nil when it is unchanged or
    /// cannot be told.
    static func watch(typed: String, done: @escaping @MainActor (String?) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: settle)
            // Cancelled while asleep: the field may hold Peel's next text by now.
            guard !Task.isCancelled else { return done(nil) }
            // Its subrole once, here; after that only whether it still has the focus.
            let focus = DictationFocus.current(full: false)
            guard !focus.facts.isSecure, !terminals.contains(focus.facts.bundleID ?? ""),
                  let element = focus.element, let first = value(of: element),
                  let range = DictationFocus.selectedRange(of: element),
                  var edit = DictationEdit(value: first, typed: typed, caret: range.location + range.length)
            else { return done(nil) }
            let clock = ContinuousClock()
            let start = clock.now
            while clock.now - start < watchFor {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { break }
                // The focus left the field.
                guard let now = DictationFocus.focusedElement(), CFEqual(now, element),
                      let reading = value(of: element) else { break }
                if edit.read(reading, at: clock.now - start) == .done { break }
            }
            done(edit.edited)
        }
    }

    /// The field's text; nil past `maxLength`, told by its length before
    /// the text is copied across.
    private static func value(of element: AXUIElement) -> String? {
        if let length = DictationFocus.value(element, kAXNumberOfCharactersAttribute) as? Int, length > maxLength { return nil }
        guard let text = DictationFocus.value(element, kAXValueAttribute) as? String, text.utf16.count <= maxLength else { return nil }
        return text
    }
}
