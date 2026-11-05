import Foundation

extension Conversation {
    /// The chat's last message as one line for a list row: its text without
    /// markup, or for one with no words what it is ("Photo", "Voice message",
    /// "Video", "File", "GIF", "Payment", "Call"); "You: " first for your own.
    /// Nil for a chat with nothing yet. The row truncates it to one line.
    public var previewLine: String? {
        guard let lastType else { return nil }
        let line = Self.previewLine(
            type: lastType, content: lastContent, mediaType: lastMediaType, deleted: lastDeleted ?? false)
        guard !line.isEmpty else { return nil }
        return lastFromMe == true ? "You: " + line : line
    }

    static func previewLine(type: Int, content: String?, mediaType: String?, deleted: Bool) -> String {
        if deleted { return "Message deleted" }
        if type == MessageType.text, let giphy = Giphy(content: content) {
            let caption = MessageMarkup.plainText(giphy.text)
            return caption.isEmpty ? "GIF" : "GIF: \(caption)"
        }
        switch type {
        case MessageType.directPayment, MessageType.boost: return "Payment"
        case MessageType.invoice: return "Payment request"
        case MessageType.call: return "Call"
        default: break
        }
        if let text = content.map(MessageMarkup.plainText), !text.isEmpty { return text }
        guard type == MessageType.attachment else { return "" }
        switch AttachmentKind(mediaType: mediaType) {
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Voice message"
        case .pdf, .text, .file: return "File"
        }
    }
}
