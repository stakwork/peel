import AppKit
import ApplicationServices
import os
import PeelUI

/// What the user did to the text Peel just typed (docs/dictation.md,
/// "Learning"): the field is read right after the insertion (another app's
/// through Accessibility, Peel's own text view directly) and every `every`
/// while it keeps the focus, for up to
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

    /// Code editors on Electron: asked, they offer their screen-reader mode.
    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]
    /// How often an app that does not answer is asked.
    private static let asks = 3
    /// What each process came to: asks left, 0 once it showed its text or
    /// is not Chromium's.
    private static var asked: [pid_t: Int] = [:]

    /// Why a watch ends, never what was typed: so "it didn't learn" can be told apart.
    private static let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    /// Chromium, and Electron apps built on it (Claude, Slack, Notion),
    /// build their Accessibility tree only for a screen reader: until asked,
    /// a field shows no text and its edit cannot be watched. Electron is
    /// asked with `AXManualAccessibility`, Chromium's browsers, which may not
    /// know it, with `AXEnhancedUserInterface`. At key-down, so the tree is
    /// built by the time the field is read; once per process, up to `asks`
    /// times while it does not answer. Other apps, and code editors (VS Code,
    /// Cursor, Windsurf), are never touched.
    static func exposeText(pid: pid_t) {
        let left = asked[pid, default: asks]
        guard left > 0, pid != getpid(), let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard !editors.contains(app.bundleIdentifier ?? ""),
              let frameworks = app.bundleURL?.appending(path: "Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path),
              names.contains(where: { $0.hasSuffix(" Framework.framework") }) else { asked[pid] = 0; return }
        // The quarter-second timeout set on `DictationFocus.system` holds here too.
        let element = AXUIElementCreateApplication(pid)
        let manual = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = manual == .success ? nil
            : AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        // Chrome answers "not implemented" to the second, and shows its text all the same.
        let answered = manual == .success || enhanced == .success || enhanced == .notImplemented
        asked[pid] = answered ? 0 : left - 1
        log.notice("asked \(app.bundleIdentifier ?? "unknown", privacy: .public) to show its text: manual \(manual.rawValue, privacy: .public), enhanced \(enhanced.map { String($0.rawValue) } ?? "not tried", privacy: .public)")
    }

    /// Watches the focused field for what becomes of `typed`; `done` gets
    /// the user's version of it, once, or nil when it is unchanged or
    /// cannot be told.
    static func watch(typed: String, done: @escaping @MainActor (String?) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: settle)
            // Cancelled while asleep: the field may hold Peel's next text by now.
            guard !Task.isCancelled else { return done(nil) }
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            guard let field = Field.focused() else {
                // In Peel, what has the focus instead (a type name, never text).
                let own = NSApp.keyWindow.map { String(describing: type(of: $0.firstResponder as Any)) } ?? "no key window"
                log.notice("edit watch in \(app, privacy: .public): no field to read (a password field, a terminal, or one that shows Accessibility no text; Peel's focus: \(own, privacy: .public))")
                return done(nil)
            }
            guard let first = field.text, let caret = field.caret,
                  var edit = DictationEdit(value: first, typed: typed, caret: caret) else {
                // Lengths only, never the text: enough to tell an offset from a missing value.
                let length = field.text.map { ($0 as NSString).length }
                log.notice("edit watch in \(app, privacy: .public): the typed text is not before the caret (field \(length ?? -1, privacy: .public), caret \(field.caret ?? -1, privacy: .public), typed \((typed as NSString).length, privacy: .public))")
                return done(nil)
            }
            let clock = ContinuousClock()
            let start = clock.now
            var why = "the time cap"
            while clock.now - start < watchFor {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { why = "the next dictation"; break }
                guard field.hasFocus, let reading = field.text else { why = "the focus left"; break }
                if edit.read(reading, at: clock.now - start) == .done { why = "done"; break }
            }
            log.notice("edit watch in \(app, privacy: .public) ended (\(why, privacy: .public)): \(edit.edited == nil ? "unchanged" : "edited", privacy: .public)")
            done(edit.edited)
        }
    }

    /// The field being watched: another app's, through Accessibility, or
    /// Peel's own text view, read directly (asking Accessibility about Peel
    /// from its main thread would wait on itself).
    @MainActor private enum Field {
        case other(AXUIElement)
        case own(ObjectIdentifier)

        /// The focused field, never a password field or a terminal's.
        static func focused() -> Field? {
            let focus = DictationFocus.current(full: false)
            guard !focus.facts.isSecure, !terminals.contains(focus.facts.bundleID ?? "") else { return nil }
            if focus.facts.pid == getpid() {
                guard let view = ownTextView() else { return nil }
                return .own(ObjectIdentifier(view))
            }
            return focus.element.map(Field.other)
        }

        /// Peel's focused text view, but a secure field's.
        private static func ownTextView() -> NSTextView? {
            guard let view = NSApp.keyWindow?.firstResponder as? NSTextView,
                  !(view.delegate is NSSecureTextField) else { return nil }
            return view
        }

        /// Peel's own view, while it still has the focus.
        private var view: NSTextView? {
            guard case .own(let id) = self, let view = Self.ownTextView(), ObjectIdentifier(view) == id else { return nil }
            return view
        }

        var hasFocus: Bool {
            switch self {
            case .other(let element): DictationFocus.focusedElement().map { CFEqual($0, element) } ?? false
            case .own: view != nil
            }
        }

        /// Its text; nil past `maxLength`, told by its length before the text is copied across.
        var text: String? {
            switch self {
            case .other(let element):
                if let length = DictationFocus.value(element, kAXNumberOfCharactersAttribute) as? Int, length > maxLength { return nil }
                guard let text = DictationFocus.value(element, kAXValueAttribute) as? String, text.utf16.count <= maxLength else { return nil }
                return text
            case .own:
                guard let view, (view.string as NSString).length <= maxLength else { return nil }
                return view.string
            }
        }

        /// Where the caret is, in UTF-16 units.
        var caret: Int? {
            switch self {
            case .other(let element): DictationFocus.selectedRange(of: element).map { $0.location + $0.length }
            case .own: view.map { NSMaxRange($0.selectedRange()) }
            }
        }
    }
}
