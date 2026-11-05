import Testing
@testable import PeelCore

struct ConversationPreviewTests {
    private func line(_ type: Int, _ content: String? = nil, media: String? = nil, me: Bool = false,
                      deleted: Bool = false) -> String? {
        Conversation(chat: "c", alias: "c", isTribe: false, lastContent: content, lastTimestamp: 1,
                     lastFromMe: me, lastType: type, lastMediaType: media, lastDeleted: deleted).previewLine
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

    @Test func noMessageNoLine() {
        #expect(Conversation(chat: "c", alias: nil, isTribe: true).previewLine == nil)
    }
}
