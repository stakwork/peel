import Testing
@testable import PeelCore
@testable import PeelUI

/// The labels a file card shows, shared by the Mac and the phone.
struct AttachmentFormatTests {
    @Test func badgeComesFromTheNameThenTheDeclaredType() {
        #expect(AttachmentFormat.badge("report.pdf") == "PDF")
        #expect(AttachmentFormat.badge("archive.torrent") == "TORR")
        #expect(AttachmentFormat.badge(nil, mediaType: "application/pdf") == "PDF")
        #expect(AttachmentFormat.badge(nil) == "FILE")
    }

    @Test func sizeIsNilWithoutBytes() {
        #expect(AttachmentFormat.size(nil) == nil)
        #expect(AttachmentFormat.kind(nil) == nil)
    }
}
