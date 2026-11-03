import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// The live text as LiveKit Agents publish it on `lk.transcription`
/// (agents-js 1.x): the agent's reply in chunks of one stream per segment,
/// the member's words sent whole on a new stream each time they change,
/// both from the agent's participant, told apart by the transcribed track.
struct TalkTranscriptTests {
    private let you = "m-1", agent = "a-1", yourTrack = "TR_mic", agentTrack = "TR_agent"

    private func attributes(_ segment: String, track: String, final: Bool = false) -> [String: String] {
        ["lk.segment_id": segment, "lk.transcribed_track_id": track, "lk.transcription_final": final ? "true" : "false"]
    }

    private func receive(_ transcript: inout TalkTranscript, _ chunk: String, stream: String, sender: String? = nil,
                         _ attributes: [String: String]) {
        transcript.receive(chunk, stream: stream, sender: sender ?? agent, attributes: attributes,
                           you: you, yourTracks: [yourTrack])
    }

    @Test func foldsEachSpeakersSegmentsIntoLines() {
        var transcript = TalkTranscript()
        // The member's words, whole each time, on a new stream: replaced.
        receive(&transcript, "what's on", stream: "s1", attributes("u1", track: yourTrack))
        receive(&transcript, "what's on my calendar", stream: "s2", attributes("u1", track: yourTrack, final: true))
        // The agent's reply, chunk by chunk on one stream: added up.
        receive(&transcript, "You have", stream: "s3", attributes("r1", track: agentTrack))
        receive(&transcript, " two meetings.", stream: "s3", attributes("r1", track: agentTrack))
        #expect(transcript.lines.map(\.speaker) == [.you, .agent])
        #expect(transcript.lines.map(\.text) == ["what's on my calendar", "You have two meetings."])
        #expect(transcript.lines.map(\.isFinal) == [true, false])
        receive(&transcript, "", stream: "s3", attributes("r1", track: agentTrack, final: true))
        #expect(transcript.lines.last?.isFinal == true)
        // The same segment id from each side is two lines.
        receive(&transcript, "and you?", stream: "s4", attributes("r1", track: yourTrack))
        #expect(transcript.lines.count == 3)
    }

    /// Whose words: the member's when the stream names one of their tracks,
    /// or came from their own identity; the agent's otherwise.
    @Test(arguments: [
        ("TR_mic", "a-1", TalkLine.Speaker.you),
        (nil, "m-1", .you),
        ("TR_agent", "a-1", .agent),
        (nil, "a-1", .agent),
    ] as [(String?, String, TalkLine.Speaker)])
    func tellsTheMemberFromTheAgent(track: String?, sender: String, speaker: TalkLine.Speaker) {
        var transcript = TalkTranscript()
        transcript.receive("hi", stream: "s", sender: sender, attributes: track.map { ["lk.transcribed_track_id": $0] } ?? [:],
                           you: you, yourTracks: [yourTrack])
        #expect(transcript.lines.first?.speaker == speaker)
    }

    @Test func keepsTheNewestLinesAndShowsTextCleaned() {
        var transcript = TalkTranscript()
        for n in 0..<(TalkTranscript.maxLines + 5) {
            receive(&transcript, "line\u{202E} \(n)\n", stream: "s\(n)", attributes("seg\(n)", track: agentTrack))
        }
        #expect(transcript.lines.count == TalkTranscript.maxLines)
        #expect(transcript.lines.first?.text == "line 5")
        // A segment that went is a new line if it comes again, not a lost one.
        receive(&transcript, "back", stream: "x", attributes("seg0", track: agentTrack))
        #expect(transcript.lines.last?.text == "back")
    }
}

/// What the call screen says, from the room's connection and the agent's
/// `lk.agent.state` (agents-js 1.x's states).
struct TalkPhaseTests {
    @Test(arguments: [
        (TalkPhase.Connection.connecting, false, nil, false, TalkPhase.connecting),
        (.connecting, true, nil, false, .reconnecting),
        (.reconnecting, true, "speaking", true, .reconnecting),
        (.connected, true, nil, false, .waiting(left: false)),
        (.connected, true, nil, true, .waiting(left: true)),
        (.connected, true, "", false, .gettingReady),
        (.connected, true, "initializing", false, .gettingReady),
        (.connected, true, "idle", false, .listening),
        (.connected, true, "listening", false, .listening),
        (.connected, true, "thinking", false, .thinking),
        (.connected, true, "speaking", false, .speaking),
        (.connected, true, "dancing", false, .gettingReady),
        (.disconnected, true, nil, true, .ended(connected: true)),
        (.disconnected, false, nil, false, .ended(connected: false)),
    ] as [(TalkPhase.Connection, Bool, String?, Bool, TalkPhase)])
    func saysWhatTheCallIsDoing(connection: TalkPhase.Connection, connectedOnce: Bool, agentState: String?,
                                agentSeen: Bool, phase: TalkPhase) {
        #expect(TalkPhase(connection: connection, connectedOnce: connectedOnce, agentState: agentState, agentSeen: agentSeen) == phase)
    }
}

/// Talk from the Apps row: the home is asked for a room, the room is
/// joined, and hanging up leaves it; a refusal is said in the home's words.
@MainActor
struct TalkStoreTests {
    private static let room = "sphinx.call.voice.0123456789abcdef0123456789abcdef"

    private func answer(voice: String? = nil) -> String {
        let token = unsignedJWT(["sub": "m-1", "video": ["room": Self.room]])
        let voice = voice.map { #","voice":"\#($0)""# } ?? ""
        return #"{"url":"ws://127.0.0.1:7880","room":"\#(Self.room)","token":"\#(token)","identity":"m-1","agent":"a-1","encrypted":false\#(voice)}"#
    }

    private func home(answering status: Int = 200, _ body: String? = nil) async throws -> (HTTPStub, TalkHome) {
        let answer = body ?? answer()
        let stub = try await HTTPStub(status: status) { _ in answer }
        return (stub, try #require(TalkHome.development(url: "http://127.0.0.1:\(stub.port)", token: "t")))
    }

    private func settled(_ talk: TalkStore) async throws {
        for _ in 0..<200 {
            if case .starting = talk.state {} else { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
    }

    @Test func joinsTheRoomTheHomeNamesAndLeavesItOnHangingUp() async throws {
        let (stub, home) = try await home()
        defer { stub.stop() }
        let rooms = Rooms()
        let talk = TalkStore(provider: rooms)
        talk.talk(to: home)
        #expect(talk.home == home)
        try await settled(talk)
        let joined = try #require(rooms.joined.first)
        #expect(joined.ticket.room == Self.room && joined.ticket.agent == "a-1")
        guard case .on(let media) = talk.state else {
            Issue.record("not on: \(talk.state)")
            return
        }
        #expect(media === joined)
        talk.hangUp()
        #expect(talk.home == nil)
        await talk.end()
        #expect(joined.left)
    }

    @Test func saysWhyItCouldNotStart() async throws {
        let (stub, home) = try await home(answering: 503, #"{"error":"no voice service configured"}"#)
        defer { stub.stop() }
        let rooms = Rooms()
        let talk = TalkStore(provider: rooms)
        talk.talk(to: home)
        try await settled(talk)
        guard case .failed(let words) = talk.state else {
            Issue.record("not failed: \(talk.state)")
            return
        }
        #expect(words == "Could not start the call. Jamie can't take calls on 127.0.0.1 right now: no voice service configured.")
        #expect(rooms.joined.isEmpty)
    }

    /// Jamie's voice: the one kept on this device is asked for, the one the
    /// home says is in effect is shown, and the toggle keeps the other and
    /// tells the room.
    @Test func asksForTheKeptVoiceAndSwitchesItOnTheCall() async throws {
        let (stub, home) = try await home(answering: 200, answer(voice: "am_michael"))
        defer { stub.stop() }
        let defaults = try #require(UserDefaults(suiteName: "TalkStore.\(UUID())"))
        TalkVoice.male.store(in: defaults)
        let rooms = Rooms()
        let talk = TalkStore(provider: rooms, defaults: defaults)
        talk.talk(to: home)
        try await settled(talk)
        let request = try #require(stub.requests.first)
        #expect(request.hasSuffix(#"{"voice":"am_michael"}"#))
        let joined = try #require(rooms.joined.first)
        #expect(talk.voice == .male && joined.voices.isEmpty)
        talk.toggleVoice()
        #expect(talk.voice == .female && joined.voices == [.female])
        #expect(TalkVoice.stored(in: defaults) == .female)
        await talk.end()
    }

    /// A switch while still calling wins over the answer, which was for the
    /// voice asked before it, and is told to the room once joined.
    @Test func aSwitchWhileCallingIsToldOnceJoined() async throws {
        let (stub, home) = try await home(answering: 200, answer(voice: "af_heart"))
        defer { stub.stop() }
        let defaults = try #require(UserDefaults(suiteName: "TalkStore.\(UUID())"))
        let rooms = Rooms()
        let talk = TalkStore(provider: rooms, defaults: defaults)
        talk.talk(to: home)
        talk.toggleVoice()
        try await settled(talk)
        let request = try #require(stub.requests.first)
        #expect(request.hasSuffix(#"{"voice":"af_heart"}"#))
        #expect(talk.voice == .male && rooms.joined.first?.voices == [.male])
        #expect(TalkVoice.stored(in: defaults) == .male)
        await talk.end()
    }

    /// On a group call, Talk waits to be asked rather than leaving it.
    @Test func neverLeavesAGroupCallUnasked() async throws {
        let (stub, home) = try await home()
        defer { stub.stop() }
        let talk = TalkStore(provider: Rooms())
        talk.otherCall = { "#design" }
        talk.talk(to: home)
        guard case .failed(let words) = talk.state else {
            Issue.record("not failed: \(talk.state)")
            return
        }
        #expect(words.contains("#design"))
        #expect(stub.requests.isEmpty)
    }
}

/// Talk calls joined as the app would, recorded.
@MainActor
private final class Rooms: CallProvider {
    final class Room: TalkMedia {
        let ticket: TalkTicket
        var left = false
        var voices: [TalkVoice] = []
        init(_ ticket: TalkTicket) { self.ticket = ticket }
        func leave() async { left = true }
        func setVoice(_ voice: TalkVoice) { voices.append(voice) }
    }

    var joined: [Room] = []

    func join(_ ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) throws -> any OngoingCall {
        throw PeelError("no group calls here")
    }

    func talk(_ ticket: TalkTicket, home: TalkHome) throws -> any TalkMedia {
        let room = Room(ticket)
        joined.append(room)
        return room
    }
}
