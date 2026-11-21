import Foundation

/// The "Voice Mode" setting (docs/voice-mode.md, "Voice Mode screen"): an
/// alternative default interface, off unless the person turns it on. This
/// device's, so `UserDefaults` through `@AppStorage`, like `VoiceDefaults`.
public enum VoiceModeSetting {
    public static let key = "voiceMode"
    public static let defaultValue = false
}

/// Which interface the app opens on once it is unlocked.
public enum VoiceModeRoute: Equatable, Sendable {
    case voice
    case standard

    /// `showedStandard` is the in-memory choice of the grid icon, for the
    /// rest of this launch: it never changes the setting.
    public static func initial(voiceModeOn: Bool, showedStandard: Bool) -> VoiceModeRoute {
        voiceModeOn && !showedStandard ? .voice : .standard
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
