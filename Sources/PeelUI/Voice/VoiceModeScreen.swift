import Foundation
import PeelCore

/// The "Voice Mode" setting (docs/voice-mode.md, "Voice Mode screen"): an
/// alternative default interface, off unless the person turns it on. This
/// device's, so `UserDefaults` through `@AppStorage`, like `VoiceDefaults`.
public enum VoiceModeSetting {
    public static let key = "voiceMode"
    public static let defaultValue = false
}

/// The four interaction modes for the Voice Mode screen.
public enum VoiceModeInteraction: String, CaseIterable, Equatable, Sendable {
    case speechInSpeechOut  // default
    case textInTextOut
    case speechInTextOut
    case textInSpeechOut

    public static let key = "voiceModeInteraction"
    public static let defaultValue = VoiceModeInteraction.speechInSpeechOut

    /// True for modes where the mic is used for input.
    public var usesMic: Bool { self == .speechInSpeechOut || self == .speechInTextOut }
    /// True for modes where the agent's reply is spoken.
    public var speaksReply: Bool { self == .speechInSpeechOut || self == .textInSpeechOut }

    /// A short label for a segmented picker: symbols, the same in every
    /// language, so not in the catalogs (`accessibilityLabel` says it in words).
    public var label: String {
        switch self {
        case .speechInSpeechOut: "🎙️ → 🔊"
        case .textInTextOut: "⌨️ → 📄"
        case .speechInTextOut: "🎙️ → 📄"
        case .textInSpeechOut: "⌨️ → 🔊"
        }
    }

    /// A longer accessibility label.
    public var accessibilityLabel: String {
        switch self {
        case .speechInSpeechOut: String(localized: "Speech in, speech out", table: "Shared")
        case .textInTextOut: String(localized: "Text in, text out", table: "Shared")
        case .speechInTextOut: String(localized: "Speech in, text out", table: "Shared")
        case .textInSpeechOut: String(localized: "Text in, speech out", table: "Shared")
        }
    }
}

/// Subtitle setting: show the spoken reply as on-screen text in speech-out modes.
public enum VoiceModeSubtitlesSetting {
    public static let key = "voiceModeSubtitles"
    public static let defaultValue = false
}

/// What the Voice Mode screen shows as the agent's reply, from the agent
/// DM's timeline rather than the voice controller, so a typed message's
/// reply shows (and is read) too, with the microphone off.
public enum VoiceModeReply {
    /// The agent's texts since your newest message (a text, a picture, a
    /// file), oldest first; empty while it has not answered. Control lines,
    /// deleted messages and yours that never went do not count. Messages
    /// oldest first, as a timeline holds them.
    public static func latest(in messages: [Message], chat: String) -> [Message] {
        var replies: [Message] = []
        for message in messages.reversed() where message.chat == chat && !message.deleted && message.control == nil {
            if message.fromMe {
                if message.notSent { continue }
                break
            }
            if message.type == MessageType.text { replies.append(message) }
        }
        return replies.reversed()
    }

    /// The replies as one text, a blank line between them.
    public static func text(of replies: [Message]) -> String? {
        let texts = replies.map(\.shownText).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
}

/// The linen's thread flecks, placed from a fixed seed so the cloth looks the
/// same every time it is drawn (never `SystemRandomNumberGenerator`).
public struct LinenFleck: Equatable, Sendable {
    /// Position and length as fractions of the canvas, 0…1.
    public var x: Double
    public var y: Double
    public var length: Double
    /// Radians; mostly along the weft or the warp.
    public var angle: Double
    /// 0…1, how dark or light.
    public var tone: Double
    public var isLight: Bool

    public static let seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    public static func make(count: Int = 70, seed: UInt64 = LinenFleck.seed) -> [LinenFleck] {
        var random = SplitMix64(state: seed)
        return (0..<count).map { _ in
            let along = random.unit() < 0.5
            return LinenFleck(
                x: random.unit(),
                y: random.unit(),
                length: 0.01 + random.unit() * 0.03,
                angle: (along ? 0 : Double.pi / 2) + (random.unit() - 0.5) * 0.3,
                tone: 0.3 + random.unit() * 0.7,
                isLight: random.unit() < 0.4
            )
        }
    }
}

/// A small seeded generator (SplitMix64).
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
