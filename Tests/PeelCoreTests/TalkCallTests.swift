import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

private let room = "sphinx.call.voice.0123456789abcdef0123456789abcdef"

/// What a home answers to `POST /voice/calls` (strut's plans/private-voice.md §4.1).
private func reply(url: String = "ws://127.0.0.1:7880", room tokenRoom: String = room, encrypted: Bool = true,
                   voice: String? = nil) -> String {
    let token = unsignedJWT(["sub": "m-1", "exp": Date.now.timeIntervalSince1970 + 600, "video": ["room": tokenRoom, "roomJoin": true]])
    let voice = voice.map { #","voice":"\#($0)""# } ?? ""
    return #"{"url":"\#(url)","room":"\#(room)","token":"\#(token)","identity":"m-1","agent":"a-1","encrypted":\#(encrypted)\#(voice)}"#
}

/// A home on a loopback stub, as the dev setting names one.
private func home(_ stub: HTTPStub) throws -> TalkHome {
    try #require(TalkHome.development(url: "http://127.0.0.1:\(stub.port)", token: "person-token-1"))
}

/// Starting a call: the request the home gets, and the answer read back.
struct TalkCallTests {
    @Test func startsACallWithThePersonsTokenAndReadsTheRoom() async throws {
        let stub = try await HTTPStub { _ in reply() }
        defer { stub.stop() }
        let ticket = try await home(stub).startCall()
        #expect(ticket.url.absoluteString == "ws://127.0.0.1:7880")
        #expect(ticket.room == room)
        #expect(ticket.identity == "m-1")
        #expect(ticket.agent == "a-1")
        let request = try #require(stub.requests.first)
        #expect(request.hasPrefix("POST /voice/calls HTTP/1.1\r\n"))
        #expect(request.lowercased().contains("\r\nauthorization: bearer person-token-1\r\n"))
        #expect(HTTPStub.jsonBody(of: request) == ["key": ticket.key])
        // The capability: this Peel shows a turn's artifact cards.
        #expect(request.contains(#""artifacts":true"#))
        // Neither the ticket nor the home tells its token, nor the ticket its key.
        for secret in [ticket.token, ticket.key] {
            #expect(!"\(ticket)".contains(secret) && !String(reflecting: ticket).contains(secret))
        }
        #expect(!"\(try home(stub))".contains("person-token-1"))
    }

    /// Every call goes with a fresh key, 32 random bytes as base64, and joins
    /// the room with the very string sent.
    @Test func sendsAFreshKeyForEveryCall() async throws {
        let stub = try await HTTPStub { _ in reply() }
        defer { stub.stop() }
        let first = try await home(stub).startCall(), second = try await home(stub).startCall()
        #expect(first.key != second.key)
        for (ticket, request) in zip([first, second], stub.requests) {
            #expect(Data(base64Encoded: ticket.key)?.count == 32)
            #expect(HTTPStub.jsonBody(of: request)?["key"] == ticket.key)
        }
    }

    /// The voice asked for rides in the body; the screen shows the one the
    /// home answers is in effect, and none it does not know.
    @Test(arguments: [
        (TalkVoice.male, "am_michael", TalkVoice?.some(.male)),
        (.female, "af_heart", .female),
        (.male, "zz_other", nil),
        (.male, nil, nil),
    ] as [(TalkVoice, String?, TalkVoice?)])
    func asksForAVoiceAndReadsTheOneInEffect(asked: TalkVoice, answered: String?, shown: TalkVoice?) async throws {
        let stub = try await HTTPStub { _ in reply(voice: answered) }
        defer { stub.stop() }
        let ticket = try await home(stub).startCall(voice: asked)
        #expect(ticket.voice == shown)
        let request = try #require(stub.requests.first)
        #expect(HTTPStub.jsonBody(of: request)?["voice"] == asked.rawValue)
    }

    /// The toggle: ♀ is `af_heart`, ♂ `am_michael`, as text and never emoji;
    /// a tap flips it, and the choice is kept per device, female by default.
    @Test func togglesJamiesVoiceBetweenTheTwo() throws {
        #expect(TalkVoice.female.rawValue == "af_heart" && TalkVoice.male.rawValue == "am_michael")
        #expect(TalkVoice.female.glyph.unicodeScalars.map(\.value) == [0x2640, 0xFE0E])
        #expect(TalkVoice.male.glyph.unicodeScalars.map(\.value) == [0x2642, 0xFE0E])
        #expect(TalkVoice.female.flipped == .male && TalkVoice.male.flipped == .female)
        #expect(TalkVoice.female.accessibilityLabel == "Jamie's voice: female")
        #expect(TalkVoice.male.accessibilityLabel == "Jamie's voice: male")
        let defaults = try #require(UserDefaults(suiteName: "TalkVoice.\(UUID())"))
        #expect(TalkVoice.stored(in: defaults) == .female)
        TalkVoice.male.store(in: defaults)
        #expect(defaults.string(forKey: "talkVoice") == "am_michael")
        #expect(TalkVoice.stored(in: defaults) == .male)
        defaults.set("zz_other", forKey: "talkVoice")
        #expect(TalkVoice.stored(in: defaults) == .female)
    }

    /// A refusal is the home's own words, with what it means first; 402
    /// (step 3) says the balance and the minimum.
    @Test(arguments: [
        (402, #"{"error":"balance too low","balance":120,"minimum":500}"#,
         "Not enough sats to talk: you have 120 sats, and a call needs 500 sats."),
        (503, #"{"error":"no voice service configured"}"#,
         "Jamie can't take calls on 127.0.0.1 right now: no voice service configured"),
        (403, #"{"error":"a call runs as a person"}"#, "127.0.0.1 takes calls only from a person's sign-in: a call runs as a person"),
        (401, "", "127.0.0.1 did not accept your sign-in."),
        (400, #"{"error":"key must be 32 bytes\n<<<"}"#, "127.0.0.1 could not start the call: key must be 32 bytes << <"),
        (402, #"{"error":"pay first"}"#, "127.0.0.1 could not start the call (HTTP 402): pay first"),
        (500, "oops", "127.0.0.1 could not start the call (HTTP 500)."),
    ])
    func saysARefusalInTheHomesWords(status: Int, body: String, words: String) async throws {
        let stub = try await HTTPStub(status: status) { _ in body }
        defer { stub.stop() }
        let error = await #expect(throws: TalkRefusal.self) { try await home(stub).startCall() }
        #expect(error.map(PeelError.readable) == words)
    }

    /// The home's answer is trusted for where media goes, within the rule
    /// every Peel connection keeps: plain ws only on this device.
    @Test(arguments: [
        ("wss://livekit.example.com", "wss://livekit.example.com"),
        ("https://livekit.example.com:7880", "wss://livekit.example.com:7880"),
        ("ws://127.0.0.1:7880", "ws://127.0.0.1:7880"),
        ("http://localhost:7880", "ws://localhost:7880"),
        ("ws://[::1]:7880", "ws://[::1]:7880"),
        ("ws://192.168.1.20:7880", nil),
        ("ws://livekit.example.com", nil),
        ("wss://livekit.example.com/?token=x", nil),
        ("wss://user:pass@livekit.example.com", nil),
        ("ftp://livekit.example.com", nil),
        ("livekit.example.com", nil),
    ] as [(String, String?)])
    func takesOnlyAServerPeelMayConnectTo(given: String, used: String?) {
        #expect(TalkTicket.mediaURL(given)?.absoluteString == used)
    }

    /// An answer it could not join: plain ws off this device, a room the
    /// agent did not join with the call's key (a voice service from before
    /// encryption answers `encrypted: false`), a token for another room,
    /// missing fields.
    @Test(arguments: [
        reply(url: "ws://10.0.0.5:7880"),
        reply(encrypted: false),
        reply().replacingOccurrences(of: #","encrypted":true"#, with: ""),
        reply(room: "sphinx.call.voice.other"),
        #"{"url":"ws://127.0.0.1:7880"}"#,
    ])
    func refusesAnAnswerItCannotJoin(body: String) {
        #expect(throws: PeelError.self) { try TalkTicket(reply: Data(body.utf8), home: "Acme", key: TalkHome.newKey()) }
    }

    /// The dev setting: a strut on this device over http, or anywhere over
    /// https, and a token; nothing else.
    @Test(arguments: [
        ("http://127.0.0.1:3000", "t", true),
        ("https://acme.sphinx.chat:3355/lab", "t", true),
        ("http://192.168.1.20:3000", "t", false),
        ("http://127.0.0.1:3000", " ", false),
        ("http://127.0.0.1:3000", nil, false),
        (nil, "t", false),
    ] as [(String?, String?, Bool)])
    func namesALocalHomeOnlyWhereATokenMayGo(url: String?, token: String?, named: Bool) {
        let home = TalkHome.development(url: url, token: token)
        #expect((home != nil) == named)
        #expect(home.map { $0.url.appending(path: "voice/calls").absoluteString } == (named ? url! + "/voice/calls" : nil))
    }

    @Test func aPairedOrgsHomeIsItsStrutAndToken() throws {
        let peer = HivePeer(id: "acme", baseUrl: "https://acme.sphinx.chat:3355/lab", token: "strut-person.x.y", label: "Acme")
        let home = try #require(TalkHome(peer: peer))
        #expect(home.id == "acme" && home.name == "Acme" && home.token == "strut-person.x.y")
        #expect(TalkHome(peer: HivePeer(id: "evil", baseUrl: "http://evil.example.com", token: "t")) == nil)
    }
}

/// A turn's artifact cards (`sphinx.artifacts`): strut's entries, resolved
/// against the call's home.
struct TalkArtifactsTests {
    private func payload(_ entries: String, id: String = "p-1") -> String {
        #"{"id":"\#(id)","timestamp":1760000000000,"artifacts":[\#(entries)]}"#
    }

    @Test func callBodyAsksForArtifacts() throws {
        let body = try TalkHome.callBody(key: "k", voice: .male)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["artifacts"] as? Bool == true && json["key"] as? String == "k" && json["voice"] as? String == "am_michael")
    }

    @Test func readsAPlanOnTheHomesStrut() throws {
        let text = payload(#"{"id":"a1","kind":"plan","title":"Reminders for Jamie, plan","label":"Plan","url":"/jobs/j1/files/plan.md","path":"plan.md"}"#)
        let card = try #require(TalkArtifacts.decode(text, workspace: "acme").first)
        #expect(card.title == "Reminders for Jamie, plan" && card.label == "Plan" && card.id == "a1")
        #expect(card.handle == AgentArtifact.Handle(path: "/peers/acme/jobs/j1/files/plan.md"))
        #expect(TalkArtifacts.batch(text, workspace: "acme")?.id == "p-1")
    }

    @Test func readsAnAppAndAPeersFile() throws {
        let text = payload(#"""
        {"id":"a2","kind":"app","title":"Board","url":"/apps/board/v2/files/dist/index.html","app":{"name":"board","version":"v2","hash":"h","builtAt":1}},
        {"id":"a3","kind":"file","title":"Notes","url":"/jobs/j9/files/n.md","peer":"beta","job":"j9","path":"n.md"}
        """#)
        let cards = TalkArtifacts.decode(text, workspace: "acme")
        #expect(cards.map(\.handle) == [
            AgentArtifact.Handle(app: "@acme/board@v2"),
            AgentArtifact.Handle(path: "/peers/acme/peers/beta/jobs/j9/files/n.md"),
        ])
    }

    @Test func readsAnHttpsLinkWithoutAHandle() throws {
        let text = payload(#"{"id":"a4","kind":"pull_request","title":"Fix it","url":"https://github.com/acme/repo/pull/7"}"#)
        let card = try #require(TalkArtifacts.decode(text, workspace: TalkHome.development).first)
        #expect(card.handle == nil && card.url == URL(string: "https://github.com/acme/repo/pull/7"))
    }

    @Test func malformedGivesNothing() {
        for text in ["", "not json", "[]", #"{"id":"p"}"#, #"{"artifacts":[{"title":"x"}]}"#, #"{"id":"p","artifacts":"x"}"#] {
            #expect(TalkArtifacts.decode(text, workspace: "acme").isEmpty)
        }
        #expect(TalkArtifacts.decode(payload("1, null, \"x\""), workspace: "acme").isEmpty)
    }

    @Test func skipsAnEntryWithNoTitleAndCaps() {
        let text = payload(#"{"id":"a5","kind":"plan","url":"/jobs/j1/files/p.md"},{"id":"a6","kind":"plan","title":"Kept","url":"/jobs/j1/files/p.md"}"#)
        #expect(TalkArtifacts.decode(text, workspace: "acme").map(\.title) == ["Kept"])
        let many = (0 ..< 30).map { #"{"id":"e\#($0)","title":"T\#($0)","url":"/jobs/j/files/f"}"# }.joined(separator: ",")
        #expect(TalkArtifacts.decode(payload(many), workspace: "acme").count == AgentArtifact.most)
    }
}
