import Foundation

/// A word strut heard, and when it started, in seconds from the recording's start.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval

    public init(text: String, start: TimeInterval) {
        self.text = text
        self.start = start
    }
}

/// One caption on screen: its words, from `start` until `end`.
public struct CaptionCue: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A recording's words as captions (docs/recording.md).
public enum RecordingCaptions {
    /// The most a cue holds: one comfortable line.
    public static let maxCharacters = 42
    /// The longest a cue stays up.
    static let maxSeconds: TimeInterval = 6
    /// A pause this long starts a new cue, and ends the last one's words.
    static let pause: TimeInterval = 1.2
    /// How long the last word of a cue is held when no next word ends it.
    static let lastWordHold: TimeInterval = 0.8
    /// The shortest and longest piece a recording's sound goes to strut in.
    static let shortestPiece: TimeInterval = 8
    static let longestPiece: TimeInterval = 20

    /// The words, in order, as cues no longer than `maxCharacters` or
    /// `maxSeconds`, a new one after each pause or sentence end; each ends
    /// as the next begins, or a moment after its last word, never past
    /// `duration`.
    public static func cues(from words: [TimedWord], duration: TimeInterval) -> [CaptionCue] {
        // Each cue as it grows: when it starts, when its last word starts, its text.
        var groups: [(start: TimeInterval, last: TimeInterval, text: String)] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let group = groups.last,
               group.text.count + 1 + text.count <= maxCharacters,
               word.start - group.start <= maxSeconds,
               word.start - group.last <= pause,
               group.text.last.map({ ".?!".contains($0) }) != true {
                groups[groups.count - 1].last = word.start
                groups[groups.count - 1].text += " " + text
            } else {
                groups.append((word.start, word.start, text))
            }
        }
        return groups.enumerated().compactMap { index, group in
            // Up until the next cue, unless a pause comes first.
            var end = group.last + lastWordHold
            if index + 1 < groups.count, groups[index + 1].start - group.last <= pause { end = groups[index + 1].start }
            end = min(end, duration)
            return end > group.start ? CaptionCue(start: group.start, end: end, text: group.text) : nil
        }
    }

    /// `text`'s words, timed by `heard`'s: strut applies the user's
    /// vocabulary (and its fixer) to the transcript's text only, while each
    /// word's time is as heard ("stack work" at 4.2 s, written "Stakwork").
    /// A word in both keeps its time; one that replaced others takes the
    /// first of theirs; one only added takes the time of the word before it.
    public static func retimed(_ heard: [TimedWord], as text: String) -> [TimedWord] {
        let written = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !written.isEmpty, !heard.isEmpty else { return heard }
        func key(_ word: String) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }
        let changes = written.map(key).difference(from: heard.map { key($0.text) })
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var timed: [TimedWord] = []
        var at = 0
        // The time of heard words dropped since the last word kept.
        var replaced: TimeInterval?
        for (index, word) in written.enumerated() {
            while at < heard.count, removed.contains(at) {
                replaced = replaced ?? heard[at].start
                at += 1
            }
            if inserted.contains(index) {
                let start = replaced ?? timed.last?.start ?? heard[min(at, heard.count - 1)].start
                timed.append(TimedWord(text: word, start: start))
            } else {
                timed.append(TimedWord(text: word, start: heard[at].start))
                at += 1
                replaced = nil
            }
        }
        return timed
    }

    /// Where a recording's sound is cut for strut, from how loud each
    /// `frame`-long stretch of it is: pieces of `shortestPiece` to
    /// `longestPiece`, each cut at the quietest stretch in that span, a
    /// pause between words. Strut puts a piece's words right with the
    /// user's vocabulary as it does a dictation's; a whole recording's
    /// text is too long for its fixer's time, and goes out as heard.
    /// Ranges of frames, end to end.
    public static func pieces(levels: [Float], frame: TimeInterval) -> [Range<Int>] {
        let shortest = Int(shortestPiece / frame), longest = Int(longestPiece / frame)
        var pieces: [Range<Int>] = []
        var start = 0
        while levels.count - start > longest {
            let span = (start + shortest)..<(start + longest)
            let cut = span.min { levels[$0] < levels[$1] } ?? span.upperBound
            pieces.append(start..<cut)
            start = cut
        }
        if start < levels.count { pieces.append(start..<levels.count) }
        return pieces
    }

    /// "Peel Segment 2026-10-28 at 14.03.07": a name Finder sorts by time,
    /// and by which Peel finds its own among the other downloads.
    public static func fileName(at date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "Peel Segment %04d-%02d-%02d at %02d.%02d.%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Whether a file name is one `fileName` made, numbered or not ("… 2.mp4"),
    /// or one from before segments were named so ("Peel Recording …").
    public static func isRecordingName(_ name: String) -> Bool {
        name.wholeMatch(of: /Peel (Segment|Recording) \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}( \d{1,2})?\.mp4/) != nil
    }
}
