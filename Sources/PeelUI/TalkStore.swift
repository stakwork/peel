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
        if case .on(let media) = state { leave(media) }
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

/// One line of a Talk call's live text: what the member said or what the
/// agent says, as it comes.
public struct TalkLine: Identifiable, Equatable, Sendable {
    public enum Speaker: Sendable { case you, agent }

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
    static let maxLines = 200
    /// The most characters of a line's text.
    static let maxText = 4000

    public private(set) var lines: [TalkLine] = []
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
                lines.removeFirst(lines.count - Self.maxLines)
            }
        }
    }
}
