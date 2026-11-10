import Testing
@testable import PeelCore

struct ConversationPreviewTests {
    private func line(_ type: Int, _ content: String? = nil, media: String? = nil, me: Bool = false,
                      deleted: Bool = false, tribe: Bool = false, from: String? = nil) -> String? {
        Conversation(chat: "c", alias: "c", isTribe: tribe, lastContent: content, lastTimestamp: 1,
                     lastFromMe: me, lastType: type, lastMediaType: media, lastDeleted: deleted, lastSenderAlias: from).previewLine
    }

    @Test func textAndOwnPrefix() {
        #expect(line(MessageType.text, "hello **you**") == "hello you")
        #expect(line(MessageType.text, "hi", me: true) == "You: hi")
    }

    @Test func wordlessMessagesSayWhatTheyAre() {
        #expect(line(MessageType.attachment, nil, media: "image/png") == "Photo")
        #expect(line(MessageType.attachment, nil, media: "video/mp4") == "Video")
        #expect(line(MessageType.attachment, nil, media: "audio/wav") == "Voice message")
        #expect(line(MessageType.attachment, nil, media: "application/zip") == "File")
        #expect(line(MessageType.directPayment) == "Payment")
        #expect(line(MessageType.call) == "Call")
        #expect(line(MessageType.text, deleted: true) == "Message deleted")
    }

    @Test func tribeNamesTheSender() {
        #expect(line(MessageType.text, "this is a test", tribe: true, from: "Paul") == "Paul: this is a test")
        #expect(line(MessageType.attachment, nil, media: "image/png", tribe: true, from: "Paul") == "Paul: Photo")
        #expect(line(MessageType.text, "hi", me: true, tribe: true, from: "Paul") == "You: hi")
        #expect(line(MessageType.text, "hi", tribe: true, from: nil) == "hi")
        #expect(line(MessageType.text, "hi", tribe: true, from: "  ") == "hi")
        #expect(line(MessageType.text, "hi", tribe: false, from: "Paul") == "hi")
    }

    @Test func noMessageNoLine() {
        #expect(Conversation(chat: "c", alias: nil, isTribe: true).previewLine == nil)
    }

    private func label(_ ms: Int64?, type: Int? = MessageType.text, now: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return Conversation(chat: "c", alias: "c", isTribe: false, lastContent: "hi", lastTimestamp: ms,
                            lastType: type)
            .dateLabel(now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
    }

    @Test func dateLabelIsTimeToday() {
        let sent: Int64 = 1_699_456_140_000 // 2023-11-08 15:09 UTC
        let now = Date(timeIntervalSince1970: 1_699_470_000) // same day, 19:00 UTC
        let text = label(sent, now: now)
        #expect(text?.contains("3:09") == true)
        #expect(text?.contains("PM") == true)
    }

    @Test func dateLabelIsDateOtherDays() {
        let sent: Int64 = 1_699_456_140_000
        let now = Date(timeIntervalSince1970: 1_699_456_140 + 3 * 86_400)
        #expect(label(sent, now: now) == "Nov 8")
    }

    @Test func dateLabelNilWithoutMessage() {
        #expect(label(nil, now: .now) == nil)
        #expect(label(1_699_456_140_000, type: nil, now: .now) == nil)
    }
}
