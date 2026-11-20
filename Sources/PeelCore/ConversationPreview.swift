import Foundation

extension Conversation {
    /// The chat's last message as one line for a list row: its text without
    /// markup, or for one with no words what it is ("Photo", "Voice message",
    /// "Video", "File", "GIF", "Payment", "Call"); "You: " first for your own, and in a tribe the sender's nickname ("Paul: ") for others'.
    /// A boost names itself and its booster ("You boosted a message: 5 sats",
    /// "Paul boosted your message: 5 sats", "Paul boosted a message: 5 sats"), with no prefix.
    /// Nil for a chat with nothing yet. The row truncates it to one line.
    public var previewLine: String? {
        guard let lastType else { return nil }
        if lastType == MessageType.boost {
            if lastDeleted == true { return String(localized: "Message deleted", table: "Shared") }  // no prefix, like the other boost lines
            return Self.boostLine(fromMe: lastFromMe == true, onMine: lastBoostOnMine == true, by: boosterName, msat: lastMsat)
        }
        let line = Self.previewLine(
            type: lastType, content: lastContent, mediaType: lastMediaType, deleted: lastDeleted ?? false)
        guard !line.isEmpty else { return nil }
        if lastFromMe == true { return String(localized: "You: \(line)", table: "Shared") }
        // In a tribe, who said it; a contact's row is theirs alone.
        if isTribe, let name = lastSenderAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "\(name): " + line
        }
        return line
    }

    /// Who boosted, for a row that has no sender prefix: the sender's nickname,
    /// else (in a contact chat) the contact's name, else nil.
    private var boosterName: String? {
        for name in [lastSenderAlias, isTribe ? nil : alias] {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return nil
    }

    static func boostLine(fromMe: Bool, onMine: Bool, by name: String?, msat: Int64?) -> String {
        let amount = msat.map { ": " + Sats.format(msat: $0) } ?? ""
        if fromMe { return String(localized: "You boosted a message", table: "Shared") + amount }
        let who = name ?? String(localized: "Someone", table: "Shared")
        let line = onMine
            ? String(localized: "\(who) boosted your message", table: "Shared")
            : String(localized: "\(who) boosted a message", table: "Shared")
        return line + amount
    }

    static func previewLine(type: Int, content: String?, mediaType: String?, deleted: Bool) -> String {
        if deleted { return String(localized: "Message deleted", table: "Shared") }
        if type == MessageType.text, let giphy = Giphy(content: content) {
            let caption = MessageMarkup.plainText(giphy.text)
            return caption.isEmpty ? "GIF" : String(localized: "GIF: \(caption)", table: "Shared")
        }
        switch type {
        case MessageType.directPayment, MessageType.boost: return String(localized: "Payment", table: "Shared")  // a boost goes through `boostLine`
        case MessageType.invoice: return String(localized: "Payment request", table: "Shared")
        case MessageType.call: return String(localized: "Call", table: "Shared")
        default: break
        }
        if let text = content.map(MessageMarkup.plainText), !text.isEmpty { return text }
        guard type == MessageType.attachment else { return "" }
        switch AttachmentKind(mediaType: mediaType) {
        case .image: return String(localized: "Photo", table: "Shared")
        case .video: return String(localized: "Video", table: "Shared")
        case .audio: return String(localized: "Voice message", table: "Shared")
        case .pdf, .text, .file: return String(localized: "File", table: "Shared")
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
