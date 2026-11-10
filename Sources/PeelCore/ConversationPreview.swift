import Foundation

extension Conversation {
    /// The chat's last message as one line for a list row: its text without
    /// markup, or for one with no words what it is ("Photo", "Voice message",
    /// "Video", "File", "GIF", "Payment", "Call"); "You: " first for your own, and in a tribe the sender's nickname ("Paul: ") for others'.
    /// Nil for a chat with nothing yet. The row truncates it to one line.
    public var previewLine: String? {
        guard let lastType else { return nil }
        let line = Self.previewLine(
            type: lastType, content: lastContent, mediaType: lastMediaType, deleted: lastDeleted ?? false)
        guard !line.isEmpty else { return nil }
        if lastFromMe == true { return "You: " + line }
        // In a tribe, who said it; a contact's row is theirs alone.
        if isTribe, let name = lastSenderAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "\(name): " + line
        }
        return line
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

extension Conversation {
    /// When the chat's last message was sent, for the end of its preview line:
    /// the time ("3:09 PM") if it was today, else the short date ("Nov 8"),
    /// in the locale's own style. Nil with no last message or no preview line.
    public func dateLabel(now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let date = lastDate, previewLine != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }
}
