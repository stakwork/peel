import Foundation

/// What a spoken phrase can ask of voice mode (docs/voice-mode.md). The
/// phrases themselves are `VoiceCommandPhrases`, a table, so a language
/// is data and not code.
public enum VoiceCommand: String, Sendable, CaseIterable, Hashable {
    /// Turns voice mode on; heard only while the wake listener is armed.
    case activate
    case deactivate
    /// Sends the draft. Said as the last words of a sentence.
    case send
    /// Throws the draft away. Said as the last words of a sentence.
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
    /// The microphone input is ignored until `unmute`.
    case mute
    case unmute
}

/// The phrases for each command, normalised (lowercase, no punctuation).
/// Every command but `activate` is introduced by the wake word ("peel send"):
/// `phrases` holds what follows the wake word, and the command must be the
/// last words of the utterance, so the text before it is kept as dictation.
/// Without the wake word everything is dictation.
public struct VoiceCommandPhrases: Sendable, Equatable {
    public var phrases: [VoiceCommand: [String]]
    /// Commands (only `activate` uses it) that also fire as the last words
    /// of an utterance; the others are matched whole.
    public var trailing: Set<VoiceCommand>
    /// The wake word that introduces a command.
    public var wakeWord: String
    /// What the recogniser mishears the wake word as; accepted only when a
    /// known command follows.
    public var wakeVariants: [String]

    public init(
        phrases: [VoiceCommand: [String]], trailing: Set<VoiceCommand>,
        wakeWord: String = "peel", wakeVariants: [String] = ["pill", "peal", "feel"]
    ) {
        self.phrases = phrases
        self.trailing = trailing
        self.wakeWord = wakeWord
        self.wakeVariants = wakeVariants
    }

    /// English. Edit here to add a phrase.
    public static let english = VoiceCommandPhrases(
        phrases: [
            // Not prefixed: the opt-in wake listener's.
            .activate: ["hey peel", "voice mode", "start voice mode", "peel start voice mode"],
            // Everything below follows the wake word.
            .deactivate: [
                "end voice mode", "end voice session", "stop voice mode", "exit voice mode", "goodbye",
            ],
            .send: ["send", "send it", "send message", "over"],
            .discard: ["scratch that", "cancel message", "never mind"],
            .stopSpeaking: ["stop"],
            .repeatReply: ["repeat that", "say that again", "repeat"],
            .skip: ["skip"],
            .readAll: ["read it all", "read everything"],
            .stopAgent: ["stop the agent", "cancel the agent"],
            .mute: ["mute"],
            .unmute: ["unmute"],
        ],
        trailing: []
    )

    /// The wake word and its variants.
    var wakeWords: [String] { [wakeWord] + wakeVariants }

    /// What the user says for `command`'s `phrase`, with the wake word.
    public func spoken(_ phrase: String, of command: VoiceCommand) -> String {
        command == .activate ? phrase : "\(wakeWord) \(phrase)"
    }

    /// Every phrase as said, prefixed, for the recogniser's contextual strings.
    public var all: [String] {
        phrases.flatMap { command, list in list.map { spoken($0, of: command) } }
    }
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
    /// The speech is playing.
    case speaking
    /// Muted: only unmute and end voice mode.
    case muted

    public var accepts: Set<VoiceCommand> {
        switch self {
        case .armed: [.activate]
        case .dictating: [.send, .discard, .deactivate, .stopAgent, .repeatReply, .readAll, .mute]
        case .waiting: [.deactivate, .stopAgent, .repeatReply, .readAll, .mute]
        case .speaking: [.stopSpeaking, .repeatReply, .skip, .readAll, .stopAgent, .mute, .deactivate]
        case .muted: [.unmute, .deactivate]
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

    /// The command `transcript` ends with, among those `accepted`: the wake
    /// word and the command phrase are its last words ("add a screen peel
    /// send"). Only `activate` needs no wake word. A bare "send it" is
    /// `.none`: it is dictation. Longer phrases win.
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

        var best: (command: VoiceCommand, count: Int)?
        for command in VoiceCommand.allCases where accepted.contains(command) {
            for phrase in table.phrases[command] ?? [] {
                let words = Self.words(of: phrase)
                guard !words.isEmpty else { continue }
                let candidates: [[String]]
                if command == .activate {
                    candidates = [words]
                } else {
                    candidates = table.wakeWords.map { Self.words(of: $0) + words }
                }
                for candidate in candidates {
                    guard candidate.count <= said.count else { continue }
                    let ending = Array(said.suffix(candidate.count)) == candidate
                    let whole = candidate == said
                    guard whole || (ending && (command != .activate || table.trailing.contains(.activate))) else { continue }
                    if best == nil || candidate.count > best!.count { best = (command, candidate.count) }
                }
            }
        }
        guard let best else { return .none }
        let firstIndex = tokens[said.count - best.count].index
        let before = spoken[..<firstIndex].joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—")))
        return .command(best.command, textBefore: before)
    }

    /// Lowercased words: letters and digits only, so "Send it!" is
    /// ["send", "it"] and "that's" is ["thats"].
    static func words(of text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") })
            .map { $0.filter { $0 != "'" && $0 != "’" } }
            .filter { !$0.isEmpty }
    }
}
