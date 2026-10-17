#if os(macOS)
import AppKit
import Testing
@testable import PeelMac

/// The composer field's Paste as the Edit menu and Cmd-V reach it: AppKit
/// enables the menu item only when the text view can read what is on the
/// general pasteboard, and only then sends `paste(_:)`. These write the
/// general pasteboard, so they run one at a time and put back what was there.
@MainActor
@Suite(.serialized)
struct ComposerPasteTests {
    /// A screenshot to the clipboard (Cmd-Ctrl-Shift-4) carries PNG and TIFF and nothing else.
    @Test func screenshotOnTheClipboardPastesIntoTheTray() throws {
        note("start screenshotOnTheClipboardPastesIntoTheTray")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let tiff = try #require(bitmap.tiffRepresentation)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        let (textView, attached, pasteEnabled) = try paste([item])
        #expect(pasteEnabled, "Edit > Paste (Cmd-V) is disabled with a screenshot on the clipboard")
        let items = attached()
        #expect(items.count == 1)
        if case .image(let data, let type) = items.first {
            #expect(type == .png)
            #expect(data == png)
        } else {
            Issue.record("the screenshot did not reach the tray: \(items)")
        }
        #expect(textView.string.isEmpty)
        note("end screenshotOnTheClipboardPastesIntoTheTray")
    }

    /// Words still paste as words.
    @Test func textOnTheClipboardPastesAsText() throws {
        note("start textOnTheClipboardPastesAsText")
        let item = NSPasteboardItem()
        item.setString("see you at 3", forType: .string)
        let (textView, attached, pasteEnabled) = try paste([item])
        #expect(pasteEnabled)
        #expect(attached().isEmpty)
        #expect(textView.string == "see you at 3")
        note("end textOnTheClipboardPastesAsText")
    }

    /// TEMPORARY: CI diagnostics, shown as GitHub annotations.
    private func note(_ line: String) {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
        let flat = line.replacingOccurrences(of: "\n", with: " | ")
        print("::notice title=ComposerPasteTests::\(flat)")
    }

    /// Puts `items` on the general pasteboard, validates an Edit > Paste item
    /// aimed at the composer field as the menu does, and sends it when enabled.
    private func paste(
        _ items: [NSPasteboardItem]
    ) throws -> (AttachingTextView, () -> [PasteboardFiles.Item], Bool) {
        let general = NSPasteboard.general
        let saved = (general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            general.clearContents()
            general.writeObjects(saved)
        }
        general.clearContents()
        let wrote = general.writeObjects(items)
        note("wrote=\(wrote) general.types=\(general.types?.map(\.rawValue) ?? [])")
        try #require(wrote)

        let textView = AttachingTextView.plain()
        let box = Box()
        textView.attach = { box.items += $0 }
        // A menu validates its items only in an app, as Peel's Edit menu does.
        _ = NSApplication.shared
        let menu = NSMenu()
        let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.target = textView
        // TEMPORARY: the same Paste aimed at a stock plain-text view, as the composer was before the fix.
        let stock = NSTextView(usingTextLayoutManager: false)
        stock.isRichText = false
        stock.importsGraphics = false
        let stockItem = menu.addItem(withTitle: "Paste (stock)", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        stockItem.target = stock
        menu.update()
        note("readable=\(textView.readablePasteboardTypes.map(\.rawValue)) enabled=\(pasteItem.isEnabled) validate=\(textView.validateUserInterfaceItem(pasteItem)) app=\(NSApp != nil) stockEnabled=\(stockItem.isEnabled)")
        if pasteItem.isEnabled {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: textView, from: pasteItem)
        }
        note("attached=\(box.items.count) string=\(textView.string.debugDescription)")
        return (textView, { box.items }, pasteItem.isEnabled)
    }

    private final class Box { var items: [PasteboardFiles.Item] = [] }
}
#endif
