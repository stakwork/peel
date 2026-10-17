#if os(macOS)
import AppKit
import PeelCore

/// The field's text view: Paste (enabled for an image alone on the clipboard)
/// with files or an image on the clipboard
/// hands them to `attach` instead of pasting their names, and a drag of
/// files, images or file promises over the field is taken the same way
/// (with the conversation's drop overlay, through `dropTargeted`) rather
/// than putting text in it.
final class AttachingTextView: NSTextView {
    /// A plain-text field, as the composer uses it: no rich text, no pictures in the text.
    static func plain() -> AttachingTextView {
        let textView = AttachingTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        return textView
    }

    var attach: (([PasteboardFiles.Item]) -> Void)?
    var dropTargeted: ((Bool) -> Void)?
    /// The drag over the field holds files; decided once as it enters.
    private var takesDrag = false

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
