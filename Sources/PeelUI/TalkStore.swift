import Foundation
import PeelCore
import PeelDiagnostics

/// Talk to Jamie (docs/talk.md): the voice call with an org's agent this
/// device is on, or starting, or why it could not start. Beside
/// `CallStore`, not in it: a home names the room (`TalkHome.startCall`),
/// with no call link, call server or chat. `AppModel.talk`; the call screen
/// shows while there is a `home`.
@MainActor @Observable
public final class TalkStore {
    public enum State {
        /// `POST /voice/calls` is on its way.
        case starting
        /// It could not start, in words.
        case failed(String)
        /// In the room the home named.
        case on(any TalkMedia)
    }

    /// The home being talked to; nil with no call and no screen.
    public private(set) var home: TalkHome?
    public private(set) var state = State.starting
    /// Jamie's voice as the screen shows it: the one kept on this device as
    /// a call starts, then the one the home says is in effect, then the
    /// member's own switches (`toggleVoice`).
    public private(set) var voice: TalkVoice
    /// The dev setting's home, for a development profile (`TalkHome.development`).
    public internal(set) var developmentHome: TalkHome?
    /// The group call this device is on, if any, by its title: Talk waits
    /// until it is left rather than leaving it unasked (`CallStore.call`).
    @ObservationIgnored var otherCall: () -> String? = { nil }
    /// Waits for the group calls left to say goodbye (`CallStore.leaving`).
    @ObservationIgnored var groupCallsLeft: () async -> Void = {}
    /// The goodbye of the rooms left, which a quit waits for.
    @ObservationIgnored public private(set) var leaving: Task<Void, Never>?

    @ObservationIgnored private let provider: any CallProvider
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var starting: Task<Void, Never>?

    public init(provider: any CallProvider, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        voice = TalkVoice.stored(in: defaults)
    }

    /// Calling or in the room: a group call waits until this is hung up.
    public var isOn: Bool {
        if case .failed = state { false } else { home != nil }
    }

    /// Calls `home`'s agent: the screen shows at once, saying it is calling,
    /// then the room once the home has named it, or why not. A call already
    /// on is left first.
    public func talk(to home: TalkHome) {
        hangUp()
        self.home = home
        voice = TalkVoice.stored(in: defaults)
        let asked = voice
        if let reason = provider.unavailable {
            state = .failed(reason)
            return
        }
        if let other = otherCall() {
            state = .failed("Leave the call in \(other) first, then talk to Jamie.")
            return
        }
        state = .starting
        starting = Task {
            let state: State
            do {
                let ticket = try await home.startCall(voice: asked)
                // The rooms left before have said goodbye first: on the phone,
                // their leaving would take the audio session from this one.
                await leaving?.value
                await groupCallsLeft()
                // Hung up meanwhile: no room is joined.
                try Task.checkCancellation()
                let media = try provider.talk(ticket, home: home)
                // Switched while calling: the room is told, once it is
                // connected. Else the screen shows the voice in effect.
                if voice != asked {
                    media.setVoice(voice)
                } else if let given = ticket.voice {
                    voice = given
                }
                state = .on(media)
            } catch {
                guard !Task.isCancelled else { return }
                Diagnostics.note(errorKind: .call)
                state = .failed(PeelError.problem(error, couldNot: "start the call"))
            }
            self.state = state
        }
    }

    /// The toggle: Jamie's other voice, kept on this device for the next
    /// call and, on a call, asked of the agent from its next sentence (or
    /// once the room is joined, while still calling).
    public func toggleVoice() {
        voice = voice.flipped
        voice.store(in: defaults)
        if case .on(let media) = state { media.setVoice(voice) }
    }

    /// The same home again, after a failure or a call that ended.
    public func tryAgain() {
        if let home { talk(to: home) }
    }

    /// Leaves the room, if one was joined, and the screen goes.
    public func hangUp() {
        starting?.cancel()
        starting = nil
        if case .on(let media) = state {
            // Persist the transcript before the room is left.
            if let home, !media.transcript.lines.isEmpty {
                let snapshot = media.transcript
                let homeId = home.id
                let homeName = home.name
                Task.detached(priority: .utility) {
                    TalkHistoryStore.save(transcript: snapshot, homeId: homeId, homeName: homeName)
                }
            }
            leave(media)
        }
        home = nil
        state = .starting
    }

    private func leave(_ media: any TalkMedia) {
        let earlier = leaving
        leaving = Task {
            await earlier?.value
            await media.leave()
        }
    }

    /// Hangs up and waits until the room has said goodbye: when Peel quits.
    public func end() async {
        hangUp()
        await leaving?.value
    }
}

extension AppModel {
    /// Where Talk can call, in the order shown: the dev setting's home, then
    /// each Stadeum workspace in use.
    public var talkHomes: [TalkHome] {
        (talk.developmentHome.map { [$0] } ?? []) + stadeum.live.compactMap(TalkHome.init(peer:))
    }
}

// MARK: - What the room shows

/// The agent's turn, as LiveKit Agents publish it on their participant
/// (`lk.agent.state`).
public enum TalkAgentState: String, Sendable {
    case initializing, idle, listening, thinking, speaking

    /// The participant attribute it is read from.
    public static let attribute = "lk.agent.state"
}

/// Where a Talk call stands, as the call screen says it: from the room's
/// connection and the agent's own state. The member interrupts by speaking,
/// so nothing here waits for a turn.
public enum TalkPhase: Equatable, Sendable {
    case connecting, reconnecting
    /// In the room, the agent not there: not yet, or `left` once it was.
    case waiting(left: Bool)
    case gettingReady, listening, thinking, speaking
    /// The room is gone: `connected` once it was, else it never connected.
    case ended(connected: Bool)

    /// The room's connection, as LiveKit reports it.
    public enum Connection: Sendable { case connecting, connected, reconnecting, disconnected }

    /// `agentState` is the agent participant's `lk.agent.state`, nil while
    /// it is not in the room; `agentSeen` whether it has been.
    public init(connection: Connection, connectedOnce: Bool, agentState: String?, agentSeen: Bool) {
        switch connection {
        case .connecting: self = connectedOnce ? .reconnecting : .connecting
        case .reconnecting: self = .reconnecting
        case .disconnected: self = .ended(connected: connectedOnce)
        case .connected:
            guard let agentState else {
                self = .waiting(left: agentSeen)
                return
            }
            switch TalkAgentState(rawValue: agentState) {
            // Idle is between turns: the member may speak.
            case .idle, .listening: self = .listening
            case .thinking: self = .thinking
            case .speaking: self = .speaking
            // An agent that has not said yet is still starting.
            case .initializing, nil: self = .gettingReady
            }
        }
    }

    public var words: String {
        switch self {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .waiting(left: false): "Waiting for Jamie…"
        case .waiting(left: true): "Jamie left the call"
        case .gettingReady: "Jamie is getting ready…"
        case .listening: "Listening"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        case .ended(connected: true): "The call ended"
        case .ended(connected: false): "Could not connect to the call"
        }
    }

    /// Whether the call is over: the screen offers Try again and Close.
    public var isOver: Bool {
        if case .ended = self { true } else { false }
    }
}

/// A Talk call's encryption as it goes (docs/talk.md): the tracks LiveKit
/// says will not encrypt or decrypt, and whether a packet of the agent's text
/// would not decrypt. The agent's state comes over LiveKit's signaling, which
/// is not encrypted, so a call whose key does not match would otherwise say
/// "Speaking" over silence. `notice` is what the call screen says instead.
public struct TalkEncryption: Equatable, Sendable {
    /// The tracks failing now, by publication id: true for the member's own
    /// (it will not encrypt), false for the agent's (it will not decrypt).
    private var failing: [String: Bool] = [:]
    /// A text packet would not decrypt. No later state clears it.
    private var textFailed = false

    public static let agentUnheard = "This call's encryption failed: Jamie can't be heard."
    public static let youUnheard = "This call's encryption failed: Jamie can't hear you."

    public init() {}

    /// A track's state from LiveKit: `failed` for a missing key or frames
    /// that will not encrypt or decrypt, `local` for the member's own track.
    public mutating func track(_ id: String, local: Bool, failed: Bool) {
        failing[id] = failed ? local : nil
    }

    /// A packet of the agent's text would not decrypt.
    public mutating func textFailedToDecrypt() { textFailed = true }

    /// What the call screen says, nil while nothing fails. The agent unheard
    /// first: then nothing of the call comes through.
    public var notice: String? {
        if textFailed || failing.values.contains(false) { return Self.agentUnheard }
        if failing.values.contains(true) { return Self.youUnheard }
        return nil
    }
}

/// One line of a Talk call's live text: what the member said or what the
/// agent says, as it comes.
public struct TalkLine: Identifiable, Equatable, Codable, Sendable {
    public enum Speaker: String, Codable, Sendable { case you, agent }

    public let id: String
    public let speaker: Speaker
    /// Cleaned for showing (`TextLine.clean`).
    public internal(set) var text: String
    /// Whether this segment is done; a line still coming may change.
    public internal(set) var isFinal: Bool
}

/// A Talk call's live text, folded from the text streams LiveKit Agents
/// publish on `lk.transcription`, as LiveKit's own `TranscriptionStreamReceiver`
/// folds them: one line per speaker and `lk.segment_id`; chunks of one
/// stream add up, and a new stream for a segment (the member's words, sent
/// whole each time they change) replaces it. Whose words they are is
/// `lk.transcribed_track_id`: one of the member's tracks, else the agent's.
public struct TalkTranscript: Equatable, Sendable {
    public static let topic = "lk.transcription"
    /// The newest lines kept; older ones go.
    public static let maxLines = 500
    /// The most characters of a line's text.
    static let maxText = 4000

    public private(set) var lines: [TalkLine] = []
    /// The newest line the cap dropped, by id: the one before the first kept.
    private(set) var lastDropped: String?
    /// Each line's text as it came, and the stream that last wrote it.
    private var raw: [String: (text: String, stream: String)] = [:]

    public init() {}

    public static func == (a: TalkTranscript, b: TalkTranscript) -> Bool { a.lines == b.lines }

    /// One chunk of a text stream on `topic`: `stream` the stream's id,
    /// `sender` the identity it came from, `attributes` the stream's;
    /// `you` the member's identity and `yourTracks` their tracks' ids.
    public mutating func receive(
        _ chunk: String, stream: String, sender: String, attributes: [String: String],
        you: String, yourTracks: Set<String>
    ) {
        let track = attributes["lk.transcribed_track_id"]
        let speaker: TalkLine.Speaker = sender == you || track.map(yourTracks.contains) == true ? .you : .agent
        let segment = attributes["lk.segment_id"] ?? stream
        let id = "\(speaker == .you ? "you" : "agent")/\(segment)"
        let isFinal = attributes["lk.transcription_final"] == "true"
        let text = if let earlier = raw[id], earlier.stream == stream { String((earlier.text + chunk).prefix(Self.maxText)) } else { String(chunk.prefix(Self.maxText)) }
        raw[id] = (text, stream)
        let shown = TextLine.clean(text, max: Self.maxText)
        if let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].text = shown
            lines[index].isFinal = isFinal
        } else {
            lines.append(TalkLine(id: id, speaker: speaker, text: shown, isFinal: isFinal))
            if lines.count > Self.maxLines {
                for gone in lines.prefix(lines.count - Self.maxLines) { raw[gone.id] = nil }
                lastDropped = lines[lines.count - Self.maxLines - 1].id
                lines.removeFirst(lines.count - Self.maxLines)
            }
        }
    }
}

/// Where one of Jamie's cards goes in a Talk call's live text (docs/talk.md):
/// under the reply it came with. A card comes as strut's run for a turn ends,
/// or as a finished job's summary is queued to be spoken, usually before
/// Jamie's line: LiveKit Agents send that in time with the audio. So it goes
/// under Jamie's line being spoken when it came; else it waits at the end,
/// then goes under the next line if that is Jamie's, or stays above it if it
/// is the member's. It never moves: each later line comes above or below it.
public enum TalkCardAnchor: Equatable, Sendable {
    /// Under this line of Jamie's.
    case under(String)
    /// Decided by the first line after this one (nil: the call's first line).
    case next(after: String?)

    /// A card's anchor as it comes, from the live text so far.
    public init(_ transcript: TalkTranscript) {
        if let last = transcript.lines.last, last.speaker == .agent, !last.isFinal {
            self = .under(last.id)
        } else {
            self = .next(after: transcript.lines.last?.id)
        }
    }

    /// Where the card goes: how many of the transcript's lines are above it.
    /// A card whose lines the cap dropped goes at the top, where they were.
    public func linesAbove(in transcript: TalkTranscript) -> Int {
        let lines = transcript.lines
        switch self {
        case .under(let id):
            return lines.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0
        case .next(after: let id):
            // The first line after the anchor's. Past the cap: the first
            // kept when the anchor is the newest line dropped (nil, before
            // any drop: the call's first line), else gone too.
            let next: Int? = if let index = lines.firstIndex(where: { $0.id == id }) { index + 1 }
                else if id == transcript.lastDropped { 0 } else { nil }
            guard let next else { return 0 }
            guard next < lines.count else { return lines.count }
            return lines[next].speaker == .agent ? next + 1 : next
        }
    }
}
