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
}

/// The transitions of voice mode as a reducer: no audio, no model, so it is
/// tested without either.
public struct VoiceMachine: Equatable, Sendable {
    public private(set) var phase = VoicePhase.idle
    public private(set) var draft = ""

    public init() {}

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public mutating func apply(_ event: VoiceEvent) -> [VoiceEffect] {
        switch event {
        case .start:
            guard !phase.isActive else { return [] }
            phase = .listening
            draft = ""
            return [.begin]
        case .stop, .command(.deactivate):
            guard phase.isActive else { return [] }
            phase = .idle
            draft = ""
            return [.end]
        case .failure(let problem):
            guard phase.isActive else { return [] }
            phase = .failed(problem)
            draft = ""
            return [.end]
        default:
            guard phase.isActive else { return [] }
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
    public static let autoSendKey = "voice.autoSend"
    public static let autoSendSecondsKey = "voice.autoSendSeconds"
    public static let wakeListenKey = "voice.wakeListen"
    public static let speechRateKey = "voice.speechRate"

    public static let spokenReplies = true
    public static let autoSend = true
    /// No new words for this long sends the draft.
    public static let autoSendSeconds: Double = 2.0
    public static let autoSendRange: ClosedRange<Double> = 1.0...5.0
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
