import CryptoKit
import Foundation
import PeelCore

/// Where a correction came from: things the person already does.
public enum SignalKind: String, Sendable, Codable {
    /// A card in the assistant's DM answered No.
    case cardRejected = "card_rejected"
    /// A card's text changed before it was allowed.
    case cardEdited = "card_edited"
    /// Text dictated, then edited by hand.
    case dictationCorrection = "dictation_correction"
    /// "No, not that": the person's next words in the assistant's DM.
    case followUp = "follow_up"
}

/// One correction as it was seen, kept until a check reads it. Only words
/// from the person's own side of the assistant's DM, a card the assistant
/// showed, or text the person dictated: never another chat.
public struct LearnedSignal: Sendable, Equatable, Codable {
    public var kind: SignalKind
    /// The orchestrator turn it is about (a run's id, or the DM message it answered).
    public var turn: String
    public var at: Date
    /// What the assistant did or proposed, or what was typed.
    public var before: String
    /// What the person said or changed it to.
    public var after: String?

    public init(kind: SignalKind, turn: String, at: Date, before: String, after: String? = nil) {
        self.kind = kind
        self.turn = turn
        self.at = at
        self.before = before
        self.after = after
    }
}

/// One thing to learn from, before it is worded as a Cause.
public struct LeafCandidate: Sendable, Equatable, Identifiable {
    /// The same correction, the same id: hash of its kind and turn.
    public var id: String
    public var kind: SignalKind
    public var turn: String
    /// Trimmed, one line, the assistant DM's words only.
    public var excerpt: String
    public var why: String
    public var previousRef: String?
    public var turnAt: Date
    public var confidence: Double
    /// What the assistant did, for the judge to word the habit from.
    public var context: String
}

/// A message of the assistant's DM, as the detector reads it.
public struct DMTurn: Sendable, Equatable {
    public var id: String
    /// True for the person's own message.
    public var fromPerson: Bool
    public var text: String
    public var at: Date
    public init(id: String, fromPerson: Bool, text: String, at: Date) {
        self.id = id
        self.fromPerson = fromPerson
        self.text = text
        self.at = at
    }
}

public enum LearnedDetector {
    public static let excerptLimit = 200
    /// Signals older than this are not read.
    public static let window: TimeInterval = 30 * 24 * 3600

    static let objections = ["not that", "that's not what", "that is not what", "that's wrong", "that is wrong", "that's not right",
                             "not what i asked", "i didn't ask", "i did not ask", "i meant", "that's not it", "don't do that",
                             "do not do that", "stop doing", "try again", "you got it wrong", "wrong one"]

    /// "No, not that"-style words: a no, or one of the objections.
    public static func isObjection(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if objections.contains(where: lower.contains) { return true }
        let words = lower.split(whereSeparator: { !$0.isLetter && $0 != "'" })
        // "No, not that", "no that's wrong", but not "no problem, thanks".
        let after: Set<Substring> = ["not", "that", "that's", "wrong", "don't", "stop", "i", "the", "other", "use", "try"]
        return words.first == "no" && words.count <= 20 && words.dropFirst().first.map(after.contains) == true
    }

    /// The person's objections in the assistant's DM: a message of theirs right
    /// after a reply of the assistant's, which it answers.
    public static func followUps(in turns: [DMTurn]) -> [LearnedSignal] {
        var signals: [LearnedSignal] = []
        for (before, after) in zip(turns, turns.dropFirst()) where !before.fromPerson && after.fromPerson && isObjection(after.text) {
            signals.append(LearnedSignal(kind: .followUp, turn: before.id, at: after.at, before: before.text, after: after.text))
        }
        return signals
    }

    /// A rejected card as a signal; `request` is the device request's id,
    /// `<run>/<hash>`, and the run is the orchestrator's turn.
    public static func rejected(request: String, action: String, content: String?, at: Date) -> LearnedSignal {
        let run = request.split(separator: "/", maxSplits: 1).first.map(String.init) ?? request
        return LearnedSignal(kind: .cardRejected, turn: run, at: at, before: [action, content].compactMap { $0 }.joined(separator: ": "),
                             after: nil)
    }

    /// A card allowed with other words than the assistant wrote.
    public static func edited(request: String, original: String, edited: String, at: Date) -> LearnedSignal {
        let run = request.split(separator: "/", maxSplits: 1).first.map(String.init) ?? request
        return LearnedSignal(kind: .cardEdited, turn: run, at: at, before: original, after: edited)
    }

    /// A dictated text the person then edited.
    public static func dictated(typed: String, edited: String, at: Date) -> LearnedSignal {
        LearnedSignal(kind: .dictationCorrection, turn: "dictation/\(Int(at.timeIntervalSince1970))", at: at, before: typed, after: edited)
    }

    /// The leaves to look at: one per correction, not one already kept
    /// (`known`, the candidate ids already evidence), the newest window only.
    public static func candidates(from signals: [LearnedSignal], known: Set<String> = [], now: Date = .now) -> [LeafCandidate] {
        var seen = known
        var out: [LeafCandidate] = []
        for signal in signals.sorted(by: { $0.at < $1.at }) where now.timeIntervalSince(signal.at) <= window {
            let id = candidateID(kind: signal.kind, turn: signal.turn)
            guard seen.insert(id).inserted else { continue }
            let said = clip(signal.after ?? "")
            let did = clip(signal.before)
            let excerpt: String, why: String, confidence: Double
            switch signal.kind {
            case .cardRejected:
                excerpt = did
                why = "You said no to what your assistant asked to do."
                confidence = 0.8
            case .cardEdited:
                excerpt = said.isEmpty ? did : said
                why = "You changed what your assistant wrote before allowing it."
                confidence = 0.7
            case .dictationCorrection:
                excerpt = said.isEmpty ? did : said
                why = "You fixed text after it was typed for you."
                confidence = 0.5
            case .followUp:
                excerpt = said
                why = "Your next words pushed back on its answer."
                confidence = 0.6
            }
            guard !excerpt.isEmpty else { continue }
            out.append(LeafCandidate(id: id, kind: signal.kind, turn: signal.turn, excerpt: excerpt, why: why,
                                     previousRef: signal.kind == .followUp ? signal.turn : nil, turnAt: signal.at,
                                     confidence: confidence, context: did))
        }
        return out
    }

    public static func candidateID(kind: SignalKind, turn: String) -> String {
        SHA256.hash(data: Data((kind.rawValue + "\n" + turn).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func clip(_ text: String) -> String { TextLine.clean(text, max: excerptLimit) }
}

/// The corrections seen so far, in the profile's folder: one JSON line each,
/// owner-only, the newest `limit` kept. A check reads it; nothing leaves it.
public struct LearnedSignalLog: Sendable {
    public let url: URL
    public static let limit = 200
    public init(url: URL) { self.url = url }

    public func all() -> [LearnedSignal] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(LearnedSignal.self, from: Data($0)) }
    }

    public func append(_ signal: LearnedSignal) {
        var kept = all()
        guard !kept.contains(where: { $0.kind == signal.kind && $0.turn == signal.turn }) else { return }
        kept.append(signal)
        kept = Array(kept.suffix(Self.limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let lines = kept.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
