import Foundation

/// The Talk call screen's waveform (docs/talk.md): rounded bars in the
/// circle that move with the voice heard (Jamie's while it speaks, the
/// member's own while it listens), a calm wave travelling across them while
/// Jamie thinks, a slow breath while calling. Pure: the heights from the
/// mode, a level and the time, and the level's smoothing; the app draws them.
/// Heights are a share of the tallest bar, `floor` to 1.
public enum TalkWave {
    public static let barCount = 7
    /// The lowest a bar goes.
    public static let floor = 0.12

    /// What the bars show.
    public enum Mode: Equatable, Sendable {
        /// Jamie speaking: the agent's audio level.
        case agent
        /// Listening: the member's microphone level.
        case member
        /// Jamie thinking: a wave travelling across.
        case thinking
        /// Calling, connecting, getting ready: a slow breath.
        case breathing
        /// Listening with the microphone muted: low and flat.
        case muted
        /// Jamie left, or the call is over: no motion.
        case still

        /// The mode for a phase; nil while still calling. `muted` only
        /// counts while listening: what Jamie says still shows.
        public init(phase: TalkPhase?, muted: Bool) {
            switch phase {
            case nil, .connecting, .reconnecting, .gettingReady, .waiting(left: false): self = .breathing
            case .listening: self = muted ? .muted : .member
            case .thinking: self = .thinking
            case .speaking: self = .agent
            case .waiting(left: true), .ended: self = .still
            }
        }

        /// Whether the bars follow a level.
        public var hearsVoice: Bool { self == .agent || self == .member }
    }

    /// A loudness from an RMS in linear full scale (0…1): -50 dBFS (a quiet
    /// room after voice processing) is 0, -14 dBFS (speech up close) is 1.
    public static func loudness(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 36))
    }

    /// Each bar's height for `mode` at `level` (0…1, smoothed) and `time`
    /// in seconds. With Reduce Motion the bars hold their shape and only
    /// their size follows the level.
    public static func heights(_ mode: Mode, level: Double, time: Double, reduceMotion: Bool,
                               count: Int = barCount) -> [Double] {
        let level = min(1, max(0, level))
        return (0 ..< count).map { i in
            let shape = envelope(i, count)
            let height: Double
            switch mode {
            case .agent, .member:
                if reduceMotion {
                    height = floor + (1 - floor) * level * shape
                } else {
                    // Each bar at its own pace, so they move like a voice
                    // rather than in lockstep; a faint shimmer in silence.
                    let wobble = 0.5 + 0.5 * sin(time * speed(i) + Double(i) * 2.4)
                    height = floor + 0.04 * wobble + (1 - floor - 0.04) * level * shape * (0.55 + 0.45 * wobble)
                }
            case .thinking:
                if reduceMotion {
                    height = floor + 0.22 * shape
                } else {
                    let wave = 0.5 + 0.5 * sin(2 * .pi * (0.7 * time - Double(i) / Double(count)))
                    height = floor + 0.08 + 0.3 * wave
                }
            case .breathing:
                let breath = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(2 * .pi * time / 2.6)
                height = floor + (0.1 + 0.18 * breath) * shape
            case .muted:
                height = floor
            case .still:
                height = floor + 0.1 * shape
            }
            return min(1, max(floor, height))
        }
    }

    /// The bars' shape: the middle tallest, the ends about two thirds.
    static func envelope(_ i: Int, _ count: Int) -> Double {
        0.6 + 0.4 * sin(.pi * (Double(i) + 0.5) / Double(count))
    }

    /// A bar's wobble, in radians a second: 1.6 to 2.8 cycles, spread by the
    /// golden ratio so neighbours differ.
    private static func speed(_ i: Int) -> Double {
        let spread = (Double(i) * 0.618_034).truncatingRemainder(dividingBy: 1)
        return 2 * .pi * (1.6 + 1.2 * spread)
    }

    /// One frame's step from the last: the level smoothed, then each bar
    /// eased toward its height, so a change of phase glides. Held by the view
    /// from frame to frame.
    public struct Animator: Sendable {
        public private(set) var bars: [Double]
        private var level: LevelSmoother
        private var mode: Mode?
        private var reduceMotion = false

        public init(count: Int = barCount) {
            bars = Array(repeating: floor, count: count)
            level = .lively()
        }

        /// `heard` is the loudness of the voice the mode shows since the last
        /// frame, `dt` the seconds since it.
        public mutating func step(_ mode: Mode, heard: Double, time: Double, dt: Double,
                                  reduceMotion: Bool) -> [Double] {
            if reduceMotion != self.reduceMotion {
                self.reduceMotion = reduceMotion
                level = reduceMotion ? .calm(from: level.value) : .lively(from: level.value)
            }
            let first = self.mode == nil
            self.mode = mode
            let smoothed = level.update(toward: mode.hearsVoice ? heard : 0, dt: dt)
            let target = TalkWave.heights(mode, level: smoothed, time: time, reduceMotion: reduceMotion, count: bars.count)
            if first {
                bars = target
            } else {
                // Voice bars follow closely; a change of shape glides.
                let tau = reduceMotion ? 0.5 : mode.hearsVoice ? 0.05 : 0.18
                let ease = dt > 0 ? 1 - exp(-dt / tau) : 0
                bars = zip(bars, target).map { $0 + ($1 - $0) * ease }
            }
            return bars
        }
    }
}

/// A level smoothed for the eye: it rises fast with the voice and falls
/// more slowly, so a word lifts the bars at once and they settle after it.
public struct LevelSmoother: Sendable {
    /// Time constants, in seconds, while rising and while falling.
    public let attack: Double
    public let release: Double
    public private(set) var value: Double

    public init(attack: Double, release: Double, value: Double = 0) {
        self.attack = attack
        self.release = release
        self.value = value
    }

    /// The waveform's: a 30 ms rise, a 250 ms fall.
    public static func lively(from value: Double = 0) -> Self { Self(attack: 0.03, release: 0.25, value: value) }
    /// With Reduce Motion: the size changes slowly either way.
    public static func calm(from value: Double = 0) -> Self { Self(attack: 0.6, release: 0.9, value: value) }

    /// Moves `dt` seconds toward `target` and returns where it is.
    @discardableResult
    public mutating func update(toward target: Double, dt: Double) -> Double {
        guard dt > 0 else { return value }
        let tau = target > value ? attack : release
        value += (target - value) * (1 - exp(-dt / tau))
        return value
    }
}
