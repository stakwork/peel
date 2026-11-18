import Foundation
import Testing
@testable import PeelCore

/// What an attachment to the agent's DM says about its picture
/// (`MessageMetadata.vision`, docs/agent-on-strut.md, "Attachments").
struct AttachmentMetadataTests {
    private func body(metadata: String?) throws -> String {
        try Engine.attachmentBody(
            text: "what is this?", key: "k", mediaType: "image/png", token: nil, replyTo: nil, thread: nil, metadata: metadata
        )
    }

    @Test func noVisionKeyAtAllWhenTheModelMayNotSee() throws {
        let body = try body(metadata: nil)
        #expect(MessageMetadata.string(in: body) == nil)
        #expect(!body.contains("vision") && !body.contains("metadata"))
    }

    @Test func theFlagIsTheEnvelopeTheBridgeReads() throws {
        let body = try body(metadata: MessageMetadata.vision)
        let metadata = try #require(MessageMetadata.string(in: body))
        guard case .object(let fields)? = JSONValue(text: metadata), case .object(let peel)? = fields["peel"] else {
            Issue.record("metadata.peel is no object")
            return
        }
        #expect(fields.count == 1 && peel == ["v": .int(1), "vision": .bool(true)])
    }

    /// The time zone goes in beside it as a send does, and a send again keeps both.
    @Test func theTimeZoneIsMergedNotInstead() throws {
        let sent = try TimeZoneOffset.setting("GMT+1", in: try body(metadata: MessageMetadata.vision))
        let metadata = try #require(MessageMetadata.string(in: sent))
        guard case .object(let fields)? = JSONValue(text: metadata) else { Issue.record("no metadata"); return }
        #expect(fields["tz"] == .string("GMT+1") && fields["peel"] != nil)
        let withoutZone = try TimeZoneOffset.setting(nil, in: sent)
        guard case .object(let kept)? = JSONValue(text: try #require(MessageMetadata.string(in: withoutZone))) else {
            Issue.record("the flag went with the zone")
            return
        }
        #expect(kept["tz"] == nil && kept["peel"] != nil)
    }

    @Test func metadataOverTheLimitIsNotSent() throws {
        let huge = #"{"peel":{"v":1,"pad":""# + String(repeating: "x", count: MessageMetadata.maxLength) + #""}}"#
        #expect(!(try body(metadata: huge)).contains("metadata"))
    }

    /// A resent or finished upload makes the body again: its metadata is read from the row.
    @Test func theBodyMadeAgainKeepsTheFlag() throws {
        let first = try body(metadata: MessageMetadata.vision)
        let again = try Engine.attachmentBody(
            text: "what is this?", key: "k", mediaType: "image/png", token: "tok", replyTo: nil, thread: nil,
            metadata: MessageMetadata.string(in: first)
        )
        #expect(MessageMetadata.string(in: again) == MessageMetadata.vision)
    }
}
