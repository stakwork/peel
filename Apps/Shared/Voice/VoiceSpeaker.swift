import AVFoundation
import Foundation

/// A speech engine voice mode can speak through. `VoiceSpeaker` (on-device
/// `AVSpeechSynthesizer`) is the one there is; a cloud engine would be
/// another conformance, with nothing else changed (docs/voice-mode.md).
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Called when everything queued has been spoken (not when stopped).
    var onFinished: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    /// Queues `chunks` after what is already queued.
    func speak(_ chunks: [String], rate: Double)
    /// Drops the queue and goes quiet at once.
    func stop()
    func pause()
    func resume()
}

/// How good the best installed voice is (Settings shows it).
enum VoiceQuality: Int, Comparable {
    case none, standard, enhanced, premium

    static func < (lhs: VoiceQuality, rhs: VoiceQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .none: "No voice installed"
        case .standard: "Standard voice"
        case .enhanced: "Enhanced voice installed"
        case .premium: "Premium voice installed"
        }
    }

    /// Where to get a better one.
    static var downloadHint: String {
        #if os(iOS)
        "Download an Enhanced or Premium voice in Settings > Accessibility > Spoken Content > Voices."
        #else
        "Download an Enhanced or Premium voice in System Settings > Accessibility > Spoken Content."
        #endif
    }
}

/// `AVSpeechSynthesizer` behind `SpeechSynthesizing`: a queue of
/// sentence-sized utterances, so `stop()` is quick and a barge-in does not
/// wait for a paragraph.
@MainActor
final class VoiceSpeaker: NSObject, SpeechSynthesizing {
    var onFinished: (() -> Void)?
    var isSpeaking: Bool { !live.isEmpty }

    private let synthesizer = AVSpeechSynthesizer()
    /// The utterances not finished, by identity, so what a `stop()` cancels
    /// is not mistaken for the end of the next queue.
    private var live: [ObjectIdentifier: AVSpeechUtterance] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        // Our audio session (`.voiceChat`, voice mode's) applies to the speech.
        synthesizer.usesApplicationAudioSession = true
        synthesizer.mixToTelephonyUplink = false
        #endif
    }

    func speak(_ chunks: [String], rate: Double) {
        let voice = Self.bestVoice()
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let wanted = Float(min(max(base * rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                               Double(AVSpeechUtteranceMaximumSpeechRate)))
        for chunk in chunks where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.rate = wanted
            utterance.postUtteranceDelay = 0.12
            live[ObjectIdentifier(utterance)] = utterance
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        live.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func pause() { synthesizer.pauseSpeaking(at: .immediate) }

    func resume() { synthesizer.continueSpeaking() }

    fileprivate func ended(_ id: ObjectIdentifier, finished: Bool) {
        guard live.removeValue(forKey: id) != nil else { return }
        if live.isEmpty, finished { onFinished?() }
    }

    // MARK: Voices

    /// The best installed voice for the system's language: Premium over
    /// Enhanced over default; novelty voices (macOS) never.
    static func bestVoice(language: String = AVSpeechSynthesisVoice.currentLanguageCode()) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && !$0.identifier.contains("speech.synthesis.voice")
        }
        return candidates.max { lhs, rhs in
            let l = (lhs.quality.rawValue, lhs.language == language ? 1 : 0)
            let r = (rhs.quality.rawValue, rhs.language == language ? 1 : 0)
            return l < r
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// The quality of the voice `bestVoice` picks.
    static func installedQuality() -> VoiceQuality {
        guard let voice = bestVoice() else { return .none }
        switch voice.quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }
}

extension VoiceSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id, finished: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id, finished: false) }
    }
}
