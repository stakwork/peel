import SwiftUI
import PeelCore
import PeelUI

enum Clipboard {
    /// Returns whether it copied, like `copyImage`, for `CopyButton` and `MenuEntry.copy`.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        return true
        #endif
    }

    #if os(macOS)
    /// The pasteboard's change count right after a secret was copied, while
    /// it may still be there.
    @MainActor private static var secretChangeCount: Int?
    #endif

    /// Copies a secret: kept on this Mac (no Universal Clipboard), marked
    /// concealed so clipboard managers skip it, and cleared after
    /// `clearAfter`, on quit, or when the account is forgotten, unless
    /// something else has been copied since.
    @MainActor static func copySecret(_ text: String, clearAfter: Duration) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let copied = board.changeCount
        secretChangeCount = copied
        Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            // Words copied again since then wait for their own clear.
            if secretChangeCount == copied { clearSecret() }
        }
        #else
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": text]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(Double(clearAfter.components.seconds))]
        )
        #endif
    }

    /// Clears a secret copied with `copySecret` if it is still on the clipboard.
    @MainActor static func clearSecret() {
        #if os(macOS)
        guard let copied = secretChangeCount else { return }
        secretChangeCount = nil
        if NSPasteboard.general.changeCount == copied { NSPasteboard.general.clearContents() }
        #endif
    }

    /// Clears twelve words pasted into the restore form, if the clipboard
    /// still holds those words. A paste cannot be marked concealed after the
    /// fact, so it is cleared once read (audit F9). Fewer words (typing with
    /// spaces) leave the clipboard unread.
    @MainActor static func clearPasted(words: [String]) {
        guard words.count >= 12, let text = paste(), Engine.words(in: text) == words else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        #else
        UIPasteboard.general.items = []
        #endif
    }

    /// Puts the picture in a file on the clipboard; false when it cannot be read.
    static func copyImage(at file: URL) -> Bool {
        #if os(macOS)
        guard let image = NSImage(contentsOf: file) else { return false }
        return copy(image)
        #else
        guard let image = UIImage(contentsOfFile: file.path) else { return false }
        UIPasteboard.general.image = image
        return true
        #endif
    }

    #if os(macOS)
    static func copy(_ image: NSImage) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }
    #endif

    static func paste() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}

/// `Clipboard`, for the model, on the Mac and the iPhone alike. A secret
/// copied on the phone expires on its own (`Clipboard.copySecret`).
struct ClipboardPasteboard: PeelUI.Pasteboard {
    func copyImage(at file: URL) -> Bool { Clipboard.copyImage(at: file) }
    func clearSecret() { Clipboard.clearSecret() }
}
