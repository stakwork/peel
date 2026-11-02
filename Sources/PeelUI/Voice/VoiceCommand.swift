import Foundation

/// What a spoken phrase can ask of voice mode (docs/voice-mode.md). The
/// phrases themselves are `VoiceCommandPhrases`, a table, so a language
/// is data and not code.
public enum VoiceCommand: String, Sendable, CaseIterable, Hashable {
    /// Turns voice mode on; heard only while the wake listener is armed.
    case activate
    case deactivate
    /// Sends the draft. Also said as the last words of a sentence.
    case send
    /// Throws the draft away. Also said as the last words of a sentence.
    case discard
    /// Barge-in: stops the speech now.
    case stopSpeaking
    case repeatReply
    /// Skips to the end of what is being read.
    case skip
    /// Reads the full text of a reply that was only summarised.
    case readAll
    /// Stops the agent's running turn (`AppModel.stopAgentTurn`).
    case stopAgent
}

/// The phrases for each command, normalised (lowercase, no punctuation).
/// `trailing` commands are also recognised as the last words of an
/// utterance, so the text before them is kept as the draft; the rest only
/// as the whole utterance, so a word inside a sentence never fires them.
public struct VoiceCommandPhrases: Sendable, Equatable {
    public var phrases: [VoiceCommand: [String]]
    public var trailing: Set<VoiceCommand>

    public init(phrases: [VoiceCommand: [String]], trailing: Set<VoiceCommand>) {
        self.phrases = phrases
        self.trailing = trailing
    }

    /// English. Edit here to add a phrase.
    public static let english = VoiceCommandPhrases(
        phrases: [
            .activate: ["hey peel", "voice mode", "start voice mode"],
            .deactivate: ["exit voice mode", "stop voice mode", "end voice mode", "goodbye peel"],
            .send: ["send it", "send message", "send that", "over"],
            .discard: ["scratch that", "cancel message", "never mind", "start over"],
            .stopSpeaking: ["stop", "quiet", "stop talking", "pause"],
            .repeatReply: ["say that again", "repeat that", "repeat", "what did it say"],
            .skip: ["skip", "next"],
            .readAll: ["read it all", "read everything", "full version"],
            .stopAgent: ["stop the agent", "cancel the agent", "abort"],
        ],
        trailing: [.send, .discard]
    )

    /// Every phrase, for the recogniser's contextual strings.
    public var all: [String] { phrases.values.flatMap { $0 } }
}

/// What the parser found.
public enum VoiceCommandMatch: Equatable, Sendable {
    case none
    /// `textBefore` is what was said before a trailing command, as spoken
    /// (case and punctuation kept, trimmed); empty for a whole-utterance one.
    case command(VoiceCommand, textBefore: String)
}

/// Where a transcript is heard, which decides the commands that count.
public enum VoiceContext: Sendable {
    /// The wake listener: only "hey peel".
    case armed
    /// Listening for the user's message.
    case dictating
    /// Waiting for the agent.
    case waiting
    /// The speech is playing: only whole-utterance controls.
    case speaking

    public var accepts: Set<VoiceCommand> {
        switch self {
        case .armed: [.activate]
        case .dictating: [.send, .discard, .deactivate, .stopAgent, .repeatReply, .readAll]
        case .waiting: [.deactivate, .stopAgent, .repeatReply, .readAll]
        case .speaking: [.stopSpeaking, .repeatReply, .skip, .readAll, .stopAgent, .deactivate]
        }
    }
}

/// Finds a command in a transcript. Pure.
public struct VoiceCommandParser: Sendable {
    public var table: VoiceCommandPhrases

    public init(table: VoiceCommandPhrases = .english) { self.table = table }

    /// Lowercase, punctuation to spaces, one space between words.
    public static func normalize(_ text: String) -> String {
        words(of: text).joined(separator: " ")
    }

    /// The command `transcript` ends with (`send`, `discard`) or is
    /// (all), among those `accepted`. Longer phrases win over shorter ones
    /// ("start over" is a discard, not an "over").
    public func parse(_ transcript: String, accepting accepted: Set<VoiceCommand>) -> VoiceCommandMatch {
        // Whitespace-separated words as spoken, with their normalised form;
        // a word of pure punctuation has none and is skipped in matching.
        let spoken = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        var tokens: [(index: Int, word: String)] = []
        for (index, raw) in spoken.enumerated() {
            for word in Self.words(of: raw) { tokens.append((index, word)) }
        }
        guard !tokens.isEmpty else { return .none }
        let said = tokens.map(\.word)

        var best: (command: VoiceCommand, words: [String])?
        for command in VoiceCommand.allCases where accepted.contains(command) {
            for phrase in table.phrases[command] ?? [] {
                let words = Self.words(of: phrase)
                guard !words.isEmpty, words.count <= said.count else { continue }
                let whole = words == said
                let ending = table.trailing.contains(command) && Array(said.suffix(words.count)) == words
                guard whole || ending else { continue }
                if best == nil || words.count > best!.words.count { best = (command, words) }
            }
        }
        guard let best else { return .none }
        let firstIndex = tokens[said.count - best.words.count].index
        let before = spoken[..<firstIndex].joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—")))
        return .command(best.command, textBefore: before)
    }

    /// Lowercased words: letters and digits only, so "Send it!" is
    /// ["send", "it"] and "that's" is ["thats"].
    private static func words(of text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") })
            .map { $0.filter { $0 != "'" && $0 != "’" } }
            .filter { !$0.isEmpty }
    }
}
