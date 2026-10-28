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
/// Checked against the Sphinx apps (sphinx-ios-v2 `AttachmentObject.getFileAndMime`,
/// `TransactionMessage.getMediaType`, which shows audio only when `mediaType`
/// contains "audio/wav"; sphinx-android-v2 `WavRecorder`, 8 kHz mono 16-bit,
/// and `AudioRecorderController.AUDIO_FORMAT_MIME_TYPE`): so the type sent is
/// exactly "audio/wav". The media key and RNCryptor v3 encryption are the
/// same as theirs (`SymmetricEncryptionManager.encryptData`). iOS Sphinx
/// records 44.1 kHz and Android 8 kHz; any PCM WAV plays on both, so we keep
/// 16 kHz: speech quality at a third of 44.1 kHz's size (uncompressed).
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
    /// A recording of this length or shorter was a tap, not a message:
    /// dropped (the Sphinx apps keep only those longer than a second).
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
        return elapsed <= minimumDuration ? .tooShort : .send
    }

    /// The file extension of an audio MIME type the Sphinx apps and others
    /// send (`audio/wav`, `audio/x-wav`, `audio/wave`, `audio/vnd.wave`,
    /// `audio/mpeg`, `audio/mp3`, `audio/mp4`, `audio/x-m4a`, `audio/aac`,
    /// `audio/ogg`, ...), by name rather than by what UTType knows; nil for
    /// anything else.
    public static func fileExtension(audioType: String) -> String? {
        let type = audioType.lowercased()
        guard type.hasPrefix("audio/") else { return nil }
        let subtype = type.dropFirst(6).split(separator: ";").first.map(String.init) ?? ""
        switch subtype {
        case "wav", "x-wav", "wave", "x-pn-wav", "vnd.wave": return "wav"
        case "mpeg", "mp3", "x-mpeg", "mpeg3", "x-mp3": return "mp3"
        case "mp4", "m4a", "x-m4a", "mp4a-latm": return "m4a"
        case "aac", "x-aac": return "aac"
        case "ogg", "opus", "vorbis": return "ogg"
        case "flac", "x-flac": return "flac"
        case "aiff", "x-aiff": return "aiff"
        default: return nil
        }
    }

    /// What a voice row shows.
    public enum RowState: Equatable, Sendable {
        /// Ours, on its way to the memes server.
        case uploading
        /// Downloading or decrypting, or its length not read yet.
        case loading
        /// Could not be fetched or played.
        case failed
        case ready
    }

    public static func rowState(
        uploading: Bool, hasFile: Bool, downloadFailed: Bool, loaded: Bool, unplayable: Bool
    ) -> RowState {
        if uploading && !hasFile { return .uploading }
        if downloadFailed || unplayable { return .failed }
        return hasFile && loaded ? .ready : .loading
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

/// What a WAV file's header says (RIFF, `fmt `, `data`): enough to tell
/// Peel's 16 kHz from iOS Sphinx's 44.1 kHz and Android's 8 kHz, and to
/// know a recording's length when the player cannot say.
public struct WavHeader: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    /// Bytes of audio; the header's claim, or what the file holds when the
    /// header's is zero or too big (a recorder that never came back to fix it).
    public let dataBytes: Int

    public var duration: TimeInterval? {
        let rate = sampleRate * channels * bitsPerSample / 8
        return rate > 0 ? TimeInterval(dataBytes) / TimeInterval(rate) : nil
    }

    public init?(_ data: Data) {
        let b = [UInt8](data.prefix(4096))
        func u32(_ i: Int) -> Int { b[i...].prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        guard b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WAVE".utf8) else { return nil }
        var at = 12
        var format: (Int, Int, Int)?
        while at + 8 <= b.count {
            let id = String(decoding: b[at..<at + 4], as: UTF8.self), size = u32(at + 4)
            if id == "fmt ", at + 24 <= b.count {
                format = (u32(at + 12), u16(at + 10), u16(at + 22))
            } else if id == "data" {
                guard let (rate, channels, bits) = format else { return nil }
                let held = max(0, data.count - (at + 8))
                sampleRate = rate; self.channels = channels; bitsPerSample = bits
                dataBytes = size == 0 || size > held ? held : size
                return
            }
            at += 8 + size + (size & 1)
        }
        return nil
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
