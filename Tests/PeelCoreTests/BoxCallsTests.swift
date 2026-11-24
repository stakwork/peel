import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Jamie from a box in a group call (docs/hive-calls.md, "From a box";
/// stadeum plans/group-calls.md §5, §7): strut's three voice routes as the
/// person, on a stand-in under the box's mount path, as strut#881 forwards
/// them to the box's voice service.
struct BoxCallsTests {
    private static let callServer = "chat.sphinx.chat"
    private static let identity = "box_0123456789abcdef0123456789abcdef"

    /// A stand-in strut answering `respond` under the mount path `/lab`, and the box kept for it.
    private static func box(_ respond: @escaping @Sendable (String) -> (Int, String)) async throws -> (HTTPStub, BoxLink) {
        let stub = try await HTTPStub(respond: { _, request in respond(request) })
        return (stub, BoxFixture.box("http://127.0.0.1:\(stub.port)/lab"))
    }

    /// A request's body as JSON, of any value.
    private static func body(_ request: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data((request.components(separatedBy: "\r\n\r\n").last ?? "").utf8))) as? [String: Any]
    }

    /// Asked as the person, a box is offered for a call only once its Jamie
    /// is ready and on the LiveKit server the account's call server names
    /// in its tickets (`https://` read as LiveKit reads it). A strut or
    /// voice service from before group calls offers nothing; a token the
    /// box no longer takes is `TokenRefused`.
    @Test(arguments: [
        (#"{"group":true,"livekit":"wss://livekit.sphinx.chat"}"#, callServer, true),
        (#"{"group":true,"livekit":"https://livekit.sphinx.chat"}"#, callServer, true),
        (#"{"group":true,"livekit":"wss://livekit.sphinx.chat"}"#, "calls.example.com", false),
        (#"{"group":true,"livekit":"wss://livekit.example.com"}"#, callServer, false),
        (#"{"group":true,"livekit":"ws://livekit.sphinx.chat"}"#, callServer, false),
        (#"{"group":false,"livekit":"wss://livekit.sphinx.chat"}"#, callServer, false),
        (#"{"group":true}"#, callServer, false),
    ])
    func aBoxIsOfferedOnlyWhenReadyOnTheCallServersLiveKit(answer: String, server: String, offered: Bool) async throws {
        let (stub, box) = try await Self.box { request in
            request.hasPrefix("GET /lab/voice/calls ") ? (200, answer) : (404, #"{"error":"not found"}"#)
        }
        defer { stub.stop() }
        let calls = try await BoxClient(box: box.url).groupCalls(box)
        #expect(calls.joins(callServer: server) == offered)
        #expect(try #require(stub.requests.first).contains("Authorization: Bearer \(box.token)"))
    }

    @Test func aBoxFromBeforeGroupCallsOffersNothing() async throws {
        let (stub, box) = try await Self.box { request in
            if request.contains("Bearer strut-person.gone") { return (401, #"{"error":"unauthorized"}"#) }
            return (405, #"{"error":"POST only"}"#)
        }
        defer { stub.stop() }
        #expect(try await BoxClient(box: box.url).groupCalls(box) == .noGroupCalls)
        // A box that fails another way keeps what was read before: the read throws.
        let (failing, failingBox) = try await Self.box { _ in (502, #"{"error":"bad gateway"}"#) }
        defer { failing.stop() }
        await #expect(throws: PeelError.self) { _ = try await BoxClient(box: failingBox.url).groupCalls(failingBox) }
        var gone = box
        gone.token = "strut-person.gone"
        await #expect(throws: BoxClient.TokenRefused.self) { _ = try await BoxClient(box: box.url).groupCalls(gone) }
    }

    /// Asking Jamie in posts the call's room and key, as the person, and
    /// `record` only when asked; done once the box says its Jamie is in,
    /// encrypted. A voice service from before group calls takes the body
    /// for a call of the person's own, in a room of its own: that Jamie is
    /// in no call here, so it is refused.
    @Test func askingJamieInPostsTheRoomAndTheKey() async throws {
        let older = #"{"url":"ws://127.0.0.1:7880","room":"sphinx.call.voice.ab","token":"t","identity":"m","agent":"a","encrypted":true}"#
        let (stub, box) = try await Self.box { request in
            guard request.hasPrefix("POST /lab/voice/calls ") else { return (404, #"{"error":"not found"}"#) }
            return Self.body(request)?["record"] == nil ? (200, older) : (200, #"{"agent":"jamie_ab12","encrypted":true}"#)
        }
        defer { stub.stop() }
        let link = try CallLink.new(server: Self.callServer, audioOnly: true, encrypted: true)
        try await BoxClient(box: box.url).startGroupCall(box, link: link, record: true)
        let asked = try #require(stub.requests.first)
        #expect(asked.contains("Authorization: Bearer \(box.token)"))
        let body = try #require(Self.body(asked))
        #expect(body["mode"] as? String == "group" && body["room"] as? String == link.room)
        #expect(body["key"] as? String == link.encryptionKey && body["record"] as? Bool == true)

        let error = await #expect(throws: PeelError.self) { try await BoxClient(box: box.url).startGroupCall(box, link: link, record: false) }
        #expect(Self.body(try #require(stub.requests.last))?.keys.contains("record") == false)
        #expect(error?.description.contains("needs an update") == true)
    }

    /// A call in the clear is never offered to a box: nothing is asked.
    @Test func aCallInTheClearIsNeverAskedAbout() async throws {
        let (stub, box) = try await Self.box { _ in (200, #"{"agent":"jamie_ab12","encrypted":true}"#) }
        defer { stub.stop() }
        let link = try CallLink.new(server: Self.callServer, audioOnly: true)
        await #expect(throws: PeelError.self) { try await BoxClient(box: box.url).startGroupCall(box, link: link, record: false) }
        #expect(stub.requests.isEmpty)
    }

    /// The box's refusals, in words the person can act on: Jamie already in
    /// the room, not ready or could not join, a sign-in it does not take;
    /// the rest in strut's own words.
    @Test(arguments: [
        (409, #"{"error":"Jamie is already in that call"}"#, "Jamie from 127.0.0.1 is already in this call"),
        (503, #"{"error":"group calls are not ready yet: the speech recognizer is loading"}"#,
         "Jamie from 127.0.0.1 can't join a call right now: group calls are not ready yet"),
        (403, #"{"error":"a person's token"}"#, "takes calls only from a person's sign-in"),
        (400, #"{"error":"key must be 32 bytes, as base64"}"#, "127.0.0.1 could not bring Jamie into the call: key must be 32 bytes"),
    ])
    func aRefusalIsSaidPlainly(status: Int, body: String, words: String) async throws {
        let (stub, box) = try await Self.box { _ in (status, body) }
        defer { stub.stop() }
        let link = try CallLink.new(server: Self.callServer, audioOnly: false, encrypted: true)
        let error = await #expect(throws: PeelError.self) { try await BoxClient(box: box.url).startGroupCall(box, link: link, record: false) }
        #expect(error?.description.contains(words) == true, "\(error?.description ?? "")")
    }

    /// The person's own ticket posts the room and the name they join with;
    /// a box whose Jamie is not in that room (404) has none, and an answer
    /// for another room is not taken.
    @Test func thePersonsTicketIsTheBoxsOrNone() async throws {
        let room = "sphinx.call.0123456789abcdef0123456789abcdef"
        let (stub, box) = try await Self.box { request in
            guard request.hasPrefix("POST /lab/voice/calls/ticket ") else { return (404, #"{"error":"not found"}"#) }
            let asked = HTTPStub.jsonBody(of: request)?["room"] ?? ""
            if asked == "sphinx.call.elsewhere" { return (200, #"{"url":"wss://livekit.sphinx.chat","room":"\#(room)","token":"t","identity":"\#(Self.identity)"}"#) }
            if asked == "sphinx.call.someone" { return (200, #"{"url":"wss://livekit.sphinx.chat","room":"sphinx.call.someone","token":"t","identity":"alice-1"}"#) }
            guard asked == room else { return (404, #"{"error":"Jamie from this box is not in that call"}"#) }
            return (200, #"{"url":"wss://livekit.sphinx.chat","room":"\#(room)","token":"eyJ.t.s","identity":"\#(Self.identity)"}"#)
        }
        defer { stub.stop() }
        let client = BoxClient(box: box.url)
        let ticket = try #require(try await client.callTicket(box, room: room, name: "Ada"))
        #expect(ticket.identity == Self.identity && ticket.token == "eyJ.t.s" && ticket.url == "wss://livekit.sphinx.chat")
        #expect(HTTPStub.jsonBody(of: try #require(stub.requests.first)) == ["room": room, "name": "Ada"])
        // The box counts UTF-16 units: a long name is cut to 128 of them, never refused.
        _ = try await client.callTicket(box, room: room, name: String(repeating: "😀", count: 70))
        #expect(HTTPStub.jsonBody(of: try #require(stub.requests.last))?["name"]?.utf16.count == 128)
        #expect(!String(describing: ticket).contains("eyJ"))
        #expect(try await client.callTicket(box, room: "sphinx.call.other", name: "Ada") == nil)
        // Refused in words that name the server, never the person joining.
        let refused = await #expect(throws: PeelError.self) { _ = try await client.callTicket(box, room: "sphinx.call.elsewhere", name: "Ada") }
        #expect(refused?.description == "\(box.title)'s call ticket could not be read.")
        // Only an identity the box mints, never another participant's.
        await #expect(throws: PeelError.self) { _ = try await client.callTicket(box, room: "sphinx.call.someone", name: "Ada") }
    }
}
