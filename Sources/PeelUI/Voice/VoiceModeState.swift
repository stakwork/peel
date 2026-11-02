import Foundation

/// Where voice mode is (docs/voice-mode.md, "State machine").
public enum VoicePhase: Equatable, Sendable {
    case idle
    /// Listening, nothing said yet.
    case listening
    /// Listening, with a draft.
    case hearing
    /// The draft is on its way to the agent.
    case sending
    /// The agent is answering.
    case waiting
    /// A reply is being read.
    case speaking
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .idle, .failed: false
        default: true
        }
    }

    /// The words the panel shows.
    public var label: String {
        switch self {
        case .idle: "Voice mode is off"
        case .listening: "Listening…"
        case .hearing: "Listening…"
        case .sending: "Sending…"
        case .waiting: "Thinking…"
        case .speaking: "Speaking…"
        case .failed(let problem): problem
        }
    }

    /// The context transcripts are heard in (`VoiceCommandParser`).
    public var context: VoiceContext? {
        switch self {
        case .listening, .hearing: .dictating
        case .sending, .waiting: .waiting
        case .speaking: .speaking
        case .idle, .failed: nil
        }
    }
}

/// What happens to voice mode.
public enum VoiceEvent: Equatable, Sendable {
    case start
    case stop
    /// The draft so far (everything heard since the last send).
    case transcript(String)
    /// No new words for the auto-send time.
    case silence
    case command(VoiceCommand)
    case sendFinished(sent: Bool)
    /// The agent's turn ended; `hasReply` if there is something to read.
    case replyReady(hasReply: Bool)
    case speechStarted
    case speechEnded
    /// A turn is still being answered (after speech that came in between).
    case awaitReply
    case failure(String)
}

/// What the controller must do about it.
public enum VoiceEffect: Equatable, Sendable {
    case begin
    case end
    case send(String)
    case clearDraft
    case stopSpeech
    case skipSpeech
    case speakLastReply
    case speakFullReply
    case stopAgent
    /// Muted: the draft is frozen and the input is matched only for unmute.
    case mute
    case unmute
}

/// The transitions of voice mode as a reducer: no audio, no model, so it is
/// tested without either.
public struct VoiceMachine: Equatable, Sendable {
    public private(set) var phase = VoicePhase.idle
    public private(set) var draft = ""
    /// Muted is a flag over the phase, so unmuting returns to whatever phase
    /// it was (listening, waiting, speaking) without remembering it.
    public private(set) var isMuted = false

    public init() {}

    /// The context transcripts are heard in: `.muted` while muted.
    public var context: VoiceContext? {
        guard phase.isActive else { return nil }
        return isMuted ? .muted : phase.context
    }

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public mutating func apply(_ event: VoiceEvent) -> [VoiceEffect] {
        switch event {
        case .start:
            guard !phase.isActive else { return [] }
            phase = .listening
            draft = ""
            isMuted = false
            return [.begin]
        case .stop, .command(.deactivate):
            guard phase.isActive else { return [] }
            phase = .idle
            draft = ""
            isMuted = false
            return [.end]
        case .failure(let problem):
            guard phase.isActive else { return [] }
            phase = .failed(problem)
            draft = ""
            isMuted = false
            return [.end]
        default:
            guard phase.isActive else { return [] }
        }

        switch event {
        case .command(.mute):
            guard !isMuted else { return [] }
            isMuted = true
            return [.mute]
        case .command(.unmute):
            guard isMuted else { return [] }
            isMuted = false
            return [.unmute]
        case .transcript, .silence, .command(.send), .command(.discard):
            // Muted: the draft is frozen and nothing is sent.
            if isMuted { return [] }
        default:
            break
        }

        switch (phase, event) {
        case (.listening, .transcript(let text)), (.hearing, .transcript(let text)):
            draft = text
            phase = hasDraft ? .hearing : .listening
            return []
        case (.hearing, .silence), (.hearing, .command(.send)):
            return beginSend()
        case (.listening, .command(.send)):
            return []
        case (.listening, .command(.discard)), (.hearing, .command(.discard)):
            draft = ""
            phase = .listening
            return [.clearDraft]
        case (.sending, .sendFinished(let sent)):
            phase = sent ? .waiting : (hasDraft ? .hearing : .listening)
            if sent { draft = "" }
            return []
        case (.waiting, .replyReady(let hasReply)), (.sending, .replyReady(let hasReply)):
            // Speech starts with `.speechStarted`; with nothing to read, listen again.
            if !hasReply { phase = .listening }
            return []
        case (.listening, .awaitReply):
            phase = .waiting
            return []
        case (_, .speechStarted):
            phase = .speaking
            return []
        case (.speaking, .speechEnded):
            phase = .listening
            draft = ""
            return [.clearDraft]
        case (.speaking, .command(.stopSpeaking)):
            phase = .listening
            draft = ""
            return [.stopSpeech, .clearDraft]
        case (.speaking, .command(.skip)):
            return [.skipSpeech]
        case (_, .command(.repeatReply)):
            return [.speakLastReply]
        case (_, .command(.readAll)):
            return [.speakFullReply]
        case (_, .command(.stopAgent)):
            return [.stopAgent]
        default:
            return []
        }
    }

    private mutating func beginSend() -> [VoiceEffect] {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .sending
        return [.send(text)]
    }
}

/// Every default and key of voice mode in one place, in `UserDefaults`:
/// these are this device's, not part of the synced `Preferences`
/// (docs/voice-mode.md, "Settings").
public enum VoiceDefaults {
    public static let spokenRepliesKey = "voice.spokenReplies"
    // ".v2": auto-send used to default to on, with 1–5 s; values stored under
    // the old keys are not read, so nobody is silently cut off by a stale 2 s.
    public static let autoSendKey = "voice.autoSend.v2"
    public static let autoSendSecondsKey = "voice.autoSendSeconds.v2"
    public static let wakeListenKey = "voice.wakeListen"
    public static let speechRateKey = "voice.speechRate"

    public static let spokenReplies = true
    /// Off: "Peel send" is the way to send; a pause can cut you off.
    public static let autoSend = false
    /// No new words for this long sends the draft, when auto-send is on.
    public static let autoSendSeconds: Double = 5.0
    public static let autoSendRange: ClosedRange<Double> = 2.0...15.0
    public static let wakeListen = false
    /// A factor of the system's default speaking rate.
    public static let speechRate: Double = 1.0
    public static let speechRateRange: ClosedRange<Double> = 0.7...1.5
    /// Recogniser failures in a row before voice mode gives up.
    public static let retryLimit = 3

    /// Seconds before retry number `attempt` (1, 2, …): 1, 2, 4.
    public static func backoff(attempt: Int) -> TimeInterval {
        Double(1 << max(0, min(attempt - 1, 4)))
    }
}

/// What the user chose.
public struct VoiceSettings: Equatable, Sendable {
    public var spokenReplies = VoiceDefaults.spokenReplies
    public var autoSend = VoiceDefaults.autoSend
    public var autoSendSeconds = VoiceDefaults.autoSendSeconds
    public var wakeListen = VoiceDefaults.wakeListen
    public var speechRate = VoiceDefaults.speechRate

    public init() {}

    public init(defaults: UserDefaults) {
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        spokenReplies = value(VoiceDefaults.spokenRepliesKey, VoiceDefaults.spokenReplies)
        autoSend = value(VoiceDefaults.autoSendKey, VoiceDefaults.autoSend)
        autoSendSeconds = value(VoiceDefaults.autoSendSecondsKey, VoiceDefaults.autoSendSeconds)
            .clamped(to: VoiceDefaults.autoSendRange)
        wakeListen = value(VoiceDefaults.wakeListenKey, VoiceDefaults.wakeListen)
        speechRate = value(VoiceDefaults.speechRateKey, VoiceDefaults.speechRate)
            .clamped(to: VoiceDefaults.speechRateRange)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
