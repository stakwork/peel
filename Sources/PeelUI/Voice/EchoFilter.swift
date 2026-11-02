import Foundation

/// Tells the speech Peel reads aloud apart from the user, when the
/// microphone hears the speaker (docs/voice-mode.md, "Echo"). Pure: no
/// audio, the clock is a parameter.
///
/// A transcript is an echo when its normalised words contain a run of three
/// words (the whole transcript if it has fewer) that is a contiguous run of
/// the normalised text being spoken, or spoken in the last few seconds.
/// `isGuarding` says when the filter applies: while speaking, and for a short
/// tail after, when the room still rings.
public struct EchoFilter: Sendable, Equatable {
    /// How long spoken text still counts as heard back.
    public var recentWindow: TimeInterval
    /// How long after the speech ends transcripts are still checked.
    public var tailWindow: TimeInterval
    /// Words of a run that make an echo.
    public static let runLength = 3

    public private(set) var speaking = false
    private var current: [String] = []
    private var recent: [(words: [String], at: Date)] = []
    private var endedAt: Date?

    public init(recentWindow: TimeInterval = 3, tailWindow: TimeInterval = 1.5) {
        self.recentWindow = recentWindow
        self.tailWindow = tailWindow
    }

    public static func == (lhs: EchoFilter, rhs: EchoFilter) -> Bool {
        lhs.speaking == rhs.speaking && lhs.current == rhs.current && lhs.endedAt == rhs.endedAt
            && lhs.recent.map(\.words) == rhs.recent.map(\.words)
    }

    /// `chunks` are about to be spoken (queued after any earlier ones that
    /// are replaced: the controller stops the speaker first).
    public mutating func speechStarted(chunks: [String], now: Date) {
        if speaking { retire(now: now) }
        current = chunks.flatMap(Self.words)
        speaking = true
        endedAt = nil
    }

    /// The speech ended or was stopped.
    public mutating func speechEnded(now: Date) {
        guard speaking else { return }
        retire(now: now)
        speaking = false
        endedAt = now
    }

    /// Forgets everything (voice mode ended).
    public mutating func reset() {
        speaking = false
        current = []
        recent = []
        endedAt = nil
    }

    /// Whether transcripts should be checked now: speaking, or in the tail.
    public func isGuarding(now: Date) -> Bool {
        if speaking { return true }
        guard let endedAt else { return false }
        return now.timeIntervalSince(endedAt) <= tailWindow
    }

    /// `transcript` is what is being (or was just) spoken, not the user.
    /// False when the filter is not guarding.
    public func isEcho(_ transcript: String, now: Date) -> Bool {
        guard isGuarding(now: now) else { return false }
        var spoken = current
        for entry in recent where now.timeIntervalSince(entry.at) <= recentWindow {
            spoken += entry.words
        }
        return Self.matches(Self.words(transcript), in: spoken)
    }

    /// `transcript`, normalised, is wholly a run of the text being spoken now.
    public func currentlyContains(_ transcript: String) -> Bool {
        let words = Self.words(transcript)
        return !words.isEmpty && Self.contains(current, words)
    }

    /// The pure rule: some run of `runLength` words of `words` (all of them
    /// when fewer) is a contiguous run of `spoken`. Nothing said is no echo.
    public static func matches(_ words: [String], in spoken: [String]) -> Bool {
        guard !words.isEmpty, !spoken.isEmpty else { return false }
        let size = min(runLength, words.count)
        for start in 0...(words.count - size) where contains(spoken, Array(words[start..<(start + size)])) {
            return true
        }
        return false
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    private static func words(_ text: String) -> [String] { VoiceCommandParser.words(of: text) }

    private mutating func retire(now: Date) {
        if !current.isEmpty { recent.append((current, now)) }
        current = []
        recent.removeAll { now.timeIntervalSince($0.at) > recentWindow }
    }
}
