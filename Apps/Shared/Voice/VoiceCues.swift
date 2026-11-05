import AVFoundation
import Foundation

/// Short tones for voice mode (docs/voice-mode.md, "Sounds"), so it can be
/// used without looking: on, sent, your turn, still thinking, a problem,
/// off. Made here as sine tones and played with `AVAudioPlayer` on voice
/// mode's own session, so the iPhone's silent switch does not hide them
/// (system sounds follow it). Tones, not words: the recogniser does not
/// write them down.
@MainActor
final class VoiceCues {
    enum Cue: CaseIterable {
        /// Voice mode is on and listening.
        case start
        /// What you said went to the agent.
        case sent
        /// Listening again, after a reply was read (or came, unread).
        case ready
        /// The agent is still working, every few seconds while waiting.
        case thinking
        /// A send failed or voice mode stopped on a problem.
        case problem
        /// Voice mode is off.
        case end
    }

    /// Players still sounding; one that ends is let go at the next cue.
    private var playing: [AVAudioPlayer] = []

    func play(_ cue: Cue) {
        guard let player = try? AVAudioPlayer(data: Self.sounds[cue] ?? Data()) else { return }
        playing.removeAll { !$0.isPlaying }
        player.play()
        playing.append(player)
    }

    func stop() {
        playing.forEach { $0.stop() }
        playing = []
    }

    // MARK: Sounds

    /// A note: its pitch (0 is a rest) and length.
    private typealias Note = (hertz: Double, seconds: Double)

    private static let sounds: [Cue: Data] = Dictionary(uniqueKeysWithValues: Cue.allCases.map { ($0, wav(notes($0), volume: volume($0))) })

    private static func notes(_ cue: Cue) -> [Note] {
        switch cue {
        case .start: [(660, 0.09), (0, 0.03), (880, 0.13)]
        case .sent: [(880, 0.07), (0, 0.02), (1175, 0.1)]
        case .ready: [(784, 0.08)]
        case .thinking: [(523, 0.05)]
        case .problem: [(440, 0.12), (0, 0.04), (330, 0.18)]
        case .end: [(880, 0.09), (0, 0.03), (587, 0.14)]
        }
    }

    private static func volume(_ cue: Cue) -> Double {
        switch cue {
        case .thinking: 0.12
        case .ready: 0.2
        default: 0.3
        }
    }

    /// 16-bit mono PCM in a WAV container, each note faded in and out over
    /// 8 ms so it does not click.
    private static func wav(_ notes: [Note], volume: Double) -> Data {
        let rate = 44_100.0
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.seconds * rate)
            let fade = min(Int(0.008 * rate), count / 2)
            for i in 0..<count {
                guard note.hertz > 0 else { samples.append(0); continue }
                let envelope = min(1, Double(min(i, count - 1 - i)) / Double(max(fade, 1)))
                let value = sin(2 * .pi * note.hertz * Double(i) / rate) * volume * envelope
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(rate))
        append(UInt32(rate) * 2)  // bytes per second
        append(UInt16(2))  // bytes per frame
        append(UInt16(16))  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        samples.forEach(append)
        return data
    }
}
