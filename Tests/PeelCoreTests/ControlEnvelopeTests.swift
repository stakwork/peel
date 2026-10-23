import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// A text message from someone else with `body`, as stored.
private func received(_ body: String, type: Int = MessageType.text) -> Message {
    Message.fixture(type: type, body: body, content: BodyFields.decode(body)?.content)
}

/// A body whose metadata is `metadata`, written into it as a string the way
/// the official apps and the bridge write it.
private func body(metadata: String, content: String = "Peel asked your Mac to read your unread messages") -> String {
    let fields = ["content": content, "metadata": metadata]
    return String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
}

/// The device channel's envelope (docs/agent-on-strut.md, "The envelope"):
/// what Peel writes reads back whole, and anyone else's metadata is read
/// without ever being taken for more than it is.
struct ControlEnvelopeTests {
    @Test(arguments: [
        ControlEnvelope(op: .request, id: "r_1", device: "mac-3f2a", kind: "chats.unseen",
                        args: .object(["since": .string("2026-10-16T08:00:00Z")]), notAfter: 1_760_610_000),
        ControlEnvelope(op: .ack, re: "r_1"),
        ControlEnvelope(op: .result, re: "r_1", status: .done, result: .array([.string("[begin chat data]"), .int(3)])),
        ControlEnvelope(op: .result, re: "r_1", status: .failed, error: "unsupported"),
        ControlEnvelope(op: .cancel, re: "r_1"),
        ControlEnvelope(op: .cancel, run: "run_9"),
        // Stop with no run named: the turn in flight.
        ControlEnvelope(op: .cancel),
        ControlEnvelope(op: .status, run: "run_9", state: "waiting", text: "Waiting for your Mac"),
    ])
    func readsBackWhatItWrites(envelope: ControlEnvelope) throws {
        let written = try envelope.adding(to: #"{"content":"Peel asked your Mac"}"#)
        #expect(received(written).control == .envelope(envelope))
        #expect(BodyFields.decode(written)?.content == "Peel asked your Mac")
    }

    /// The wire names are the spec's, `not_after` included, so the bridge reads them.
    @Test func writesTheSpecsFieldNames() throws {
        let written = try ControlEnvelope(op: .request, id: "r_1", device: "d", kind: "chats.list", notAfter: 5)
            .adding(to: #"{"content":"x"}"#)
        let metadata = try #require(MessageMetadata.string(in: written))
        let peel = try #require(JSONValue(text: metadata))
        #expect(peel == .object(["peel": .object([
            "v": .int(1), "op": .string("request"), "id": .string("r_1"), "device": .string("d"),
            "kind": .string("chats.list"), "not_after": .int(5),
        ])]))
    }

    /// The time zone switch and the envelope share the metadata: setting or
    /// clearing one never drops the other.
    @Test func keepsTheTimeZoneBesideTheEnvelope() throws {
        let envelope = ControlEnvelope(op: .ack, re: "r_1")
        let zoned = try TimeZoneOffset.setting("GMT+1", in: #"{"content":"hi"}"#)
        let both = try envelope.adding(to: zoned)
        #expect(received(both).control == .envelope(envelope))
        #expect(MessageMetadata.string(in: both).flatMap(JSONValue.init(text:)) == .object([
            "tz": .string("GMT+1"), "peel": .object(["v": .int(1), "op": .string("ack"), "re": .string("r_1")]),
        ]))
        // A resend sets the offset again, or clears it when the switch is off.
        let resent = try TimeZoneOffset.setting("GMT-5", in: both)
        #expect(received(resent).control == .envelope(envelope))
        #expect(MessageMetadata.string(in: resent)?.contains(#""tz":"GMT-5""#) == true)
        let cleared = try TimeZoneOffset.setting(nil, in: both)
        #expect(received(cleared).control == .envelope(envelope))
        #expect(MessageMetadata.string(in: cleared)?.contains("tz") == false)
    }

    /// Control messages Peel cannot read stay control messages (a line,
    /// never a bubble), and nothing about them is acted on.
    @Test(arguments: [
        #"{"peel":{"v":2,"op":"request","id":"r","device":"d","kind":"chats.list","not_after":1}}"#,
        #"{"peel":{"v":"1","op":"ack","re":"r"}}"#,
        #"{"peel":{"op":"ack","re":"r"}}"#,
        #"{"peel":{"v":1,"op":"launch","re":"r"}}"#,
        #"{"peel":{"v":1,"op":7}}"#,
        #"{"peel":{"v":1,"op":"ack"}}"#,
        #"{"peel":{"v":1,"op":"request","id":"r","device":"d","kind":"chats.list"}}"#,
        #"{"peel":{"v":1,"op":"request","id":"r","device":"d","kind":"chats.list","not_after":"soon"}}"#,
        #"{"peel":{"v":1,"op":"result","re":"r"}}"#,
        #"{"peel":{"v":1,"op":"result","re":"r","status":"maybe"}}"#,
        #"{"peel":{"v":1,"op":"status","run":"x","text":"Waiting"}}"#,
        #"{"peel":{"v":1,"op":"ack","re":["r"]}}"#,
    ])
    func unreadableEnvelopesAreUnsupported(metadata: String) {
        #expect(received(body(metadata: metadata)).control == .unsupported)
    }

    /// Anything that is not a control message reads as none: no `peel`, a
    /// talk message's extras (no `op`), or metadata that is not an object
    /// Peel can read.
    @Test(arguments: [
        #"{"tz":"GMT+1"}"#,
        #"{"peel":{"tools":[{"name":"search_messages"}]}}"#,
        #"{"peel":{"automation":"Weekly recap"}}"#,
        #"{"peel":"request"}"#,
        #"{"peel":null}"#,
        #"{"peel":[{"op":"ack"}]}"#,
        #"["peel"]"#,
        #"{"peel":{"op":"ack""#,
        #""peel""#,
        "",
    ])
    func otherMetadataIsNotControl(metadata: String) {
        #expect(received(body(metadata: metadata)).control == nil)
    }

    @Test(arguments: [
        // The key in the content, not the metadata.
        #"{"content":"\"peel\" {\"op\":\"ack\"}"}"#,
        // Metadata that is not a string.
        #"{"content":"x","metadata":{"peel":{"v":1,"op":"ack","re":"r"}}}"#,
        #"{"content":"x","metadata":5,"peel":{"v":1,"op":"ack","re":"r"}}"#,
        // Not JSON at all.
        #"{"content":"x","metadata":"{\"peel\":{\"v\":1"#,
    ])
    func malformedBodiesAreNotControl(body: String) {
        #expect(received(body).control == nil)
    }

    /// The key spelled with escapes is the same key to any JSON reader, so
    /// it is the same control message here.
    @Test func escapedKeysAreReadAsAnyReaderReadsThem() {
        let ack = ControlEnvelope(op: .ack, re: "r")
        #expect(received(body(metadata: #"{"\u0070eel":{"v":1,"op":"ack","re":"r"}}"#)).control == .envelope(ack))
        #expect(received(#"{"content":"x","metadata":"{\"\u0070eel\":{\"v\":1,\"op\":\"ack\",\"re\":\"r\"}}"}"#).control == .envelope(ack))
    }

    /// Only text carries an envelope: a payment's or an attachment's
    /// metadata never hides it, and a deleted message is only deleted.
    @Test func onlyTextIsControl() {
        let control = body(metadata: #"{"peel":{"v":1,"op":"ack","re":"r"}}"#)
        for type in [MessageType.directPayment, MessageType.attachment, MessageType.invoice, MessageType.call] {
            #expect(received(control, type: type).control == nil)
        }
        var deleted = received(control)
        deleted.deleted = true
        #expect(deleted.control == nil)
    }

    /// Hostile metadata costs a bounded read and never a crash: too long to
    /// read (valid JSON padded past the limit), or nested deeper than the
    /// decoder goes.
    @Test func hostileMetadataIsBounded() {
        let padding = String(repeating: " ", count: MessageMetadata.maxLength)
        #expect(received(body(metadata: #"{"peel":{"v":1,"op":"ack","re":"r"}}"# + padding)).control == nil)
        let deep = String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000)
        #expect(received(body(metadata: #"{"peel":{"v":1,"op":"ack","re":"r","args":"# + deep + "}}")).control == nil)
    }
}

/// The device side's own rules (`Engine+DeviceRequests`) that the journey
/// does not reach: the bridge's id and kind rules, the size cap, and the
/// request this Peel cannot read.
struct DeviceRequestRuleTests {
    /// The cases of the bridge's own test (runner `device.rs`, `ids`): a
    /// request the bridge would refuse to send is not the agent's.
    @Test func idsAndKindsAsTheBridgeChecksThem() {
        #expect(Engine.isRequestID("1792159542479/turn/003-peel_device"))
        #expect(!Engine.isRequestID("") && !Engine.isRequestID("a b") && !Engine.isRequestID(String(repeating: "x", count: 129)))
        #expect(!Engine.isRequestID("r\u{e9}"))
        #expect(Engine.isKind("chats.unseen") && Engine.isKind("calendar.create"))
        #expect(!Engine.isKind("") && !Engine.isKind("do this") && !Engine.isKind(String(repeating: "k", count: 65)))
    }

    /// A result too large to send is a failure that says so, never a cut
    /// one: the chat data's end marker must arrive.
    @Test func aResultTooLargeIsRefusedWhole() {
        let fits = DeviceAnswer.done(String(repeating: "a", count: 20_000))
        #expect(Engine.fitted(fits, re: "r") == fits)
        let large = Engine.fitted(.done(String(repeating: "\u{1F600}", count: 9_000)), re: "r")
        #expect(large.status == .failed && large.text == nil)
        #expect(large.error?.hasPrefix("the result is too large to send") == true)
    }

    /// An envelope of a later version is answered `unsupported` by id, but
    /// only when it names this device.
    @Test func anUnreadableRequestIsNamedOnlyForThisDevice() {
        let later = body(metadata: #"{"peel":{"v":2,"op":"request","id":"r9","device":"mac-1","kind":"x"}}"#)
        #expect(received(later).control == .unsupported)
        #expect(Engine.unreadableRequestID(in: later, device: "mac-1") == "r9")
        #expect(Engine.unreadableRequestID(in: later, device: "mac-2") == nil)
        let ack = body(metadata: #"{"peel":{"v":2,"op":"ack","id":"r9","device":"mac-1"}}"#)
        #expect(Engine.unreadableRequestID(in: ack, device: "mac-1") == nil)
    }

    /// A reply's tool rows are the bridge's list as written, read only from
    /// talk: fields that do not fit drop the row or the field, never the reply.
    @Test func readsAReplysToolRows() {
        let reply = received(body(metadata: #"""
            {"tz":"GMT+1","peel":{"tools":[{"name":"sphinx_unseen","summary":"{}"},
            {"name":"sphinx_send","summary":"{\"chat\":\"Kate\"}","failed":true},
            {"summary":"no name"},{"name":""},{"name":"memory_recall","summary":5,"failed":"yes"},"junk"]}}
            """#, content: "You have 3 unread chats."))
        #expect(reply.agentTools == [
            AgentToolLine(name: "sphinx_unseen", summary: "{}"),
            AgentToolLine(name: "sphinx_send", summary: #"{"chat":"Kate"}"#, failed: true),
            AgentToolLine(name: "memory_recall"),
        ])
        // A control message's `tools`, or none at all, are no tool rows.
        #expect(received(body(metadata: #"{"peel":{"v":1,"op":"ack","re":"r","tools":[{"name":"x"}]}}"#)).agentTools.isEmpty)
        #expect(received(body(metadata: #"{"peel":{"automation":"Weekly recap"}}"#)).agentTools.isEmpty)
        #expect(received(body(metadata: #"{"peel":{"tools":[{"name":"x"}]}}"#), type: MessageType.attachment).agentTools.isEmpty)
    }

    /// A turn runs from your message until the agent's reply names it; a
    /// control line or a message that never went is no turn of yours.
    @Test func yourNewestMessageIsUnansweredUntilAReplyNamesIt() {
        let asked = Message.fixture(uuid: "m1", fromMe: true, content: "What did I miss?", timestamp: 1)
        let request = received(body(metadata: #"{"peel":{"v":1,"op":"request","id":"r","device":"d","kind":"chats.unseen","not_after":9}}"#))
        let ack = Message.fixture(uuid: "m2", fromMe: true,
                                  body: body(metadata: #"{"peel":{"v":1,"op":"ack","re":"r"}}"#), timestamp: 3)
        let reply = Message.fixture(uuid: "m3", content: "Three chats.", timestamp: 4, replyUUID: "m1")
        #expect(AgentDM.unanswered(in: [asked]) == asked)
        #expect(AgentDM.unanswered(in: [asked, request, ack]) == asked)
        #expect(AgentDM.unanswered(in: [asked, request, ack, reply]) == nil)
        // A late turn's reply (no reply link) or an older one answers nothing new.
        let again = Message.fixture(uuid: "m4", fromMe: true, content: "/new", timestamp: 5)
        let late = Message.fixture(uuid: "m5", content: "Your Mac answered.", timestamp: 6)
        #expect(AgentDM.unanswered(in: [asked, reply, again, late]) == again)
        // Refused by the server: not running, and the one before it is answered.
        let refused = Message.fixture(uuid: "m6", fromMe: true, content: "hello?", timestamp: 7, status: "FAILED")
        #expect(AgentDM.unanswered(in: [asked, reply, refused]) == nil)
        #expect(AgentDM.unanswered(in: []) == nil)
    }

    /// A job's message names its job and what it points to, read only from
    /// talk; a link is kept only when it is https, and nothing malformed
    /// drops the message's other extras.
    @Test func readsAJobAndWhatItPointsTo() {
        let reply = received(body(metadata: #"""
            {"peel":{"job":{"id":"j_7","title":"Lisbon flights","state":"asking"},
            "artifacts":[{"id":"plan","title":"Plan","label":"Plan","url":"https://example.com/plan"},
            {"id":"page","title":"Page","url":"file:///etc/passwd"},{"title":""},"junk",{"id":"x","title":"Shot","url":"javascript:alert(1)"},
            {"title":"Plain","url":"http://example.com"},{"title":"Spoof","url":"https://bank.com@evil.example/x"}],
            "tools":[{"name":"web_search"}]}}
            """#, content: "Which dates?"))
        #expect(reply.agentJob == AgentJob(id: "j_7", title: "Lisbon flights", state: .asking))
        #expect(reply.agentArtifacts.map(\.title) == ["Plan", "Page", "Shot", "Plain", "Spoof"])
        #expect(reply.agentArtifacts.map(\.url) == [URL(string: "https://example.com/plan"), nil, nil, nil, nil])
        #expect(reply.agentTools.map(\.name) == ["web_search"])
        // A state it does not know is no state; a job with no id is none.
        #expect(received(body(metadata: #"{"peel":{"job":{"id":"j_8","state":"exploded"}}}"#)).agentJob == AgentJob(id: "j_8"))
        #expect(received(body(metadata: #"{"peel":{"job":{"title":"x"}}}"#)).agentJob == nil)
        // A control message's job is no job.
        #expect(received(body(metadata: #"{"peel":{"v":1,"op":"ack","re":"r","job":{"id":"j"}}}"#)).agentJob == nil)
    }
}
