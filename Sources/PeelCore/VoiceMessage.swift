import Foundation

/// Sphinx-style voice messages, the platform-independent part: what goes up,
/// when a recording counts, and the arithmetic of the recorder's clock and
/// the player's bar. The apps own the microphone and the speaker.
///
/// A voice message is an ordinary attachment (message type 6) with the
/// `audio` media type, sent through `Engine.sendAttachment`: the same memes
/// server sign-in, the same fresh media key (`mediaKey` and
/// `mediaKeyForSelf`) and the same send path for contacts and tribes.
///
/// Format: 16-bit linear PCM WAV, mono, 16 kHz, named `audio.wav` with
/// `mediaType` `audio/wav`, as the Mac app's `AttachmentObject.getFileAndMime`
/// does for a recording (its upload `name` field is `audio`, see
/// `OutgoingFile.field`). WAV is what Sphinx's iOS and Mac apps send and
/// play, `AttachmentKind` already treats `audio/*` as audio, and
/// AVFoundation plays it on both of our platforms. Android's player also
/// handles it, at ~32 KB/s (a minute is under 2 MB, well within the
/// attachment limit). Received audio in other formats (`audio/mp4`,
/// `audio/mpeg`, ogg) is played as it is, by container.
public enum VoiceMessage {
    public static let mediaType = "audio/wav"
    public static let fileName = "audio.wav"
    public static let sampleRate = 16_000
    /// A recording shorter than this was a tap, not a message: dropped.
    public static let minimumDuration: TimeInterval = 1
    /// The recorder stops and sends at this length.
    public static let maximumDuration: TimeInterval = 300
    /// How far (in points) a finger may slide left or up from where the
    /// mic was pressed before releasing cancels.
    public static let cancelDistance: Double = 80

    /// Whether a declared media type is audio, as the official apps tell it.
    public static func isVoice(mediaType: String?) -> Bool {
        AttachmentKind(mediaType: mediaType) == .audio
    }

    /// What releasing the mic does.
    public enum Outcome: Equatable, Sendable {
        case send, cancel, tooShort
    }

    /// Slid away: left or up past `cancelDistance` (translations in points,
    /// negative x is left, negative y is up).
    public static func isCancelling(dx: Double, dy: Double) -> Bool {
        -dx > cancelDistance || -dy > cancelDistance
    }

    /// What to do on release, given how long it recorded and where the
    /// finger is.
    public static func outcome(elapsed: TimeInterval, dx: Double, dy: Double) -> Outcome {
        if isCancelling(dx: dx, dy: dy) { return .cancel }
        return elapsed < minimumDuration ? .tooShort : .send
    }

    /// The recorder's clock: "0:07", "1:02".
    public static func clock(_ seconds: TimeInterval) -> String {
        MediaInfo.format(duration: seconds)
    }

    /// The player's "current / total" label.
    public static func timeLabel(current: TimeInterval, total: TimeInterval?) -> String {
        guard let total, total > 0 else { return clock(current) }
        return "\(clock(current)) / \(clock(total))"
    }

    /// How far along, 0...1; 0 when the length is not known.
    public static func fraction(current: TimeInterval, total: TimeInterval?) -> Double {
        guard let total, total > 0, current.isFinite else { return 0 }
        return min(1, max(0, current / total))
    }

    /// The time a touch at `x` points of a `width`-point bar means.
    public static func seekTime(x: Double, width: Double, total: TimeInterval) -> TimeInterval {
        guard width > 0, total > 0 else { return 0 }
        return min(1, max(0, x / width)) * total
    }
}

/// The recorder's state while the mic is held, with its elapsed time kept
/// by the caller's clock (so it is testable without one).
public struct VoiceRecorderState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, recording, cancelling
    }

    public private(set) var phase: Phase = .idle
    public private(set) var elapsed: TimeInterval = 0

    public init() {}

    public var isRecording: Bool { phase != .idle }
    public var clock: String { VoiceMessage.clock(elapsed) }

    public mutating func begin() {
        phase = .recording
        elapsed = 0
    }

    /// The clock ticked; true when the maximum length is reached.
    @discardableResult
    public mutating func tick(elapsed: TimeInterval) -> Bool {
        guard isRecording else { return false }
        self.elapsed = min(elapsed, VoiceMessage.maximumDuration)
        return elapsed >= VoiceMessage.maximumDuration
    }

    /// The finger moved, `dx` and `dy` from where it pressed.
    public mutating func drag(dx: Double, dy: Double) {
        guard isRecording else { return }
        phase = VoiceMessage.isCancelling(dx: dx, dy: dy) ? .cancelling : .recording
    }

    /// The finger lifted: what to do, and back to idle.
    public mutating func finish(dx: Double, dy: Double) -> VoiceMessage.Outcome {
        guard isRecording else { return .cancel }
        let outcome = VoiceMessage.outcome(elapsed: elapsed, dx: dx, dy: dy)
        phase = .idle
        return outcome
    }

    /// Aborted (the app left, the permission was refused, a call began).
    public mutating func abort() {
        phase = .idle
        elapsed = 0
    }
}

extension Engine {
    /// Sends a recording as a voice message to a contact or a tribe: the
    /// attachment send path, after checking the file really is audio (so a
    /// failed recording never goes up as a broken file). Returns the row's id.
    @discardableResult
    public func sendVoiceMessage(
        _ file: URL, to pubkey: String, replyTo: String? = nil, inThread: String? = nil,
        stored: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int64 {
        let head = try await Task.detached { () -> Data in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            return try handle.read(upToCount: 12) ?? Data()
        }.value
        guard AttachmentKind.verified(head, declared: .audio) == .audio else {
            throw PeelError("the recording could not be read")
        }
        return try await sendAttachment(file, to: pubkey, replyTo: replyTo, inThread: inThread, stored: stored)
    }
}
