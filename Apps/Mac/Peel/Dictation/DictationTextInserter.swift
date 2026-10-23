import AppKit
import ApplicationServices
import PeelUI

/// What has the keyboard: the frontmost app and its focused element, as
/// Accessibility reports them. Needs Accessibility; without it nothing is
/// known about the element, and dictation pastes.
@MainActor
struct DictationFocus {
    let facts: FocusFacts
    let element: AXUIElement?

    private static let system: AXUIElement = {
        let system = AXUIElementCreateSystemWide()
        // Asked on the main thread: an app that hangs costs a quarter second
        // a question, not six. Set on the system-wide element, it holds for all.
        AXUIElementSetMessagingTimeout(system, 0.25)
        return system
    }()

    /// At key-down only what the plan needs then (which element, and whether
    /// it is a password field); when inserting, the rest too.
    static func current(full: Bool) -> DictationFocus {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        // Peel itself: asking would wait on this very thread. Its own fields
        // take the paste like any app's.
        let element = pid == getpid() ? nil : value(system, kAXFocusedUIElementAttribute).flatMap { focused in
            CFGetTypeID(focused) == AXUIElementGetTypeID() ? (focused as! AXUIElement) : nil
        }
        let facts = FocusFacts(
            pid: pid,
            bundleID: app?.bundleIdentifier,
            element: element.map { AnyHashableSendable($0) },
            role: full ? element.flatMap { value($0, kAXRoleAttribute) as? String } : nil,
            subrole: element.flatMap { value($0, kAXSubroleAttribute) as? String },
            isEditable: full && element.map {
                value($0, "AXEditable") as? Bool == true || value($0, "AXEditableAncestor") != nil
            } ?? false,
            secureInput: SecureInput.isEnabled
        )
        return DictationFocus(facts: facts, element: element)
    }

    fileprivate static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}

/// Puts dictated text where the user was typing: through Accessibility in a
/// few native apps, else by pasting with the clipboard saved and put back,
/// else on the clipboard with a word in the HUD. Never into a password field.
@MainActor
enum DictationTextInserter {
    /// What happened, for the HUD.
    enum Outcome: Equatable {
        case inserted
        /// On the clipboard instead.
        case copied(Why)
        /// A password field (false) or another app's secure entry (true).
        case blocked(secureEntry: Bool)

        enum Why: Equatable { case noField, focusMoved, noAccessibility, notPosted }
    }

    /// Marks Peel's own ⌘V, so its key tap lets it by (`DictationHotkeyTap`).
    nonisolated static let eventMarker: Int64 = 0x7065_656C

    /// Long enough for a busy app (Electron, a loaded browser tab) to read
    /// the clipboard after ⌘V; the restore is what the wait costs, not the paste.
    private static let restoreDelay: Duration = .milliseconds(750)

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func insert(_ text: String, startedIn start: FocusFacts) async -> Outcome {
        let now = DictationFocus.current(full: true)
        switch TextInsertionPlan.plan(from: start, to: now.facts) {
        case .blocked:
            return .blocked(secureEntry: start.secureInput || now.facts.secureInput)
        case .copy(let reason):
            Clipboard.copy(text)
            return .copied(reason == .focusMoved ? .focusMoved : .noField)
        case .accessibility:
            if let element = now.element, setSelectedText(text, in: element) { return .inserted }
            return await paste(text)
        case .paste:
            return await paste(text)
        }
    }

    /// Replaces the selection (or inserts at the caret), checked by the
    /// field's length: it must grow by the text less what was selected.
    /// Reading the whole value back would copy a long note across processes,
    /// and text already in it would pass for inserted.
    private static func setSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        guard let before = length(of: element), let selected = selectionLength(of: element),
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        return length(of: element) == before - selected + text.utf16.count
    }

    private static func length(of element: AXUIElement) -> Int? {
        DictationFocus.value(element, kAXNumberOfCharactersAttribute) as? Int
    }

    private static func selectionLength(of element: AXUIElement) -> Int? {
        guard let value = DictationFocus.value(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range.length : nil
    }

    /// ⌘V with the text on the clipboard, marked so clipboard managers skip
    /// it; what was there before goes back once the app has read it, unless
    /// something else was copied meanwhile or it was a concealed secret
    /// (putting that back would outlive its password manager's clear).
    private static func paste(_ text: String) async -> Outcome {
        // Without Accessibility macOS drops the ⌘V without a word, and putting
        // the clipboard back would lose the text.
        guard !Offscreen.refuses("a key press to another app"), AXIsProcessTrusted() else {
            Clipboard.copy(text)
            return .copied(.noAccessibility)
        }
        let board = NSPasteboard.general
        let saved = snapshot(board)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: transient)
        item.setString("", forType: concealed)
        board.writeObjects([item])
        let ours = board.changeCount
        guard postCommandV() else {
            // The text stays on the clipboard, plainly, so it is not lost.
            Clipboard.copy(text)
            return .copied(.notPosted)
        }
        try? await Task.sleep(for: restoreDelay)
        if board.changeCount == ours {
            board.clearContents()
            let secret = saved.contains { $0.types.contains(concealed) || $0.types.contains(transient) }
            if !saved.isEmpty, !secret { board.writeObjects(saved) }
        }
        return .inserted
    }

    /// Every item and type on the clipboard, copied out, since the items
    /// themselves go when it is cleared.
    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let key = CGKeyCode(KeyCode.v)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            // Only Command, whatever else is held, so it is ⌘V and not ⌥⌘V.
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
